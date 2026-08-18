{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Plan.Lifecycle
  ( FlowAction(..)
  , State
  , drawFlow
  , handleFlowEvent
  , startAdd
  , startSelectedCancel
  , startSelectedEdit
  , startSelectedReplace
  ) where

import Brick
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal')

import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, addDays)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import HKernel.Account (accountName, mkAccount)
import HKernel.Actual.Journal (actualJournalValue)
import HKernel.Editor.PlanLifecycle
  ( PlanAddIntent(..)
  , PlanAddPreview(..)
  , PlanCancelIntent(..)
  , PlanCancelPreview(..)
  , PlanEditIntent(..)
  , PlanEditPreview(..)
  , PlanSupersedeIntent(..)
  , PlanSupersedePreview(..)
  , mkPositivePlanEditAmount
  , preparePlanAddFromResolvedJournals
  , preparePlanCancelFromResolvedJournals
  , preparePlanEditFromResolvedJournals
  , preparePlanSupersedeFromResolvedJournals
  )
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , contextHouseholdState
  , contextPlanSource
  , contextSource
  )
import HKernel.Household.Application (HouseholdState(..))
import HKernel.Ledger
  ( Posting
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( amountCommodity
  , amountQuantity
  , commodityCode
  , mkCommodity
  , negateQuantity
  , parseQuantity
  , quantityToRational
  , renderQuantity
  )
import HKernel.Plan (planIdText)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalValue
  )

data PreviewResult preview
  = PreviewRejected Text
  | PreviewReady preview

data PlanAddInput = PlanAddInput
  { planAddDateText        :: Text
  , planAddDescriptionText :: Text
  , planAddFromText        :: Text
  , planAddToText          :: Text
  , planAddAmountText      :: Text
  , planAddCommodityText   :: Text
  } deriving (Eq, Show)

data PlanEditInput = PlanEditInput
  { planEditDateText   :: Text
  , planEditAmountText :: Text
  } deriving (Eq, Show)

data State event
  = AddInput (Form PlanAddInput event Name)
  | AddPreview (PreviewResult PlanAddPreview) (Form PlanAddInput event Name)
  | EditInput IdentifiedPlanTransaction (Form PlanEditInput event Name)
  | EditPreview IdentifiedPlanTransaction (PreviewResult PlanEditPreview)
      (Form PlanEditInput event Name)
  | CancelPreview Day IdentifiedPlanTransaction (PreviewResult PlanCancelPreview)
  | ReplaceInput Day IdentifiedPlanTransaction (Form PlanAddInput event Name)
  | ReplacePreview Day IdentifiedPlanTransaction
      (PreviewResult PlanSupersedePreview) (Form PlanAddInput event Name)

data FlowAction
  = FlowMaintain
  | FlowReturn
  | FlowQuit
  | FlowPublishAdd PlanAddPreview
  | FlowPublishEdit PlanEditPreview
  | FlowPublishCancel PlanCancelPreview
  | FlowPublishSupersede PlanSupersedePreview

startAdd :: AppContext -> State event
startAdd context =
  AddInput (mkPlanAddForm (addDays 1 (contextEntryDay context)))

startSelectedEdit :: AppContext -> Maybe (State event)
startSelectedEdit context = do
  (_, identified) <- L.listSelectedElement (contextPlanList context)
  pure (EditInput identified (mkPlanEditForm identified))

startSelectedCancel :: AppContext -> Maybe (State event)
startSelectedCancel context = do
  (_, identified) <- L.listSelectedElement (contextPlanList context)
  let retiredOn = contextObservationDay context
  pure (CancelPreview retiredOn identified
    (either PreviewRejected PreviewReady
      (prepareCancel context retiredOn identified)))

startSelectedReplace :: AppContext -> Maybe (State event)
startSelectedReplace context = do
  (_, identified) <- L.listSelectedElement (contextPlanList context)
  pure (ReplaceInput
    (contextObservationDay context)
    identified
    (mkPlanReplaceForm identified))

planAddDateTextL :: Lens' PlanAddInput Text
planAddDateTextL f input =
  (\value -> input { planAddDateText = value }) <$> f (planAddDateText input)

