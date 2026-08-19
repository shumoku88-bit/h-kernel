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
  , startReconcile
  , startSelectedReverse
  , toggleWorkspaceFocus
  ) where

import Brick
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal', singular)

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import System.IO.Error (isDoesNotExistError, tryIOError)
import Text.Read (readMaybe)

import HKernel.Account
  ( Account
  , accountName
  , declaredAccountDefaultCommodity
  , lookupAccountDeclaration
  )
import HKernel.Actual.Journal (actualJournalValue)
import HKernel.Application.Config (HouseholdRoot, HouseholdSourcePaths(..))
import HKernel.Editor.ActualAppend
  ( ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , classifyActualAddWriteResult
  )
import HKernel.Editor.ActualWorkspace
  ( AccountReconciliation
  , externalBalanceObservedOn
  , externalBalanceValue
  , observeExternalBalance
  , reconcileAccountBalance
  , reconciliationDifference
  , reconciliationExternalObservation
  , reconciliationLedgerBalance
  , reconciliationMatches
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
  , Name(..)
  , WorkspaceReloadFailure(..)
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
import HKernel.Money
  ( Balance
  , balanceEntries
  , commodityCode
  , mkAmount
  , mkCommodity
  , parseQuantity
  , renderQuantity
  , singletonBalance
  )

data State event
  = DailyFlow (Daily.State event)
  | RecordFlow (Record.State event)
  | ReverseFlow (Reverse.State event)
  | ReconcileFlow (ReconcileState event)
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
  | ReloadFailed WorkspaceReloadFailure

data ReconcileInput = ReconcileInput
  { reconcileBalanceText   :: Text
  , reconcileCommodityText :: Text
  , reconcileDateText      :: Text
  }

data ReconcileState event
  = ReconcileInputState Account (Form ReconcileInput event Name)
  | ReconcileResultState
      Account
      (Either Text AccountReconciliation)
      (Form ReconcileInput event Name)

startDaily :: Day -> State event
startDaily = DailyFlow . Daily.startDaily

startIncome :: Day -> State event
startIncome = DailyFlow . Daily.startIncome

startRecord :: Day -> State event
startRecord = RecordFlow . Record.startRecord

startIssueRealize :: Day -> HouseholdIssue -> Maybe (State event)
startIssueRealize day issue = RecordFlow <$> Record.startIssueRealize day issue

startReconcile :: AppContext -> Account -> State event
startReconcile context account =
  ReconcileFlow (ReconcileInputState account (mkReconcileForm context account))

startSelectedReverse :: AppContext -> State event
startSelectedReverse = ReverseFlow . Reverse.startSelected

reconcileBalanceTextL :: Lens' ReconcileInput Text
reconcileBalanceTextL f input =
  (\value -> input { reconcileBalanceText = value })
    <$> f (reconcileBalanceText input)

reconcileCommodityTextL :: Lens' ReconcileInput Text
reconcileCommodityTextL f input =
  (\value -> input { reconcileCommodityText = value })
    <$> f (reconcileCommodityText input)

reconcileDateTextL :: Lens' ReconcileInput Text
reconcileDateTextL f input =
  (\value -> input { reconcileDateText = value })
    <$> f (reconcileDateText input)

mkReconcileForm
  :: AppContext
  -> Account
  -> Form ReconcileInput event Name
mkReconcileForm context account =
  setFormFocus AmountField
    (newForm
      [ label "External balance:"
          @@= editTextField reconcileBalanceTextL AmountField (Just 1)
      , label "Commodity:"
          @@= editTextField reconcileCommodityTextL AccountCommodityField (Just 1)
      , label "Observed on:"
          @@= editTextField reconcileDateTextL DateField (Just 1)
      ] initialInput)
  where
    label labelText widget =
      padBottom (Pad 1)
        ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)
    registry = householdStateAccountsRegistry (contextHouseholdState context)
    defaultCommodity =
      lookupAccountDeclaration account registry >>= declaredAccountDefaultCommodity
    initialInput = ReconcileInput
      { reconcileBalanceText = ""
      , reconcileCommodityText = maybe "" commodityCode defaultCommodity
      , reconcileDateText = T.pack (show (contextObservationDay context))
      }

drawFlow :: AppContext -> State AppEvent -> Widget Name
drawFlow context state = case state of
  DailyFlow dailyState -> Daily.drawFlow context dailyState
  RecordFlow recordState -> Record.drawFlow context recordState
  ReverseFlow reverseState -> Reverse.drawFlow reverseState
  ReconcileFlow reconcileState -> drawReconcileFlow reconcileState
  WriteOutcome outcome ->
    center
      (borderWithLabel (str "Actual Write Result")
        (padAll 1
          (renderWriteOutcome outcome
            <=> str " " <=> strWrap "[Esc] Actual | [Q] Quit")))
  RealizeWriteOutcome message ->
    center
      (borderWithLabel (str "Issue Realize Result")
        (hLimit 86
          (padAll 1
            (withAttr (attrName "error") (txtWrap message)
              <=> str " " <=> strWrap "[Esc] Issues | [Q] Quit"))))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ -> emptyWidget
  QuitRequested -> emptyWidget

