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
import Data.Time.Calendar (Day, addDays)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import qualified Data.Vector as Vec
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory)

import HKernel.Account (accountName)
import HKernel.Application.Config (mkHouseholdRoot)
import qualified HKernel.Editor.TUI.Actual as Actual
import qualified HKernel.Editor.TUI.Home as Home
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
  , householdEnvelopeOrder
  , householdPolicyCycle
  , householdUnassignedBudgetAccounts
  )
import HKernel.Report.Config
  ( reportConfigurationPlan
  , reportConfigurationPresentation
  )

data ActualReturn
  = ActualReturnWorkspace
  | ActualReturnHome Day

data UIState
  = Home Day
  | Workspace
  | ActualFlow ActualReturn (Actual.State AppEvent)
  | PlanFlow (Plan.State AppEvent)
  | MaintenanceFlow (Maintenance.State AppEvent)
  | ReportPicker (L.List Name ReportChoice)
  | ShowWorkspaceReloadFailure

data AppWrapper = AppWrapper AppContext UIState

zoomActualFlow :: Traversal' AppWrapper (Actual.State AppEvent)
zoomActualFlow f (AppWrapper context (ActualFlow returnTarget state)) =
  (\updated -> AppWrapper context (ActualFlow returnTarget updated)) <$> f state
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

zoomContext :: Lens' AppWrapper AppContext
zoomContext f (AppWrapper context state) =
  (\updated -> AppWrapper updated state) <$> f context

drawUI :: AppWrapper -> [Widget Name]
drawUI (AppWrapper context (Home selectedDay)) =
  [drawHomeShell context selectedDay]
drawUI (AppWrapper context Workspace) = [drawHouseholdShell context]
drawUI (AppWrapper context (ActualFlow _ state)) = [Actual.drawFlow context state]
drawUI (AppWrapper _ (PlanFlow state)) = [Plan.drawFlow state]
drawUI (AppWrapper _ (MaintenanceFlow state)) = [Maintenance.drawFlow state]
drawUI (AppWrapper _ (ReportPicker choices)) = [Report.drawPicker choices]
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

drawHomeShell :: AppContext -> Day -> Widget Name
drawHomeShell context selectedDay =
  vBox [drawNavigationBar Nothing, Home.draw context selectedDay]

drawHouseholdShell :: AppContext -> Widget Name
drawHouseholdShell context =
  vBox
    [ drawNavigationBar (Just (contextCurrentSection context))
    , drawSectionBody context
    ]

drawNavigationBar :: Maybe HouseholdSection -> Widget Name
drawNavigationBar currentSection =
  borderWithLabel (str "h-kernel Household")
    (hBox (homeTab : map renderTab [minBound .. maxBound]))
  where
    homeTab = clickable HomeTab renderedHome
    renderedHome = case currentSection of
      Nothing -> withAttr (attrName "activeTab") (str " [Home] ")
      Just _ -> str "  Home  "
    renderTab section = clickable (SectionTab section) rendered
      where
        rendered
          | Just section == currentSection = withAttr (attrName "activeTab")
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
  ReportsSection -> Report.drawWorkspace context
  SettingsSection -> drawSettingsView context

