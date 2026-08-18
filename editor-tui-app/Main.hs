{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Graphics.Vty.CrossPlatform (mkVty)
import Lens.Micro (Lens', Traversal', singular)
import Lens.Micro.Mtl ()

import qualified Data.List.NonEmpty as NonEmpty
import Data.Time.Calendar (Day)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory)

import HKernel.Application.Config (mkHouseholdRoot)
import qualified HKernel.Editor.TUI.Actual as Actual
import qualified HKernel.Editor.TUI.Home as Home
import qualified HKernel.Editor.TUI.Maintenance as Maintenance
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , ReportChoice(..)
  , makeWorkspaceContext
  )
import qualified HKernel.Editor.TUI.Plan as Plan
import qualified HKernel.Editor.TUI.Report as Report
import qualified HKernel.Editor.TUI.Settings as Settings
import qualified HKernel.Editor.TUI.Shell as Shell
import HKernel.Household.Application (loadCanonicalHouseholdWriteSnapshot)
import HKernel.Household.EnvelopeObservation (EnvelopeChangeBaseline(..))

data ActualReturn
  = ActualReturnWorkspace Day
  | ActualReturnHome Day

data UIState
  = Home Day
  | Workspace Day Shell.ShellFocus
  | ActualFlow ActualReturn (Actual.State AppEvent)
  | PlanFlow Day (Plan.State AppEvent)
  | MaintenanceFlow Day (Maintenance.State AppEvent)
  | ReportPicker Day Report.PickerState
  | ShowWorkspaceReloadFailure

data AppWrapper = AppWrapper AppContext UIState

zoomActualFlow :: Traversal' AppWrapper (Actual.State AppEvent)
zoomActualFlow f (AppWrapper context (ActualFlow returnTarget state)) =
  (\updated -> AppWrapper context (ActualFlow returnTarget updated)) <$> f state
zoomActualFlow _ wrapper = pure wrapper

zoomPlanFlow :: Traversal' AppWrapper (Plan.State AppEvent)
zoomPlanFlow f (AppWrapper context (PlanFlow selectedDay state)) =
  (\updated -> AppWrapper context (PlanFlow selectedDay updated)) <$> f state
zoomPlanFlow _ wrapper = pure wrapper

zoomMaintenanceFlow :: Traversal' AppWrapper (Maintenance.State AppEvent)
zoomMaintenanceFlow f (AppWrapper context (MaintenanceFlow selectedDay state)) =
  (\updated -> AppWrapper context (MaintenanceFlow selectedDay updated)) <$> f state
zoomMaintenanceFlow _ wrapper = pure wrapper

zoomReportPicker :: Traversal' AppWrapper Report.PickerState
zoomReportPicker f (AppWrapper context (ReportPicker selectedDay choices)) =
  (\updated -> AppWrapper context (ReportPicker selectedDay updated)) <$> f choices
zoomReportPicker _ wrapper = pure wrapper

zoomContext :: Lens' AppWrapper AppContext
zoomContext f (AppWrapper context state) =
  (\updated -> AppWrapper updated state) <$> f context

drawUI :: AppWrapper -> [Widget Name]
drawUI (AppWrapper context (Home selectedDay)) =
  [ Shell.draw context selectedDay Shell.CalendarFocus (drawSectionBody context) ]
drawUI (AppWrapper context (Workspace selectedDay focus)) =
  [ Shell.draw context selectedDay focus (drawSectionBody context) ]
drawUI (AppWrapper context (ActualFlow _ state)) = [Actual.drawFlow context state]
drawUI (AppWrapper _ (PlanFlow _ state)) = [Plan.drawFlow state]
drawUI (AppWrapper _ (MaintenanceFlow _ state)) = [Maintenance.drawFlow state]
drawUI (AppWrapper _ (ReportPicker _ choices)) = [Report.drawPicker choices]
drawUI (AppWrapper _ ShowWorkspaceReloadFailure) =
  [ center
      (borderWithLabel (str "Household reload")
        (padAll 1
          (withAttr (attrName "error")
            (vBox
              [ strWrap "The source write succeeded, but the Household could not reload."
              , strWrap "Restart the TUI before continuing."
              , str " "
              , strWrap "[Esc/Q] Quit"
              ]))))
  ]

