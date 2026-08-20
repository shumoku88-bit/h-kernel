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

import Data.List (sortOn)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import qualified Data.Vector as Vec
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory)
import System.IO.Error (tryIOError)

import HKernel.Application.Config
  ( HouseholdSourcePaths(..)
  , mkHouseholdRoot
  )
import HKernel.Editor.HouseholdWorkspace (admitIssueRelationSource)
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteIntent(..)
  , publishWithAdmission
  )
import qualified HKernel.Editor.TUI.Actual as Actual
import HKernel.Editor.TUI.DateUrgency
  ( dateDueTodayAttr
  , dateOverdueAttr
  )
import qualified HKernel.Editor.TUI.Home as Home
import qualified HKernel.Editor.TUI.Maintenance as Maintenance
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , ReportChoice(..)
  , WorkspaceReloadFailure
  , contextHouseholdState
  , makeWorkspaceContext
  , refreshIssueRelationObservation
  , reloadWorkspaceContext
  , workspaceReloadFailureText
  )
import qualified HKernel.Editor.TUI.Plan as Plan
import qualified HKernel.Editor.TUI.Report as Report
import qualified HKernel.Editor.TUI.Settings as Settings
import qualified HKernel.Editor.TUI.Shell as Shell
import HKernel.Household.Application
  ( HouseholdState(..)
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Household.EnvelopeObservation (EnvelopeChangeBaseline(..))
import HKernel.Household.Issue.Relation.TSV
  ( issueRelationHeader
  , renderIssueRelations
  )
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueId
  , IssueRelation(..)
  , IssueRelationEvent
  , IssueRelationEventId
  , IssueRelationEventIdError
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  , householdIssueText
  , issueIdText
  , issueRelationEventId
  , issueRelationEventIdText
  , issueRelationIssueId
  , issueRelationMeaning
  , mkIssueRelationEvent
  , mkIssueRelationEventId
  )

data ActualReturn
  = ActualReturnWorkspace Day
  | ActualReturnHome Day

data IssueContinuationState
  = IssueContinuationPicker
      HouseholdIssue
      Text
      (L.List Name HouseholdIssue)
  | IssueContinuationPreview
      HouseholdIssue
      HouseholdIssue
      Text
      (Either Text (IssueRelationEvent, Text, Text))
  | IssueContinuationOutcome Text

data UIState
  = Home Day (Maybe Day)
  | Workspace Day Shell.ShellFocus
  | ActualFlow ActualReturn (Actual.State AppEvent)
  | PlanFlow Day (Plan.State AppEvent)
  | MaintenanceFlow Day (Maintenance.State AppEvent)
  | IssueContinuationFlow Day IssueContinuationState
  | ReportPicker Day Report.PickerState
  | ShowWorkspaceReloadFailure WorkspaceReloadFailure

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

zoomIssueContinuationList :: Traversal' AppWrapper (L.List Name HouseholdIssue)
zoomIssueContinuationList f
    (AppWrapper context
      (IssueContinuationFlow selectedDay
        (IssueContinuationPicker target source choices))) =
  (\updated -> AppWrapper context
      (IssueContinuationFlow selectedDay
        (IssueContinuationPicker target source updated))) <$> f choices
zoomIssueContinuationList _ wrapper = pure wrapper

zoomReportPicker :: Traversal' AppWrapper Report.PickerState
zoomReportPicker f (AppWrapper context (ReportPicker selectedDay choices)) =
  (\updated -> AppWrapper context (ReportPicker selectedDay updated)) <$> f choices
zoomReportPicker _ wrapper = pure wrapper

zoomContext :: Lens' AppWrapper AppContext
zoomContext f (AppWrapper context state) =
  (\updated -> AppWrapper updated state) <$> f context

drawUI :: AppWrapper -> [Widget Name]
drawUI (AppWrapper context (Home selectedDay rangeStart)) =
  [ Shell.draw context selectedDay Shell.CalendarFocus (drawSectionBody context)
      <=> padTop (Pad 1) (drawCalendarRangeStatus selectedDay rangeStart)
  ]
drawUI (AppWrapper context (Workspace selectedDay focus)) =
  [ Shell.draw context selectedDay focus (drawSectionBody context) ]
drawUI (AppWrapper context (ActualFlow _ state)) = [Actual.drawFlow context state]
drawUI (AppWrapper _ (PlanFlow _ state)) = [Plan.drawFlow state]
drawUI (AppWrapper _ (MaintenanceFlow _ state)) = [Maintenance.drawFlow state]
drawUI (AppWrapper _ (IssueContinuationFlow _ state)) =
  [drawIssueContinuation state]
