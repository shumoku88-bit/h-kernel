{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Graphics.Vty.CrossPlatform (mkVty)
import Lens.Micro (Lens', Traversal')
import Lens.Micro.Mtl ()

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import qualified Data.Vector as Vec
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory)

import HKernel.Account (accountName)
import HKernel.Actual.Journal (actualJournalCompletionDeclarations)
import HKernel.Application.Config (mkHouseholdRoot)
import HKernel.Budget.Policy (budgetPolicyEnvelopeDefinitions)
import qualified HKernel.Editor.TUI.Actual as Actual
import qualified HKernel.Editor.TUI.Maintenance as Maintenance
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , ReportChoice
  , contextHouseholdState
  , makeWorkspaceContext
  )
import qualified HKernel.Editor.TUI.Plan as Plan
import qualified HKernel.Editor.TUI.Report as Report
import HKernel.Household.Application
  ( HouseholdState(..)
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Household.Policy
  ( householdAllocationEnvelopes
  , householdCycleIncomeAccount
  , householdPolicyCycle
  , householdUnassignedBudgetAccounts
  )
import qualified HKernel.Ledger
import HKernel.Plan (planIdText)
import HKernel.Plan.Completion (declaredCompletionPlanId)
import qualified HKernel.Plan.Journal
import HKernel.Report.Config
  ( reportConfigurationPlan
  , reportConfigurationPresentation
  )

data UIState
  = Workspace
  | ActualFlow (Actual.State AppEvent)
  | PlanFlow (Plan.State AppEvent)
  | MaintenanceFlow (Maintenance.State AppEvent)
  | ReportPicker (L.List Name ReportChoice)
  | PlanBudgetSyncPicker (L.List Name HKernel.Plan.Journal.IdentifiedPlanTransaction)
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

zoomPlanBudgetSyncPicker
  :: Traversal' AppWrapper (L.List Name HKernel.Plan.Journal.IdentifiedPlanTransaction)
zoomPlanBudgetSyncPicker f (AppWrapper context (PlanBudgetSyncPicker plans)) =
  (\updated -> AppWrapper context (PlanBudgetSyncPicker updated)) <$> f plans
zoomPlanBudgetSyncPicker _ wrapper = pure wrapper

zoomContext :: Lens' AppWrapper AppContext
zoomContext f (AppWrapper context state) =
  (\updated -> AppWrapper updated state) <$> f context

drawUI :: AppWrapper -> [Widget Name]
drawUI (AppWrapper context Workspace) = [drawHouseholdShell context]
drawUI (AppWrapper context (ActualFlow state)) = [Actual.drawFlow context state]
drawUI (AppWrapper _ (PlanFlow state)) = [Plan.drawFlow state]
drawUI (AppWrapper _ (MaintenanceFlow state)) = [Maintenance.drawFlow state]
drawUI (AppWrapper _ (ReportPicker choices)) = [Report.drawPicker choices]
drawUI (AppWrapper _ (PlanBudgetSyncPicker plans)) = [drawPlanBudgetSyncPicker plans]
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
    renderTab section = clickable (SectionTab section) rendered
      where
        rendered
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
  PlansSection ->
    Plan.drawWorkspace context
      <=> str "[B] Retry Budget sync for a completed Plan"
  BudgetSection -> Maintenance.drawBudgetWorkspace context
  AccountsSection -> Maintenance.drawAccountsWorkspace context
  IssuesSection -> Maintenance.drawIssuesWorkspace context
  ReportsSection -> Report.drawWorkspace context
  SettingsSection -> drawSettingsView context

drawPlanBudgetSyncPicker
  :: L.List Name HKernel.Plan.Journal.IdentifiedPlanTransaction
  -> Widget Name
drawPlanBudgetSyncPicker plans =
  center
    (borderWithLabel (str "Retry completed Plan Budget sync")
      (hLimit 86
        (vLimit 24
          (padAll 1
            ( L.renderList renderCompletedPlan True plans
              <=> str " "
              <=> str "[wheel/↑/↓ or j/k] Move   [Enter] Retry sync   [Esc] Back   [Q] Quit")))))

renderCompletedPlan :: Bool -> HKernel.Plan.Journal.IdentifiedPlanTransaction -> Widget Name
renderCompletedPlan selected identified
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    transaction = HKernel.Plan.Journal.identifiedPlanTransaction identified
    row = txt
      ( T.pack (show (HKernel.Ledger.transactionDate transaction))
        <> "  " <> HKernel.Ledger.transactionDescription transaction
        <> "  [" <> planIdText (HKernel.Plan.Journal.identifiedPlanId identified) <> "]"
      )

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
    , str "[wheel] Scroll   [1-7] Switch section   [q] Quit"
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
    PlanBudgetSyncPicker _ -> handlePlanBudgetSyncPicker context event
    ShowWorkspaceReloadFailure -> handleExitOnlyEvent event

handleWorkspaceEvent :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleWorkspaceEvent context event = case event of
  MouseDown (SectionTab section) V.BLeft _ _ -> switchSection section
  MouseDown SettingsViewport V.BScrollUp _ _
    | inSettings -> vScrollBy (viewportScroll SettingsViewport) (-3)
  MouseDown SettingsViewport V.BScrollDown _ _
    | inSettings -> vScrollBy (viewportScroll SettingsViewport) 3
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
  _ -> case contextCurrentSection context of
    ActualSection -> do
      action <- zoom zoomContext (Actual.handleWorkspaceEvent event)
      AppWrapper currentContext _ <- get
      case action of
        Actual.MaintainContext -> pure ()
        Actual.OpenDaily -> put (AppWrapper currentContext (ActualFlow (Actual.startDaily (contextEntryDay currentContext))))
        Actual.OpenIncome -> put (AppWrapper currentContext (ActualFlow (Actual.startIncome (contextEntryDay currentContext))))
        Actual.OpenMulti -> put (AppWrapper currentContext (ActualFlow (Actual.startMulti (contextEntryDay currentContext))))
        Actual.OpenReverse -> put (AppWrapper currentContext (ActualFlow (Actual.startSelectedReverse currentContext)))
    PlansSection -> do
      action <- zoom zoomContext (Plan.handleWorkspaceEvent event)
      AppWrapper currentContext _ <- get
      case action of
        Plan.MaintainContext -> pure ()
        Plan.StartFlow flow -> put (AppWrapper currentContext (PlanFlow flow))
        Plan.OpenBudgetSyncPicker -> openPlanBudgetSyncPicker
    BudgetSection -> do
      action <- Maintenance.handleBudgetWorkspaceEvent event
      case action of
        Maintenance.BudgetActionMaintain -> pure ()
        Maintenance.BudgetActionStartMovement ->
          put (AppWrapper context (MaintenanceFlow Maintenance.startBudgetMovement))
    AccountsSection -> do
      action <- Maintenance.handleAccountsWorkspaceEvent event
      case action of
        Maintenance.AccountsActionMaintain -> pure ()
        Maintenance.AccountsActionStartAdd ->
          put (AppWrapper context (MaintenanceFlow Maintenance.startAccountAdd))
    IssuesSection -> do
      action <- zoom zoomContext (Maintenance.handleIssuesWorkspaceEvent event)
      AppWrapper currentContext _ <- get
      case action of
        Maintenance.IssuesActionMaintain -> pure ()
        Maintenance.IssuesActionStartAdd ->
          put (AppWrapper currentContext (MaintenanceFlow Maintenance.startIssueAdd))
        Maintenance.IssuesActionStartClose flow ->
          put (AppWrapper currentContext (MaintenanceFlow flow))
    ReportsSection -> do
      action <- zoom zoomContext (Report.handleWorkspaceEvent event)
      case action of
        Report.MaintainContext -> pure ()
        Report.OpenPicker -> openReportPicker
    SettingsSection -> pure ()
  where
    inSettings = contextCurrentSection context == SettingsSection
    switchSection :: HouseholdSection -> EventM Name AppWrapper ()
    switchSection section =
      put (AppWrapper (context { contextCurrentSection = section }) Workspace)
    openReportPicker =
      let picker = L.list ReportPickerList (Vec.fromList Report.reportChoices) 1
          selectedIndex = Report.reportChoiceIndex (contextSelectedReport context)
      in put (AppWrapper context (ReportPicker (L.listMoveTo selectedIndex picker)))
    openPlanBudgetSyncPicker =
      let state = contextHouseholdState context
          completedIds = map declaredCompletionPlanId
            (actualJournalCompletionDeclarations (householdStateActualJournal state))
          completedPlans = filter
            (\identified -> HKernel.Plan.Journal.identifiedPlanId identified `elem` completedIds)
            (HKernel.Plan.Journal.planJournalTransactions (householdStatePlanJournal state))
      in case completedPlans of
          [] -> put (AppWrapper context
            (PlanFlow (Plan.WriteOutcome "No completed Plans are available for Budget sync retry.")))
          _ -> put (AppWrapper context
            (PlanBudgetSyncPicker (L.list PlanList (Vec.fromList completedPlans) 1)))

moveListSelection
  :: Traversal' AppWrapper (L.List Name a)
  -> Int
  -> EventM Name AppWrapper ()
moveListSelection traversal row =
  zoom traversal $ do
    items <- get
    put (L.listMoveTo row items)

handleReportPicker :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleReportPicker context event = case event of
  MouseDown ReportPickerList V.BScrollUp _ _ ->
    zoom zoomReportPicker (L.handleListEvent (V.EvKey V.KUp []))
  MouseDown ReportPickerList V.BScrollDown _ _ ->
    zoom zoomReportPicker (L.handleListEvent (V.EvKey V.KDown []))
  MouseDown ReportPickerList V.BLeft _ (Location (_, row)) ->
    case Report.reportChoiceAt row of
      Nothing -> pure ()
      Just choice -> openChoice choice
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context Workspace)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey V.KEnter []) -> do
    AppWrapper _ state <- get
    case state of
      ReportPicker choices -> case L.listSelectedElement choices of
        Nothing -> put (AppWrapper context Workspace)
        Just (_, choice) -> openChoice choice
      _ -> pure ()
  VtyEvent vtyEvent -> zoom zoomReportPicker (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()
  where
    openChoice choice = do
      put (AppWrapper (context { contextSelectedReport = choice }) Workspace)
      let reportsViewport = viewportScroll ReportsViewport
      vScrollToBeginning reportsViewport
      hScrollToBeginning reportsViewport

handlePlanBudgetSyncPicker :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handlePlanBudgetSyncPicker context event = case event of
  MouseDown PlanList V.BScrollUp _ _ ->
    zoom zoomPlanBudgetSyncPicker (L.handleListEvent (V.EvKey V.KUp []))
  MouseDown PlanList V.BScrollDown _ _ ->
    zoom zoomPlanBudgetSyncPicker (L.handleListEvent (V.EvKey V.KDown []))
  MouseDown PlanList V.BLeft _ (Location (_, row)) ->
    moveListSelection zoomPlanBudgetSyncPicker row
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context Workspace)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey V.KEnter []) -> do
    AppWrapper _ state <- get
    case state of
      PlanBudgetSyncPicker plans -> case L.listSelectedElement plans of
        Nothing -> put (AppWrapper context Workspace)
        Just (_, identified) ->
          publishPlanRequest context
            (Plan.PublishBudgetSync (HKernel.Plan.Journal.identifiedPlanId identified))
      _ -> pure ()
  VtyEvent vtyEvent ->
    zoom zoomPlanBudgetSyncPicker (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()

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
    PlanFlow (Plan.PublishRequested request) -> publishPlanRequest context request
    _ -> pure ()

publishPlanRequest :: AppContext -> Plan.PublishRequest -> EventM Name AppWrapper ()
publishPlanRequest context request = do
  result <- suspendAndResume' (Plan.publishCandidate context request)
  case result of
    Plan.Published freshContext -> put (AppWrapper freshContext Workspace)
    Plan.BudgetSyncPending freshContext planId message ->
      put (AppWrapper freshContext (PlanFlow (Plan.BudgetSyncWarning planId message)))
    Plan.PublicationFailed message ->
      put (AppWrapper context (PlanFlow (Plan.WriteOutcome message)))
    Plan.ReloadFailed -> put (AppWrapper context ShowWorkspaceReloadFailure)

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
      let context = makeWorkspaceContext False today snapshot
          initialState = AppWrapper context Workspace
          buildVty = do
            vty <- mkVty V.defaultConfig
            V.setMode (V.outputIface vty) V.Mouse True
            pure vty
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <household-root-or-actual.journal>"
