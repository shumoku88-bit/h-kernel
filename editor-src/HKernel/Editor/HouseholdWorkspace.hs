-- | Shared Household workspace projections and cross-domain operations.
-- Canonical source order remains owned by the admitted source models. Operations
-- exposed here retain their own domain owners and do not make presentation state
-- semantic authority.
module HKernel.Editor.HouseholdWorkspace
  ( IssueWorkspaceFilter(..)
  , IssueRealizeIntent(..)
  , IssueRealizeError(..)
  , IssueRealizePreview(..)
  , prepareIssueRealize
  , IssueRealizeWriteIntent(..)
  , IssueRealizeWriteError(..)
  , publishIssueRealize
  , publishIssueRealizeUsing
  , homeActualTransactionsOn
  , homeCycleEndDay
  , homeIssuesDueOn
  , homePlannedTransactionsOn
  , issuesForWorkspace
  , workspaceAccounts
  , workspaceIssueCounts
  , workspaceOpenPlansAt
  , workspaceReportBookAt
  , workspaceTransactions
  ) where

import Data.List (sortOn)
import qualified Data.Set as Set
import Data.Time.Calendar (Day, addDays, toModifiedJulianDay)

import HKernel.Account
  ( Account
  , AccountRegistry
  , accountDeclarations
  , declaredAccount
  )
import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntryTransaction
  )
import HKernel.Editor.IssueRealize
  ( IssueRealizeError(..)
  , IssueRealizeIntent(..)
  , IssueRealizePreview(..)
  , prepareIssueRealize
  )
import HKernel.Editor.IssueRealizePublication
  ( IssueRealizeWriteError(..)
  , IssueRealizeWriteIntent(..)
  , publishIssueRealize
  , publishIssueRealizeUsing
  )
import HKernel.Editor.PlanLifecycle (planInactiveIdsAt)
import HKernel.Household.Report (HouseholdReportSurface(..))
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueDue(..)
  , IssueStatus(..)
  , householdIssueDue
  , householdIssueRecordedOn
  , householdIssueStatus
  )
import HKernel.Ledger (Transaction, transactionDate)
import HKernel.Period (Period, periodEndExclusive)
import HKernel.Plan (CommittedOutgoingPlan, committedPlanDate)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanJournal
  , identifiedPlanId
  , planJournalTransactions
  )
import HKernel.Report (ReportBook, reportBookWithPlan)
import HKernel.Report.Config
  ( ReportConfiguration
  , reportConfigurationPlan
  )
import HKernel.Report.CycleAccounts (currentCycleAccountsPeriod)
import HKernel.Report.Plan
  ( ReportPlanError
  , resolveReportPlanWithCurrentCycle
  )

-- | Workspace-local visibility for the Household notebook.
-- Canonical admission keeps every Issue regardless of this presentation choice.
data IssueWorkspaceFilter
  = OpenIssueFilter
  | ClosedIssueFilter
  | AllIssueFilter
  deriving (Eq, Show)

-- | Stable Account choices for delivery adapters. Presentation state such as a
-- selected row belongs to the adapter, not to this projection.
workspaceAccounts :: AccountRegistry -> [Account]
workspaceAccounts = map declaredAccount . accountDeclarations

-- | Newest Actual transactions first for workspace browsing. Canonical source
-- order remains unchanged in the admitted Actual journal.
workspaceTransactions :: ActualJournal -> [Transaction]
workspaceTransactions =
  reverse
    . map actualTransactionEntryTransaction
    . actualJournalTransactionEntries

-- | Open Plan choices at one observation day. A lifecycle-invalid admitted
-- state exposes no mutation targets rather than treating invalid Plans as open.
workspaceOpenPlansAt
  :: Day
  -> PlanJournal
  -> ActualJournal
  -> [IdentifiedPlanTransaction]
workspaceOpenPlansAt observedOn planJournal actualJournal =
  filter isOpen allPlans
  where
    allPlans = planJournalTransactions planJournal
    inactivePlanIds = case planInactiveIdsAt observedOn planJournal actualJournal of
      Right ids -> ids
      Left _ -> Set.fromList (map identifiedPlanId allPlans)
    isOpen identified =
      identifiedPlanId identified `Set.notMember` inactivePlanIds

-- | Report selection is a rebuildable projection of the admitted Actual journal
-- and report configuration. Household-relative queries receive only the
-- already-resolved current Period; delivery adapters do not reimplement cycle
-- discovery.
workspaceReportBookAt
  :: Day
  -> ActualJournal
  -> Maybe Period
  -> ReportConfiguration
  -> Either ReportPlanError ReportBook
workspaceReportBookAt observedOn actualJournal currentCycle reportConfig = do
  plan <- resolveReportPlanWithCurrentCycle
    observedOn
    (actualJournalValue actualJournal)
    currentCycle
    (reportConfigurationPlan reportConfig)
  pure (reportBookWithPlan plan (actualJournalValue actualJournal))

workspaceIssueCounts :: [HouseholdIssue] -> (Int, Int)
workspaceIssueCounts issues =
  ( length (filter ((== Open) . householdIssueStatus) issues)
  , length (filter ((/= Open) . householdIssueStatus) issues)
  )

-- | Select one explicit workspace view and keep newest matters first. Stable
-- sorting preserves source order for ties without mutating issues.tsv.
issuesForWorkspace
  :: IssueWorkspaceFilter
  -> [HouseholdIssue]
  -> [HouseholdIssue]
issuesForWorkspace visibility =
  sortOn issueWorkspaceKey . filter (visibleWith visibility)
  where
    issueWorkspaceKey issue =
      ( statusRank (householdIssueStatus issue)
      , negate (toModifiedJulianDay (householdIssueRecordedOn issue))
      )
    statusRank Open = (0 :: Int)
    statusRank Resolved = 1
    statusRank Dropped = 1

visibleWith :: IssueWorkspaceFilter -> HouseholdIssue -> Bool
visibleWith visibility issue = case visibility of
  OpenIssueFilter -> householdIssueStatus issue == Open
  ClosedIssueFilter -> householdIssueStatus issue /= Open
  AllIssueFilter -> True

-- | Day-local Actual facts for calendar/detail deliveries.
homeActualTransactionsOn :: Day -> ActualJournal -> [Transaction]
homeActualTransactionsOn selectedDay actualJournal =
  [ transaction
  | entry <- actualJournalTransactionEntries actualJournal
  , let transaction = actualTransactionEntryTransaction entry
  , transactionDate transaction == selectedDay
  ]

-- | Day-local outgoing Plan projection from the already admitted Household
-- report surface.
homePlannedTransactionsOn
  :: Day
  -> HouseholdReportSurface
  -> [CommittedOutgoingPlan]
homePlannedTransactionsOn selectedDay surface =
  [ plan
  | plan <- householdPlannedTransactions surface
  , committedPlanDate plan == selectedDay
  ]

-- | Open Issues due on one day. Closed history remains available through the
-- canonical Issue source and explicit workspace filters.
homeIssuesDueOn :: Day -> [HouseholdIssue] -> [HouseholdIssue]
homeIssuesDueOn selectedDay issues =
  [ issue
  | issue <- issues
  , householdIssueStatus issue == Open
  , householdIssueDue issue == DueOn selectedDay
  ]

-- | Human-facing cycle end day for a half-open current cycle.
homeCycleEndDay :: HouseholdReportSurface -> Day
homeCycleEndDay surface =
  addDays (-1)
    (periodEndExclusive
      (currentCycleAccountsPeriod (householdCurrentCycleAccounts surface)))
