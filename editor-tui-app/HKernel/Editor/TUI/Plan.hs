{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Plan
  ( PublishRequest(..)
  , PublishResult(..)
  , State(..)
  , WorkspaceAction(..)
  , drawFlow
  , drawWorkspace
  , handleFlowEvent
  , handleWorkspaceEvent
  , publishCandidate
  , startAdd
  , startSelectedCancel
  , startSelectedCompletion
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
import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteIntent(..)
  , admitPlanJournalRootSource
  , publishWithPathAdmission
  )
import HKernel.Editor.Interaction.PlanCompleteAdvance
  ( PlanCompleteAdvanceInput(..)
  , initialPlanCompleteAdvanceInput
  , parsePlanCompleteAdvanceInput
  )
import HKernel.Editor.PlanCompleteAdvance
  ( PlanAdvanceProposal(..)
  , PlanCompleteAdvancePreview(..)
  , PlanCompleteAdvanceWriteError(..)
  , PlanCompleteAdvanceWriteIntent(..)
  , PlanRecurrence(..)
  , preparePlanCompleteAdvance
  , proposePlanAdvance
  , publishPlanCompleteAdvance
  )
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
  , HouseholdSection(..)
  , Name(..)
  , contextHouseholdState
  , contextPlanListL
  , contextPlanSource
  , contextSource
  , contextSourcePath
  , reloadWorkspaceContext
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , loadCanonicalHousehold
  )
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
import HKernel.Plan (PlanId, planIdText)
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
  = Input PlanAdvanceProposal (Form PlanCompleteAdvanceInput event Name)
  | Preview PlanAdvanceProposal (PreviewResult PlanCompleteAdvancePreview) (Form PlanCompleteAdvanceInput event Name)
  | Confirmation PlanAdvanceProposal PlanCompleteAdvancePreview (Form PlanCompleteAdvanceInput event Name)
  | AddInput (Form PlanAddInput event Name)
  | AddPreview (PreviewResult PlanAddPreview) (Form PlanAddInput event Name)
  | EditInput IdentifiedPlanTransaction (Form PlanEditInput event Name)
  | EditPreview IdentifiedPlanTransaction (PreviewResult PlanEditPreview) (Form PlanEditInput event Name)
  | CancelPreview Day IdentifiedPlanTransaction (PreviewResult PlanCancelPreview)
  | ReplaceInput Day IdentifiedPlanTransaction (Form PlanAddInput event Name)
  | ReplacePreview Day IdentifiedPlanTransaction (PreviewResult PlanSupersedePreview) (Form PlanAddInput event Name)
  | WriteOutcome Text
  | ReturnToWorkspace
  | PublishRequested PublishRequest
  | QuitRequested

data PublishRequest
  = PublishCompleteAdvance PlanId PlanCompleteAdvancePreview
  | PublishAdd PlanAddPreview
  | PublishEdit PlanEditPreview
  | PublishCancel PlanCancelPreview
  | PublishSupersede PlanSupersedePreview

data PublishResult
  = Published AppContext
  | PublicationFailed Text
  | ReloadFailed

startSelectedCompletion :: AppContext -> Maybe (State event)
startSelectedCompletion context = do
  (_, identified) <- L.listSelectedElement (contextPlanList context)
  pure $ case proposePlanAdvance
      (householdStatePlanJournal (contextHouseholdState context))
      (identifiedPlanId identified) of
    Left errors -> WriteOutcome
      ("Cannot prepare selected Plan: " <> T.pack (show (NonEmpty.toList errors)))
    Right proposal -> Input proposal
      (mkPlanCompleteForm (contextObservationDay context) proposal)

startAdd :: AppContext -> State event
startAdd context = AddInput (mkPlanAddForm (addDays 1 (contextEntryDay context)))

startSelectedEdit :: AppContext -> Maybe (State event)
startSelectedEdit context = do
  (_, identified) <- L.listSelectedElement (contextPlanList context)
  pure (EditInput identified (mkPlanEditForm identified))