drawSectionBody :: AppContext -> Widget Name
drawSectionBody context = case contextCurrentSection context of
  ActualSection -> Actual.drawWorkspace context
  PlansSection -> Plan.drawWorkspace context
  EntitlementSection -> Maintenance.drawEntitlementWorkspace context
  AccountsSection -> Maintenance.drawAccountsWorkspace context
  IssuesSection -> Maintenance.drawIssuesWorkspace context
  ReportsSection -> Report.drawWorkspace context
  SettingsSection -> Settings.drawWorkspace context

appEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
appEvent event = do
  AppWrapper context state <- get
  case state of
    Home selectedDay -> handleHomeEvent context selectedDay event
    Workspace selectedDay focus -> handleWorkspaceEvent context selectedDay focus event
    ActualFlow returnTarget _ -> handleActualFlow context returnTarget event
    PlanFlow selectedDay _ -> handlePlanFlow context selectedDay event
    MaintenanceFlow selectedDay _ -> handleMaintenanceFlow context selectedDay event
    ReportPicker selectedDay _ -> handleReportPicker context selectedDay event
    ShowWorkspaceReloadFailure -> handleExitOnlyEvent event

handleHomeEvent
  :: AppContext
  -> Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleHomeEvent context selectedDay event = case event of
  MouseDown (SectionTab section) V.BLeft _ _ -> switchSection section
  VtyEvent (V.EvKey (V.KChar '\t') []) ->
    put (AppWrapper context (Workspace selectedDay Shell.SectionFocus))
  VtyEvent (V.EvKey V.KBackTab []) ->
    put (AppWrapper context (Workspace selectedDay Shell.SurfaceFocus))
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> do
    action <- zoom zoomContext (Home.handleLocalEvent selectedDay event)
    AppWrapper currentContext _ <- get
    case action of
      Home.HomeMaintain -> pure ()
      Home.HomeSelectDay day -> put (AppWrapper currentContext (Home day))
      Home.HomeRecord day -> put (AppWrapper currentContext
        (ActualFlow (ActualReturnHome day) (Actual.startRecord day)))
      Home.HomeObserveChange day -> openChange currentContext day
  where
    switchSection section =
      put (AppWrapper
        (context { contextCurrentSection = section })
        (Workspace selectedDay Shell.SectionFocus))
    openChange currentContext day = do
      put (AppWrapper
        (currentContext
          { contextCurrentSection = ReportsSection
          , contextSelectedReport = ReportEnvelopeChange (ExplicitDay day)
          })
        (Workspace day Shell.SurfaceFocus))
      let reportsViewport = viewportScroll ReportsViewport
      vScrollToBeginning reportsViewport
      hScrollToBeginning reportsViewport

handleWorkspaceEvent
  :: AppContext
  -> Day
  -> Shell.ShellFocus
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleWorkspaceEvent context selectedDay focus event = case event of
  MouseDown (CalendarDay day) V.BLeft _ _ -> do
    vScrollToBeginning (viewportScroll HomeDayViewport)
    put (AppWrapper context (Home day))
  MouseDown (SectionTab section) V.BLeft _ _ -> switchSection section
  VtyEvent (V.EvKey (V.KChar '\t') []) ->
    switchFocus (Shell.nextFocus focus)
  VtyEvent (V.EvKey V.KBackTab []) ->
    switchFocus (Shell.previousFocus focus)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> case focus of
    Shell.CalendarFocus -> put (AppWrapper context (Home selectedDay))
    Shell.SectionFocus -> handleSectionNavigation context selectedDay event
    Shell.SurfaceFocus -> handleSectionSurfaceEvent context selectedDay event
  where
    switchFocus next = case next of
      Shell.CalendarFocus -> put (AppWrapper context (Home selectedDay))
      nextFocus -> put (AppWrapper context (Workspace selectedDay nextFocus))
    switchSection section =
      put (AppWrapper
        (context { contextCurrentSection = section })
        (Workspace selectedDay Shell.SectionFocus))

