-- | Household workspace projections plus the explicit cross-domain Issue
-- realization entrypoint. Projection logic remains pure; realization semantics
-- live in their dedicated owner and are only re-exported here for delivery
-- compatibility.
module HKernel.Editor.HouseholdWorkspace
  ( IssueWorkspaceFilter(..)
  , IssueRealizeIntent(..)
  , IssueRealizeError(..)
  , IssueRealizePreview(..)
  , IssueRealizeDisplayPreview(..)
  , prepareIssueRealizeDisplayPreview
  , IssueRelationHouseholdAdmissionError(..)
  , admitIssueRelationSource
  , prepareIssueRealize
  , IssueRealizeObservedSources(..)
  , IssueRealizeOperationError(..)
  , publishIssueRealizeFromObservedSources
  , publishIssueRealizeFromObservedSourcesUsing
  , IssueRealizeWriteError(..)
  , HomeActualObservation(..)
  , homeActualObservationOn
  , HomeIssueObservationError(..)
  , HomeIssueObservation(..)
  , homeIssueObservationOn
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
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
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
  ( IssueRealizeIntent(..)
  , IssueRealizeError(..)
  , IssueRealizePreview(..)
  , IssueRealizeDisplayPreview(..)
  , prepareIssueRealizeDisplayPreview
  , IssueRelationHouseholdAdmissionError(..)
  , admitIssueRelationSource
  , prepareIssueRealize
  , IssueRealizeObservedSources(..)
  , IssueRealizeOperationError(..)
  , publishIssueRealizeFromObservedSources
  , publishIssueRealizeFromObservedSourcesUsing
  , IssueRealizeWriteError(..)
  )
import HKernel.Editor.PlanLifecycle (planInactiveIdsAt)
import HKernel.Household.Cycle
  ( HouseholdCycleObservation
  , householdCycleCurrentPeriod
  )
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueClosed(..)
  , IssueDue(..)
  , IssueId
  , IssueStatus(..)
  , householdIssueClosed
  , householdIssueDue
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  )
import HKernel.Ledger (Transaction, transactionDate)
import HKernel.Period (Period, periodEndExclusive)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanJournal
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalTransactions
  )
import HKernel.Report (ReportBook, reportBookWithPlan)
import HKernel.Report.Config
  ( ReportConfiguration
  , reportConfigurationPlan
  )
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

-- | Selected-day Actual knowledge at one explicit observation horizon.
--
-- A future focus coordinate is not an empty Actual day: it is unavailable from
-- the earlier knowledge horizon even when the admitted source already contains
-- future-dated transactions. This keeps source contents from leaking across the
-- observation boundary while preserving available-empty as a distinct result.
data HomeActualObservation
  = HomeActualAvailable [Transaction]
  | HomeActualUnavailable
  deriving (Eq, Show)

homeActualObservationOn
  :: Day
  -> Day
  -> ActualJournal
  -> HomeActualObservation
homeActualObservationOn observedThrough selectedDay actualJournal
  | selectedDay > observedThrough = HomeActualUnavailable
  | otherwise = HomeActualAvailable
      (homeActualTransactionsOn selectedDay actualJournal)

-- | An older closed Issue without closure-time evidence cannot answer whether
-- it was still open at an earlier observation horizon.
data HomeIssueObservationError
  = HomeIssueClosureUndetermined IssueId
  deriving (Eq, Show)

-- | Due-Issue knowledge for one selected day at one observation horizon.
-- Empty and unavailable remain distinct: an invisible future-recorded Issue is
-- simply absent, while a relevant historical Issue with unknown closure time
-- makes the due projection unavailable rather than being guessed open/closed.
data HomeIssueObservation
  = HomeIssueAvailable [HouseholdIssue]
  | HomeIssueUnavailable (NonEmpty HomeIssueObservationError)
  deriving (Eq, Show)

homeIssueObservationOn
  :: Day
  -> Day
  -> [HouseholdIssue]
  -> HomeIssueObservation
homeIssueObservationOn observedThrough selectedDay issues =
  case NonEmpty.nonEmpty uncertain of
    Just errors -> HomeIssueUnavailable errors
    Nothing -> HomeIssueAvailable
      [ issue
      | issue <- relevant
      , issueKnownOpenAt observedThrough issue
      ]
  where
    relevant =
      [ issue
      | issue <- issues
      , householdIssueRecordedOn issue <= observedThrough
      , householdIssueDue issue == DueOn selectedDay
      ]
    uncertain =
      [ HomeIssueClosureUndetermined (householdIssueId issue)
      | issue <- relevant
      , householdIssueStatus issue /= Open
      , householdIssueClosed issue == ClosedUndetermined
      ]

issueKnownOpenAt :: Day -> HouseholdIssue -> Bool
issueKnownOpenAt observedThrough issue = case householdIssueStatus issue of
  Open -> True
  Resolved -> closedAfterObservation
  Dropped -> closedAfterObservation
  where
    closedAfterObservation = case householdIssueClosed issue of
      ClosedOn day -> day > observedThrough
      NotClosed -> False
      ClosedUndetermined -> False

-- | Day-local Actual facts for calendar/detail deliveries.
--
-- This compatibility projection has no knowledge-horizon coordinate. New Home
-- observation code should use 'homeActualObservationOn'.
homeActualTransactionsOn :: Day -> ActualJournal -> [Transaction]
homeActualTransactionsOn selectedDay actualJournal =
  [ transaction
  | entry <- actualJournalTransactionEntries actualJournal
  , let transaction = actualTransactionEntryTransaction entry
  , transactionDate transaction == selectedDay
  ]

-- | Day-local Plan facts from one already role-neutral open-Plan observation.
-- Home is a calendar of household intent, not the narrow payment Report, so it
-- keeps whole Plan transactions and does not require a report-facing shape.
homePlannedTransactionsOn
  :: Day
  -> [IdentifiedPlanTransaction]
  -> [IdentifiedPlanTransaction]
homePlannedTransactionsOn selectedDay plans =
  [ plan
  | plan <- plans
  , transactionDate (identifiedPlanTransaction plan) == selectedDay
  ]

-- | Open Issues due on one day. Closed history remains available through the
-- canonical Issue source and explicit workspace filters.
--
-- This compatibility projection reads current lifecycle state only. New Home
-- observation code should use 'homeIssueObservationOn' when an observation
-- horizon matters.
homeIssuesDueOn :: Day -> [HouseholdIssue] -> [HouseholdIssue]
homeIssuesDueOn selectedDay issues =
  [ issue
  | issue <- issues
  , householdIssueStatus issue == Open
  , householdIssueDue issue == DueOn selectedDay
  ]

-- | Human-facing cycle end day for one independently observed half-open cycle.
homeCycleEndDay :: HouseholdCycleObservation -> Day
homeCycleEndDay observation =
  addDays (-1)
    (periodEndExclusive (householdCycleCurrentPeriod observation))
