module HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , ReportChoice(..)
  , WorkspaceFocus(..)
  , makeWorkspaceContext
  , reloadWorkspaceContext
  ) where

import qualified Brick.Widgets.List as L
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
  , actualTransactionEntryTransaction
  )
import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Household.Application
  ( HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.HouseholdIssue (HouseholdIssue)
import HKernel.Ledger (Transaction)
import HKernel.Plan.Completion (declaredCompletionPlanId)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , identifiedPlanId
  , planJournalTransactions
  )
import HKernel.Spike.HouseholdReport.Render (HouseholdReportSection)

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
  | ReverseDateField
  | ReverseDescriptionField
  | WorkspaceAccountList
  | WorkspaceTransactionList
  | PlanList
  | PlanActualDateField
  | PlanActualAmountField
  | PlanSuccessorDateField
  | PlanSuccessorAmountField
  | BudgetMemoField
  | BudgetFromField
  | BudgetToField
  | BudgetAmountField
  | BudgetCommodityField
  | AccountNameField
  | AccountTypeField
  | AccountCommodityField
  | IssueList
  | IssueCategoryField
  | IssueTitleField
  | IssueAmountField
  | IssueCommodityField
  | IssueDetailsField
  | IssueDecisionMemoField
  | BudgetViewport
  | AccountsViewport
  | IssuesViewport
  | ReportsViewport
  | SettingsViewport
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
  { contextHouseholdState       :: HouseholdState
  , contextCurrentSection       :: HouseholdSection
  , contextSelectedReport       :: ReportChoice
  , contextObservationDay       :: Day
  , contextEntryDay             :: Day
  , contextWorkspaceAccounts    :: L.List Name (Maybe Account)
  , contextWorkspaceList        :: L.List Name Transaction
  , contextWorkspaceFocus       :: WorkspaceFocus
  , contextPlanList             :: L.List Name IdentifiedPlanTransaction
  , contextIssueList            :: L.List Name HouseholdIssue
  , contextSourcePath           :: FilePath
  , contextSource               :: Text
  , contextPlanSource           :: Text
  , contextBudgetSource         :: Text
  , contextIssuesSource         :: Text
  }

type AppEvent = ()

makeWorkspaceContext
  :: Bool
  -> Day
  -> FilePath
  -> Text
  -> Text
  -> Text
  -> Text
  -> HouseholdState
  -> AppContext
makeWorkspaceContext focusLatest today journalFile source planSource budgetSource issuesSource state =
  AppContext
    { contextHouseholdState = state
    , contextCurrentSection = ActualSection
    , contextSelectedReport = ReportTrialBalance
    , contextObservationDay = today
    , contextEntryDay = today
    , contextWorkspaceAccounts = workspaceAccounts
    , contextWorkspaceList = workspaceList
    , contextWorkspaceFocus = TransactionsFocus
    , contextPlanList = planList
    , contextIssueList = issueList
    , contextSourcePath = journalFile
    , contextSource = source
    , contextPlanSource = planSource
    , contextBudgetSource = budgetSource
    , contextIssuesSource = issuesSource
    }
  where
    declarations = accountDeclarations (householdStateAccountsRegistry state)
    transactions =
      map actualTransactionEntryTransaction
        (actualJournalTransactionEntries (householdStateActualJournal state))
    workspaceAccounts = L.list WorkspaceAccountList
      (Vec.fromList (Nothing : map (Just . declaredAccount) declarations)) 1
    initialWorkspaceList = L.list WorkspaceTransactionList (Vec.fromList transactions) 1
    workspaceList
      | focusLatest && not (null transactions) =
          L.listMoveTo (length transactions - 1) initialWorkspaceList
      | otherwise = initialWorkspaceList
    closedPlanIds = map declaredCompletionPlanId
      (actualJournalCompletionDeclarations (householdStateActualJournal state))
    openPlans = filter
      (\identified -> identifiedPlanId identified `notElem` closedPlanIds)
      (planJournalTransactions (householdStatePlanJournal state))
    planList = L.list PlanList (Vec.fromList openPlans) 1
    issueList = L.list IssueList (Vec.fromList (householdStateIssues state)) 1

reloadWorkspaceContext :: AppContext -> IO (Maybe AppContext)
reloadWorkspaceContext context = do
  let root = householdStateRoot (contextHouseholdState context)
  loadResult <- loadCanonicalHouseholdWriteSnapshot root
  case loadResult of
    Left _ -> pure Nothing
    Right snapshot -> do
      let freshState = householdWriteSnapshotState snapshot
          freshPaths = householdStatePaths freshState
          actualPath = householdActualJournalPath freshPaths
          freshActual = householdWriteSnapshotActualSource snapshot
          freshPlan = householdWriteSnapshotPlanSource snapshot
          freshBudget = householdWriteSnapshotBudgetSource snapshot
          freshIssues = householdWriteSnapshotIssuesSource snapshot
      pure (Just
        ((makeWorkspaceContext True
            (contextObservationDay context)
            actualPath freshActual freshPlan freshBudget freshIssues freshState)
          { contextEntryDay = contextEntryDay context
          , contextCurrentSection = contextCurrentSection context
          }))