planAddDescriptionTextL :: Lens' PlanAddInput Text
planAddDescriptionTextL f input =
  (\value -> input { planAddDescriptionText = value })
    <$> f (planAddDescriptionText input)

planAddFromTextL :: Lens' PlanAddInput Text
planAddFromTextL f input =
  (\value -> input { planAddFromText = value }) <$> f (planAddFromText input)

planAddToTextL :: Lens' PlanAddInput Text
planAddToTextL f input =
  (\value -> input { planAddToText = value }) <$> f (planAddToText input)

planAddAmountTextL :: Lens' PlanAddInput Text
planAddAmountTextL f input =
  (\value -> input { planAddAmountText = value }) <$> f (planAddAmountText input)

planAddCommodityTextL :: Lens' PlanAddInput Text
planAddCommodityTextL f input =
  (\value -> input { planAddCommodityText = value })
    <$> f (planAddCommodityText input)

planEditDateTextL :: Lens' PlanEditInput Text
planEditDateTextL f input =
  (\value -> input { planEditDateText = value }) <$> f (planEditDateText input)

planEditAmountTextL :: Lens' PlanEditInput Text
planEditAmountTextL f input =
  (\value -> input { planEditAmountText = value }) <$> f (planEditAmountText input)

labelField :: String -> Widget Name -> Widget Name
labelField labelText widget =
  padBottom (Pad 1)
    ((vLimit 1 (hLimit 23 (str labelText <+> fill ' '))) <+> widget)

mkPlanAddForm :: Day -> Form PlanAddInput event Name
mkPlanAddForm day = mkPlanAddFormFrom
  PlanAddDescriptionField
  (PlanAddInput (T.pack (show day)) "" "" "" "" "JPY")

mkPlanReplaceForm :: IdentifiedPlanTransaction -> Form PlanAddInput event Name
mkPlanReplaceForm identified =
  mkPlanAddFormFrom PlanAddAmountField (replacementInputFor identified)

mkPlanAddFormFrom :: Name -> PlanAddInput -> Form PlanAddInput event Name
mkPlanAddFormFrom focus input =
  setFormFocus focus
    (newForm
      [ labelField "Plan date:"
          @@= editTextField planAddDateTextL PlanAddDateField (Just 1)
      , labelField "Description:"
          @@= editTextField planAddDescriptionTextL PlanAddDescriptionField (Just 1)
      , labelField "Pay from:"
          @@= editTextField planAddFromTextL PlanAddFromField (Just 1)
      , labelField "Category / to:"
          @@= editTextField planAddToTextL PlanAddToField (Just 1)
      , labelField "Amount:"
          @@= editTextField planAddAmountTextL PlanAddAmountField (Just 1)
      , labelField "Commodity:"
          @@= editTextField planAddCommodityTextL PlanAddCommodityField (Just 1)
      ]
      input)

replacementInputFor :: IdentifiedPlanTransaction -> PlanAddInput
replacementInputFor identified =
  case (negativePostings, positivePostings) of
    ([fromPosting], [toPosting])
      | amountCommodity (postingAmount fromPosting)
          == amountCommodity (postingAmount toPosting) ->
          PlanAddInput
            originalDate
            originalDescription
            (accountName (postingAccount fromPosting))
            (accountName (postingAccount toPosting))
            (renderQuantity (amountQuantity (postingAmount toPosting)))
            (commodityCode (amountCommodity (postingAmount toPosting)))
    _ -> PlanAddInput originalDate originalDescription "" "" "" fallbackCommodity
  where
    transaction = identifiedPlanTransaction identified
    postings = NonEmpty.toList (transactionPostings transaction)
    negativePostings = filter
      ((< 0) . quantityToRational . amountQuantity . postingAmount)
      postings
    positivePostings = filter
      ((> 0) . quantityToRational . amountQuantity . postingAmount)
      postings
    originalDate = T.pack (show (transactionDate transaction))
    originalDescription = transactionDescription transaction
    fallbackCommodity = commodityCode
      (amountCommodity
        (postingAmount (NonEmpty.head (transactionPostings transaction))))