drawUI (AppWrapper _ (ReportPicker _ choices)) = [Report.drawPicker choices]
drawUI (AppWrapper _ (ShowWorkspaceReloadFailure failure)) =
  [ center
      (borderWithLabel (str "Household reload")
        (padAll 1
          (withAttr (attrName "error")
            (vBox
              [ strWrap "The source write completed, but the Household could not safely refresh."
              , txtWrap (workspaceReloadFailureText failure)
              , strWrap "Restart the TUI before continuing."
              , str " "
              , strWrap "[Esc/Q] Quit"
              ]))))
  ]

drawIssueContinuation :: IssueContinuationState -> Widget Name
drawIssueContinuation state = case state of
  IssueContinuationPicker target _ choices ->
    center
      (borderWithLabel (str "Issue continued from")
        (hLimit 96 (vLimit 34 (padAll 1
          (vBox
            [ strWrap
                ("Current Issue: "
                  <> T.unpack (issueIdText (householdIssueId target))
                  <> "  " <> T.unpack (householdIssueText target))
            , str " "
            , strWrap "Choose the earlier Issue. Candidates are newest first."
            , str " "
            , vLimit 20 (L.renderList renderContinuationChoice True choices)
            , str " "
            , strWrap "[j/k/Arrows] Move   [Enter] Preview   [Esc] Issues"
            ])))))
  IssueContinuationPreview target source _ result ->
    center
      (borderWithLabel (str "Issue continuation preview")
        (hLimit 96 (vLimit 32 (padAll 1
          (vBox
            [ txtWrap
                (issueIdText (householdIssueId source)
                  <> "  -> continued-as ->  "
                  <> issueIdText (householdIssueId target))
            , str " "
            , case result of
                Left message -> withAttr (attrName "error") (txtWrap message)
                Right (_, row, _) -> txtWrap row
            , str " "
            , strWrap
                (case result of
                  Left _ -> "[Esc] Back   [Q] Quit"
                  Right _ -> "[Enter] Publish   [Esc] Back   [Q] Quit")
            ])))))
  IssueContinuationOutcome message ->
    center
      (borderWithLabel (str "Issue continuation")
        (hLimit 88 (padAll 1
          (txtWrap message <=> str " " <=> strWrap "[Esc] Issues   [Q] Quit"))))

renderContinuationChoice :: Bool -> HouseholdIssue -> Widget Name
renderContinuationChoice selected issue
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = txt
      (T.pack (show (householdIssueRecordedOn issue))
        <> "  [" <> T.pack (show (householdIssueStatus issue)) <> "]  "
        <> issueIdText (householdIssueId issue)
        <> "  " <> householdIssueText issue)

drawCalendarRangeStatus :: Day -> Maybe Day -> Widget Name
drawCalendarRangeStatus selectedDay rangeStart = case rangeStart of
  Nothing ->
    withAttr (attrName "shellMuted")
      (strWrap "Observation: [Enter] selected day → current observation · [Space] mark FROM for an explicit range")
  Just from
    | selectedDay < from ->
        withAttr (attrName "warning")
          (strWrap
            ("Observation range: FROM through " <> show from
              <> " · THROUGH cursor through " <> show selectedDay
              <> " precedes FROM · [Space] replace FROM · [Esc] clear"))
    | otherwise ->
        withAttr (attrName "shellFocus")
          (strWrap
            ("Observation range: FROM through " <> show from
              <> " → THROUGH through " <> show selectedDay
              <> " · [Enter] compare · [Space] replace FROM · [Esc] clear"))

drawSectionBody :: AppContext -> Widget Name
drawSectionBody context = case contextCurrentSection context of
  ActualSection -> Actual.drawWorkspace context
  PlansSection -> Plan.drawWorkspace context
  EntitlementSection -> Maintenance.drawEntitlementWorkspace context
  AccountsSection -> Maintenance.drawAccountsWorkspace context
  IssuesSection ->
    Maintenance.drawIssuesWorkspace context
      <=> strWrap "[F] Continued from another Issue"
  ReportsSection -> Report.drawWorkspace context
  SettingsSection -> Settings.drawWorkspace context

appEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
appEvent event = do
  AppWrapper context state <- get
  case state of
    Home selectedDay rangeStart -> handleHomeEvent context selectedDay rangeStart event
    Workspace selectedDay focus -> handleWorkspaceEvent context selectedDay focus event
    ActualFlow returnTarget _ -> handleActualFlow context returnTarget event
    PlanFlow selectedDay _ -> handlePlanFlow context selectedDay event
    MaintenanceFlow selectedDay _ -> handleMaintenanceFlow context selectedDay event
    IssueContinuationFlow selectedDay _ ->
      handleIssueContinuation context selectedDay event
    ReportPicker selectedDay _ -> handleReportPicker context selectedDay event
    ShowWorkspaceReloadFailure _ -> handleExitOnlyEvent event

handleHomeEvent
  :: AppContext
  -> Day
  -> Maybe Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleHomeEvent context selectedDay rangeStart event = case event of
  MouseDown (SectionTab section) V.BLeft _ _ -> switchSection section
  MouseDown (HomeChangeFrom day) V.BLeft _ _ ->
    put (AppWrapper context (Home day (Just day)))
  VtyEvent (V.EvKey (V.KChar ' ') []) ->
    put (AppWrapper context (Home selectedDay (Just selectedDay)))
  VtyEvent (V.EvKey V.KEnter []) -> chooseThrough selectedDay
  VtyEvent (V.EvKey V.KEsc []) -> case rangeStart of
    Nothing -> pure ()
    Just _ -> put (AppWrapper context (Home selectedDay Nothing))
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
      Home.HomeSelectDay day ->
        put (AppWrapper currentContext (Home day rangeStart))
      Home.HomeRecord day -> put (AppWrapper currentContext
        (ActualFlow (ActualReturnHome day) (Actual.startRecord day)))
      Home.HomeObserveChange day -> chooseThroughWith currentContext day
  where
    switchSection section =
      put (AppWrapper
        (context { contextCurrentSection = section })
        (Workspace selectedDay Shell.SectionFocus))
    chooseThrough day = chooseThroughWith context day
    chooseThroughWith currentContext through = case rangeStart of
      Nothing -> openChangeToCurrent currentContext through
      Just from -> openChange currentContext from through
    openChangeToCurrent currentContext from =
      openReport currentContext from (ReportEnvelopeChange (ExplicitDay from))
    openChange currentContext from through =
      openReport currentContext through (ReportEnvelopeChangeBetween from through)
    openReport currentContext selected report = do
      put (AppWrapper
        (currentContext
          { contextCurrentSection = ReportsSection
          , contextSelectedReport = report
          })
        (Workspace selected Shell.SurfaceFocus))
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
    put (AppWrapper context (Home day Nothing))
  MouseDown (SectionTab section) V.BLeft _ _ -> switchSection section
  VtyEvent (V.EvKey (V.KChar '\t') []) ->
    switchFocus (Shell.nextFocus focus)
  VtyEvent (V.EvKey V.KBackTab []) ->
    switchFocus (Shell.previousFocus focus)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> case focus of
    Shell.CalendarFocus -> put (AppWrapper context (Home selectedDay Nothing))
    Shell.SectionFocus -> handleSectionNavigation context selectedDay event
    Shell.SurfaceFocus -> handleSectionSurfaceEvent context selectedDay event
  where
    switchFocus next = case next of
      Shell.CalendarFocus -> put (AppWrapper context (Home selectedDay Nothing))
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
    put (AppWrapper context (Home selectedDay Nothing))
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
    IssuesSection -> case event of
      VtyEvent (V.EvKey (V.KChar 'f') []) ->
        startIssueContinuation context selectedDay
      VtyEvent (V.EvKey (V.KChar 'F') []) ->
        startIssueContinuation context selectedDay
      _ -> do
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

startIssueContinuation
  :: AppContext
  -> Day
  -> EventM Name AppWrapper ()
startIssueContinuation context selectedDay =
  case L.listSelectedElement (contextIssueList context) of
    Nothing -> pure ()
    Just (_, target) -> do
      let state = contextHouseholdState context
          path = householdIssueRelationsPath (householdStatePaths state)
      sourceResult <- suspendAndResume' (tryIOError (TIO.readFile path))
      case sourceResult of
        Left err ->
          put (AppWrapper context
            (IssueContinuationFlow selectedDay
              (IssueContinuationOutcome
                ("Cannot read issue-relations.tsv: " <> T.pack (show err)))))
        Right relationSource ->
          case admitIssueRelationSource
              (householdStateActualJournal state)
              (householdStatePlanJournal state)
              (householdStateIssues state)
              relationSource of
            Left errors ->
              put (AppWrapper context
                (IssueContinuationFlow selectedDay
                  (IssueContinuationOutcome
                    ("Issue relation admission failed: "
                      <> T.pack (show (NonEmpty.toList errors))))))
            Right _ ->
              let candidates = continuationCandidates
                    target (householdStateIssues state)
              in if null candidates
                  then put (AppWrapper context
                    (IssueContinuationFlow selectedDay
                      (IssueContinuationOutcome
                        "No earlier Issue is available as a continuation source.")))
                  else put (AppWrapper context
                    (IssueContinuationFlow selectedDay
                      (IssueContinuationPicker
                        target
                        relationSource
                        (L.list IssueList (Vec.fromList candidates) 1))))

