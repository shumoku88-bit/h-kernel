{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , IssueRelationObservation(..)
  , Name(..)
  , ReportChoice(..)
  , WorkspaceFocus(..)
  , WorkspaceReloadFailure(..)
  , contextAccountsSource
  , contextEntitlementSource
  , contextHouseholdCycleObservation
  , contextHouseholdState
  , contextIssueCounts
  , contextIssueListL
  , contextIssueRelationHistory
  , contextIssuesSource
  , contextOpenPlanObservation
  , contextPlanListL
  , contextPlanSource
  , contextSource
  , contextSourcePath
  , contextWorkspaceAccountsL
  , contextWorkspaceListL
  , makeWorkspaceContext
  , refreshIssueRelationObservation
  , reloadWorkspaceContext
  , setIssueWorkspaceFilter
  , workspaceReloadFailureText
  ) where

import qualified Brick.Widgets.List as L
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Lens.Micro (Lens')
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import qualified Data.Vector as Vec
import System.IO.Error (isDoesNotExistError, tryIOError)

import HKernel.Account (Account)
import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Editor.HouseholdWorkspace
  ( IssueWorkspaceFilter(..)
  , admitIssueRelationSource
  , issuesForWorkspace
  , plansForWorkspace
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
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueId
  , IssueRelation(..)
  , IssueRelationEvent
  , issueRelationIssueId
  , issueRelationMeaning
  )
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
  | ReportEnvelopeChangeBetween Day Day
  | ReportEnvelopeAlignedPreviousCycle
  | ReportRecentTransactions
  | ReportCombinedBook
  deriving (Eq, Show)

data WorkspaceReloadFailure
  = HouseholdReloadFailed (NonEmpty HouseholdLoadError)
  | PostReloadValidationFailed Text
  deriving (Show)

workspaceReloadFailureText :: WorkspaceReloadFailure -> Text
workspaceReloadFailureText failure = case failure of
  HouseholdReloadFailed errors ->
    T.pack "Household reload failed: " <> T.pack (show errors)
  PostReloadValidationFailed message -> message

data IssueRelationObservation
  = IssueRelationsAvailable [IssueRelationEvent]
  | IssueRelationsUnavailable Text
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
  , contextIssueRelationObservation   :: IssueRelationObservation
  }

type AppEvent = ()

contextHouseholdState :: AppContext -> HouseholdState
contextHouseholdState = householdWriteSnapshotState . contextHouseholdSnapshot

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

contextIssueRelationHistory
  :: IssueId
  -> AppContext
  -> Either Text ([IssueRelationEvent], [IssueRelationEvent])
contextIssueRelationHistory issueId context = case contextIssueRelationObservation context of
  IssueRelationsUnavailable message -> Left message
  IssueRelationsAvailable relations -> Right
    ( [ relation
      | relation <- relations
      , issueRelationIssueId relation == issueId
      ]
    , [ relation
      | relation <- relations
      , case issueRelationMeaning relation of
          IssueContinuedAs targetIssueId -> targetIssueId == issueId
          _ -> False
      ]
    )

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
    , contextWorkspaceFocus = AccountsFocus
    , contextPlanList = L.list PlanList (Vec.fromList openPlans) 1
    , contextIssueFilter = OpenIssueFilter
    , contextIssueList = L.list IssueList
        (Vec.fromList (issuesForWorkspace OpenIssueFilter issues)) 1
    , contextIssueRelationObservation = IssueRelationsAvailable []
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
    openPlans = either (const []) plansForWorkspace openPlanObservation
    householdSurface = buildHouseholdReportSurfaceFromHousehold today state
    currentCycle = either
      (const Nothing)
      (Just . householdCycleCurrentPeriod)
      cycleObservation

refreshIssueRelationObservation :: AppContext -> IO AppContext
refreshIssueRelationObservation context = do
  result <- tryIOError (TIO.readFile path)
  pure context
    { contextIssueRelationObservation = case result of
        Left err
          | isDoesNotExistError err -> IssueRelationsAvailable []
          | otherwise -> IssueRelationsUnavailable
              ("Relation source read failed: " <> T.pack (show err))
        Right source -> case admitIssueRelationSource
            (householdStateActualJournal state)
            (householdStatePlanJournal state)
            (householdStateIssues state)
            source of
          Left errors -> IssueRelationsUnavailable
            ("Issue relation admission failed: "
              <> T.pack (show (NonEmpty.toList errors)))
          Right relations -> IssueRelationsAvailable relations
    }
  where
    state = contextHouseholdState context
    path = householdIssueRelationsPath (householdStatePaths state)

reloadWorkspaceContext
  :: AppContext
  -> IO (Either WorkspaceReloadFailure AppContext)
reloadWorkspaceContext context = do
  let root = householdStateRoot (contextHouseholdState context)
  loadResult <- loadCanonicalHouseholdWriteSnapshot root
  case loadResult of
    Left errors -> pure (Left (HouseholdReloadFailed errors))
    Right snapshot -> do
      let fresh =
            setIssueWorkspaceFilter
              (contextIssueFilter context)
              ((makeWorkspaceContext
                  (contextObservationDay context)
                  snapshot)
                { contextEntryDay = contextEntryDay context
                , contextCurrentSection = contextCurrentSection context
                })
      Right <$> refreshIssueRelationObservation fresh

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
