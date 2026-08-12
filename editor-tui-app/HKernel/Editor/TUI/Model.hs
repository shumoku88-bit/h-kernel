module HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , ReportChoice(..)
  , WorkspaceFocus(..)
  , contextAccountsSource
  , contextBudgetSource
  , contextHouseholdState
  , contextIssueListL
  , contextIssuesSource
  , contextPlanListL
  , contextPlanSource
  , contextSource
  , contextSourcePath
  , contextWorkspaceAccountsL
  , contextWorkspaceListL
  , makeWorkspaceContext
  , reloadWorkspaceContext
  ) where

import qualified Brick.Widgets.List as L
import Data.List.NonEmpty (NonEmpty)
import Lens.Micro (Lens')
import Data.Text (Text)
import Data.Time.Calendar (Day)
import qualified Data.Vector as Vec

import HKernel.Account
  ( Account
  , accountDeclarations
  , declaredAccount
  )
import HKernel.Actual.Journal
  ( actualJournalCompletionDeclarations
  , actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntryTransaction
  )
import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Household.Application
  ( HouseholdLoadError
  , HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Household.Report (HouseholdReportSurface)
import HKernel.Household.Report.Render (HouseholdReportSection)
import HKernel.HouseholdIssue (HouseholdIssue)
import HKernel.Editor.HouseholdWorkspace (issuesForWorkspace)
import HKernel.Ledger (Transaction)
import HKernel.Plan.Completion (declaredCompletionPlanId)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , identifiedPlanId
  , planJournalTransactions
  )
import HKernel.Report (ReportBook, reportBookWithPlan)
import HKernel.Report.Config (reportConfigurationPlan)
import HKernel.Report.Plan (ReportPlanError, resolveReportPlan)

data Name
  = DateField
  | DescriptionField
  | FromAccountField
  | ToAccountField
  | AmountField
  | MultiDateField
  | MultiDescriptionField
  | MultiPostingCountField
  | MultiAccountField
  | MultiAmountField
  | MultiAccountCandidate Int
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
  | BudgetMemoField
  | BudgetFromField
  | BudgetToField
  | BudgetAmountField
  | BudgetCommodityField
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
  | HomeDayViewport
  | BudgetViewport
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
  | BudgetSection
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
  | ReportRecentTransactions
  | ReportCombinedBook
  deriving (Eq, Show)

data AppContext = AppContext
  { contextHouseholdSnapshot       :: HouseholdWriteSnapshot
  , contextCurrentSection          :: HouseholdSection
  , contextSelectedReport          :: ReportChoice
  , contextObservationDay          :: Day
  , contextResolvedReportBook      :: Either ReportPlanError ReportBook
  , contextHouseholdReportSurface  :: Either (NonEmpty HouseholdLoadError) HouseholdReportSurface
  , contextEntryDay                :: Day
  , contextWorkspaceAccounts       :: L.List Name (Maybe Account)
  , contextWorkspaceList           :: L.List Name Transaction
  , contextWorkspaceFocus          :: WorkspaceFocus
  , contextPlanList                :: L.List Name IdentifiedPlanTransaction
  , contextIssueList               :: L.List Name HouseholdIssue
  }

type AppEvent = ()

contextHouseholdState :: AppContext -> HouseholdState
contextHouseholdState = householdWriteSnapshotState . contextHouseholdSnapshot

contextAccountsSource :: AppContext -> Text
contextAccountsSource = householdWriteSnapshotAccountsSource . contextHouseholdSnapshot

contextSource :: AppContext -> Text
contextSource = householdWriteSnapshotActualSource . contextHouseholdSnapshot

contextPlanSource :: AppContext -> Text
contextPlanSource = householdWriteSnapshotPlanSource . contextHouseholdSnapshot

contextBudgetSource :: AppContext -> Text
contextBudgetSource = householdWriteSnapshotBudgetSource . contextHouseholdSnapshot

contextIssuesSource :: AppContext -> Text
contextIssuesSource = householdWriteSnapshotIssuesSource . contextHouseholdSnapshot

contextSourcePath :: AppContext -> FilePath
contextSourcePath =
  householdActualJournalPath . householdStatePaths . contextHouseholdState

makeWorkspaceContext
  :: Bool
  -> Day
  -> HouseholdWriteSnapshot
  -> AppContext
makeWorkspaceContext _focusLatest today snapshot =
  AppContext
    { contextHouseholdSnapshot = snapshot
    , contextCurrentSection = ActualSection
    , contextSelectedReport = ReportTrialBalance
    , contextObservationDay = today
    , contextResolvedReportBook = resolvedReportBook
    , contextHouseholdReportSurface = householdReportSurface
    , contextEntryDay = today
    , contextWorkspaceAccounts = workspaceAccounts
    , contextWorkspaceList = workspaceList
    , contextWorkspaceFocus = TransactionsFocus
    , contextPlanList = planList
    , contextIssueList = issueList
    }
  where
    state = householdWriteSnapshotState snapshot
    declarations = accountDeclarations (householdStateAccountsRegistry state)
    transactions =
      reverse
        (map actualTransactionEntryTransaction
          (actualJournalTransactionEntries (householdStateActualJournal state)))
    workspaceAccounts = L.list WorkspaceAccountList
      (Vec.fromList (Nothing : map (Just . declaredAccount) declarations)) 1
    workspaceList = L.list WorkspaceTransactionList (Vec.fromList transactions) 1
    closedPlanIds = map declaredCompletionPlanId
      (actualJournalCompletionDeclarations (householdStateActualJournal state))
    openPlans = filter
      (\identified -> identifiedPlanId identified `notElem` closedPlanIds)
      (planJournalTransactions (householdStatePlanJournal state))
    planList = L.list PlanList (Vec.fromList openPlans) 1
    issueList = L.list IssueList
      (Vec.fromList (issuesForWorkspace (householdStateIssues state))) 1
    journal = actualJournalValue (householdStateActualJournal state)
    reportConfig = householdStateReportConfig state
    resolvedReportBook = case resolveReportPlan
        today journal (reportConfigurationPlan reportConfig) of
      Left err -> Left err
      Right plan -> Right (reportBookWithPlan plan journal)
    householdReportSurface = buildHouseholdReportSurfaceFromHousehold today state

reloadWorkspaceContext :: AppContext -> IO (Maybe AppContext)
reloadWorkspaceContext context = do
  let root = householdStateRoot (contextHouseholdState context)
  loadResult <- loadCanonicalHouseholdWriteSnapshot root
  case loadResult of
    Left _ -> pure Nothing
    Right snapshot ->
      pure (Just
        ((makeWorkspaceContext True
            (contextObservationDay context)
            snapshot)
          { contextEntryDay = contextEntryDay context
          , contextCurrentSection = contextCurrentSection context
          }))

contextWorkspaceAccountsL :: Lens' AppContext (L.List Name (Maybe Account))
contextWorkspaceAccountsL f context =
  (\updated -> context { contextWorkspaceAccounts = updated }) <$> f (contextWorkspaceAccounts context)

contextWorkspaceListL :: Lens' AppContext (L.List Name Transaction)
contextWorkspaceListL f context =
  (\updated -> context { contextWorkspaceList = updated }) <$> f (contextWorkspaceList context)

contextPlanListL :: Lens' AppContext (L.List Name IdentifiedPlanTransaction)
contextPlanListL f context =
  (\updated -> context { contextPlanList = updated }) <$> f (contextPlanList context)

contextIssueListL :: Lens' AppContext (L.List Name HouseholdIssue)
contextIssueListL f context =
  (\updated -> context { contextIssueList = updated }) <$> f (contextIssueList context)