continuationCandidates
  :: HouseholdIssue
  -> [HouseholdIssue]
  -> [HouseholdIssue]
continuationCandidates target =
  reverse
    . sortOn householdIssueRecordedOn
    . filter isCandidate
  where
    targetId = householdIssueId target
    targetDay = householdIssueRecordedOn target
    isCandidate issue =
      householdIssueId issue /= targetId
        && householdIssueRecordedOn issue <= targetDay

handleIssueContinuation
  :: AppContext
  -> Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleIssueContinuation context selectedDay event = do
  AppWrapper _ current <- get
  case current of
    IssueContinuationFlow _ state -> case state of
      IssueContinuationPicker target relationSource choices -> case event of
        VtyEvent (V.EvKey V.KEsc []) -> returnToIssues
        VtyEvent (V.EvKey V.KEnter []) ->
          case L.listSelectedElement choices of
            Nothing -> pure ()
            Just (_, source) ->
              put (AppWrapper context
                (IssueContinuationFlow selectedDay
                  (IssueContinuationPreview
                    target
                    source
                    relationSource
                    (prepareIssueContinuation context relationSource source target))))
        MouseDown IssueList V.BLeft _ (Location (_, row)) ->
          zoom zoomIssueContinuationList (modify (L.listMoveTo row))
        VtyEvent (V.EvKey vtyKey vtyMods) ->
          zoom zoomIssueContinuationList
            (L.handleListEventVi L.handleListEvent (V.EvKey vtyKey vtyMods))
        _ -> pure ()
      IssueContinuationPreview target source relationSource result -> case event of
        VtyEvent (V.EvKey V.KEsc []) ->
          put (AppWrapper context
            (IssueContinuationFlow selectedDay
              (IssueContinuationPicker
                target relationSource
                (L.list IssueList
                  (Vec.fromList
                    (continuationCandidates
                      target
                      (householdStateIssues (contextHouseholdState context))))
                  1))))
        VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
        VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
        VtyEvent (V.EvKey V.KEnter []) -> case result of
          Left _ -> pure ()
          Right (_, _, candidateSource) ->
            publishIssueContinuation context selectedDay relationSource candidateSource
        _ -> pure ()
      IssueContinuationOutcome _ -> case event of
        VtyEvent (V.EvKey V.KEsc []) -> returnToIssues
        VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
        VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
        _ -> pure ()
    _ -> pure ()
  where
    returnToIssues =
      put (AppWrapper context (Workspace selectedDay Shell.SurfaceFocus))

prepareIssueContinuation
  :: AppContext
  -> Text
  -> HouseholdIssue
  -> HouseholdIssue
  -> Either Text (IssueRelationEvent, Text, Text)
prepareIssueContinuation context relationSource source target = do
  let household = contextHouseholdState context
      recordedOn = contextEntryDay context
      sourceId = householdIssueId source
      targetId = householdIssueId target
  if householdIssueRecordedOn source > householdIssueRecordedOn target
    then Left "The continuation source must not be newer than the target Issue."
    else Right ()
  if recordedOn < householdIssueRecordedOn target
    then Left "The relation date cannot precede the target Issue."
    else Right ()
  existing <- either
    (Left . ("Issue relation admission failed: " <>)
      . T.pack . show . NonEmpty.toList)
    Right
    (admitIssueRelationSource
      (householdStateActualJournal household)
      (householdStatePlanJournal household)
      (householdStateIssues household)
      relationSource)
  if any (sameContinuation sourceId targetId) existing
    then Left "This Issue continuation is already recorded."
    else Right ()
  eventId <- either (Left . T.pack . show) Right
    (generateContinuationEventId recordedOn sourceId targetId existing)
  relation <- either (Left . T.pack . show) Right
    (mkIssueRelationEvent
      eventId
      recordedOn
      sourceId
      (IssueContinuedAs targetId)
      "")
  let row = renderSingleRelationRow relation
      candidateSource = appendRelationRow relationSource row
  _ <- either
    (Left . ("Candidate relation rejected: " <>)
      . T.pack . show . NonEmpty.toList)
    Right
    (admitIssueRelationSource
      (householdStateActualJournal household)
      (householdStatePlanJournal household)
      (householdStateIssues household)
      candidateSource)
  pure (relation, row, candidateSource)