startSelectedCancel :: AppContext -> Maybe (State event)
startSelectedCancel context = do
  (_, identified) <- L.listSelectedElement (contextPlanList context)
  let retiredOn = contextObservationDay context
  pure (CancelPreview retiredOn identified
    (either PreviewRejected PreviewReady (prepareCancel context retiredOn identified)))

startSelectedReplace :: AppContext -> Maybe (State event)
startSelectedReplace context = do
  (_, identified) <- L.listSelectedElement (contextPlanList context)
  pure (ReplaceInput
    (contextObservationDay context)
    identified
    (mkPlanReplaceForm identified))

planActualDateTextL :: Lens' PlanCompleteAdvanceInput Text
planActualDateTextL f input =
  (\value -> input { planActualDateText = value }) <$> f (planActualDateText input)

planActualAmountTextL :: Lens' PlanCompleteAdvanceInput Text
planActualAmountTextL f input =
  (\value -> input { planActualAmountText = value }) <$> f (planActualAmountText input)

planSuccessorDateTextL :: Lens' PlanCompleteAdvanceInput Text
planSuccessorDateTextL f input =
  (\value -> input { planSuccessorDateText = value }) <$> f (planSuccessorDateText input)

planSuccessorAmountTextL :: Lens' PlanCompleteAdvanceInput Text
planSuccessorAmountTextL f input =
  (\value -> input { planSuccessorAmountText = value }) <$> f (planSuccessorAmountText input)

planAddDateTextL :: Lens' PlanAddInput Text
planAddDateTextL f input =
  (\value -> input { planAddDateText = value }) <$> f (planAddDateText input)

planAddDescriptionTextL :: Lens' PlanAddInput Text
planAddDescriptionTextL f input =
  (\value -> input { planAddDescriptionText = value }) <$> f (planAddDescriptionText input)

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
  (\value -> input { planAddCommodityText = value }) <$> f (planAddCommodityText input)

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

mkPlanCompleteForm
  :: Day
  -> PlanAdvanceProposal
  -> Form PlanCompleteAdvanceInput event Name
mkPlanCompleteForm today proposal =
  let form = newForm
        [ labelField "Actual date:"
            @@= editTextField planActualDateTextL PlanActualDateField (Just 1)
        , labelField "Actual amount override:"
            @@= editTextField planActualAmountTextL PlanActualAmountField (Just 1)
        , labelField "Next nominal date:"
            @@= editTextField planSuccessorDateTextL PlanSuccessorDateField (Just 1)
        , labelField "Next amount override:"
            @@= editTextField planSuccessorAmountTextL PlanSuccessorAmountField (Just 1)
        ]
  in setFormFocus PlanActualDateField
      (form (initialPlanCompleteAdvanceInput today proposal))

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
      (amountCommodity (postingAmount (NonEmpty.head (transactionPostings transaction))))

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
        (T.pack (show (transactionDate (identifiedPlanTransaction identified))))
        ""))

zoomInputForm
  :: Traversal' (State AppEvent) (Form PlanCompleteAdvanceInput AppEvent Name)
