{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Actual
  ( PublishResult(..)
  , State(..)
  , WorkspaceAction(..)
  , applyWorkspaceAccountFilter
  , drawFlow
  , drawWorkspace
  , handleFlowEvent
  , handleWorkspaceEvent
  , publishCandidate
  , startDaily
  , startIncome
  , startIssueRealize
  , startRecord
  , startSelectedReverse
  , toggleWorkspaceFocus
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Graphics.Vty as V
import Lens.Micro (Traversal', singular)

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import System.IO.Error (isDoesNotExistError, tryIOError)

import HKernel.Application.Config (HouseholdRoot, HouseholdSourcePaths(..))
import HKernel.Editor.ActualAppend
  ( ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , classifyActualAddWriteResult
  )
import HKernel.Editor.IssueRealize
  ( IssueRealizeIntent
  , IssueRealizeObservedSources(..)
  , IssueRealizeOperationError(..)
  , IssueRealizeWriteError(..)
  , admitIssueRelationSource
  , publishIssueRealizeFromObservedSources
  )
import HKernel.Editor.SourcePublication (publishActualBlockWithPathAdmission)
import qualified HKernel.Editor.TUI.Actual.Daily as Daily
import qualified HKernel.Editor.TUI.Actual.Record as Record
import qualified HKernel.Editor.TUI.Actual.Reverse as Reverse
import HKernel.Editor.TUI.Actual.Workspace (WorkspaceAction(..))
import qualified HKernel.Editor.TUI.Actual.Workspace as Workspace
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name
  , contextHouseholdState
  , contextIssuesSource
  , contextSource
  , contextSourcePath
  , reloadWorkspaceContext
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , loadCanonicalHousehold
  )
import HKernel.HouseholdIssue (HouseholdIssue)

data State event
  = DailyFlow (Daily.State event)
  | RecordFlow (Record.State event)
  | ReverseFlow (Reverse.State event)
  | WriteOutcome ActualAddWriteOutcome
  | RealizeWriteOutcome Text
  | ReturnToWorkspace
  | PublishRequested PublishRequest
  | QuitRequested

data PublishRequest
  = PublishActual Day Text
  | PublishIssueRealize Day IssueRealizeIntent

data PublishResult
  = Published AppContext
  | PublicationFailed ActualAddWriteOutcome
  | RealizationFailed AppContext Text
  | ReloadFailed

startDaily :: Day -> State event
startDaily = DailyFlow . Daily.startDaily

startIncome :: Day -> State event
startIncome = DailyFlow . Daily.startIncome

startRecord :: Day -> State event
startRecord = RecordFlow . Record.startRecord

startIssueRealize :: Day -> HouseholdIssue -> Maybe (State event)
startIssueRealize day issue = RecordFlow <$> Record.startIssueRealize day issue

startSelectedReverse :: AppContext -> State event
startSelectedReverse = ReverseFlow . Reverse.startSelected

drawFlow :: AppContext -> State AppEvent -> Widget Name
drawFlow context state = case state of
  DailyFlow dailyState -> Daily.drawFlow context dailyState
  RecordFlow recordState -> Record.drawFlow context recordState
  ReverseFlow reverseState -> Reverse.drawFlow reverseState
  WriteOutcome outcome ->
    center
      (borderWithLabel (str "Actual Write Result")
        (padAll 1
          (renderWriteOutcome outcome
            <=> str " " <=> str "[Esc] Actual | [Q] Quit")))
  RealizeWriteOutcome message ->
    center
      (borderWithLabel (str "Issue Realize Result")
        (hLimit 86
          (padAll 1
            (withAttr (attrName "error") (txt message)
              <=> str " " <=> str "[Esc] Issues | [Q] Quit"))))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ -> emptyWidget
  QuitRequested -> emptyWidget

zoomDailyFlow :: Traversal' (State AppEvent) (Daily.State AppEvent)
zoomDailyFlow f (DailyFlow state) = DailyFlow <$> f state
zoomDailyFlow _ state = pure state

zoomRecordFlow :: Traversal' (State AppEvent) (Record.State AppEvent)
zoomRecordFlow f (RecordFlow state) = RecordFlow <$> f state
zoomRecordFlow _ state = pure state

zoomReverseFlow :: Traversal' (State AppEvent) (Reverse.State AppEvent)
zoomReverseFlow f (ReverseFlow state) = ReverseFlow <$> f state
zoomReverseFlow _ state = pure state

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleFlowEvent context event = do
  state <- get
  case state of
    DailyFlow _ -> do
      action <- zoom (singular zoomDailyFlow) (Daily.handleFlowEvent context event)
      case action of
        Daily.FlowMaintain -> pure ()
        Daily.FlowReturn -> put ReturnToWorkspace
        Daily.FlowQuit -> put QuitRequested
        Daily.FlowPublish stickyDay block ->
          put (PublishRequested (PublishActual stickyDay block))
    RecordFlow _ -> do
      action <- zoom (singular zoomRecordFlow) (Record.handleFlowEvent context event)
      case action of
        Record.FlowMaintain -> pure ()
        Record.FlowReturn -> put ReturnToWorkspace
        Record.FlowQuit -> put QuitRequested
        Record.FlowPublishActual stickyDay block ->
          put (PublishRequested (PublishActual stickyDay block))
        Record.FlowPublishIssueRealize stickyDay intent ->
          put (PublishRequested (PublishIssueRealize stickyDay intent))
    ReverseFlow _ -> do
      action <- zoom (singular zoomReverseFlow) (Reverse.handleFlowEvent context event)
      case action of
        Reverse.FlowMaintain -> pure ()
        Reverse.FlowReturn -> put ReturnToWorkspace
        Reverse.FlowQuit -> put QuitRequested
        Reverse.FlowPublish block ->
          put (PublishRequested (PublishActual (contextEntryDay context) block))
    WriteOutcome _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      _ -> pure ()
    RealizeWriteOutcome _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      _ -> pure ()
    ReturnToWorkspace -> pure ()
    PublishRequested _ -> pure ()
    QuitRequested -> pure ()

drawWorkspace :: AppContext -> Widget Name
drawWorkspace = Workspace.drawWorkspace

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext WorkspaceAction
handleWorkspaceEvent = Workspace.handleWorkspaceEvent

applyWorkspaceAccountFilter :: AppContext -> AppContext
applyWorkspaceAccountFilter = Workspace.applyWorkspaceAccountFilter

toggleWorkspaceFocus :: AppContext -> AppContext
toggleWorkspaceFocus = Workspace.toggleWorkspaceFocus

publishCandidate :: AppContext -> PublishRequest -> IO PublishResult
publishCandidate context request = case request of
  PublishActual stickyDay block -> publishActualCandidate stickyDay block
  PublishIssueRealize stickyDay intent -> publishRealizeCandidate stickyDay intent
  where
    state = contextHouseholdState context
    root = householdStateRoot state
    publishActualCandidate stickyDay block = do
      let stickyContext = context { contextEntryDay = stickyDay }
          postAdmission _ = loadCanonicalHousehold root
      writeResult <- publishActualBlockWithPathAdmission
        postAdmission
        (contextSourcePath context)
        (contextSource context)
        block
      let writeOutcome = classifyActualAddWriteResult writeResult
      case writeOutcome of
        ActualAddWriteSucceeded -> reloadAfter stickyContext
        _ -> pure (PublicationFailed writeOutcome)
    publishRealizeCandidate stickyDay intent = do
      let realizationState = contextHouseholdState context
          paths = householdStatePaths realizationState
          relationPath = householdIssueRelationsPath paths
      relationResult <- readOptionalRelationSource relationPath
      case relationResult of
        Left message -> finishRealizationFailure True
          ("Issue realization source read failed: " <> message)
        Right (relationExists, relationSource) -> do
          let observed = IssueRealizeObservedSources
                { issueRealizeObservedActualPath = householdActualJournalPath paths
                , issueRealizeObservedActualJournal =
                    householdStateActualJournal realizationState
                , issueRealizeObservedActualSource = contextSource context
                , issueRealizeObservedPlanJournal =
                    householdStatePlanJournal realizationState
                , issueRealizeObservedRelationPath = relationPath
                , issueRealizeObservedRelationExists = relationExists
                , issueRealizeObservedRelationSource = relationSource
                , issueRealizeObservedIssuesPath = householdIssuesPath paths
                , issueRealizeObservedIssuesSource = contextIssuesSource context
                }
          writeResult <- publishIssueRealizeFromObservedSources
            (admitIssueRealizeAfterWrite root relationPath)
            observed
            intent
          case writeResult of
            Right () -> reloadRealizationAfter
              (context { contextEntryDay = stickyDay })
            Left operationError -> finishRealizationFailure
              (realizationFailureRecoverySafe operationError)
              ("Issue realization write failed: "
                <> T.pack (show operationError))
    finishRealizationFailure recoverySafe message
      | not recoverySafe = pure ReloadFailed
      | otherwise = do
          reloadedContext <- reloadAndAdmitRealization False context
          pure $ case reloadedContext of
            Nothing -> ReloadFailed
            Just freshContext -> RealizationFailed freshContext message
    reloadAfter stickyContext = do
      reloadedContext <- reloadWorkspaceContext stickyContext
      pure (maybe ReloadFailed Published reloadedContext)
    reloadRealizationAfter stickyContext = do
      reloadedContext <- reloadAndAdmitRealization True stickyContext
      pure (maybe ReloadFailed Published reloadedContext)

readOptionalRelationSource :: FilePath -> IO (Either Text (Bool, Text))
readOptionalRelationSource path = do
  result <- tryIOError (TIO.readFile path)
  pure $ case result of
    Right source -> Right (True, source)
    Left errorValue
      | isDoesNotExistError errorValue -> Right (False, "")
      | otherwise -> Left ("Relation source read failed: " <> T.pack (show errorValue))

realizationFailureRecoverySafe
  :: IssueRealizeOperationError admissionError
  -> Bool
realizationFailureRecoverySafe operationError = case operationError of
  IssueRealizePreparationFailed _ -> True
  IssueRealizePublicationFailed writeError -> writeFailureRecoverySafe writeError

writeFailureRecoverySafe
  :: IssueRealizeWriteError admissionError
  -> Bool
writeFailureRecoverySafe writeError = case writeError of
  IssueRealizeActualStale -> True
  IssueRealizeRelationStale -> True
  IssueRealizeIssuesStale -> True
  IssueRealizePostAdmissionFailed _ actualSafe relationSafe issuesSafe ->
    actualSafe && relationSafe && issuesSafe
  IssueRealizeFileIOError _ actualSafe relationSafe issuesSafe ->
    actualSafe && relationSafe && issuesSafe

reloadAndAdmitRealization
  :: Bool
  -> AppContext
  -> IO (Maybe AppContext)
reloadAndAdmitRealization requireRelationSource context = do
  reloadedContext <- reloadWorkspaceContext context
  case reloadedContext of
    Nothing -> pure Nothing
    Just freshContext -> do
      let state = contextHouseholdState freshContext
          relationPath = householdIssueRelationsPath (householdStatePaths state)
      relationRead <- tryIOError (TIO.readFile relationPath)
      let relationSource = case relationRead of
            Right source -> Just (True, source)
            Left errorValue
              | isDoesNotExistError errorValue -> Just (False, "")
              | otherwise -> Nothing
      pure $ do
        (relationExists, source) <- relationSource
        if requireRelationSource && not relationExists
          then Nothing
          else pure ()
        case admitIssueRelationSource
            (householdStateActualJournal state)
            (householdStatePlanJournal state)
            (householdStateIssues state)
            source of
          Left _ -> Nothing
          Right _ -> Just freshContext

admitIssueRealizeAfterWrite
  :: HouseholdRoot
  -> FilePath
  -> IO (Either String ())
admitIssueRealizeAfterWrite root relationPath = do
  householdResult <- loadCanonicalHousehold root
  case householdResult of
    Left errors -> pure
      (Left ("Household post-admission failed: " <> show errors))
    Right state -> do
      relationRead <- tryIOError (TIO.readFile relationPath)
      case relationRead of
        Left errorValue -> pure
          (Left ("Relation post-admission read failed: " <> show errorValue))
        Right relationSource -> pure $ case admitIssueRelationSource
            (householdStateActualJournal state)
            (householdStatePlanJournal state)
            (householdStateIssues state)
            relationSource of
          Left errors -> Left
            ("Relation post-admission failed: " <> show (NonEmpty.toList errors))
          Right _ -> Right ()

renderWriteOutcome :: ActualAddWriteOutcome -> Widget Name
renderWriteOutcome outcome = case outcome of
  ActualAddWriteSucceeded -> withAttr (attrName "success")
    (str "Published and post-admitted successfully.")
  ActualAddWriteStale -> withAttr (attrName "error")
    (vBox
      [ str "Source changed after preview. Nothing was written."
      , str "Return to Actual and preview the current source before retrying."
      ])
  ActualAddWriteRecovered failure -> withAttr (attrName "warning")
    (vBox
      [ str "Publication failed, and the backup was restored."
      , txt (writeFailureText failure)
      ])
  ActualAddWriteFileIOFailed -> withAttr (attrName "error")
    (vBox
      [ str "The writer could not complete because of a filesystem error."
      , str "No source-local error detail is retained in the TUI state."
      ])
  ActualAddWriteFailed failure -> withAttr (attrName "error")
    (vBox
      [ str "Publication failed and automatic recovery did not complete."
      , txt (writeFailureText failure)
      ])

writeFailureText :: ActualAddWriteFailure -> Text
writeFailureText failure = case failure of
  ActualAddPostAdmissionFailure ->
    "The published candidate failed complete-source admission."
  ActualAddPostPublishReadFailure ->
    "The published source could not be read for post-admission."
