module HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , ReportChoice(..)
  , WorkspaceFocus(..)
  , contextAccountsSource
  , contextEntitlementSource
  , contextHouseholdCycleObservation
  , contextHouseholdState
  , contextIssueCounts
  , contextIssueListL
  , contextIssuesSource
  , contextOpenPlanObservation
  , contextPlanListL
  , contextPlanSource
  , contextSource
  , contextSourcePath
  , contextWorkspaceAccountsL
  , contextWorkspaceListL
  , makeWorkspaceContext
  , reloadWorkspaceContext
  , setIssueWorkspaceFilter
  ) where

import qualified Brick.Widgets.List as L
import Data.List.NonEmpty (NonEmpty)
import Lens.Micro (Lens')
import Data.Text (Text)
import Data.Time.Calendar (Day)
import qualified Data.Vector as Vec

import HKernel.Account (Account)
import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Editor.HouseholdWorkspace
  ( IssueWorkspaceFilter(..)
  , issuesForWorkspace
  , workspaceAccounts
  , workspaceIssueCounts
  , workspaceOpenPlanObservationAt
  , workspaceReportBookAt
  , workspaceTransactions
  )
import HKernel.Household.Application
  ( HouseholdLoadError
  , HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Household.Cycle
  ( HouseholdCycleError
  , HouseholdCycleObservation
  , householdCycleCurrentPeriod
  , observeHouseholdCycle
  )
import HKernel.Household.EnvelopeObservation (EnvelopeChangeBaseline)
import HKernel.Household.Policy (householdPolicyCycle)
import HKernel.Household.Report (HouseholdReportSurface)
import HKernel.Household.Report.Render (HouseholdReportSection)
import HKernel.HouseholdIssue (HouseholdIssue)
import HKernel.Ledger (Transaction)
import HKernel.Plan.Journal (IdentifiedPlanTransaction)
import HKernel.Plan.Open (PlanObservationError)
import HKernel.Report (ReportBook)
import HKernel.Report.Plan (ReportPlanError)

data Name
  = DateField
  | DescriptionField
  | FromAccountField
  | ToAccountField
  | AmountField
  | ExpenseDateField
  | ExpenseDescriptionField
  | ExpensePaymentField
  | ExpenseItemCountField
  | ExpenseItemAccountField
  | ExpenseItemAmountField
  | MultiDateField
  | MultiDescriptionField
  | MultiPostingCountField
  | MultiAccountField
  | MultiAmountField
  | AccountCandidate Int
  | ReverseDateField
  | ReverseDescriptionField
  | WorkspaceAccountList
  | WorkspaceTransactionList
  | PlanList
  | PlanActualDateField
  | PlanActualAmountField
  | PlanSuccessorDateField
  | PlanSuccessorAmountField
  | PlanAddDateField
  | PlanAddDescriptionField
  | PlanAddFromField
  | PlanAddToField
  | PlanAddAmountField
  | PlanAddCommodityField
  | PlanEditDateField
  | PlanEditAmountField
  | EntitlementMemoField
  | EntitlementFromField
  | EntitlementToField
  | EntitlementAmountField
  | EntitlementCommodityField
  | AccountNameField
  | AccountTypeField
  | AccountCommodityField
  | IssueList
  | IssueRecordedDateField
  | IssueCategoryField
  | IssueTitleField
  | IssueDueField
  | IssueAmountField
  | IssueCommodityField
  | IssueDetailsField
  | IssueClosedDateField
  | IssueDecisionMemoField
  | ReportPickerList
  | HomeTab
  | CalendarDay Day
  | HomeChangeFrom Day
  | HomeDayViewport
  | EntitlementViewport
  | AccountsViewport
  | IssuesViewport
  | ReportsViewport
  | SettingsViewport
  | SectionTab HouseholdSection
  deriving (Eq, Ord, Show)

data WorkspaceFocus
  = AccountsFocus
  | TransactionsFocus
  deriving (Eq, Show)

data HouseholdSection
  = ActualSection
  | PlansSection
  | EntitlementSection
  | AccountsSection
  | IssuesSection
  | ReportsSection
  | SettingsSection
  deriving (Eq, Ord, Show, Enum, Bounded)

data ReportChoice
  = ReportTrialBalance
  | ReportBalanceSheet
  | ReportProfitAndLoss
  | ReportDailyFlow
  | ReportMonthlyAccounts
  | ReportHousehold HouseholdReportSection
  | ReportEnvelopeChange EnvelopeChangeBaseline
  | ReportEnvelopeChangeFromPreviousObservation Day
  | ReportEnvelopeAlignedPreviousCycle
  | ReportRecentTransactions
  | ReportCombinedBook
  deriving (Eq, Show)

data AppContext = AppContext
  { contextHouseholdSnapshot          :: HouseholdWriteSnapshot
  , contextCurrentSection             :: HouseholdSection
  , contextSelectedReport             :: ReportChoice
  , contextObservationDay             :: Day
  , contextResolvedReportBook         :: Either ReportPlanError ReportBook
  , contextHouseholdReportSurface     :: Either (NonEmpty HouseholdLoadError) HouseholdReportSurface
  , contextEntryDay                   :: Day
  , contextWorkspaceAccounts          :: L.List Name (Maybe Account)
  , contextWorkspaceList              :: L.List Name Transaction
  , contextWorkspaceFocus             :: WorkspaceFocus
  , contextPlanList                   :: L.List Name IdentifiedPlanTransaction
  , contextIssueFilter                :: IssueWorkspaceFilter
  , contextIssueList                  :: L.List Name HouseholdIssue
  }

type AppEvent = ()

contextHouseholdState :: AppContext -> HouseholdState
contextHouseholdState = householdWriteSnapshotState . contextHouseholdSnapshot

-- | Lightweight temporal observations are derived from the admitted Household
-- and the explicit observation coordinate instead of being cached beside UI
-- state. This keeps one semantic owner and prevents stale duplicate values when
-- the context is projected differently by the shell.
contextHouseholdCycleObservation
  :: AppContext
  -> Either (NonEmpty HouseholdCycleError) HouseholdCycleObservation
contextHouseholdCycleObservation context =
  observeHouseholdCycle
    (contextObservationDay context)
    (householdStateActualJournal state)
    (householdStatePlanJournal state)
    (householdPolicyCycle (householdStatePolicy state))
  where
    state = contextHouseholdState context

contextOpenPlanObservation
  :: AppContext
  -> Either (NonEmpty PlanObservationError) [IdentifiedPlanTransaction]
contextOpenPlanObservation context =
  workspaceOpenPlanObservationAt
    (contextObservationDay context)
    (householdStatePlanJournal state)
    (householdStateActualJournal state)
  where
    state = contextHouseholdState context

contextAccountsSource :: AppContext -> Text
contextAccountsSource = householdWriteSnapshotAccountsSource . contextHouseholdSnapshot

contextSource :: AppContext -> Text
contextSource = householdWriteSnapshotActualSource . contextHouseholdSnapshot

contextPlanSource :: AppContext -> Text
contextPlanSource = householdWriteSnapshotPlanSource . contextHouseholdSnapshot

contextEntitlementSource :: AppContext -> Text
contextEntitlementSource = householdWriteSnapshotEntitlementSource . contextHouseholdSnapshot

contextIssuesSource :: AppContext -> Text
contextIssuesSource = householdWriteSnapshotIssuesSource . contextHouseholdSnapshot

contextSourcePath :: AppContext -> FilePath
contextSourcePath =
  householdActualJournalPath . householdStatePaths . contextHouseholdState

makeWorkspaceContext
  :: Day
  -> HouseholdWriteSnapshot
  -> AppContext
makeWorkspaceContext today snapshot =
  AppContext
    { contextHouseholdSnapshot = snapshot
    , contextCurrentSection = ActualSection
    , contextSelectedReport = ReportTrialBalance
    , contextObservationDay = today
    , contextResolvedReportBook =
        workspaceReportBookAt today actualJournal currentCycle reportConfig
    , contextHouseholdReportSurface = householdSurface
    , contextEntryDay = today
    , contextWorkspaceAccounts = L.list WorkspaceAccountList
        (Vec.fromList (Nothing : map Just accounts)) 1
    , contextWorkspaceList = L.list WorkspaceTransactionList
        (Vec.fromList transactions) 1
    , contextWorkspaceFocus = TransactionsFocus
    , contextPlanList = L.list PlanList (Vec.fromList openPlans) 1
    , contextIssueFilter = OpenIssueFilter
    , contextIssueList = L.list IssueList
        (Vec.fromList (issuesForWorkspace OpenIssueFilter issues)) 1
    }
  where
    state = householdWriteSnapshotState snapshot
    actualJournal = householdStateActualJournal state
    planJournal = householdStatePlanJournal state
    reportConfig = householdStateReportConfig state
    issues = householdStateIssues state
    accounts = workspaceAccounts (householdStateAccountsRegistry state)
    transactions = workspaceTransactions actualJournal
    cycleObservation = observeHouseholdCycle
      today
      actualJournal
      planJournal
      (householdPolicyCycle (householdStatePolicy state))
    openPlanObservation = workspaceOpenPlanObservationAt today planJournal actualJournal
    openPlans = either (const []) id openPlanObservation
    householdSurface = buildHouseholdReportSurfaceFromHousehold today state
    currentCycle = either
      (const Nothing)
      (Just . householdCycleCurrentPeriod)
      cycleObservation

reloadWorkspaceContext :: AppContext -> IO (Maybe AppContext)
reloadWorkspaceContext context = do
  let root = householdStateRoot (contextHouseholdState context)
  loadResult <- loadCanonicalHouseholdWriteSnapshot root
  case loadResult of
    Left _ -> pure Nothing
    Right snapshot ->
      pure (Just
        (setIssueWorkspaceFilter
          (contextIssueFilter context)
          ((makeWorkspaceContext
              (contextObservationDay context)
              snapshot)
            { contextEntryDay = contextEntryDay context
            , contextCurrentSection = contextCurrentSection context
            })))

contextWorkspaceAccountsL :: Lens' AppContext (L.List Name (Maybe Account))
contextWorkspaceAccountsL f context =
  (\updated -> context { contextWorkspaceAccounts = updated }) <$> f (contextWorkspaceAccounts context)

contextWorkspaceListL :: Lens' AppContext (L.List Name Transaction)
contextWorkspaceListL f context =
  (\updated -> context { contextWorkspaceList = updated }) <$> f (contextWorkspaceList context)

contextPlanListL :: Lens' AppContext (L.List Name IdentifiedPlanTransaction)
contextPlanListL f context =
  (\updated -> context { contextPlanList = updated }) <$> f (contextPlanList context)

contextIssueCounts :: AppContext -> (Int, Int)
contextIssueCounts = workspaceIssueCounts . householdStateIssues . contextHouseholdState

setIssueWorkspaceFilter :: IssueWorkspaceFilter -> AppContext -> AppContext
setIssueWorkspaceFilter visibility context = context
  { contextIssueFilter = visibility
  , contextIssueList = L.list IssueList
      (Vec.fromList
        (issuesForWorkspace visibility
          (householdStateIssues (contextHouseholdState context)))) 1
  }

contextIssueListL :: Lens' AppContext (L.List Name HouseholdIssue)
contextIssueListL f context =
  (\updated -> context { contextIssueList = updated }) <$> f (contextIssueList context)
