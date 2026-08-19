{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Maintenance.Issues
  ( State
  , FlowAction(..)
  , PublishRequest(..)
  , PublishResult(..)
  , WorkspaceAction(..)
  , drawFlow
  , drawWorkspace
  , handleFlowEvent
  , handleWorkspaceEvent
  , publishCandidate
  , startAdd
  ) where

import Brick
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal')

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Editor.HouseholdWorkspace (IssueWorkspaceFilter(..))
import HKernel.Editor.IssueAppend
  ( IssueAppendIntent(..)
  , IssueAppendPreview(..)
  , IssueCloseDisposition(..)
  , IssueCloseIntent(..)
  , IssueClosePreview(..)
  , IssueDueUpdateIntent(..)
  , IssueDueUpdatePreview(..)
  , generateAvailableIssueId
  , prepareIssueAppendWithDue
  , prepareIssueClose
  , prepareIssueCloseOn
  , prepareIssueDueUpdate
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteIntent(..)
  , publishWithPathAdmission
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , contextHouseholdState
  , contextIssueCounts
  , contextIssueListL
  , contextIssuesSource
  , reloadWorkspaceContext
  , setIssueWorkspaceFilter
  )
import HKernel.Editor.TUI.Scroll qualified as Scroll
import HKernel.Editor.TUI.SourcePreview (renderSourcePreview)
import HKernel.Household.Application
  ( HouseholdState(..)
  , loadCanonicalHousehold
  )
import HKernel.Household.Issue.TSV (householdIssueSourceUsesClosedColumn)
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueClosed(..)
  , IssueDue(..)
  , IssueStatus(..)
  , householdIssueAmount
  , householdIssueClosed
  , householdIssueDetails
  , householdIssueDue
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  , householdIssueText
  , issueIdText
  )
import HKernel.Money
  ( Amount
  , amountCommodity
  , amountQuantity
  , commodityCode
  , mkAmount
  , mkCommodity
  , parseQuantity
  , renderQuantity
  )

data PreviewResult preview
  = PreviewRejected Text
  | PreviewReady preview

data IssueInput = IssueInput
  { issueRecordedDateText :: Text
  , issueCategoryText     :: Text
  , issueTitleText        :: Text
  , issueDueText          :: Text
  , issueAmountText       :: Text
  , issueCommodityText    :: Text
  , issueDetailsText      :: Text
  } deriving (Eq, Show)

data IssueDueInput = IssueDueInput
  { issueDueUpdateText :: Text
  } deriving (Eq, Show)

data IssueCloseInput = IssueCloseInput
  { issueClosedDateText   :: Text
  , issueDecisionMemoText :: Text
  } deriving (Eq, Show)

data State event
  = AddInput (Form IssueInput event Name)
  | AddPreview (PreviewResult IssueAppendPreview) (Form IssueInput event Name)
  | DueInput HouseholdIssue (Form IssueDueInput event Name)
  | DuePreview HouseholdIssue (PreviewResult IssueDueUpdatePreview) (Form IssueDueInput event Name)
  | CloseChoice HouseholdIssue
  | CloseInput HouseholdIssue IssueCloseDisposition (Form IssueCloseInput event Name)
  | ClosePreview HouseholdIssue IssueCloseDisposition (PreviewResult IssueClosePreview) (Form IssueCloseInput event Name)

data PublishRequest
  = PublishAdd IssueAppendPreview
  | PublishDueUpdate IssueDueUpdatePreview
  | PublishClose IssueClosePreview

data FlowAction
  = FlowMaintain
  | FlowReturn
  | FlowQuit
  | FlowPublish PublishRequest

data WorkspaceAction
  = WorkspaceMaintain
  | WorkspaceStartAdd
  | WorkspaceStartDueUpdate (State AppEvent)
  | WorkspaceDueUpdateUnavailable Text
  | WorkspaceStartClose (State AppEvent)
  | WorkspaceCloseUnavailable Text
  | WorkspaceStartRealize HouseholdIssue

data PublishResult
  = Published AppContext
  | PublicationFailed Text
  | ReloadFailed

issueRecordedDateL :: Lens' IssueInput Text
issueRecordedDateL f input =
  (\value -> input { issueRecordedDateText = value }) <$> f (issueRecordedDateText input)

issueCategoryL :: Lens' IssueInput Text
issueCategoryL f input = (\value -> input { issueCategoryText = value }) <$> f (issueCategoryText input)