zoomInputForm f (Input proposal form) = Input proposal <$> f form
zoomInputForm _ state = pure state

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
  Input proposal form ->
    center
      (borderWithLabel (str "Complete & Advance Plan")
        (hLimit 82
          (padAll 1
            ( renderPlanProposal proposal
              <=> str " "
              <=> renderForm form
              <=> str " "
              <=> str "Blank Actual amount uses the planned amount."
              <=> str "Blank Next amount keeps the original planned amount."
              <=> str "Clear Next nominal date to complete without a successor."
              <=> str "[Tab] Next field | [Esc] Plans | [Enter] Preview"))))
  Preview _ result _ ->
    center
      (borderWithLabel (str "Complete & Advance Preview")
        (hLimit 86
          (vLimit 30
            (padAll 1
              (renderPreviewResult renderCompletePreview result
                <=> str " "
                <=> str (completionPreviewControls result))))))
  Confirmation _ preview _ ->
    center
      (borderWithLabel (str "Confirm Complete & Advance")
        (hLimit 86
          (vLimit 30
            (padAll 1
              ( str "This will update Actual and, when present, append the successor Plan as one operation."
                <=> str " "
                <=> renderCompletePreview preview
                <=> str " "
                <=> str "[Y] Publish | [N/Esc] Back | [Q] Quit")))))
  AddInput form ->
    center
      (borderWithLabel (str "Add Plan")
        (hLimit 82
          (padAll 1
            ( renderForm form
              <=> str " "
              <=> str "Plan identity is generated by the Plan domain."
              <=> str "The common daily form creates one balanced two-posting Plan."
              <=> str "[Tab] Next field | [Esc] Plans | [Enter] Preview"))))
  AddPreview result _ ->
    simplePreview "Add Plan Preview"
      (renderPreviewResult (txt . addCandidateBlock) result)
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
              <=> str "Blank amount keeps the current amount; amount edits require a binary Plan."
              <=> str "The selected PlanId is retained automatically."
              <=> str "[Tab] Next field | [Esc] Plans | [Enter] Preview"))))
  EditPreview _ result _ ->
    simplePreview "Edit Plan Preview"
      (renderPreviewResult renderEditPreview result)
      (simplePreviewControls result)
  CancelPreview retiredOn _ result ->
    simplePreview "Cancel Selected Plan"
      ( txt ("Retire on: " <> T.pack (show retiredOn))
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
              <=> txt ("Retire old Plan on: " <> T.pack (show retiredOn))
              <=> str "Replacement Plan gets a fresh PlanId."
              <=> str " "
              <=> renderForm form
              <=> str " "
              <=> str "Simple two-posting Plans are prefilled from the selected Plan."
              <=> str "[Tab] Next field | [Esc] Plans | [Enter] Preview"))))
  ReplacePreview retiredOn _ result _ ->
    simplePreview "Replace Plan Preview"
      ( txt ("Retire old Plan on: " <> T.pack (show retiredOn))
        <=> str " "
        <=> renderPreviewResult renderSupersedePreview result)
      (simplePreviewControls result)
  WriteOutcome message ->
    center
      (borderWithLabel (str "Plan Result")
        (padAll 1 (txt message <=> str " " <=> str "[Esc] Plans | [Q] Quit")))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ -> emptyWidget
  QuitRequested -> emptyWidget

simplePreview :: String -> Widget Name -> String -> Widget Name
simplePreview title body controls =
  center
    (borderWithLabel (str title)
      (hLimit 88
        (vLimit 32
          (padAll 1
            (body <=> str " " <=> str controls)))))

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ borderWithLabel (str "Open Plans (plan.journal)")
        (vLimit 18
          (L.renderList renderPlanItem True (contextPlanList context)))
    , borderWithLabel (str "Selected Plan")
        (padAll 1 (renderSelectedPlan context))
    , str "[j/k/Arrows] Move   [Enter/C] Complete & Advance   [A] Add   [E] Edit"
    , str "[X] Cancel   [R] Replace   [1-7] Sections   [q] Quit"
    ]

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleFlowEvent context event = do
  state <- get
  case state of
    Input proposal form -> handleInput context proposal form event
    Preview proposal result form -> handlePreview proposal result form event
    Confirmation proposal preview form -> handleConfirmation proposal preview form event
    AddInput form -> handleAddInput context form event
    AddPreview result form -> handleSimplePreview (AddInput form) PublishAdd result event
    EditInput identified form -> handleEditInput context identified form event
    EditPreview identified result form ->
      handleSimplePreview (EditInput identified form) PublishEdit result event
    CancelPreview _ _ result ->
      handleSimplePreview ReturnToWorkspace PublishCancel result event
    ReplaceInput retiredOn identified form ->
      handleReplaceInput context retiredOn identified form event
    ReplacePreview retiredOn identified result form ->
      handleSimplePreview
        (ReplaceInput retiredOn identified form)
        PublishSupersede
        result
        event
    WriteOutcome _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      _ -> pure ()
    ReturnToWorkspace -> pure ()
    PublishRequested _ -> pure ()
    QuitRequested -> pure ()