mkPlanEditForm :: IdentifiedPlanTransaction -> Form PlanEditInput event Name
mkPlanEditForm identified =
  setFormFocus PlanEditDateField
    (newForm
      [ labelField "Plan date:"
          @@= editTextField planEditDateTextL PlanEditDateField (Just 1)
      , labelField "Amount override:"
          @@= editTextField planEditAmountTextL PlanEditAmountField (Just 1)
      ]
      (PlanEditInput
        (T.pack (show
          (transactionDate (identifiedPlanTransaction identified))))
        ""))

zoomAddForm :: Traversal' (State AppEvent) (Form PlanAddInput AppEvent Name)
zoomAddForm f (AddInput form) = AddInput <$> f form
zoomAddForm _ state = pure state

zoomEditForm :: Traversal' (State AppEvent) (Form PlanEditInput AppEvent Name)
zoomEditForm f (EditInput identified form) = EditInput identified <$> f form
zoomEditForm _ state = pure state

zoomReplaceForm :: Traversal' (State AppEvent) (Form PlanAddInput AppEvent Name)
zoomReplaceForm f (ReplaceInput retiredOn identified form) =
  ReplaceInput retiredOn identified <$> f form
zoomReplaceForm _ state = pure state

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  AddInput form ->
    center
      (borderWithLabel (str "Add Plan")
        (hLimit 82
          (padAll 1
            ( renderForm form
              <=> str " "
              <=> strWrap "Plan identity is generated by the Plan domain."
              <=> strWrap "The common daily form creates one balanced two-posting Plan."
              <=> strWrap "[Tab] Next field | [Esc] Plans | [Enter] Preview"))))
  AddPreview result _ ->
    simplePreview "Add Plan Preview"
      (renderPreviewResult (txtWrap . addCandidateBlock) result)
      (simplePreviewControls result)
  EditInput identified form ->
    center
      (borderWithLabel (str "Edit Selected Plan")
        (hLimit 82
          (padAll 1
            ( renderIdentifiedPlan identified
              <=> str " "
              <=> renderForm form
              <=> str " "
              <=> strWrap "Blank amount keeps the current amount; amount edits require a binary Plan."
              <=> strWrap "The selected PlanId is retained automatically."
              <=> strWrap "[Tab] Next field | [Esc] Plans | [Enter] Preview"))))
  EditPreview _ result _ ->
    simplePreview "Edit Plan Preview"
      (renderPreviewResult renderEditPreview result)
      (simplePreviewControls result)
  CancelPreview retiredOn _ result ->
    simplePreview "Cancel Selected Plan"
      ( txtWrap ("Retire on: " <> T.pack (show retiredOn))
        <=> str " "
        <=> renderPreviewResult renderCancelPreview result)
      (simplePreviewControls result)
  ReplaceInput retiredOn identified form ->
    center
      (borderWithLabel (str "Replace Selected Plan")
        (hLimit 82
          (padAll 1
            ( renderIdentifiedPlan identified
              <=> str " "
              <=> txtWrap ("Retire old Plan on: " <> T.pack (show retiredOn))
              <=> strWrap "Replacement Plan gets a fresh PlanId."
              <=> str " "
              <=> renderForm form
              <=> str " "
              <=> strWrap "Simple two-posting Plans are prefilled from the selected Plan."
              <=> strWrap "[Tab] Next field | [Esc] Plans | [Enter] Preview"))))
  ReplacePreview retiredOn _ result _ ->
    simplePreview "Replace Plan Preview"
      ( txtWrap ("Retire old Plan on: " <> T.pack (show retiredOn))
        <=> str " "
        <=> renderPreviewResult renderSupersedePreview result)
      (simplePreviewControls result)

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleFlowEvent context event = do
  state <- get
  case state of
    AddInput form -> handleAddInput context form event
    AddPreview result form ->
      handleSimplePreview (Just (AddInput form)) FlowPublishAdd result event
    EditInput identified form -> handleEditInput context identified form event
    EditPreview identified result form ->
      handleSimplePreview
        (Just (EditInput identified form)) FlowPublishEdit result event
    CancelPreview _ _ result ->
      handleSimplePreview Nothing FlowPublishCancel result event
    ReplaceInput retiredOn identified form ->
      handleReplaceInput context retiredOn identified form event
    ReplacePreview retiredOn identified result form ->
      handleSimplePreview
        (Just (ReplaceInput retiredOn identified form))
        FlowPublishSupersede
        result
        event