issueTitleL :: Lens' IssueInput Text
issueTitleL f input = (\value -> input { issueTitleText = value }) <$> f (issueTitleText input)

issueDueL :: Lens' IssueInput Text
issueDueL f input = (\value -> input { issueDueText = value }) <$> f (issueDueText input)

issueAmountL :: Lens' IssueInput Text
issueAmountL f input = (\value -> input { issueAmountText = value }) <$> f (issueAmountText input)

issueCommodityL :: Lens' IssueInput Text
issueCommodityL f input = (\value -> input { issueCommodityText = value }) <$> f (issueCommodityText input)

issueDetailsL :: Lens' IssueInput Text
issueDetailsL f input = (\value -> input { issueDetailsText = value }) <$> f (issueDetailsText input)

issueDueUpdateL :: Lens' IssueDueInput Text
issueDueUpdateL f input =
  (\value -> input { issueDueUpdateText = value }) <$> f (issueDueUpdateText input)

issueClosedDateL :: Lens' IssueCloseInput Text
issueClosedDateL f input =
  (\value -> input { issueClosedDateText = value }) <$> f (issueClosedDateText input)

issueDecisionMemoL :: Lens' IssueCloseInput Text
issueDecisionMemoL f input =
  (\value -> input { issueDecisionMemoText = value })
    <$> f (issueDecisionMemoText input)

labelField :: String -> Widget Name -> Widget Name
labelField labelText widget =
  padBottom (Pad 1) ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)

mkIssueForm :: Form IssueInput event Name
mkIssueForm =
  newForm
    [ labelField "Recorded:" @@= editTextField issueRecordedDateL IssueRecordedDateField (Just 1)
    , labelField "Category:" @@= editTextField issueCategoryL IssueCategoryField (Just 1)
    , labelField "Title:" @@= editTextField issueTitleL IssueTitleField (Just 1)
    , labelField "Due:" @@= editTextField issueDueL IssueDueField (Just 1)
    , labelField "Amount:" @@= editTextField issueAmountL IssueAmountField (Just 1)
    , labelField "Commodity:" @@= editTextField issueCommodityL IssueCommodityField (Just 1)
    , labelField "Details:" @@= editTextField issueDetailsL IssueDetailsField (Just 1)
    ]
    (IssueInput "" "general" "" "?" "" "" "")

mkIssueDueForm :: HouseholdIssue -> Form IssueDueInput event Name
mkIssueDueForm issue =
  newForm
    [ labelField "Due:" @@= editTextField issueDueUpdateL IssueDueField (Just 1)
    ]
    (IssueDueInput (renderIssueDueInput (householdIssueDue issue)))

mkIssueCloseForm :: Form IssueCloseInput event Name
mkIssueCloseForm =
  newForm
    [ labelField "Closed:" @@= editTextField issueClosedDateL IssueClosedDateField (Just 1)
    , labelField "Decision memo:" @@= editTextField issueDecisionMemoL IssueDecisionMemoField (Just 1)
    ]
    (IssueCloseInput "" "")

startAdd :: State event
startAdd = AddInput mkIssueForm

zoomIssueForm :: Traversal' (State AppEvent) (Form IssueInput AppEvent Name)
zoomIssueForm f (AddInput form) = AddInput <$> f form
zoomIssueForm _ state = pure state

zoomIssueDueForm :: Traversal' (State AppEvent) (Form IssueDueInput AppEvent Name)
zoomIssueDueForm f (DueInput issue form) = DueInput issue <$> f form
zoomIssueDueForm _ state = pure state

zoomIssueCloseForm :: Traversal' (State AppEvent) (Form IssueCloseInput AppEvent Name)
zoomIssueCloseForm f (CloseInput issue disposition form) =
  CloseInput issue disposition <$> f form