drawReconcileFlow :: ReconcileState AppEvent -> Widget Name
drawReconcileFlow reconcileState = case reconcileState of
  ReconcileInputState account form ->
    center
      (borderWithLabel (str "Compare Account Balance")
        (hLimit 76
          (padAll 1
            (vBox
              [ txtWrap ("Account: " <> accountName account)
              , strWrap "External balance is temporary observation evidence. It will not modify actual.journal."
              , str " "
              , renderForm form
              , str " "
              , strWrap "[Tab] Next field | [Enter] Compare | [Esc] Actual"
              ]))))
  ReconcileResultState account result _ ->
    center
      (borderWithLabel (str "Account Reconciliation")
        (hLimit 76
          (padAll 1
            (case result of
              Left message ->
                withAttr (attrName "error")
                  (txtWrap ("Input rejected: " <> message))
                  <=> str " "
                  <=> strWrap "[Esc/B] Edit | [Enter] Actual | [Q] Quit"
              Right reconciliation ->
                renderReconciliation account reconciliation
                  <=> str " "
                  <=> strWrap "[Esc/B] Edit | [Enter] Actual | [Q] Quit"))))

renderReconciliation :: Account -> AccountReconciliation -> Widget Name
renderReconciliation account reconciliation =
  vBox
    [ txtWrap ("Account: " <> accountName account)
    , txtWrap ("Observed on: " <> T.pack (show observedOn))
    , str " "
    , txtWrap ("External observed: " <> renderBalance externalBalance)
    , txtWrap ("Canonical ledger:  " <> renderBalance ledgerBalance)
    , txtWrap ("Difference:        " <> renderBalance difference)
    , str " "
    , status
    , str " "
    , strWrap "Difference = external observed balance - canonical ledger balance. No source was modified."
    ]
  where
    external = reconciliationExternalObservation reconciliation
    observedOn = externalBalanceObservedOn external
    externalBalance = externalBalanceValue external
    ledgerBalance = reconciliationLedgerBalance reconciliation
    difference = reconciliationDifference reconciliation
    status
      | reconciliationMatches reconciliation =
          withAttr (attrName "success") (str "Status: MATCHED")
      | otherwise =
          withAttr (attrName "warning")
            (str "Status: DIFFERENCE | inspect this Account's Actual history")

renderBalance :: Balance -> Text
renderBalance balance = case balanceEntries balance of
  [] -> "0"
  entries -> T.intercalate ", "
    [ renderQuantity quantity <> " " <> commodityCode commodity
    | (commodity, quantity) <- entries
    ]

zoomDailyFlow :: Traversal' (State AppEvent) (Daily.State AppEvent)
zoomDailyFlow f (DailyFlow state) = DailyFlow <$> f state
zoomDailyFlow _ state = pure state

zoomRecordFlow :: Traversal' (State AppEvent) (Record.State AppEvent)
zoomRecordFlow f (RecordFlow state) = RecordFlow <$> f state
zoomRecordFlow _ state = pure state

zoomReverseFlow :: Traversal' (State AppEvent) (Reverse.State AppEvent)
zoomReverseFlow f (ReverseFlow state) = ReverseFlow <$> f state
zoomReverseFlow _ state = pure state

zoomReconcileFlow :: Traversal' (State AppEvent) (ReconcileState AppEvent)
zoomReconcileFlow f (ReconcileFlow state) = ReconcileFlow <$> f state
zoomReconcileFlow _ state = pure state

zoomReconcileForm
  :: Traversal'
      (ReconcileState AppEvent)
      (Form ReconcileInput AppEvent Name)
zoomReconcileForm f (ReconcileInputState account form) =
  ReconcileInputState account <$> f form
zoomReconcileForm _ state = pure state

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
    ReconcileFlow _ -> do
      action <- zoom (singular zoomReconcileFlow)
        (handleReconcileEvent context event)
      case action of
        ReconcileMaintain -> pure ()
        ReconcileReturn -> put ReturnToWorkspace
        ReconcileQuit -> put QuitRequested
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

data ReconcileAction
  = ReconcileMaintain
  | ReconcileReturn
  | ReconcileQuit

handleReconcileEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (ReconcileState AppEvent) ReconcileAction
handleReconcileEvent context event = do
  state <- get
  case state of
    ReconcileInputState account form -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> pure ReconcileReturn
      VtyEvent (V.EvKey V.KEnter []) -> do
        put (ReconcileResultState account
          (prepareReconciliation context account (formState form)) form)
        pure ReconcileMaintain
      _ -> zoom zoomReconcileForm (handleFormEvent event) >> pure ReconcileMaintain
    ReconcileResultState account _ form -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> back account form
      VtyEvent (V.EvKey (V.KChar 'b') []) -> back account form
      VtyEvent (V.EvKey (V.KChar 'B') []) -> back account form
      VtyEvent (V.EvKey V.KEnter []) -> pure ReconcileReturn
      VtyEvent (V.EvKey (V.KChar 'q') []) -> pure ReconcileQuit
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure ReconcileQuit
      _ -> pure ReconcileMaintain
  where
    back account form = put (ReconcileInputState account form) >> pure ReconcileMaintain

