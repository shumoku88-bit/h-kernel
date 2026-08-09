{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Main (main) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Graphics.Vty.CrossPlatform (mkVty)
import Lens.Micro (Traversal')
import Lens.Micro.Mtl ()

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import qualified Data.Vector as Vec
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory)

import HKernel.Account (accountName)
import qualified HKernel.Account
import HKernel.Actual.Journal (actualJournalValue)
import HKernel.Application.Config (HouseholdSourcePaths(..), mkHouseholdRoot)
import HKernel.Budget.Policy (budgetPolicyEnvelopeDefinitions)
import HKernel.Engine (mkDateRange)
import qualified HKernel.Editor.TUI.Actual as Actual
import qualified HKernel.Editor.TUI.Maintenance as Maintenance
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , ReportChoice(..)
  , WorkspaceFocus(..)
  , makeWorkspaceContext
  )
import qualified HKernel.Editor.TUI.Plan as Plan
import HKernel.Household.Application
  ( HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Household.Policy
  ( householdAllocationEnvelopes
  , householdCycleIncomeAccount
  , householdPolicyCycle
  , householdUnassignedBudgetAccounts
  )
import qualified HKernel.HouseholdIssue
import qualified HKernel.Ledger
import qualified HKernel.Plan.Journal
import HKernel.Render
  ( renderBalanceSheetWithPresentation
  , renderDailyFlowWithPresentation
  , renderMonthlyAccountsWithPresentation
  , renderProfitAndLossWithPresentation
  , renderRecentTransactionsWithPresentation
  , renderTrialBalanceWithPresentation
  )
import HKernel.Report
  ( balanceSheetAsOf
  , dailyFlow
  , defaultRecentCount
  , monthlyAccounts
  , profitAndLoss
  , recentTransactions
  , reportBook
  , trialBalanceAsOf
  )
import HKernel.Report.Config
  ( reportConfigurationPlan
  , reportConfigurationPresentation
  )
import HKernel.Spike.HouseholdReport.Render
  ( HouseholdReportSection(..)
  , IssueVisibility(..)
  , renderHouseholdReportSection
  , renderReportBookWithHouseholdPresentation
  )

data UIState
  = Workspace
  | ActualFlow (Actual.State AppEvent)
  | PlanFlow (Plan.State AppEvent)
  | MaintenanceFlow (Maintenance.State AppEvent)
  | ReportPicker (L.List Name ReportChoice)
  | ShowWorkspaceReloadFailure

data AppWrapper = AppWrapper AppContext UIState

zoomActualFlow :: Traversal' AppWrapper (Actual.State AppEvent)
zoomActualFlow f (AppWrapper context (ActualFlow state)) =
  (\updated -> AppWrapper context (ActualFlow updated)) <$> f state
zoomActualFlow _ wrapper = pure wrapper

zoomPlanFlow :: Traversal' AppWrapper (Plan.State AppEvent)
zoomPlanFlow f (AppWrapper context (PlanFlow state)) =
  (\updated -> AppWrapper context (PlanFlow updated)) <$> f state
zoomPlanFlow _ wrapper = pure wrapper

zoomMaintenanceFlow :: Traversal' AppWrapper (Maintenance.State AppEvent)
zoomMaintenanceFlow f (AppWrapper context (MaintenanceFlow state)) =
  (\updated -> AppWrapper context (MaintenanceFlow updated)) <$> f state
zoomMaintenanceFlow _ wrapper = pure wrapper

zoomReportPicker :: Traversal' AppWrapper (L.List Name ReportChoice)
zoomReportPicker f (AppWrapper context (ReportPicker choices)) =
  (\updated -> AppWrapper context (ReportPicker updated)) <$> f choices
zoomReportPicker _ wrapper = pure wrapper

zoomWorkspaceAccounts :: Traversal' AppWrapper (L.List Name (Maybe HKernel.Account.Account))
zoomWorkspaceAccounts f (AppWrapper context Workspace) =
  (\updated -> AppWrapper (context { contextWorkspaceAccounts = updated }) Workspace)
    <$> f (contextWorkspaceAccounts context)
zoomWorkspaceAccounts _ wrapper = pure wrapper

zoomWorkspaceList :: Traversal' AppWrapper (L.List Name HKernel.Ledger.Transaction)
zoomWorkspaceList f (AppWrapper context Workspace) =
  (\updated -> AppWrapper (context { contextWorkspaceList = updated }) Workspace)
    <$> f (contextWorkspaceList context)
zoomWorkspaceList _ wrapper = pure wrapper

zoomPlanList :: Traversal' AppWrapper (L.List Name HKernel.Plan.Journal.IdentifiedPlanTransaction)
zoomPlanList f (AppWrapper context Workspace) =
  (\updated -> AppWrapper (context { contextPlanList = updated }) Workspace)
    <$> f (contextPlanList context)
zoomPlanList _ wrapper = pure wrapper

zoomIssueList :: Traversal' AppWrapper (L.List Name HKernel.HouseholdIssue.HouseholdIssue)
zoomIssueList f (AppWrapper context Workspace) =
  (\updated -> AppWrapper (context { contextIssueList = updated }) Workspace)
    <$> f (contextIssueList context)
zoomIssueList _ wrapper = pure wrapper

drawUI :: AppWrapper -> [Widget Name]
drawUI (AppWrapper context Workspace) = [drawHouseholdShell context]
drawUI (AppWrapper context (ActualFlow state)) = [Actual.drawFlow context state]
drawUI (AppWrapper _ (PlanFlow state)) = [Plan.drawFlow state]
drawUI (AppWrapper _ (MaintenanceFlow state)) = [Maintenance.drawFlow state]
drawUI (AppWrapper _ (ReportPicker choices)) = [drawReportPicker choices]
drawUI (AppWrapper _ ShowWorkspaceReloadFailure) =
  [ center
      (borderWithLabel (str "Household reload")
        (padAll 1
          (withAttr (attrName "error")
            (vBox
              [ str "The source write succeeded, but the Household could not reload."
              , str "Restart the TUI before continuing."
              , str " "
              , str "[Esc/Q] Quit"
              ]))))
  ]

drawHouseholdShell :: AppContext -> Widget Name
drawHouseholdShell context =
  vBox [drawSectionTabBar (contextCurrentSection context), drawSectionBody context]

drawSectionTabBar :: HouseholdSection -> Widget Name
drawSectionTabBar currentSection =
  borderWithLabel (str "h-kernel Household")
    (hBox (map renderTab [minBound .. maxBound]))
  where
    renderTab section
      | section == currentSection = withAttr (attrName "activeTab")
          (str (" [" <> sectionNum section <> ": " <> sectionName section <> "] "))
      | otherwise = str ("  " <> sectionNum section <> ": " <> sectionName section <> "  ")
    sectionNum ActualSection = "1"
    sectionNum PlansSection = "2"
    sectionNum BudgetSection = "3"
    sectionNum AccountsSection = "4"
    sectionNum IssuesSection = "5"
    sectionNum ReportsSection = "6"
    sectionNum SettingsSection = "7"
    sectionName ActualSection = "Actual"
    sectionName PlansSection = "Plans"
    sectionName BudgetSection = "Budget"
    sectionName AccountsSection = "Accounts"
    sectionName IssuesSection = "Issues"
    sectionName ReportsSection = "Reports"
    sectionName SettingsSection = "Settings"

drawSectionBody :: AppContext -> Widget Name
drawSectionBody context = case contextCurrentSection context of
  ActualSection -> Actual.drawWorkspace context
  PlansSection -> Plan.drawWorkspace context
  BudgetSection -> Maintenance.drawBudgetWorkspace context
  AccountsSection -> Maintenance.drawAccountsWorkspace context
  IssuesSection -> Maintenance.drawIssuesWorkspace context
  ReportsSection -> drawReportsView context
  SettingsSection -> drawSettingsView context

drawReportsView :: AppContext -> Widget Name
drawReportsView context =
  vBox
    [ borderWithLabel (txt ("Household Report: " <> reportChoiceLabel selected))
        (withVScrollBars OnRight
          (withHScrollBars OnBottom
            (viewport ReportsViewport Both (renderSelectedReport context))))
    , str "[Enter] Choose report   [↑↓←→] Scroll   [PgUp/PgDn] Page   [Shift+←→] Horizontal page"
    , str "[Home/End] Top/Bottom   [r] Next report   [1-7] Switch section   [q] Quit"
    ]
  where
    selected = contextSelectedReport context

drawReportPicker :: L.List Name ReportChoice -> Widget Name
drawReportPicker choices =
  center
    (borderWithLabel (str "Choose Household Report")
      (hLimit 64
        (vLimit 22
          (padAll 1
            (L.renderList renderReportChoice True choices
              <=> str " "
              <=> str "[↑/↓ or j/k] Move   [Enter] Open   [Esc] Back   [Q] Quit")))))

renderReportChoice :: Bool -> ReportChoice -> Widget Name
renderReportChoice selected choice
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = txt (reportChoiceLabel choice)

reportChoiceLabel :: ReportChoice -> Text
reportChoiceLabel choice = case choice of
  ReportTrialBalance -> "Account Balances"
  ReportBalanceSheet -> "Balance Sheet"
  ReportProfitAndLoss -> "Profit & Loss"
  ReportDailyFlow -> "Daily Flow"
  ReportMonthlyAccounts -> "Monthly Accounts"
  ReportHousehold section -> case section of
    HouseholdCycleAccounts -> "Cycle Accounts & Comparison"
    HouseholdDailyTarget -> "Daily Target"
    HouseholdPlannedTransactions -> "Planned Transactions"
    HouseholdIssues visibility -> case visibility of
      OpenIssuesOnly -> "Open Issues"
      AllIssues -> "All Issues"
    HouseholdEnvelopeBacking -> "Envelope & Backing"
  ReportRecentTransactions -> "Recent Actual"
  ReportCombinedBook -> "Full Household Report"

reportChoices :: [ReportChoice]
reportChoices =
  [ ReportTrialBalance
  , ReportBalanceSheet
  , ReportProfitAndLoss
  , ReportDailyFlow
  , ReportMonthlyAccounts
  , ReportHousehold HouseholdCycleAccounts
  , ReportHousehold HouseholdDailyTarget
  , ReportHousehold HouseholdPlannedTransactions
  , ReportHousehold (HouseholdIssues OpenIssuesOnly)
  , ReportHousehold HouseholdEnvelopeBacking
  , ReportRecentTransactions
  , ReportCombinedBook
  ]

renderSelectedReport :: AppContext -> Widget Name
renderSelectedReport context = case contextSelectedReport context of
  ReportTrialBalance ->
    txt (renderTrialBalanceWithPresentation pres (trialBalanceAsOf day journal))
  ReportBalanceSheet ->
    txt (renderBalanceSheetWithPresentation pres (balanceSheetAsOf day journal))
  ReportProfitAndLoss ->
    txt (renderProfitAndLossWithPresentation pres (profitAndLoss (defaultDateRange day) journal))
  ReportDailyFlow ->
    txt (renderDailyFlowWithPresentation pres (dailyFlow (defaultDateRange day) journal))
  ReportMonthlyAccounts ->
    txt (renderMonthlyAccountsWithPresentation pres (monthlyAccounts (defaultDateRange day) journal))
  ReportHousehold section -> case buildHouseholdReportSurfaceFromHousehold day state of
    Left err -> txt ("Report surface error: " <> T.pack (show err))
    Right surface -> txt (renderHouseholdReportSection pres section surface)
  ReportRecentTransactions ->
    txt (renderRecentTransactionsWithPresentation pres
      (recentTransactions defaultRecentCount day journal))
  ReportCombinedBook -> case buildHouseholdReportSurfaceFromHousehold day state of
    Left err -> txt ("Report surface error: " <> T.pack (show err))
    Right surface -> txt
      (renderReportBookWithHouseholdPresentation pres (reportBook (defaultDateRange day) journal) surface)
  where
    state = contextHouseholdState context
    day = contextObservationDay context
    journal = actualJournalValue (householdStateActualJournal state)
    pres = reportConfigurationPresentation (householdStateReportConfig state)
    defaultDateRange value = case mkDateRange value value of
      Right range -> range
      Left _ -> error "unreachable date range"

drawSettingsView :: AppContext -> Widget Name
drawSettingsView context =
  vBox
    [ borderWithLabel (str "Household Settings & Policy")
        (vLimit 18
          (viewport SettingsViewport Vertical
            (vBox
              [ str "=== [budget.toml] Budget Policy ==="
              , str ("Envelopes count: "
                  <> show (length (budgetPolicyEnvelopeDefinitions
                    (householdStateBudgetPolicy state))))
              , str " "
              , str "=== [household.toml] Household Policy ==="
              , txt ("Income Cycle Account: "
                  <> accountName (householdCycleIncomeAccount
                    (householdPolicyCycle (householdStatePolicy state))))
              , txt ("Allocation Envelopes: "
                  <> T.pack (show (householdAllocationEnvelopes
                    (householdStatePolicy state))))
              , txt ("Unassigned Accounts: "
                  <> T.intercalate ", "
                    (map accountName
                      (Set.toAscList (householdUnassignedBudgetAccounts
                        (householdStatePolicy state)))))
              , str " "
              , str "=== [report.toml] Report Configuration ==="
              , txt ("Report Plan: "
                  <> T.pack (show (reportConfigurationPlan
                    (householdStateReportConfig state))))
              , txt ("Presentation: "
                  <> T.pack (show (reportConfigurationPresentation
                    (householdStateReportConfig state))))
              ])))
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    state = contextHouseholdState context

appEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
appEvent event = do
  AppWrapper context state <- get
  case state of
    Workspace -> handleWorkspaceEvent context event
    ActualFlow _ -> handleActualFlow context event
    PlanFlow _ -> handlePlanFlow context event
    MaintenanceFlow _ -> handleMaintenanceFlow context event
    ReportPicker _ -> handleReportPicker context event
    ShowWorkspaceReloadFailure -> handleExitOnlyEvent event

handleWorkspaceEvent :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleWorkspaceEvent context event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey (V.KChar '1') []) -> switchSection ActualSection
  VtyEvent (V.EvKey (V.KChar '2') []) -> switchSection PlansSection
  VtyEvent (V.EvKey (V.KChar '3') []) -> switchSection BudgetSection
  VtyEvent (V.EvKey (V.KChar '4') []) -> switchSection AccountsSection
  VtyEvent (V.EvKey (V.KChar '5') []) -> switchSection IssuesSection
  VtyEvent (V.EvKey (V.KChar '6') []) -> switchSection ReportsSection
  VtyEvent (V.EvKey (V.KChar '7') []) -> switchSection SettingsSection
  VtyEvent (V.EvKey V.KEnter [])
    | inReports -> openReportPicker
  VtyEvent (V.EvKey V.KUp [])
    | inReports -> vScrollBy reportsViewport (-1)
  VtyEvent (V.EvKey V.KDown [])
    | inReports -> vScrollBy reportsViewport 1
  VtyEvent (V.EvKey V.KLeft [V.MShift])
    | inReports -> hScrollPage reportsViewport Up
  VtyEvent (V.EvKey V.KRight [V.MShift])
    | inReports -> hScrollPage reportsViewport Down
  VtyEvent (V.EvKey V.KLeft [])
    | inReports -> hScrollBy reportsViewport (-4)
  VtyEvent (V.EvKey V.KRight [])
    | inReports -> hScrollBy reportsViewport 4
  VtyEvent (V.EvKey V.KPageUp [])
    | inReports -> vScrollPage reportsViewport Up
  VtyEvent (V.EvKey V.KPageDown [])
    | inReports -> vScrollPage reportsViewport Down
  VtyEvent (V.EvKey V.KHome [])
    | inReports -> vScrollToBeginning reportsViewport
  VtyEvent (V.EvKey V.KEnd [])
    | inReports -> vScrollToEnd reportsViewport
  VtyEvent (V.EvKey (V.KChar 't') [])
    | inReports -> selectReport ReportTrialBalance
  VtyEvent (V.EvKey (V.KChar 'b') [])
    | inReports -> selectReport ReportBalanceSheet
  VtyEvent (V.EvKey (V.KChar 'p') [])
    | inReports -> selectReport ReportProfitAndLoss
  VtyEvent (V.EvKey (V.KChar 'd') [])
    | inReports -> selectReport ReportDailyFlow
  VtyEvent (V.EvKey (V.KChar 'm') [])
    | inReports -> selectReport ReportMonthlyAccounts
  VtyEvent (V.EvKey (V.KChar 'c') [])
    | inReports -> selectReport (ReportHousehold HouseholdCycleAccounts)
  VtyEvent (V.EvKey (V.KChar 'T') [])
    | inReports -> selectReport (ReportHousehold HouseholdDailyTarget)
  VtyEvent (V.EvKey (V.KChar 'P') [])
    | inReports -> selectReport (ReportHousehold HouseholdPlannedTransactions)
  VtyEvent (V.EvKey (V.KChar 'E') [])
    | inReports -> selectReport (ReportHousehold HouseholdEnvelopeBacking)
  VtyEvent (V.EvKey (V.KChar 'a') [])
    | inReports -> selectReport ReportRecentTransactions
  VtyEvent (V.EvKey (V.KChar 'h') [])
    | inReports -> selectReport ReportCombinedBook
  VtyEvent (V.EvKey (V.KChar 'r') [])
    | inReports -> selectReport (cycleReport (contextSelectedReport context))
  VtyEvent (V.EvKey (V.KChar 'a') [])
    | inActual -> openActualDaily
  VtyEvent (V.EvKey (V.KChar 'A') [])
    | inActual -> openActualDaily
  VtyEvent (V.EvKey (V.KChar 'm') [])
    | inActual -> openActualMulti
  VtyEvent (V.EvKey (V.KChar 'M') [])
    | inActual -> openActualMulti
  VtyEvent (V.EvKey V.KEnter [])
    | inBudget -> put (AppWrapper context (MaintenanceFlow Maintenance.startBudgetMovement))
  VtyEvent (V.EvKey (V.KChar 'm') [])
    | inBudget -> put (AppWrapper context (MaintenanceFlow Maintenance.startBudgetMovement))
  VtyEvent (V.EvKey (V.KChar 'M') [])
    | inBudget -> put (AppWrapper context (MaintenanceFlow Maintenance.startBudgetMovement))
  VtyEvent (V.EvKey V.KEnter [])
    | inAccounts -> put (AppWrapper context (MaintenanceFlow Maintenance.startAccountAdd))
  VtyEvent (V.EvKey (V.KChar 'a') [])
    | inAccounts -> put (AppWrapper context (MaintenanceFlow Maintenance.startAccountAdd))
  VtyEvent (V.EvKey (V.KChar 'A') [])
    | inAccounts -> put (AppWrapper context (MaintenanceFlow Maintenance.startAccountAdd))
  VtyEvent (V.EvKey (V.KChar 'a') [])
    | inIssues -> put (AppWrapper context (MaintenanceFlow Maintenance.startIssueAdd))
  VtyEvent (V.EvKey (V.KChar 'A') [])
    | inIssues -> put (AppWrapper context (MaintenanceFlow Maintenance.startIssueAdd))
  VtyEvent (V.EvKey V.KEnter [])
    | inIssues -> openSelectedIssue
  VtyEvent (V.EvKey (V.KChar 'a') [])
    | inPlans -> put (AppWrapper context (PlanFlow (Plan.startAdd context)))
  VtyEvent (V.EvKey (V.KChar 'A') [])
    | inPlans -> put (AppWrapper context (PlanFlow (Plan.startAdd context)))
  VtyEvent (V.EvKey (V.KChar 'e') [])
    | inPlans -> openSelectedPlanEdit
  VtyEvent (V.EvKey (V.KChar 'E') [])
    | inPlans -> openSelectedPlanEdit
  VtyEvent (V.EvKey V.KEnter [])
    | inActual && contextWorkspaceFocus context == AccountsFocus ->
        put (AppWrapper (context { contextWorkspaceFocus = TransactionsFocus }) Workspace)
  VtyEvent (V.EvKey V.KEnter [])
    | inActual -> put (AppWrapper context (ActualFlow (Actual.startSelectedReverse context)))
  VtyEvent (V.EvKey V.KEnter [])
    | inPlans -> openSelectedPlan
  VtyEvent (V.EvKey (V.KChar 'c') [])
    | inPlans -> openSelectedPlan
  VtyEvent (V.EvKey (V.KChar 'C') [])
    | inPlans -> openSelectedPlan
  VtyEvent (V.EvKey (V.KChar '\t') [])
    | inActual -> put (AppWrapper (Actual.toggleWorkspaceFocus context) Workspace)
  VtyEvent (V.EvKey V.KLeft [])
    | inActual -> put (AppWrapper (context { contextWorkspaceFocus = AccountsFocus }) Workspace)
  VtyEvent (V.EvKey V.KRight [])
    | inActual -> put (AppWrapper (context { contextWorkspaceFocus = TransactionsFocus }) Workspace)
  VtyEvent vtyEvent
    | inActual -> handleActualListEvent context vtyEvent
  VtyEvent vtyEvent
    | inPlans -> zoom zoomPlanList (L.handleListEventVi L.handleListEvent vtyEvent)
  VtyEvent vtyEvent
    | inIssues -> zoom zoomIssueList (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()
  where
    inActual = contextCurrentSection context == ActualSection
    inPlans = contextCurrentSection context == PlansSection
    inBudget = contextCurrentSection context == BudgetSection
    inAccounts = contextCurrentSection context == AccountsSection
    inIssues = contextCurrentSection context == IssuesSection
    inReports = contextCurrentSection context == ReportsSection
    reportsViewport = viewportScroll ReportsViewport
    switchSection :: HouseholdSection -> EventM Name AppWrapper ()
    switchSection section =
      put (AppWrapper (context { contextCurrentSection = section }) Workspace)
    selectReport :: ReportChoice -> EventM Name AppWrapper ()
    selectReport report = do
      put (AppWrapper (context { contextSelectedReport = report }) Workspace)
      vScrollToBeginning reportsViewport
      hScrollToBeginning reportsViewport
    openReportPicker =
      let picker = L.list ReportPickerList (Vec.fromList reportChoices) 1
          selectedIndex = reportChoiceIndex (contextSelectedReport context)
      in put (AppWrapper context (ReportPicker (L.listMoveTo selectedIndex picker)))
    openActualDaily = put (AppWrapper context (ActualFlow (Actual.startDaily (contextEntryDay context))))
    openActualMulti = put (AppWrapper context (ActualFlow (Actual.startMulti (contextEntryDay context))))
    openSelectedPlan :: EventM Name AppWrapper ()
    openSelectedPlan = case Plan.startSelectedCompletion context of
      Nothing -> pure ()
      Just flow -> put (AppWrapper context (PlanFlow flow))
    openSelectedPlanEdit :: EventM Name AppWrapper ()
    openSelectedPlanEdit = case Plan.startSelectedEdit context of
      Nothing -> pure ()
      Just flow -> put (AppWrapper context (PlanFlow flow))
    openSelectedIssue :: EventM Name AppWrapper ()
    openSelectedIssue = case Maintenance.startSelectedIssueClose context of
      Nothing -> pure ()
      Just flow -> put (AppWrapper context (MaintenanceFlow flow))

reportChoiceIndex :: ReportChoice -> Int
reportChoiceIndex choice = go 0 reportChoices
  where
    go _ [] = 0
    go index (candidate : rest)
      | candidate == choice = index
      | otherwise = go (index + 1) rest

handleReportPicker :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleReportPicker context event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context Workspace)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey V.KEnter []) -> do
    AppWrapper _ state <- get
    case state of
      ReportPicker choices -> case L.listSelectedElement choices of
        Nothing -> put (AppWrapper context Workspace)
        Just (_, choice) -> do
          put (AppWrapper (context { contextSelectedReport = choice }) Workspace)
          let reportsViewport = viewportScroll ReportsViewport
          vScrollToBeginning reportsViewport
          hScrollToBeginning reportsViewport
      _ -> pure ()
  VtyEvent vtyEvent -> zoom zoomReportPicker (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()

handleActualListEvent :: AppContext -> V.Event -> EventM Name AppWrapper ()
handleActualListEvent context vtyEvent = case contextWorkspaceFocus context of
  AccountsFocus -> do
    zoom zoomWorkspaceAccounts (L.handleListEventVi L.handleListEvent vtyEvent)
    AppWrapper updatedContext _ <- get
    put (AppWrapper (Actual.applyWorkspaceAccountFilter updatedContext) Workspace)
  TransactionsFocus ->
    zoom zoomWorkspaceList (L.handleListEventVi L.handleListEvent vtyEvent)

handleActualFlow :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleActualFlow context event = do
  zoom zoomActualFlow (Actual.handleFlowEvent context event)
  AppWrapper currentContext state <- get
  case state of
    ActualFlow Actual.ReturnToWorkspace -> put (AppWrapper currentContext Workspace)
    ActualFlow Actual.QuitRequested -> halt
    ActualFlow (Actual.PublishRequested stickyDay block) -> do
      result <- suspendAndResume' (Actual.publishCandidate context stickyDay block)
      case result of
        Actual.Published freshContext -> put (AppWrapper freshContext Workspace)
        Actual.PublicationFailed outcome ->
          put (AppWrapper context (ActualFlow (Actual.WriteOutcome outcome)))
        Actual.ReloadFailed -> put (AppWrapper context ShowWorkspaceReloadFailure)
    _ -> pure ()

handlePlanFlow :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handlePlanFlow context event = do
  zoom zoomPlanFlow (Plan.handleFlowEvent context event)
  AppWrapper currentContext state <- get
  case state of
    PlanFlow Plan.ReturnToWorkspace -> put (AppWrapper currentContext Workspace)
    PlanFlow Plan.QuitRequested -> halt
    PlanFlow (Plan.PublishRequested request) -> do
      result <- suspendAndResume' (Plan.publishCandidate context request)
      case result of
        Plan.Published freshContext -> put (AppWrapper freshContext Workspace)
        Plan.BudgetSyncPending freshContext planId message ->
          put (AppWrapper freshContext (PlanFlow (Plan.BudgetSyncWarning planId message)))
        Plan.PublicationFailed message ->
          put (AppWrapper context (PlanFlow (Plan.WriteOutcome message)))
        Plan.ReloadFailed -> put (AppWrapper context ShowWorkspaceReloadFailure)
    _ -> pure ()

handleMaintenanceFlow :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleMaintenanceFlow context event = do
  zoom zoomMaintenanceFlow (Maintenance.handleFlowEvent context event)
  AppWrapper currentContext state <- get
  case state of
    MaintenanceFlow Maintenance.ReturnToWorkspace -> put (AppWrapper currentContext Workspace)
    MaintenanceFlow Maintenance.QuitRequested -> halt
    MaintenanceFlow (Maintenance.PublishRequested request) -> do
      result <- suspendAndResume' (Maintenance.publishCandidate context request)
      case result of
        Maintenance.Published freshContext -> put (AppWrapper freshContext Workspace)
        Maintenance.PublicationFailed message ->
          put (AppWrapper context (MaintenanceFlow (Maintenance.WriteOutcome message)))
        Maintenance.ReloadFailed -> put (AppWrapper context ShowWorkspaceReloadFailure)
    _ -> pure ()

handleExitOnlyEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleExitOnlyEvent event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

cycleReport :: ReportChoice -> ReportChoice
cycleReport choice = go reportChoices
  where
    go [] = ReportTrialBalance
    go [_] = ReportTrialBalance
    go (current : next : rest)
      | current == choice = next
      | otherwise = go (next : rest)

app :: App AppWrapper AppEvent Name
app = App
  { appDraw = drawUI
  , appChooseCursor = showFirstCursor
  , appHandleEvent = appEvent
  , appStartEvent = pure ()
  , appAttrMap = const
      (attrMap V.defAttr
        [ (L.listSelectedAttr, V.black `on` V.white)
        , (attrName "activeTab", V.black `on` V.cyan)
        , (attrName "error", fg V.red)
        , (attrName "success", fg V.green)
        , (attrName "warning", fg V.yellow)
        ])
  }

main :: IO ()
main = do
  today <- localDay . zonedTimeToLocalTime <$> getZonedTime
  arguments <- getArgs
  case arguments of
    [path] -> do
      pathIsDirectory <- doesDirectoryExist path
      let rootDir
            | pathIsDirectory = path
            | otherwise = takeDirectory path
          rootPath = if rootDir == "" then "." else rootDir
      root <- case mkHouseholdRoot rootPath of
        Left err -> die ("Invalid household root: " <> show err)
        Right value -> pure value
      householdResult <- loadCanonicalHouseholdWriteSnapshot root
      snapshot <- case householdResult of
        Left errs -> die
          ("Failed to load canonical Household:\n"
            <> unlines (map show (NonEmpty.toList errs)))
        Right value -> pure value
      let state = householdWriteSnapshotState snapshot
          paths = householdStatePaths state
          journalFile = householdActualJournalPath paths
          source = householdWriteSnapshotActualSource snapshot
          planSource = householdWriteSnapshotPlanSource snapshot
          budgetSource = householdWriteSnapshotBudgetSource snapshot
          issuesSource = householdWriteSnapshotIssuesSource snapshot
          context = makeWorkspaceContext False today journalFile source planSource budgetSource issuesSource state
          initialState = AppWrapper context Workspace
          buildVty = mkVty V.defaultConfig
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <household-root-or-actual.journal>"