zoomIssueCloseForm _ state = pure state

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  AddInput form -> inputBox "Add Household Issue" form
    [ "Recorded: YYYY-MM-DD; blank uses today's entry date."
    , "Due: YYYY-MM-DD | none | ? (undetermined)."
    , "Issue identity is generated from the recorded date."
    , "Leave both Amount and Commodity blank for a non-monetary Issue."
    , "[Tab] Next field   [Enter] Preview   [Esc] Issues"
    ]
  AddPreview result _ -> previewBox "Issue Preview"
    (renderPreviewResult (renderSourcePreview . candidateBlock) result)
    (previewControls result)
  DueInput issue form -> inputBox "Update Issue Due" form
    [ "Selected: " <> T.unpack (issueIdText (householdIssueId issue))
    , "Due: YYYY-MM-DD | none | ? (undetermined)."
    , "Only the due coordinate will change."
    , "[Enter] Preview   [Esc] Issues"
    ]
  DuePreview _ result _ ->
    previewBox "Issue Due Preview"
      (renderPreviewResult renderIssueDuePreview result)
      (previewControls result)
  CloseChoice issue ->
    center (borderWithLabel (str "Close Selected Issue")
      (hLimit 78 (padAll 1
        (renderIssue issue
          <=> str " "
          <=> strWrap "[R] Resolve   [D] Drop   [Esc] Issues"))))
  CloseInput issue disposition form -> inputBox
    (case disposition of ResolveIssue -> "Resolve Issue"; DropIssue -> "Drop Issue")
    form
    [ "Selected: " <> T.unpack (issueIdText (householdIssueId issue))
    , "Closed: YYYY-MM-DD; blank uses today's entry date on the current schema."
    , "Older 8/9-column sources may close only with this field blank."
    , "[Tab] Next field   [Enter] Preview   [Esc] Back"
    ]
  ClosePreview _ _ result _ ->
    previewBox "Issue Close Preview"
      (renderPreviewResult renderIssueClosePreview result)
      (previewControls result)

inputBox :: String -> Form input AppEvent Name -> [String] -> Widget Name
inputBox title form helpLines =
  center
    (borderWithLabel (str title)
      (hLimit 82
        (padAll 1
          (renderForm form <=> str " " <=> vBox (map strWrap helpLines)))))

previewBox :: String -> Widget Name -> String -> Widget Name
previewBox title body controls =
  center
    (borderWithLabel (str title)
      (hLimit 88
        (vLimit 32
          (padAll 1
            (body <=> str " " <=> strWrap controls)))))

renderPreviewResult
  :: (preview -> Widget Name)
  -> PreviewResult preview
  -> Widget Name
renderPreviewResult renderPreview result = case result of
  PreviewRejected message -> withAttr (attrName "error") (txtWrap message)
  PreviewReady preview -> renderPreview preview

previewControls :: PreviewResult preview -> String
previewControls result = case result of
  PreviewReady _ -> "[Enter] Publish   [Esc] Back   [Q] Quit"
  PreviewRejected _ -> "[Esc] Back   [Q] Quit"

renderIssueDuePreview :: IssueDueUpdatePreview -> Widget Name
renderIssueDuePreview preview =
  renderSourcePreview (dueUpdateOriginalRow preview)
    <=> str " -> "
    <=> renderSourcePreview (dueUpdateCandidateRow preview)

renderIssueClosePreview :: IssueClosePreview -> Widget Name
renderIssueClosePreview preview =
  renderSourcePreview (closeOriginalRow preview)
    <=> str " -> "
    <=> renderSourcePreview (closeCandidateRow preview)

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleFlowEvent context event = do
  state <- get
  case state of
    AddInput form -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
      VtyEvent (V.EvKey V.KEnter []) -> do
        case prepareIssueAdd context (formState form) of
          Left message -> put (AddPreview (PreviewRejected message) form)
          Right preview -> put (AddPreview (PreviewReady preview) form)
        pure FlowMaintain
      _ -> zoom zoomIssueForm (handleFormEvent event) >> pure FlowMaintain
    AddPreview result form -> handlePreview (AddInput form) (PublishAdd <$> ready result) event
    DueInput issue form -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
      VtyEvent (V.EvKey V.KEnter []) -> do
        case prepareSelectedIssueDueUpdate context issue (formState form) of
          Left message -> put (DuePreview issue (PreviewRejected message) form)
          Right preview -> put (DuePreview issue (PreviewReady preview) form)
        pure FlowMaintain
      _ -> zoom zoomIssueDueForm (handleFormEvent event) >> pure FlowMaintain
    DuePreview issue result form ->
      handlePreview (DueInput issue form) (PublishDueUpdate <$> ready result) event
    CloseChoice issue -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
      VtyEvent (V.EvKey (V.KChar 'r') []) -> put (CloseInput issue ResolveIssue mkIssueCloseForm) >> pure FlowMaintain
      VtyEvent (V.EvKey (V.KChar 'R') []) -> put (CloseInput issue ResolveIssue mkIssueCloseForm) >> pure FlowMaintain
      VtyEvent (V.EvKey (V.KChar 'd') []) -> put (CloseInput issue DropIssue mkIssueCloseForm) >> pure FlowMaintain
      VtyEvent (V.EvKey (V.KChar 'D') []) -> put (CloseInput issue DropIssue mkIssueCloseForm) >> pure FlowMaintain
      _ -> pure FlowMaintain
    CloseInput issue disposition form -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put (CloseChoice issue) >> pure FlowMaintain
      VtyEvent (V.EvKey V.KEnter []) -> do
        case prepareSelectedIssueClose context issue disposition (formState form) of
          Left message -> put (ClosePreview issue disposition (PreviewRejected message) form)
          Right preview -> put (ClosePreview issue disposition (PreviewReady preview) form)
        pure FlowMaintain
      _ -> zoom zoomIssueCloseForm (handleFormEvent event) >> pure FlowMaintain
    ClosePreview issue disposition result form ->
      handlePreview (CloseInput issue disposition form) (PublishClose <$> ready result) event
  where
    ready result = case result of
      PreviewReady value -> Just value
      PreviewRejected _ -> Nothing