prepareReconciliation
  :: AppContext
  -> Account
  -> ReconcileInput
  -> Either Text AccountReconciliation
prepareReconciliation context account input = do
  observedOn <- case
      (readMaybe (T.unpack (T.strip (reconcileDateText input))) :: Maybe Day) of
    Nothing -> Left ("Invalid observation date: " <> reconcileDateText input)
    Just day -> Right day
  quantity <- case parseQuantity (T.strip (reconcileBalanceText input)) of
    Left err -> Left ("Invalid external balance: " <> T.pack (show err))
    Right value -> Right value
  commodity <- case mkCommodity (T.strip (reconcileCommodityText input)) of
    Left err -> Left ("Invalid commodity: " <> T.pack (show err))
    Right value -> Right value
  let external = observeExternalBalance account observedOn
        (singletonBalance (mkAmount commodity quantity))
      journal = actualJournalValue
        (householdStateActualJournal (contextHouseholdState context))
  Right (reconcileAccountBalance journal external)

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
      | not recoverySafe = pure
          (ReloadFailed
            (PostReloadValidationFailed
              ("Issue realization failed and automatic recovery could not establish a safe source state: "
                <> message)))
      | otherwise = do
          reloadedContext <- reloadAndAdmitRealization False context
          pure $ case reloadedContext of
            Left failure -> ReloadFailed failure
            Right freshContext -> RealizationFailed freshContext message
    reloadAfter stickyContext = do
      reloadedContext <- reloadWorkspaceContext stickyContext
      pure $ case reloadedContext of
        Left failure -> ReloadFailed failure
        Right freshContext -> Published freshContext
    reloadRealizationAfter stickyContext = do
      reloadedContext <- reloadAndAdmitRealization True stickyContext
      pure $ case reloadedContext of
        Left failure -> ReloadFailed failure
        Right freshContext -> Published freshContext

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
  -> IO (Either WorkspaceReloadFailure AppContext)
reloadAndAdmitRealization requireRelationSource context = do
  reloadedContext <- reloadWorkspaceContext context
  case reloadedContext of
    Left failure -> pure (Left failure)
    Right freshContext -> do
      let state = contextHouseholdState freshContext
          relationPath = householdIssueRelationsPath (householdStatePaths state)
      relationRead <- tryIOError (TIO.readFile relationPath)
      case relationRead of
        Left errorValue
          | isDoesNotExistError errorValue ->
              validateRelation freshContext relationPath False ""
          | otherwise -> pure
              (Left
                (PostReloadValidationFailed
                  ("Issue relation reload read failed: "
                    <> T.pack (show errorValue))))
        Right source -> validateRelation freshContext relationPath True source
  where
    validateRelation freshContext relationPath relationExists source
      | requireRelationSource && not relationExists =
          pure
            (Left
              (PostReloadValidationFailed
                ("Issue relation source is required after realization but is missing: "
                  <> T.pack relationPath)))
      | otherwise =
          let state = contextHouseholdState freshContext
          in pure $ case admitIssueRelationSource
              (householdStateActualJournal state)
              (householdStatePlanJournal state)
              (householdStateIssues state)
              source of
            Left errors ->
              Left
                (PostReloadValidationFailed
                  ("Issue relation post-reload admission failed: "
                    <> T.pack (show (NonEmpty.toList errors))))
            Right _ -> Right freshContext

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
    (strWrap "Published and post-admitted successfully.")
  ActualAddWriteStale -> withAttr (attrName "error")
    (vBox
      [ strWrap "Source changed after preview. Nothing was written."
      , strWrap "Return to Actual and preview the current source before retrying."
      ])
  ActualAddWriteRecovered failure -> withAttr (attrName "warning")
    (vBox
      [ strWrap "Publication failed, and the backup was restored."
      , txtWrap (writeFailureText failure)
      ])
  ActualAddWriteFileIOFailed -> withAttr (attrName "error")
    (vBox
      [ strWrap "The writer could not complete because of a filesystem error."
      , strWrap "No source-local error detail is retained in the TUI state."
      ])
  ActualAddWriteFailed failure -> withAttr (attrName "error")
    (vBox
      [ strWrap "Publication failed and automatic recovery did not complete."
      , txtWrap (writeFailureText failure)
      ])

writeFailureText :: ActualAddWriteFailure -> Text
writeFailureText failure = case failure of
  ActualAddPostAdmissionFailure ->
    "The published candidate failed complete-source admission."
  ActualAddPostPublishReadFailure ->
    "The published source could not be read for post-admission."