sameContinuation
  :: IssueId
  -> IssueId
  -> IssueRelationEvent
  -> Bool
sameContinuation sourceId targetId relation =
  issueRelationIssueId relation == sourceId
    && case issueRelationMeaning relation of
      IssueContinuedAs existingTarget -> existingTarget == targetId
      _ -> False

generateContinuationEventId
  :: Day
  -> IssueId
  -> IssueId
  -> [IssueRelationEvent]
  -> Either IssueRelationEventIdError IssueRelationEventId
generateContinuationEventId recordedOn sourceId targetId existing = go (1 :: Int)
  where
    occupied = map
      (issueRelationEventIdText . issueRelationEventId)
      existing
    base =
      "REL-" <> T.pack (show recordedOn)
        <> "-" <> issueIdText sourceId
        <> "-continued-" <> issueIdText targetId
    go index = do
      let value
            | index == 1 = base
            | otherwise = base <> "-" <> T.pack (show index)
      candidate <- mkIssueRelationEventId value
      if value `elem` occupied
        then go (index + 1)
        else Right candidate

renderSingleRelationRow :: IssueRelationEvent -> Text
renderSingleRelationRow relation =
  case T.lines (renderIssueRelations [relation]) of
    _header : row : _ -> row
    _ -> error "renderIssueRelations did not render one relation row"

appendRelationRow :: Text -> Text -> Text
appendRelationRow existing row
  | noMeaningfulLines = issueRelationHeader <> "\n" <> row <> "\n"
  | T.isSuffixOf "\n" existing = existing <> row <> "\n"
  | otherwise = existing <> "\n" <> row <> "\n"
  where
    noMeaningfulLines = null
      [ line
      | line <- T.lines existing
      , let stripped = T.strip line
      , not (T.null stripped)
      , not ("#" `T.isPrefixOf` stripped)
      ]

publishIssueContinuation
  :: AppContext
  -> Day
  -> Text
  -> Text
  -> EventM Name AppWrapper ()
publishIssueContinuation context selectedDay expectedSource candidateSource = do
  let household = contextHouseholdState context
      path = householdIssueRelationsPath (householdStatePaths household)
      admission source = admitIssueRelationSource
        (householdStateActualJournal household)
        (householdStatePlanJournal household)
        (householdStateIssues household)
        source
  result <- suspendAndResume'
    (publishWithAdmission admission WriteIntent
      { targetFilePath = path
      , expectedOldBytes = ExpectedSource expectedSource
      , candidateNewBytes = CandidateSource candidateSource
      })
  case result of
    Left err ->
      put (AppWrapper context
        (IssueContinuationFlow selectedDay
          (IssueContinuationOutcome
            ("Issue continuation publication failed: " <> T.pack (show err)))))
    Right () -> do
      reloaded <- suspendAndResume' (reloadWorkspaceContext context)
      case reloaded of
        Left failure ->
          put (AppWrapper context (ShowWorkspaceReloadFailure failure))
        Right fresh ->
          put (AppWrapper
            (fresh { contextCurrentSection = IssuesSection })
            (Workspace selectedDay Shell.SurfaceFocus))

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
        Actual.ReloadFailed failure ->
          put (AppWrapper context (ShowWorkspaceReloadFailure failure))
    _ -> pure ()

returnFromActual :: AppContext -> ActualReturn -> AppWrapper
returnFromActual context (ActualReturnWorkspace selectedDay) =
  AppWrapper context (Workspace selectedDay Shell.SurfaceFocus)
returnFromActual context (ActualReturnHome selectedDay) =
  AppWrapper context (Home selectedDay Nothing)

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
    Plan.ReloadFailed failure ->
      put (AppWrapper context (ShowWorkspaceReloadFailure failure))

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
        Maintenance.ReloadFailed failure ->
          put (AppWrapper context (ShowWorkspaceReloadFailure failure))
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
        , (dateDueTodayAttr, V.withStyle (fg V.yellow) V.bold)
        , (dateOverdueAttr, V.withStyle (fg V.red) V.bold)
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
      context <- refreshIssueRelationObservation (makeWorkspaceContext today snapshot)
      let initialState = AppWrapper context (Home today Nothing)
          buildVty = do
            vty <- mkVty V.defaultConfig
            V.setMode (V.outputIface vty) V.Mouse True
            pure vty
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <household-root-or-actual.journal>"