handleInput
  :: AppContext
  -> PlanAdvanceProposal
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleInput context proposal form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) -> preparePreview context proposal form
  _ -> zoom zoomInputForm (handleFormEvent event)

preparePreview
  :: AppContext
  -> PlanAdvanceProposal
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> EventM Name (State AppEvent) ()
preparePreview context proposal form =
  case parsePlanCompleteAdvanceInput proposal (formState form) of
    Left inputError ->
      put (Preview proposal
        (PreviewRejected ("Input rejected: " <> T.pack (show inputError))) form)
    Right intent -> case preparePlanCompleteAdvance
        (householdStatePlanJournal state)
        (householdStateActualJournal state)
        (contextPlanSource context)
        (contextSource context)
        intent of
      Left errors -> put (Preview proposal
        (PreviewRejected
          ("Plan completion rejected: " <> T.pack (show (NonEmpty.toList errors)))) form)
      Right preview -> put (Preview proposal (PreviewReady preview) form)
  where
    state = contextHouseholdState context

handlePreview
  :: PlanAdvanceProposal
  -> PreviewResult PlanCompleteAdvancePreview
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handlePreview proposal result form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'b') []) -> back
  VtyEvent (V.EvKey (V.KChar 'B') []) -> back
  VtyEvent (V.EvKey (V.KChar 'c') []) -> continuePreview
  VtyEvent (V.EvKey (V.KChar 'C') []) -> continuePreview
  VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
  _ -> pure ()
  where
    back = put (Input proposal form)
    continuePreview = case result of
      PreviewRejected _ -> pure ()
      PreviewReady preview -> put (Confirmation proposal preview form)

handleConfirmation
  :: PlanAdvanceProposal
  -> PlanCompleteAdvancePreview
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleConfirmation proposal preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'n') []) -> back
  VtyEvent (V.EvKey (V.KChar 'N') []) -> back
  VtyEvent (V.EvKey (V.KChar 'y') []) ->
    put (PublishRequested (PublishCompleteAdvance (proposalPlanId proposal) preview))
  VtyEvent (V.EvKey (V.KChar 'Y') []) ->
    put (PublishRequested (PublishCompleteAdvance (proposalPlanId proposal) preview))
  VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
  _ -> pure ()
  where
    back = put (Preview proposal (PreviewReady preview) form)

handleAddInput
  :: AppContext
  -> Form PlanAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleAddInput context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) -> case prepareAdd context (formState form) of
    Left message -> put (AddPreview (PreviewRejected message) form)
    Right preview -> put (AddPreview (PreviewReady preview) form)
  _ -> zoom zoomAddForm (handleFormEvent event)

handleEditInput
  :: AppContext
  -> IdentifiedPlanTransaction
  -> Form PlanEditInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleEditInput context identified form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) -> case prepareEdit context identified (formState form) of
    Left message -> put (EditPreview identified (PreviewRejected message) form)
    Right preview -> put (EditPreview identified (PreviewReady preview) form)
  _ -> zoom zoomEditForm (handleFormEvent event)

handleReplaceInput
  :: AppContext
  -> Day
  -> IdentifiedPlanTransaction
  -> Form PlanAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleReplaceInput context retiredOn identified form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) -> case prepareReplace context retiredOn identified (formState form) of
    Left message -> put
      (ReplacePreview retiredOn identified (PreviewRejected message) form)
    Right preview -> put
      (ReplacePreview retiredOn identified (PreviewReady preview) form)
  _ -> zoom zoomReplaceForm (handleFormEvent event)

