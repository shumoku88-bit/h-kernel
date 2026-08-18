{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Brick
import Brick.Types (availWidthL, getContext)
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Graphics.Vty.CrossPlatform (mkVty)
import Lens.Micro (Lens', Traversal', singular, (^.))
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
import HKernel.Household.Application (loadCanonicalHouseholdWriteSnapshot)
import HKernel.Household.EnvelopeObservation (EnvelopeChangeBaseline(..))

data ActualReturn
  = ActualReturnWorkspace
  | ActualReturnHome Day

data UIState
  = Home Day
  | Workspace
  | ActualFlow ActualReturn (Actual.State AppEvent)
  | PlanFlow (Plan.State AppEvent)
  | MaintenanceFlow (Maintenance.State AppEvent)
  | ReportPicker Report.PickerState
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

zoomReportPicker :: Traversal' AppWrapper Report.PickerState
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
              [ strWrap "The source write succeeded, but the Household could not reload."
              , strWrap "Restart the TUI before continuing."
              , str " "
              , strWrap "[Esc/Q] Quit"
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
    (responsiveAt 96 compactTabs wideTabs)
  where
    renderedTabs = map renderTab [minBound .. maxBound]
    wideTabs = hBox (homeTab : renderedTabs)
    compactTabs = vBox
      [ hBox (homeTab : take 3 renderedTabs)
      , hBox (drop 3 renderedTabs)
      ]
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
    sectionNum EntitlementSection = "3"
    sectionNum AccountsSection = "4"
    sectionNum IssuesSection = "5"
    sectionNum ReportsSection = "6"
    sectionNum SettingsSection = "7"
    sectionName ActualSection = "Actual"
    sectionName PlansSection = "Plans"
    sectionName EntitlementSection = "Envelopes"
    sectionName AccountsSection = "Accounts"
    sectionName IssuesSection = "Issues"
    sectionName ReportsSection = "Reports"
    sectionName SettingsSection = "Settings"

-- | Select layout from Brick's current render context. Terminal dimensions are
-- presentation evidence only and do not enter application or Household state.
responsiveAt :: Int -> Widget name -> Widget name -> Widget name
responsiveAt breakpoint compact wide =
  Widget Greedy Fixed $ do
    context <- getContext
    render $ if context ^. availWidthL < breakpoint then compact else wide

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
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey (V.KChar '1') []) -> switchSection ActualSection
  VtyEvent (V.EvKey (V.KChar '2') []) -> switchSection PlansSection
  VtyEvent (V.EvKey (V.KChar '3') []) -> switchSection EntitlementSection
  VtyEvent (V.EvKey (V.KChar '4') []) -> switchSection AccountsSection
  VtyEvent (V.EvKey (V.KChar '5') []) -> switchSection IssuesSection
  VtyEvent (V.EvKey (V.KChar '6') []) -> switchSection ReportsSection
  VtyEvent (V.EvKey (V.KChar '7') []) -> switchSection SettingsSection
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
      put (AppWrapper (context { contextCurrentSection = section }) Workspace)
    openChange currentContext day = do
      put (AppWrapper
        (currentContext
          { contextCurrentSection = ReportsSection
          , contextSelectedReport = ReportEnvelopeChange (ExplicitDay day)
          })
        Workspace)
      let reportsViewport = viewportScroll ReportsViewport
      vScrollToBeginning reportsViewport
      hScrollToBeginning reportsViewport

handleWorkspaceEvent :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleWorkspaceEvent context event = case event of
  MouseDown HomeTab V.BLeft _ _ -> openHome
  MouseDown (SectionTab section) V.BLeft _ _ -> switchSection section
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'h') []) -> openHome
  VtyEvent (V.EvKey (V.KChar 'H') []) -> openHome
  VtyEvent (V.EvKey (V.KChar '1') []) -> switchSection ActualSection
  VtyEvent (V.EvKey (V.KChar '2') []) -> switchSection PlansSection
  VtyEvent (V.EvKey (V.KChar '3') []) -> switchSection EntitlementSection
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
        Actual.OpenReconcile account -> put (AppWrapper currentContext
          (ActualFlow ActualReturnWorkspace
            (Actual.startReconcile currentContext account)))
        Actual.OpenReverse -> put (AppWrapper currentContext
          (ActualFlow ActualReturnWorkspace
            (Actual.startSelectedReverse currentContext)))
    PlansSection -> do
      action <- zoom zoomContext (Plan.handleWorkspaceEvent event)
      AppWrapper currentContext _ <- get
      case action of
        Plan.MaintainContext -> pure ()
        Plan.StartFlow flow -> put (AppWrapper currentContext (PlanFlow flow))
    EntitlementSection -> do
      action <- Maintenance.handleEntitlementWorkspaceEvent event
      case action of
        Maintenance.EntitlementActionMaintain -> pure ()
        Maintenance.EntitlementActionStartTransfer ->
          put (AppWrapper context (MaintenanceFlow Maintenance.startEntitlementTransfer))
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
          case Actual.startIssueRealize (contextEntryDay currentContext) issue of
            Nothing -> pure ()
            Just flow -> put (AppWrapper currentContext
              (ActualFlow ActualReturnWorkspace flow))
    ReportsSection -> do
      action <- zoom zoomContext (Report.handleWorkspaceEvent event)
      case action of
        Report.MaintainContext -> pure ()
        Report.OpenPicker ->
          put (AppWrapper context
            (ReportPicker (Report.openPicker (contextSelectedReport context))))
    SettingsSection -> Settings.handleWorkspaceEvent event
  where
    openHome = put (AppWrapper context (Home (contextObservationDay context)))
    switchSection :: HouseholdSection -> EventM Name AppWrapper ()
    switchSection section =
      put (AppWrapper (context { contextCurrentSection = section }) Workspace)

handleReportPicker :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleReportPicker context event = do
  action <- zoom (singular zoomReportPicker) (Report.handlePickerEvent event)
  case action of
    Report.PickerMaintain -> pure ()
    Report.PickerBack -> put (AppWrapper context Workspace)
    Report.PickerQuit -> halt
    Report.PickerOpen choice -> do
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
        Actual.RealizationFailed freshContext message ->
          put (AppWrapper freshContext
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