drawSettingsView :: AppContext -> Widget Name
drawSettingsView context =
  vBox
    [ borderWithLabel (str "Household Settings & Policy")
        (vLimit 18
          (viewport SettingsViewport Vertical
            (vBox
              [ str "=== [budget.toml] Envelope Policy ==="
              , str ("Envelopes count: "
                  <> show (length (householdEnvelopeOrder
                    (householdStatePolicy state))))
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
    , str "[wheel] Scroll   [h] Home   [1-7] Switch section   [q] Quit"
    ]
  where
    state = contextHouseholdState context

appEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
appEvent event = do
  AppWrapper context state <- get
  case state of
    Home selectedDay -> handleHomeEvent context selectedDay event
    Workspace -> handleWorkspaceEvent context event
    ActualFlow returnTarget _ -> handleActualFlow context returnTarget event
    PlanFlow _ -> handlePlanFlow context event
    MaintenanceFlow _ -> handleMaintenanceFlow context event
    ReportPicker _ -> handleReportPicker context event
    ShowWorkspaceReloadFailure -> handleExitOnlyEvent event

handleHomeEvent
  :: AppContext
  -> Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleHomeEvent context selectedDay event = case event of
  MouseDown HomeTab V.BLeft _ _ -> pure ()
  MouseDown (SectionTab section) V.BLeft _ _ -> switchSection section
  MouseDown (CalendarDay day) V.BLeft _ _ -> selectDay day
  MouseDown HomeDayViewport V.BScrollUp _ _ ->
    vScrollBy (viewportScroll HomeDayViewport) (-3)
  MouseDown HomeDayViewport V.BScrollDown _ _ ->
    vScrollBy (viewportScroll HomeDayViewport) 3
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey V.KLeft []) -> selectDay (addDays (-1) selectedDay)
  VtyEvent (V.EvKey V.KRight []) -> selectDay (addDays 1 selectedDay)
  VtyEvent (V.EvKey V.KUp []) -> selectDay (addDays (-7) selectedDay)
  VtyEvent (V.EvKey V.KDown []) -> selectDay (addDays 7 selectedDay)
  VtyEvent (V.EvKey (V.KChar 't') []) -> selectDay (contextObservationDay context)
  VtyEvent (V.EvKey (V.KChar 'T') []) -> selectDay (contextObservationDay context)
  VtyEvent (V.EvKey (V.KChar 'r') []) ->
    put (AppWrapper context
      (ActualFlow (ActualReturnHome selectedDay) (Actual.startRecord selectedDay)))
  VtyEvent (V.EvKey (V.KChar 'R') []) ->
    put (AppWrapper context
      (ActualFlow (ActualReturnHome selectedDay) (Actual.startRecord selectedDay)))
  VtyEvent (V.EvKey (V.KChar '1') []) -> switchSection ActualSection
  VtyEvent (V.EvKey (V.KChar '2') []) -> switchSection PlansSection
  VtyEvent (V.EvKey (V.KChar '3') []) -> switchSection BudgetSection
  VtyEvent (V.EvKey (V.KChar '4') []) -> switchSection AccountsSection
  VtyEvent (V.EvKey (V.KChar '5') []) -> switchSection IssuesSection
  VtyEvent (V.EvKey (V.KChar '6') []) -> switchSection ReportsSection
  VtyEvent (V.EvKey (V.KChar '7') []) -> switchSection SettingsSection
  _ -> pure ()
  where
    selectDay day = do
      put (AppWrapper context (Home day))
      vScrollToBeginning (viewportScroll HomeDayViewport)
    switchSection section =
      put (AppWrapper (context { contextCurrentSection = section }) Workspace)

handleWorkspaceEvent :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleWorkspaceEvent context event = case event of
  MouseDown HomeTab V.BLeft _ _ -> openHome
  MouseDown (SectionTab section) V.BLeft _ _ -> switchSection section
  MouseDown SettingsViewport V.BScrollUp _ _
    | inSettings -> vScrollBy (viewportScroll SettingsViewport) (-3)
  MouseDown SettingsViewport V.BScrollDown _ _
    | inSettings -> vScrollBy (viewportScroll SettingsViewport) 3
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'h') []) -> openHome
  VtyEvent (V.EvKey (V.KChar 'H') []) -> openHome
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
        Actual.OpenDaily -> put (AppWrapper currentContext
          (ActualFlow ActualReturnWorkspace
            (Actual.startDaily (contextEntryDay currentContext))))
        Actual.OpenIncome -> put (AppWrapper currentContext
          (ActualFlow ActualReturnWorkspace
            (Actual.startIncome (contextEntryDay currentContext))))
        Actual.OpenRecord -> put (AppWrapper currentContext
          (ActualFlow ActualReturnWorkspace
            (Actual.startRecord (contextEntryDay currentContext))))
        Actual.OpenReverse -> put (AppWrapper currentContext
          (ActualFlow ActualReturnWorkspace
            (Actual.startSelectedReverse currentContext)))
    PlansSection -> do
      action <- zoom zoomContext (Plan.handleWorkspaceEvent event)
      AppWrapper currentContext _ <- get
      case action of
        Plan.MaintainContext -> pure ()
        Plan.StartFlow flow -> put (AppWrapper currentContext (PlanFlow flow))
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
        Maintenance.IssuesActionStartDueUpdate flow ->
          put (AppWrapper currentContext (MaintenanceFlow flow))
        Maintenance.IssuesActionStartClose flow ->
          put (AppWrapper currentContext (MaintenanceFlow flow))
        Maintenance.IssuesActionStartRealize issue ->
          put (AppWrapper currentContext
            (ActualFlow ActualReturnWorkspace
              (Actual.startIssueRealize (contextEntryDay currentContext) issue)))
    ReportsSection -> do
      action <- zoom zoomContext (Report.handleWorkspaceEvent event)
      case action of
        Report.MaintainContext -> pure ()
        Report.OpenPicker -> openReportPicker
    SettingsSection -> pure ()
  where
    inSettings = contextCurrentSection context == SettingsSection
    openHome = put (AppWrapper context (Home (contextObservationDay context)))
    switchSection :: HouseholdSection -> EventM Name AppWrapper ()
    switchSection section =
      put (AppWrapper (context { contextCurrentSection = section }) Workspace)
    openReportPicker =
      let picker = L.list ReportPickerList (Vec.fromList Report.reportChoices) 1
          selectedIndex = Report.reportChoiceIndex (contextSelectedReport context)
      in put (AppWrapper context (ReportPicker (L.listMoveTo selectedIndex picker)))

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

handleActualFlow
  :: AppContext
  -> ActualReturn
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleActualFlow context returnTarget event = do
  zoom zoomActualFlow (Actual.handleFlowEvent context event)
  AppWrapper currentContext state <- get
  case state of
    ActualFlow _ Actual.ReturnToWorkspace ->
      put (returnFromActual currentContext returnTarget)
    ActualFlow _ Actual.QuitRequested -> halt
    ActualFlow currentReturn (Actual.PublishRequested request) -> do
      result <- suspendAndResume' (Actual.publishCandidate context request)
      case result of
        Actual.Published freshContext ->
          put (returnFromActual freshContext currentReturn)
        Actual.PublicationFailed outcome ->
          put (AppWrapper context
            (ActualFlow currentReturn (Actual.WriteOutcome outcome)))
        Actual.RealizationFailed message ->
          put (AppWrapper context
            (ActualFlow currentReturn (Actual.RealizeWriteOutcome message)))
        Actual.ReloadFailed -> put (AppWrapper context ShowWorkspaceReloadFailure)
    _ -> pure ()

returnFromActual :: AppContext -> ActualReturn -> AppWrapper
returnFromActual context ActualReturnWorkspace = AppWrapper context Workspace
returnFromActual context (ActualReturnHome selectedDay) =
  AppWrapper context (Home selectedDay)

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
        , (attrName "homeSelectedDay", V.withStyle V.defAttr V.reverseVideo)
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
          initialState = AppWrapper context (Home today)
          buildVty = do
            vty <- mkVty V.defaultConfig
            V.setMode (V.outputIface vty) V.Mouse True
            pure vty
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <household-root-or-actual.journal>"