handleAddInput
  :: AppContext
  -> Form PlanAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleAddInput context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
  VtyEvent (V.EvKey V.KEnter []) -> do
    case prepareAdd context (formState form) of
      Left message -> put (AddPreview (PreviewRejected message) form)
      Right preview -> put (AddPreview (PreviewReady preview) form)
    pure FlowMaintain
  _ -> zoom zoomAddForm (handleFormEvent event) >> pure FlowMaintain

handleEditInput
  :: AppContext
  -> IdentifiedPlanTransaction
  -> Form PlanEditInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleEditInput context identified form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
  VtyEvent (V.EvKey V.KEnter []) -> do
    case prepareEdit context identified (formState form) of
      Left message -> put (EditPreview identified (PreviewRejected message) form)
      Right preview -> put (EditPreview identified (PreviewReady preview) form)
    pure FlowMaintain
  _ -> zoom zoomEditForm (handleFormEvent event) >> pure FlowMaintain

handleReplaceInput
  :: AppContext
  -> Day
  -> IdentifiedPlanTransaction
  -> Form PlanAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleReplaceInput context retiredOn identified form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
  VtyEvent (V.EvKey V.KEnter []) -> do
    case prepareReplace context retiredOn identified (formState form) of
      Left message -> put
        (ReplacePreview retiredOn identified (PreviewRejected message) form)
      Right preview -> put
        (ReplacePreview retiredOn identified (PreviewReady preview) form)
    pure FlowMaintain
  _ -> zoom zoomReplaceForm (handleFormEvent event) >> pure FlowMaintain

handleSimplePreview
  :: Maybe (State AppEvent)
  -> (preview -> FlowAction)
  -> PreviewResult preview
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleSimplePreview back toAction result event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> case back of
    Nothing -> pure FlowReturn
    Just backState -> put backState >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter []) -> case result of
    PreviewRejected _ -> pure FlowMaintain
    PreviewReady preview -> pure (toAction preview)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> pure FlowQuit
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure FlowQuit
  _ -> pure FlowMaintain

