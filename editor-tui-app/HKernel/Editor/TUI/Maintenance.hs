{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Maintenance
  ( AccountsWorkspaceAction(..)
  , EntitlementWorkspaceAction(..)
  , IssuesWorkspaceAction(..)
  , PublishRequest(..)
  , PublishResult(..)
  , State(..)
  , drawAccountsWorkspace
  , drawEntitlementWorkspace
  , drawIssuesWorkspace
  , drawFlow
  , handleAccountsWorkspaceEvent
  , handleEntitlementWorkspaceEvent
  , handleFlowEvent
  , handleIssuesWorkspaceEvent
  , publishCandidate
  , startAccountAdd
  , startEntitlementTransfer
  , startIssueAdd
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Lens.Micro (Traversal', singular)

import Data.List (sortOn)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import qualified Data.Vector as Vec
import System.IO.Error (tryIOError)

import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Editor.AccountAppend (AccountJournalAppendPreview)
import HKernel.Editor.EntitlementTransferAppend (EntitlementTransferAppendPreview)
import HKernel.Editor.HouseholdWorkspace (admitIssueRelationSource)
import HKernel.Editor.IssueAppend
  ( IssueAppendPreview
  , IssueClosePreview
  , IssueDueUpdatePreview
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteIntent(..)
  , publishWithAdmission
  )
import qualified HKernel.Editor.TUI.Maintenance.Accounts as Accounts
import qualified HKernel.Editor.TUI.Maintenance.Entitlement as Entitlement
import qualified HKernel.Editor.TUI.Maintenance.Issues as Issues
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , WorkspaceReloadFailure
  , contextHouseholdState
  , reloadWorkspaceContext
  )
import HKernel.Editor.TUI.SourcePreview (renderSourcePreview)
import HKernel.Household.Application (HouseholdState(..))
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

data ContinuationPreview = ContinuationPreview
  { continuationRelation       :: IssueRelationEvent
  , continuationRow            :: Text
  , continuationExpectedSource :: Text
  , continuationCandidateSource :: Text
  }

data State event
  = EntitlementFlow (Entitlement.State event)
  | AccountFlow (Accounts.State event)
  | IssueFlow (Issues.State event)
  | IssueContinuationPicker HouseholdIssue Text (L.List Name HouseholdIssue)
  | IssueContinuationPreview
      HouseholdIssue
      HouseholdIssue
      Text
      (Either Text ContinuationPreview)
  | WriteOutcome Text
  | ReturnToWorkspace
  | PublishRequested PublishRequest
  | QuitRequested

data PublishRequest
  = PublishEntitlement EntitlementTransferAppendPreview
  | PublishAccount Text AccountJournalAppendPreview
  | PublishIssueAdd IssueAppendPreview
  | PublishIssueDueUpdate IssueDueUpdatePreview
  | PublishIssueClose IssueClosePreview
  | PublishIssueContinuation ContinuationPreview

data PublishResult
  = Published AppContext
  | PublicationFailed Text
  | ReloadFailed WorkspaceReloadFailure

data EntitlementWorkspaceAction
  = EntitlementActionMaintain
  | EntitlementActionStartTransfer
  deriving (Eq, Show)

data AccountsWorkspaceAction
  = AccountsActionMaintain
  | AccountsActionStartAdd
  deriving (Eq, Show)

data IssuesWorkspaceAction
  = IssuesActionMaintain
  | IssuesActionStartAdd
  | IssuesActionStartDueUpdate (State AppEvent)
  | IssuesActionStartClose (State AppEvent)
  | IssuesActionStartContinuation (State AppEvent)
  | IssuesActionStartRealize HouseholdIssue

startEntitlementTransfer :: State event
startEntitlementTransfer = EntitlementFlow Entitlement.start

startAccountAdd :: State event
startAccountAdd = AccountFlow Accounts.start

startIssueAdd :: State event
startIssueAdd = IssueFlow Issues.startAdd

drawEntitlementWorkspace :: AppContext -> Widget Name
drawEntitlementWorkspace = Entitlement.drawWorkspace

drawAccountsWorkspace :: AppContext -> Widget Name
drawAccountsWorkspace = Accounts.drawWorkspace

drawIssuesWorkspace :: AppContext -> Widget Name
drawIssuesWorkspace context =
  Issues.drawWorkspace context
    <=> strWrap "[F] Continued from another Issue"

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  EntitlementFlow entitlementState -> Entitlement.drawFlow entitlementState
  AccountFlow accountState -> Accounts.drawFlow accountState
  IssueFlow issueState -> Issues.drawFlow issueState
  IssueContinuationPicker target _ choices -> drawContinuationPicker target choices
  IssueContinuationPreview target source _ result ->
    drawContinuationPreview target source result
  WriteOutcome message ->
    center (borderWithLabel (str "Maintenance Result")
      (hLimit 84
        (padAll 1
          (txtWrap message <=> str " " <=> strWrap "[Esc] Workspace   [Q] Quit"))))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ -> emptyWidget
  QuitRequested -> emptyWidget

drawContinuationPicker
  :: HouseholdIssue
  -> L.List Name HouseholdIssue
  -> Widget Name
drawContinuationPicker target choices =
  center
    (borderWithLabel (str "Issue continued from")
      (hLimit 96
        (vLimit 34
          (padAll 1
            (vBox
              [ txtWrap
                  ("Current Issue: " <> issueIdText (householdIssueId target)
                    <> "  " <> householdIssueText target)
              , str " "
              , strWrap "Choose the earlier Issue. Candidates are newest first."
              , str " "
              , vLimit 20 (L.renderList renderContinuationChoice True choices)
              , str " "
              , strWrap "[j/k/Arrows] Move   [Enter] Preview   [Esc] Issues"
              ])))))

drawContinuationPreview
  :: HouseholdIssue
  -> HouseholdIssue
  -> Either Text ContinuationPreview
  -> Widget Name
drawContinuationPreview target source result =
  center
    (borderWithLabel (str "Issue continuation preview")
      (hLimit 96
        (vLimit 32
          (padAll 1
            (vBox
              [ txtWrap
                  (issueIdText (householdIssueId source)
                    <> "  -> continued-as ->  "
                    <> issueIdText (householdIssueId target))
              , str " "
              , case result of
                  Left message -> withAttr (attrName "error") (txtWrap message)
                  Right preview -> renderSourcePreview (continuationRow preview)
              , str " "
              , strWrap
                  (case result of
                    Left _ -> "[Esc] Back   [Q] Quit"
                    Right _ -> "[Enter] Publish   [Esc] Back   [Q] Quit")
              ])))))

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

zoomEntitlementFlow :: Traversal' (State AppEvent) (Entitlement.State AppEvent)
zoomEntitlementFlow f (EntitlementFlow state) = EntitlementFlow <$> f state
zoomEntitlementFlow _ state = pure state

zoomAccountFlow :: Traversal' (State AppEvent) (Accounts.State AppEvent)
zoomAccountFlow f (AccountFlow state) = AccountFlow <$> f state
zoomAccountFlow _ state = pure state

zoomIssueFlow :: Traversal' (State AppEvent) (Issues.State AppEvent)
zoomIssueFlow f (IssueFlow state) = IssueFlow <$> f state
zoomIssueFlow _ state = pure state

zoomContinuationList
  :: Traversal' (State AppEvent) (L.List Name HouseholdIssue)
zoomContinuationList f (IssueContinuationPicker target source choices) =
  IssueContinuationPicker target source <$> f choices
zoomContinuationList _ state = pure state

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleFlowEvent context event = do
  state <- get
  case state of
    EntitlementFlow _ -> do
      action <- zoom (singular zoomEntitlementFlow) (Entitlement.handleFlowEvent context event)
      case action of
        Entitlement.FlowMaintain -> pure ()
        Entitlement.FlowReturn -> put ReturnToWorkspace
        Entitlement.FlowQuit -> put QuitRequested
        Entitlement.FlowPublish preview -> put (PublishRequested (PublishEntitlement preview))
    AccountFlow _ -> do
      action <- zoom (singular zoomAccountFlow) (Accounts.handleFlowEvent context event)
      case action of
        Accounts.FlowMaintain -> pure ()
        Accounts.FlowReturn -> put ReturnToWorkspace
        Accounts.FlowQuit -> put QuitRequested
        Accounts.FlowPublish source preview ->
          put (PublishRequested (PublishAccount source preview))
    IssueFlow _ -> do
      action <- zoom (singular zoomIssueFlow) (Issues.handleFlowEvent context event)
      case action of
        Issues.FlowMaintain -> pure ()
        Issues.FlowReturn -> put ReturnToWorkspace
        Issues.FlowQuit -> put QuitRequested
        Issues.FlowPublish request -> put (PublishRequested (fromIssueRequest request))
    IssueContinuationPicker target relationSource choices -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey V.KEnter []) ->
        case L.listSelectedElement choices of
          Nothing -> pure ()
          Just (_, source) ->
            put (IssueContinuationPreview
              target
              source
              relationSource
              (prepareIssueContinuation context relationSource source target))
      MouseDown IssueList V.BLeft _ (Location (_, row)) ->
        zoom zoomContinuationList (modify (L.listMoveTo row))
      VtyEvent (V.EvKey vtyKey vtyMods) ->
        zoom zoomContinuationList
          (L.handleListEventVi L.handleListEvent (V.EvKey vtyKey vtyMods))
      _ -> pure ()
    IssueContinuationPreview target source relationSource result -> case event of
      VtyEvent (V.EvKey V.KEsc []) ->
        put (IssueContinuationPicker target relationSource
          (continuationList target (contextHouseholdState context)))
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      VtyEvent (V.EvKey V.KEnter []) -> case result of
        Left _ -> pure ()
        Right preview -> put (PublishRequested (PublishIssueContinuation preview))
      _ -> pure ()
    WriteOutcome _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      _ -> pure ()
    ReturnToWorkspace -> pure ()
    PublishRequested _ -> pure ()
    QuitRequested -> pure ()

fromIssueRequest :: Issues.PublishRequest -> PublishRequest
fromIssueRequest request = case request of
  Issues.PublishAdd preview -> PublishIssueAdd preview
  Issues.PublishDueUpdate preview -> PublishIssueDueUpdate preview
  Issues.PublishClose preview -> PublishIssueClose preview

handleEntitlementWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s EntitlementWorkspaceAction
handleEntitlementWorkspaceEvent event = do
  action <- Entitlement.handleWorkspaceEvent event
  pure $ case action of
    Entitlement.WorkspaceMaintain -> EntitlementActionMaintain
    Entitlement.WorkspaceStartTransfer -> EntitlementActionStartTransfer

handleAccountsWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s AccountsWorkspaceAction
handleAccountsWorkspaceEvent event = do
  action <- Accounts.handleWorkspaceEvent event
  pure $ case action of
    Accounts.WorkspaceMaintain -> AccountsActionMaintain
    Accounts.WorkspaceStartAdd -> AccountsActionStartAdd

handleIssuesWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext IssuesWorkspaceAction
handleIssuesWorkspaceEvent event = case event of
  VtyEvent (V.EvKey (V.KChar 'f') []) -> openSelectedContinuation
  VtyEvent (V.EvKey (V.KChar 'F') []) -> openSelectedContinuation
  _ -> do
    action <- Issues.handleWorkspaceEvent event
    pure $ case action of
      Issues.WorkspaceMaintain -> IssuesActionMaintain
      Issues.WorkspaceStartAdd -> IssuesActionStartAdd
      Issues.WorkspaceStartDueUpdate flow -> IssuesActionStartDueUpdate (IssueFlow flow)
      Issues.WorkspaceDueUpdateUnavailable message ->
        IssuesActionStartDueUpdate (WriteOutcome message)
      Issues.WorkspaceStartClose flow -> IssuesActionStartClose (IssueFlow flow)
      Issues.WorkspaceCloseUnavailable message ->
        IssuesActionStartClose (WriteOutcome message)
      Issues.WorkspaceStartRealize issue -> IssuesActionStartRealize issue
  where
    openSelectedContinuation = do
      context <- get
      case L.listSelectedElement (contextIssueList context) of
        Nothing -> pure IssuesActionMaintain
        Just (_, target) -> do
          let state = contextHouseholdState context
              path = householdIssueRelationsPath (householdStatePaths state)
          sourceResult <- suspendAndResume' (tryIOError (TIO.readFile path))
          case sourceResult of
            Left err -> pure (IssuesActionStartContinuation (WriteOutcome
              ("Cannot read issue-relations.tsv: " <> T.pack (show err))))
            Right relationSource -> case admitIssueRelationSource
                (householdStateActualJournal state)
                (householdStatePlanJournal state)
                (householdStateIssues state)
                relationSource of
              Left errors -> pure (IssuesActionStartContinuation (WriteOutcome
                ("Issue relation admission failed: "
                  <> T.pack (show (NonEmpty.toList errors)))))
              Right _ ->
                let choices = continuationList target state
                in if Vec.null (L.listElements choices)
                    then pure (IssuesActionStartContinuation (WriteOutcome
                      "No earlier Issue is available as a continuation source."))
                    else pure (IssuesActionStartContinuation
                      (IssueContinuationPicker target relationSource choices))

continuationList
  :: HouseholdIssue
  -> HouseholdState
  -> L.List Name HouseholdIssue
continuationList target state =
  L.list IssueList
    (Vec.fromList (continuationCandidates target (householdStateIssues state)))
    1

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

prepareIssueContinuation
  :: AppContext
  -> Text
  -> HouseholdIssue
  -> HouseholdIssue
  -> Either Text ContinuationPreview
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
  existing <- case admitIssueRelationSource
      (householdStateActualJournal household)
      (householdStatePlanJournal household)
      (householdStateIssues household)
      relationSource of
    Left errors -> Left
      ("Issue relation admission failed: "
        <> T.pack (show (NonEmpty.toList errors)))
    Right relations -> Right relations
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
  row <- renderSingleRelationRow relation
  let candidateSource = appendRelationRow relationSource row
  _ <- case admitIssueRelationSource
      (householdStateActualJournal household)
      (householdStatePlanJournal household)
      (householdStateIssues household)
      candidateSource of
    Left errors -> Left
      ("Candidate relation rejected: "
        <> T.pack (show (NonEmpty.toList errors)))
    Right admitted -> Right admitted
  pure ContinuationPreview
    { continuationRelation = relation
    , continuationRow = row
    , continuationExpectedSource = relationSource
    , continuationCandidateSource = candidateSource
    }

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

renderSingleRelationRow :: IssueRelationEvent -> Either Text Text
renderSingleRelationRow relation =
  case T.lines (renderIssueRelations [relation]) of
    _header : row : _ -> Right row
    _ -> Left "Issue relation renderer produced no data row."

appendRelationRow :: Text -> Text -> Text
appendRelationRow existing row
  | hasMeaningfulSource = ensureLineEnd existing <> row <> "\n"
  | otherwise =
      ensureLineEnd existing <> issueRelationHeader <> "\n" <> row <> "\n"
  where
    hasMeaningfulSource = any meaningful (T.lines existing)
    meaningful line =
      let stripped = T.strip line
      in not (T.null stripped) && not ("#" `T.isPrefixOf` stripped)
    ensureLineEnd source
      | T.null source = ""
      | T.isSuffixOf "\n" source = source
      | otherwise = source <> "\n"

publishCandidate :: AppContext -> PublishRequest -> IO PublishResult
publishCandidate context request = case request of
  PublishEntitlement preview -> do
    result <- Entitlement.publishCandidate context preview
    pure $ case result of
      Entitlement.Published fresh -> Published fresh
      Entitlement.PublicationFailed message -> PublicationFailed message
      Entitlement.ReloadFailed failure -> ReloadFailed failure
  PublishAccount source preview -> do
    result <- Accounts.publishCandidate context source preview
    pure $ case result of
      Accounts.Published fresh -> Published fresh
      Accounts.PublicationFailed message -> PublicationFailed message
      Accounts.ReloadFailed failure -> ReloadFailed failure
  PublishIssueAdd preview -> publishIssue (Issues.PublishAdd preview)
  PublishIssueDueUpdate preview -> publishIssue (Issues.PublishDueUpdate preview)
  PublishIssueClose preview -> publishIssue (Issues.PublishClose preview)
  PublishIssueContinuation preview -> publishContinuation preview
  where
    publishIssue issueRequest = do
      result <- Issues.publishCandidate context issueRequest
      pure $ case result of
        Issues.Published fresh -> Published fresh
        Issues.PublicationFailed message -> PublicationFailed message
        Issues.ReloadFailed failure -> ReloadFailed failure
    publishContinuation preview = do
      let state = contextHouseholdState context
          paths = householdStatePaths state
          admission source = admitIssueRelationSource
            (householdStateActualJournal state)
            (householdStatePlanJournal state)
            (householdStateIssues state)
            source
      result <- publishWithAdmission admission WriteIntent
        { targetFilePath = householdIssueRelationsPath paths
        , expectedOldBytes = ExpectedSource (continuationExpectedSource preview)
        , candidateNewBytes = CandidateSource (continuationCandidateSource preview)
        }
      case result of
        Left err -> pure (PublicationFailed (T.pack (show err)))
        Right () -> do
          reloaded <- reloadWorkspaceContext
            (context { contextCurrentSection = IssuesSection })
          pure $ case reloaded of
            Left failure -> ReloadFailed failure
            Right fresh -> Published (fresh { contextCurrentSection = IssuesSection })