handleSectionNavigation
  :: AppContext
  -> Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleSectionNavigation context selectedDay event = case event of
  VtyEvent (V.EvKey V.KUp []) -> move (-1)
  VtyEvent (V.EvKey V.KDown []) -> move 1
  VtyEvent (V.EvKey (V.KChar 'k') []) -> move (-1)
  VtyEvent (V.EvKey (V.KChar 'K') []) -> move (-1)
  VtyEvent (V.EvKey (V.KChar 'j') []) -> move 1
  VtyEvent (V.EvKey (V.KChar 'J') []) -> move 1
  VtyEvent (V.EvKey V.KRight []) -> enterSurface
  VtyEvent (V.EvKey V.KEnter []) -> enterSurface
  VtyEvent (V.EvKey V.KLeft []) ->
    put (AppWrapper context (Home selectedDay))
  _ -> pure ()
  where
    move delta =
      put (AppWrapper
        (context
          { contextCurrentSection =
              Shell.moveSection delta (contextCurrentSection context)
          })
        (Workspace selectedDay Shell.SectionFocus))
    enterSurface =
      put (AppWrapper context (Workspace selectedDay Shell.SurfaceFocus))

handleSectionSurfaceEvent
  :: AppContext
  -> Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleSectionSurfaceEvent context selectedDay event =
  case contextCurrentSection context of
    ActualSection -> do
      action <- zoom zoomContext (Actual.handleWorkspaceEvent event)
      AppWrapper currentContext _ <- get
      case action of
        Actual.MaintainContext -> pure ()
        Actual.OpenDaily -> put (AppWrapper currentContext
          (ActualFlow (ActualReturnWorkspace selectedDay)
            (Actual.startDaily (contextEntryDay currentContext))))
        Actual.OpenIncome -> put (AppWrapper currentContext
          (ActualFlow (ActualReturnWorkspace selectedDay)
            (Actual.startIncome (contextEntryDay currentContext))))
        Actual.OpenRecord -> put (AppWrapper currentContext
          (ActualFlow (ActualReturnWorkspace selectedDay)
            (Actual.startRecord (contextEntryDay currentContext))))
        Actual.OpenReconcile account -> put (AppWrapper currentContext
          (ActualFlow (ActualReturnWorkspace selectedDay)
            (Actual.startReconcile currentContext account)))
        Actual.OpenReverse -> put (AppWrapper currentContext
          (ActualFlow (ActualReturnWorkspace selectedDay)
            (Actual.startSelectedReverse currentContext)))
    PlansSection -> do
      action <- zoom zoomContext (Plan.handleWorkspaceEvent event)
      AppWrapper currentContext _ <- get
      case action of
        Plan.MaintainContext -> pure ()
        Plan.StartFlow flow ->
          put (AppWrapper currentContext (PlanFlow selectedDay flow))
    EntitlementSection -> do
      action <- Maintenance.handleEntitlementWorkspaceEvent event
      case action of
        Maintenance.EntitlementActionMaintain -> pure ()
        Maintenance.EntitlementActionStartTransfer ->
          put (AppWrapper context
            (MaintenanceFlow selectedDay Maintenance.startEntitlementTransfer))
    AccountsSection -> do
      action <- Maintenance.handleAccountsWorkspaceEvent event
      case action of
        Maintenance.AccountsActionMaintain -> pure ()
        Maintenance.AccountsActionStartAdd ->
          put (AppWrapper context
            (MaintenanceFlow selectedDay Maintenance.startAccountAdd))
    IssuesSection -> do
      action <- zoom zoomContext (Maintenance.handleIssuesWorkspaceEvent event)
      AppWrapper currentContext _ <- get
      case action of
        Maintenance.IssuesActionMaintain -> pure ()
        Maintenance.IssuesActionStartAdd ->
          put (AppWrapper currentContext
            (MaintenanceFlow selectedDay Maintenance.startIssueAdd))
        Maintenance.IssuesActionStartDueUpdate flow ->
          put (AppWrapper currentContext (MaintenanceFlow selectedDay flow))
        Maintenance.IssuesActionStartClose flow ->
          put (AppWrapper currentContext (MaintenanceFlow selectedDay flow))
        Maintenance.IssuesActionStartRealize issue ->
          case Actual.startIssueRealize (contextEntryDay currentContext) issue of
            Nothing -> pure ()
            Just flow -> put (AppWrapper currentContext
              (ActualFlow (ActualReturnWorkspace selectedDay) flow))
    ReportsSection -> do
      action <- zoom zoomContext (Report.handleWorkspaceEvent event)
      case action of
        Report.MaintainContext -> pure ()
        Report.OpenPicker ->
          put (AppWrapper context
            (ReportPicker selectedDay
              (Report.openPicker (contextSelectedReport context))))
    SettingsSection -> Settings.handleWorkspaceEvent event