handlePreview
  :: State AppEvent
  -> Maybe PublishRequest
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handlePreview back request event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put back >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter []) -> maybe (pure FlowMaintain) (pure . FlowPublish) request
  VtyEvent (V.EvKey (V.KChar 'q') []) -> pure FlowQuit
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure FlowQuit
  _ -> pure FlowMaintain

prepareIssueAdd :: AppContext -> IssueInput -> Either Text IssueAppendPreview
prepareIssueAdd context input = do
  recordedOn <- parseIssueDayInput
    (contextEntryDay context) "Recorded" (issueRecordedDateText input)
  issueId <- either (Left . showText) Right
    (generateAvailableIssueId
      recordedOn
      (map householdIssueId
        (householdStateIssues (contextHouseholdState context))))
  due <- parseIssueDueInput (issueDueText input)
  amount <- prepareOptionalAmount (issueAmountText input) (issueCommodityText input)
  let intent = IssueAppendIntent
        { intentIssueId = issueId
        , intentStatus = Open
        , intentDate = recordedOn
        , intentCategory = T.strip (issueCategoryText input)
        , intentTitle = T.strip (issueTitleText input)
        , intentAmount = amount
        , intentDetails = T.strip (issueDetailsText input)
        }
  case prepareIssueAppendWithDue (contextIssuesSource context) due intent of
    Left errors -> Left ("Issue rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview

prepareSelectedIssueDueUpdate
  :: AppContext
  -> HouseholdIssue
  -> IssueDueInput
  -> Either Text IssueDueUpdatePreview
prepareSelectedIssueDueUpdate context issue input = do
  due <- parseIssueDueInput (issueDueUpdateText input)
  let intent = IssueDueUpdateIntent
        { dueUpdateIssueId = householdIssueId issue
        , dueUpdateValue = due
        }
  case prepareIssueDueUpdate (contextIssuesSource context) intent of
    Left errors -> Left ("Issue due update rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview

prepareSelectedIssueClose
  :: AppContext
  -> HouseholdIssue
  -> IssueCloseDisposition
  -> IssueCloseInput
  -> Either Text IssueClosePreview
prepareSelectedIssueClose context issue disposition input =
  if householdIssueSourceUsesClosedColumn source
    then do
      closedOn <- parseIssueDayInput
        (contextEntryDay context) "Closed" rawClosed
      finish (prepareIssueCloseOn source closedOn intent)
    else if T.null rawClosed
      then finish (prepareIssueClose source intent)
      else Left
        "Issue close rejected: the current issues.tsv has no closed column; migrate the source before storing a close date."
  where
    source = contextIssuesSource context
    rawClosed = T.strip (issueClosedDateText input)
    intent = IssueCloseIntent
      { closeIssueId = householdIssueId issue
      , closeDisposition = disposition
      , closeDecisionMemo = issueDecisionMemoText input
      }
    finish result = case result of
      Left errors -> Left ("Issue close rejected: " <> showText (NonEmpty.toList errors))
      Right preview -> Right preview

parseIssueDayInput :: Day -> Text -> Text -> Either Text Day
parseIssueDayInput fallback label input
  | T.null value = Right fallback
  | otherwise = case parseTimeM True defaultTimeLocale "%F" (T.unpack value) of
      Just day -> Right day
      Nothing -> Left (label <> " must be YYYY-MM-DD.")
  where
    value = T.strip input

parseIssueDueInput :: Text -> Either Text IssueDue
parseIssueDueInput input = case T.toCaseFold (T.strip input) of
  "none" -> Right NoDueDate
  "?" -> Right DueUndetermined
  "undetermined" -> Right DueUndetermined
  value -> case parseTimeM True defaultTimeLocale "%F" (T.unpack value) of
    Just day -> Right (DueOn day)
    Nothing -> Left "Due must be YYYY-MM-DD, none, or ?."

renderIssueDueInput :: IssueDue -> Text
renderIssueDueInput due = case due of
  DueOn day -> T.pack (show day)
  NoDueDate -> "none"
  DueUndetermined -> "?"

renderIssueDueDisplay :: IssueDue -> Text
renderIssueDueDisplay due = case due of
  DueOn day -> "due " <> T.pack (show day)
  NoDueDate -> "no due date"
  DueUndetermined -> "due undetermined"

renderIssueClosedDisplay :: IssueClosed -> Text
renderIssueClosedDisplay closed = case closed of
  ClosedOn day -> "closed " <> T.pack (show day)
  NotClosed -> "open"
  ClosedUndetermined -> "closed date undetermined"

prepareOptionalAmount :: Text -> Text -> Either Text (Maybe Amount)
prepareOptionalAmount quantityText commodityText
  | T.null quantity && T.null commodity = Right Nothing
  | T.null quantity || T.null commodity = Left "Issue Amount and Commodity must both be blank or both be present."
  | otherwise = do
      parsedQuantity <- either (Left . showText) Right (parseQuantity quantity)
      parsedCommodity <- either (Left . showText) Right (mkCommodity commodity)
      Right (Just (mkAmount parsedCommodity parsedQuantity))
  where
    quantity = T.strip quantityText
    commodity = T.strip commodityText

publishCandidate :: AppContext -> PublishRequest -> IO PublishResult
publishCandidate context request = do
  let state = contextHouseholdState context
      paths = householdStatePaths state
      root = householdStateRoot state
      source = contextIssuesSource context
      candidate = case request of
        PublishAdd preview -> candidateCompleteSource preview
        PublishDueUpdate preview -> dueUpdateCandidateCompleteSource preview
        PublishClose preview -> closeCandidateCompleteSource preview
  result <- publishWithPathAdmission
    (\_ -> loadCanonicalHousehold root)
    WriteIntent
      { targetFilePath = householdIssuesPath paths
      , expectedOldBytes = ExpectedSource source
      , candidateNewBytes = CandidateSource candidate
      }
  case result of
    Left err -> pure (PublicationFailed (T.pack (show err)))
    Right () -> do
      reloaded <- reloadWorkspaceContext (context { contextCurrentSection = IssuesSection })
      pure $ case reloaded of
        Nothing -> ReloadFailed
        Just fresh -> Published (fresh { contextCurrentSection = IssuesSection })

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ borderWithLabel (str "Issues (issues.tsv)")
        (vBox
          [ strWrap
              ("View: " <> issueWorkspaceFilterLabel (contextIssueFilter context)
                <> " | Open: " <> show openCount
                <> " | Closed: " <> show closedCount)
          , vLimit 18 (L.renderList renderIssueItem True (contextIssueList context))
          ])
    , borderWithLabel (str "Selected Issue")
        (padAll 1 (renderSelectedIssue context))
    , strWrap "[O] Open   [C] Closed   [L] All   [j/k/Arrows/wheel] Move"
    , strWrap "[R] Realize as Actual (Open)   [Enter] Resolve/Drop   [U] Due   [A] Add Issue"
    ]
  where
    (openCount, closedCount) = contextIssueCounts context
    issueWorkspaceFilterLabel visibility = case visibility of
      OpenIssueFilter -> "Open"
      ClosedIssueFilter -> "Closed"
      AllIssueFilter -> "All"

renderIssueItem :: Bool -> HouseholdIssue -> Widget Name
renderIssueItem selected issue
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    lifecycle = case householdIssueStatus issue of
      Open -> ""
      _ -> "  " <> renderIssueClosedDisplay (householdIssueClosed issue)
    -- The list has item height 1, so the summary remains one line. The selected
    -- detail pane below is the lossless, wrapping presentation of the Issue.
    row = txt ("[" <> T.pack (show (householdIssueStatus issue)) <> "]  "
      <> renderIssueDueDisplay (householdIssueDue issue) <> "  "
      <> T.pack (show (householdIssueRecordedOn issue)) <> "  "
      <> issueIdText (householdIssueId issue) <> "  "
      <> householdIssueText issue <> lifecycle)

renderSelectedIssue :: AppContext -> Widget Name
renderSelectedIssue context = case L.listSelectedElement (contextIssueList context) of
  Nothing -> str "No issues recorded."
  Just (_, issue) -> renderIssue issue

renderIssue :: HouseholdIssue -> Widget Name
renderIssue issue =
  vBox
    [ txtWrap ("[" <> T.pack (show (householdIssueStatus issue)) <> "]  "
        <> T.pack (show (householdIssueRecordedOn issue))
        <> "  " <> issueIdText (householdIssueId issue))
    , txtWrap ("Due: " <> renderIssueDueDisplay (householdIssueDue issue))
    , txtWrap ("Closed: " <> renderIssueClosedDisplay (householdIssueClosed issue))
    , txtWrap ("Text: " <> householdIssueText issue)
    , maybe emptyWidget
        (\amount -> txtWrap ("Amount: " <> renderQuantity (amountQuantity amount)
          <> " " <> commodityCode (amountCommodity amount)))
        (householdIssueAmount issue)
    , txtWrap ("Details: " <> householdIssueDetails issue)
    ]

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext WorkspaceAction
handleWorkspaceEvent event = case Scroll.listWheelEvent IssueList event of
  Just wheelEvent -> do
    zoom contextIssueListL (L.handleListEvent wheelEvent)
    pure WorkspaceMaintain
  Nothing -> case event of
    MouseDown IssueList V.BLeft _ (Location (_, row)) -> do
      zoom contextIssueListL (modify (L.listMoveTo row))
      pure WorkspaceMaintain
    VtyEvent (V.EvKey (V.KChar 'o') []) -> selectView OpenIssueFilter
    VtyEvent (V.EvKey (V.KChar 'O') []) -> selectView OpenIssueFilter
    VtyEvent (V.EvKey (V.KChar 'c') []) -> selectView ClosedIssueFilter
    VtyEvent (V.EvKey (V.KChar 'C') []) -> selectView ClosedIssueFilter
    VtyEvent (V.EvKey (V.KChar 'l') []) -> selectView AllIssueFilter
    VtyEvent (V.EvKey (V.KChar 'L') []) -> selectView AllIssueFilter
    VtyEvent (V.EvKey (V.KChar 'a') []) -> pure WorkspaceStartAdd
    VtyEvent (V.EvKey (V.KChar 'A') []) -> pure WorkspaceStartAdd
    VtyEvent (V.EvKey (V.KChar 'u') []) -> openSelectedIssueDueUpdate
    VtyEvent (V.EvKey (V.KChar 'U') []) -> openSelectedIssueDueUpdate
    VtyEvent (V.EvKey (V.KChar 'r') []) -> openSelectedIssueRealize
    VtyEvent (V.EvKey (V.KChar 'R') []) -> openSelectedIssueRealize
    VtyEvent (V.EvKey V.KEnter []) -> openSelectedIssueClose
    VtyEvent (V.EvKey vtyKey vtyMods) -> do
      zoom contextIssueListL (L.handleListEventVi L.handleListEvent (V.EvKey vtyKey vtyMods))
      pure WorkspaceMaintain
    _ -> pure WorkspaceMaintain
  where
    selectView visibility = do
      modify (setIssueWorkspaceFilter visibility)
      pure WorkspaceMaintain
    openSelectedIssueClose = do
      context <- get
      case L.listSelectedElement (contextIssueList context) of
        Just (_, issue) -> case householdIssueStatus issue of
          Open -> pure (WorkspaceStartClose (CloseChoice issue))
          status -> pure (WorkspaceCloseUnavailable
            ("Selected Issue is already " <> T.pack (show status) <> "."))
        Nothing -> pure WorkspaceMaintain
    openSelectedIssueDueUpdate = do
      context <- get
      case L.listSelectedElement (contextIssueList context) of
        Just (_, issue) -> case householdIssueStatus issue of
          Open -> pure (WorkspaceStartDueUpdate (DueInput issue (mkIssueDueForm issue)))
          status -> pure (WorkspaceDueUpdateUnavailable
            ("Selected Issue is already " <> T.pack (show status) <> "."))
        Nothing -> pure WorkspaceMaintain
    openSelectedIssueRealize = do
      context <- get
      case L.listSelectedElement (contextIssueList context) of
        Just (_, issue) | householdIssueStatus issue == Open ->
          pure (WorkspaceStartRealize issue)
        _ -> pure WorkspaceMaintain

showText :: Show value => value -> Text
showText = T.pack . show