handleSimplePreview
  :: State AppEvent
  -> (preview -> PublishRequest)
  -> PreviewResult preview
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleSimplePreview back toRequest result event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put back
  VtyEvent (V.EvKey V.KEnter []) -> case result of
    PreviewRejected _ -> pure ()
    PreviewReady preview -> put (PublishRequested (toRequest preview))
  VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
  _ -> pure ()

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
    Left errors -> Left ("Plan add rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview

parsePlanAddIntent :: PlanAddInput -> Either Text PlanAddIntent
parsePlanAddIntent input = do
  date <- parseDay (planAddDateText input)
  let description = T.strip (planAddDescriptionText input)
  if T.null description then Left "Plan description cannot be blank." else Right ()
  fromAccount <- either (Left . showText) Right (mkAccount (T.strip (planAddFromText input)))
  toAccount <- either (Left . showText) Right (mkAccount (T.strip (planAddToText input)))
  quantity <- either (Left . showText) Right (parseQuantity (T.strip (planAddAmountText input)))
  if quantityToRational quantity > 0 then Right () else Left "Plan amount must be positive."
  commodity <- either (Left . showText) Right (mkCommodity (T.strip (planAddCommodityText input)))
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
    Left errors -> Left ("Plan edit rejected: " <> showText (NonEmpty.toList errors))
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
    Left errors -> Left ("Plan cancellation rejected: " <> showText (NonEmpty.toList errors))
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
    Left errors -> Left ("Plan replacement rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview
  where
    state = contextHouseholdState context

parseDay :: Text -> Either Text Day
parseDay text = case parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack (T.strip text)) of
  Nothing -> Left "Date must be YYYY-MM-DD."
  Just day -> Right day

publishCandidate :: AppContext -> PublishRequest -> IO PublishResult
publishCandidate context request = case request of
  PublishCompleteAdvance planId preview -> publishCompleteAdvance context planId preview
  PublishAdd preview -> publishPlanRoot context (addCandidateCompleteSource preview)
  PublishEdit preview -> publishPlanRoot context (editCandidateCompleteSource preview)
  PublishCancel preview -> publishPlanRoot context (cancelCandidateCompleteSource preview)
  PublishSupersede preview -> publishPlanRoot context (supersedeCandidateCompleteSource preview)

publishCompleteAdvance
  :: AppContext
  -> PlanId
  -> PlanCompleteAdvancePreview
  -> IO PublishResult
publishCompleteAdvance context _planId preview = do
  let state = contextHouseholdState context
      paths = householdStatePaths state
      root = householdStateRoot state
      planPath = householdPlanJournalPath paths
      intent = PlanCompleteAdvanceWriteIntent
        { writeActualPath = contextSourcePath context
        , writeExpectedActual = contextSource context
        , writeCandidateActual = completeAdvanceActualSource preview
        , writePlanPath = planPath
        , writeExpectedPlan = contextPlanSource context
        , writeCandidatePlan = completeAdvancePlanSource preview
        }
      postAdmission = loadCanonicalHousehold root
  writeResult <- publishPlanCompleteAdvance postAdmission intent
  case writeResult of
    Left writeError -> pure (PublicationFailed (renderWriteError writeError))
    Right () -> reloadPlans context

publishPlanRoot :: AppContext -> Text -> IO PublishResult
publishPlanRoot context candidate = do
  let state = contextHouseholdState context
      root = householdStateRoot state
      planPath = householdPlanJournalPath (householdStatePaths state)
  preAdmission <- admitPlanJournalRootSource planPath candidate
  case preAdmission of
    Left errors -> pure
      (PublicationFailed ("Plan candidate path admission failed: " <> showText (NonEmpty.toList errors)))
    Right _ -> do
      writeResult <- publishWithPathAdmission
        (\_ -> loadCanonicalHousehold root)
        WriteIntent
          { targetFilePath = planPath
          , expectedOldBytes = ExpectedSource (contextPlanSource context)
          , candidateNewBytes = CandidateSource candidate
          }
      case writeResult of
        Left err -> pure (PublicationFailed (showText err))
        Right () -> reloadPlans context

reloadPlans :: AppContext -> IO PublishResult
reloadPlans context = do
  reloaded <- reloadWorkspaceContext
    (context { contextCurrentSection = PlansSection })
  pure $ case reloaded of
    Nothing -> ReloadFailed
    Just freshContext -> Published
      (freshContext { contextCurrentSection = PlansSection })

renderWriteError :: PlanCompleteAdvanceWriteError admissionError -> Text
renderWriteError writeError = case writeError of
  PlanCompleteAdvanceActualStale ->
    "actual.journal changed after preview. Nothing was published."
  PlanCompleteAdvancePlanStale ->
    "plan.journal changed after preview. Nothing was published."
  PlanCompleteAdvancePostAdmissionFailed _ actualRestored planRestored ->
    "Whole-Household post-admission failed. Actual restored: "
      <> yesNo actualRestored <> "; Plan restored: " <> yesNo planRestored
  PlanCompleteAdvanceFileIOError _ actualRestored planRestored ->
    "Filesystem publication failed. Actual restored: "
      <> yesNo actualRestored <> "; Plan restored: " <> yesNo planRestored
  where
    yesNo True = "YES"
    yesNo False = "NO"

renderPlanItem :: Bool -> IdentifiedPlanTransaction -> Widget Name
renderPlanItem selected identified
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    transaction = identifiedPlanTransaction identified
    row = txt
      (T.pack (show (transactionDate transaction))
        <> "  [" <> planIdText (identifiedPlanId identified) <> "]  "
        <> transactionDescription transaction)

renderSelectedPlan :: AppContext -> Widget Name
renderSelectedPlan context = case L.listSelectedElement (contextPlanList context) of
  Nothing -> str "No open Plans."
  Just (_, identified) -> renderIdentifiedPlan identified

renderIdentifiedPlan :: IdentifiedPlanTransaction -> Widget Name
renderIdentifiedPlan identified =
  let transaction = identifiedPlanTransaction identified
  in vBox
    ( txt (T.pack (show (transactionDate transaction))
        <> "  [" <> planIdText (identifiedPlanId identified) <> "]  "
        <> transactionDescription transaction)
      : map renderPosting (NonEmpty.toList (transactionPostings transaction))
    )

renderPlanProposal :: PlanAdvanceProposal -> Widget Name
renderPlanProposal proposal =
  vBox
    [ txt ("Plan: " <> T.pack (show (proposalNominalDate proposal))
        <> "  [" <> planIdText (proposalPlanId proposal) <> "]  "
        <> proposalDescription proposal)
    , txt ("Recurrence: " <> recurrenceLabel (proposalRecurrence proposal))
    , str "Planned postings:"
    , vBox (map renderPosting
        (NonEmpty.toList (transactionPostings (proposalOriginalTransaction proposal))))
    ]

recurrenceLabel :: PlanRecurrence -> Text
recurrenceLabel recurrence = case recurrence of
  PlanRecursOnce -> "once"
  PlanRecursMonthly -> "monthly (next date is based on the nominal Plan date)"
  PlanRecursByHouseholdCycle -> "cycle (next nominal date is explicit)"
  PlanRecurrenceUnspecified -> "unspecified (next nominal date is explicit)"

renderPreviewResult
  :: (preview -> Widget Name)
  -> PreviewResult preview
  -> Widget Name
renderPreviewResult renderPreview result = case result of
  PreviewRejected message -> withAttr (attrName "error") (txt message)
  PreviewReady preview -> renderPreview preview

renderEditPreview :: PlanEditPreview -> Widget Name
renderEditPreview preview =
  str "Before" <=> txt (editOriginalBlock preview)
    <=> str " " <=> str "After" <=> txt (editCandidateBlock preview)

renderCancelPreview :: PlanCancelPreview -> Widget Name
renderCancelPreview preview =
  str "Before" <=> txt (cancelOriginalBlock preview)
    <=> str " " <=> str "After" <=> txt (cancelRetiredBlock preview)

renderSupersedePreview :: PlanSupersedePreview -> Widget Name
renderSupersedePreview preview =
  vBox
    [ str "Retired Plan"
    , txt (supersedeRetiredBlock preview)
    , str " "
    , str "Replacement Plan"
    , txt (supersedeReplacementBlock preview)
    ]

renderCompletePreview :: PlanCompleteAdvancePreview -> Widget Name
renderCompletePreview preview =
  vBox
    [ withAttr (attrName "success") (str "Actual completion")
    , txt (completeAdvanceActualBlock preview)
    , str " "
    , withAttr (attrName "success") (str "Next Plan")
    , case completeAdvanceSuccessorBlock preview of
        Nothing -> str "No successor will be added."
        Just block -> txt block
    ]

completionPreviewControls :: PreviewResult PlanCompleteAdvancePreview -> String
completionPreviewControls result = case result of
  PreviewReady _ -> "[Esc/B] Back | [C] Continue to confirmation | [Q] Quit"
  PreviewRejected _ -> "[Esc/B] Back | [Q] Quit"

simplePreviewControls :: PreviewResult preview -> String
simplePreviewControls result = case result of
  PreviewReady _ -> "[Enter] Publish | [Esc] Back | [Q] Quit"
  PreviewRejected _ -> "[Esc] Back | [Q] Quit"

renderPosting :: Posting -> Widget Name
renderPosting posting =
  txt ("  " <> accountName (postingAccount posting) <> "  "
    <> renderQuantity (amountQuantity amount) <> " "
    <> commodityCode (amountCommodity amount))
  where
    amount = postingAmount posting

showText :: Show value => value -> Text
showText = T.pack . show

data WorkspaceAction
  = MaintainContext
  | StartFlow (State AppEvent)

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext WorkspaceAction
handleWorkspaceEvent event = case event of
  MouseDown PlanList V.BScrollUp _ _ -> do
    zoom contextPlanListL (L.handleListEvent (V.EvKey V.KUp []))
    pure MaintainContext
  MouseDown PlanList V.BScrollDown _ _ -> do
    zoom contextPlanListL (L.handleListEvent (V.EvKey V.KDown []))
    pure MaintainContext
  MouseDown PlanList V.BLeft _ (Location (_, row)) -> do
    zoom contextPlanListL (modify (L.listMoveTo row))
    pure MaintainContext
  VtyEvent (V.EvKey (V.KChar 'a') []) -> openAdd
  VtyEvent (V.EvKey (V.KChar 'A') []) -> openAdd
  VtyEvent (V.EvKey (V.KChar 'e') []) -> openSelectedEdit
  VtyEvent (V.EvKey (V.KChar 'E') []) -> openSelectedEdit
  VtyEvent (V.EvKey (V.KChar 'x') []) -> openSelectedCancel
  VtyEvent (V.EvKey (V.KChar 'X') []) -> openSelectedCancel
  VtyEvent (V.EvKey (V.KChar 'r') []) -> openSelectedReplace
  VtyEvent (V.EvKey (V.KChar 'R') []) -> openSelectedReplace
  VtyEvent (V.EvKey V.KEnter []) -> openSelectedCompletion
  VtyEvent (V.EvKey (V.KChar 'c') []) -> openSelectedCompletion
  VtyEvent (V.EvKey (V.KChar 'C') []) -> openSelectedCompletion
  VtyEvent (V.EvKey vtyKey vtyMods) -> do
    zoom contextPlanListL (L.handleListEventVi L.handleListEvent (V.EvKey vtyKey vtyMods))
    pure MaintainContext
  _ -> pure MaintainContext
  where
    openAdd = do
      context <- get
      pure (StartFlow (startAdd context))
    openSelectedEdit = do
      context <- get
      case startSelectedEdit context of
        Nothing -> pure MaintainContext
        Just flow -> pure (StartFlow flow)
    openSelectedCancel = do
      context <- get
      case startSelectedCancel context of
        Nothing -> pure MaintainContext
        Just flow -> pure (StartFlow flow)
    openSelectedReplace = do
      context <- get
      case startSelectedReplace context of
        Nothing -> pure MaintainContext
        Just flow -> pure (StartFlow flow)
    openSelectedCompletion = do
      context <- get
      case startSelectedCompletion context of
        Nothing -> pure MaintainContext
        Just flow -> pure (StartFlow flow)