handleReportPicker
  :: AppContext
  -> Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleReportPicker context selectedDay event = do
  action <- zoom (singular zoomReportPicker) (Report.handlePickerEvent event)
  case action of
    Report.PickerMaintain -> pure ()
    Report.PickerBack ->
      put (AppWrapper context (Workspace selectedDay Shell.SurfaceFocus))
    Report.PickerQuit -> halt
    Report.PickerOpen choice -> do
      put (AppWrapper
        (context { contextSelectedReport = choice })
        (Workspace selectedDay Shell.SurfaceFocus))
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
        Actual.RealizationFailed freshContext message ->
          put (AppWrapper freshContext
            (ActualFlow currentReturn (Actual.RealizeWriteOutcome message)))
        Actual.ReloadFailed -> put (AppWrapper context ShowWorkspaceReloadFailure)
    _ -> pure ()

returnFromActual :: AppContext -> ActualReturn -> AppWrapper
returnFromActual context (ActualReturnWorkspace selectedDay) =
  AppWrapper context (Workspace selectedDay Shell.SurfaceFocus)
returnFromActual context (ActualReturnHome selectedDay) =
  AppWrapper context (Home selectedDay)

handlePlanFlow
  :: AppContext
  -> Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handlePlanFlow context selectedDay event = do
  zoom zoomPlanFlow (Plan.handleFlowEvent context event)
  AppWrapper currentContext state <- get
  case state of
    PlanFlow _ Plan.ReturnToWorkspace ->
      put (AppWrapper currentContext (Workspace selectedDay Shell.SurfaceFocus))
    PlanFlow _ Plan.QuitRequested -> halt
    PlanFlow _ (Plan.PublishRequested request) ->
      publishPlanRequest context selectedDay request
    _ -> pure ()

publishPlanRequest
  :: AppContext
  -> Day
  -> Plan.PublishRequest
  -> EventM Name AppWrapper ()
publishPlanRequest context selectedDay request = do
  result <- suspendAndResume' (Plan.publishCandidate context request)
  case result of
    Plan.Published freshContext ->
      put (AppWrapper freshContext (Workspace selectedDay Shell.SurfaceFocus))
    Plan.PublicationFailed message ->
      put (AppWrapper context (PlanFlow selectedDay (Plan.WriteOutcome message)))
    Plan.ReloadFailed -> put (AppWrapper context ShowWorkspaceReloadFailure)

handleMaintenanceFlow
  :: AppContext
  -> Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleMaintenanceFlow context selectedDay event = do
  zoom zoomMaintenanceFlow (Maintenance.handleFlowEvent context event)
  AppWrapper currentContext state <- get
  case state of
    MaintenanceFlow _ Maintenance.ReturnToWorkspace ->
      put (AppWrapper currentContext (Workspace selectedDay Shell.SurfaceFocus))
    MaintenanceFlow _ Maintenance.QuitRequested -> halt
    MaintenanceFlow _ (Maintenance.PublishRequested request) -> do
      result <- suspendAndResume' (Maintenance.publishCandidate context request)
      case result of
        Maintenance.Published freshContext ->
          put (AppWrapper freshContext (Workspace selectedDay Shell.SurfaceFocus))
        Maintenance.PublicationFailed message ->
          put (AppWrapper context
            (MaintenanceFlow selectedDay (Maintenance.WriteOutcome message)))
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
        , (attrName "activeTab", V.black `on` V.white)
        , (attrName "homeSelectedDay", V.black `on` V.cyan)
        , (attrName "shellFocus", V.withStyle V.defAttr V.bold)
        , (attrName "shellMuted", V.withStyle V.defAttr V.dim)
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
      let context = makeWorkspaceContext today snapshot
          initialState = AppWrapper context (Home today)
          buildVty = do
            vty <- mkVty V.defaultConfig
            V.setMode (V.outputIface vty) V.Mouse True
            pure vty
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <household-root-or-actual.journal>"