prepareAdd :: AppContext -> PlanAddInput -> Either Text PlanAddPreview
prepareAdd context input = do
  intent <- parsePlanAddIntent input
  let state = contextHouseholdState context
  case preparePlanAddFromResolvedJournals
      (planJournalValue (householdStatePlanJournal state))
      (actualJournalValue (householdStateActualJournal state))
      (contextPlanSource context)
      (contextSource context)
      intent of
    Left errors -> Left
      ("Plan add rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview

parsePlanAddIntent :: PlanAddInput -> Either Text PlanAddIntent
parsePlanAddIntent input = do
  date <- parseDay (planAddDateText input)
  let description = T.strip (planAddDescriptionText input)
  if T.null description
    then Left "Plan description cannot be blank."
    else Right ()
  fromAccount <- either (Left . showText) Right
    (mkAccount (T.strip (planAddFromText input)))
  toAccount <- either (Left . showText) Right
    (mkAccount (T.strip (planAddToText input)))
  quantity <- either (Left . showText) Right
    (parseQuantity (T.strip (planAddAmountText input)))
  if quantityToRational quantity > 0
    then Right ()
    else Left "Plan amount must be positive."
  commodity <- either (Left . showText) Right
    (mkCommodity (T.strip (planAddCommodityText input)))
  pure PlanAddIntent
    { addDate = date
    , addDescription = description
    , addPostings =
        IntentPosting fromAccount (negateQuantity quantity) (Just commodity)
          :| [IntentPosting toAccount quantity (Just commodity)]
    , addRequestedId = Nothing
    , addSeries = Nothing
    }

prepareEdit
  :: AppContext
  -> IdentifiedPlanTransaction
  -> PlanEditInput
  -> Either Text PlanEditPreview
prepareEdit context identified input = do
  date <- parseDay (planEditDateText input)
  amount <- case T.strip (planEditAmountText input) of
    "" -> Right Nothing
    amountText -> do
      quantity <- either (Left . showText) Right (parseQuantity amountText)
      positive <- either (Left . showText) Right (mkPositivePlanEditAmount quantity)
      Right (Just positive)
  let intent = PlanEditIntent
        { editPlanId = planIdText (identifiedPlanId identified)
        , editDate = Just date
        , editAmount = amount
        }
      state = contextHouseholdState context
  case preparePlanEditFromResolvedJournals
      (planJournalValue (householdStatePlanJournal state))
      (actualJournalValue (householdStateActualJournal state))
      (contextPlanSource context)
      (contextSource context)
      intent of
    Left errors -> Left
      ("Plan edit rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview

prepareCancel
  :: AppContext
  -> Day
  -> IdentifiedPlanTransaction
  -> Either Text PlanCancelPreview
prepareCancel context retiredOn identified =
  case preparePlanCancelFromResolvedJournals
      (planJournalValue (householdStatePlanJournal state))
      (actualJournalValue (householdStateActualJournal state))
      (contextPlanSource context)
      (contextSource context)
      PlanCancelIntent
        { cancelPlanId = planIdText (identifiedPlanId identified)
        , cancelOn = retiredOn
        } of
    Left errors -> Left
      ("Plan cancellation rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview
  where
    state = contextHouseholdState context

prepareReplace
  :: AppContext
  -> Day
  -> IdentifiedPlanTransaction
  -> PlanAddInput
  -> Either Text PlanSupersedePreview
prepareReplace context retiredOn identified replacementInput = do
  replacement <- parsePlanAddIntent replacementInput
  case preparePlanSupersedeFromResolvedJournals
      (planJournalValue (householdStatePlanJournal state))
      (actualJournalValue (householdStateActualJournal state))
      (contextPlanSource context)
      (contextSource context)
      PlanSupersedeIntent
        { supersedePlanId = planIdText (identifiedPlanId identified)
        , supersedeOn = retiredOn
        , supersedeReplacement = replacement
        } of
    Left errors -> Left
      ("Plan replacement rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview
  where
    state = contextHouseholdState context

parseDay :: Text -> Either Text Day
parseDay text =
  case parseTimeM True defaultTimeLocale "%Y-%m-%d"
      (T.unpack (T.strip text)) of
    Nothing -> Left "Date must be YYYY-MM-DD."
    Just day -> Right day

simplePreview :: String -> Widget Name -> String -> Widget Name
simplePreview title body controls =
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

renderEditPreview :: PlanEditPreview -> Widget Name
renderEditPreview preview =
  str "Before" <=> txtWrap (editOriginalBlock preview)
    <=> str " " <=> str "After" <=> txtWrap (editCandidateBlock preview)

renderCancelPreview :: PlanCancelPreview -> Widget Name
renderCancelPreview preview =
  str "Before" <=> txtWrap (cancelOriginalBlock preview)
    <=> str " " <=> str "After" <=> txtWrap (cancelRetiredBlock preview)

renderSupersedePreview :: PlanSupersedePreview -> Widget Name
renderSupersedePreview preview =
  vBox
    [ str "Retired Plan"
    , txtWrap (supersedeRetiredBlock preview)
    , str " "
    , str "Replacement Plan"
    , txtWrap (supersedeReplacementBlock preview)
    ]

simplePreviewControls :: PreviewResult preview -> String
simplePreviewControls result = case result of
  PreviewReady _ -> "[Enter] Publish | [Esc] Back | [Q] Quit"
  PreviewRejected _ -> "[Esc] Back | [Q] Quit"

renderIdentifiedPlan :: IdentifiedPlanTransaction -> Widget Name
renderIdentifiedPlan identified =
  let transaction = identifiedPlanTransaction identified
  in vBox
    ( txtWrap (T.pack (show (transactionDate transaction))
        <> "  [" <> planIdText (identifiedPlanId identified) <> "]  "
        <> transactionDescription transaction)
      : map renderPosting (NonEmpty.toList (transactionPostings transaction))
    )

renderPosting :: Posting -> Widget Name
renderPosting posting =
  txtWrap ("  " <> accountName (postingAccount posting) <> "  "
    <> renderQuantity (amountQuantity amount) <> " "
    <> commodityCode (amountCommodity amount))
  where
    amount = postingAmount posting

showText :: Show value => value -> Text
showText = T.pack . show