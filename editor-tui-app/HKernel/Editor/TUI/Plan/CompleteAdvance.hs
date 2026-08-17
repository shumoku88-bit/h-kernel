{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Plan.CompleteAdvance
  ( FlowAction(..)
  , State
  , drawFlow
  , handleFlowEvent
  , startSelectedCompletion
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

import HKernel.Account (accountName)
import HKernel.Editor.Interaction.PlanCompleteAdvance
  ( PlanCompleteAdvanceInput(..)
  , initialPlanCompleteAdvanceInput
  , parsePlanCompleteAdvanceInput
  )
import HKernel.Editor.PlanCompleteAdvance
  ( PlanAdvanceProposal(..)
  , PlanCompleteAdvancePreview(..)
  , PlanRecurrence(..)
  , preparePlanCompleteAdvance
  , proposePlanAdvance
  )
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
  , transactionPostings
  )
import HKernel.Money
  ( amountCommodity
  , amountQuantity
  , commodityCode
  , renderQuantity
  )
import HKernel.Plan (PlanId, planIdText)
import HKernel.Plan.Journal (identifiedPlanId)

data PreviewResult preview
  = PreviewRejected Text
  | PreviewReady preview

data State event
  = Input PlanAdvanceProposal (Form PlanCompleteAdvanceInput event Name)
  | Preview PlanAdvanceProposal (PreviewResult PlanCompleteAdvancePreview)
      (Form PlanCompleteAdvanceInput event Name)
  | Confirmation PlanAdvanceProposal PlanCompleteAdvancePreview
      (Form PlanCompleteAdvanceInput event Name)

data FlowAction
  = FlowMaintain
  | FlowReturn
  | FlowQuit
  | FlowPublish PlanId PlanCompleteAdvancePreview

startSelectedCompletion :: AppContext -> Maybe (State event)
startSelectedCompletion context = do
  (_, identified) <- L.listSelectedElement (contextPlanList context)
  pure $ case proposePlanAdvance
      (householdStatePlanJournal (contextHouseholdState context))
      (identifiedPlanId identified) of
    Left errors ->
      -- Keep proposal rejection in the parent result surface rather than
      -- manufacturing a partial completion state.
      InputRejected
        ("Cannot prepare selected Plan: "
          <> T.pack (show (NonEmpty.toList errors)))
    Right proposal -> Input proposal
      (mkPlanCompleteForm (contextObservationDay context) proposal)

-- Proposal construction can fail before a form exists. Keep that failure in
-- this concrete flow owner so the parent does not need PlanCompleteAdvance
-- internals merely to render it.
data InitialState event
  = InputRejected Text
  | InputReady (State event)

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

zoomInputForm
  :: Traversal' (State AppEvent) (Form PlanCompleteAdvanceInput AppEvent Name)
zoomInputForm f (Input proposal form) = Input proposal <$> f form
zoomInputForm _ state = pure state

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

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleFlowEvent context event = do
  state <- get
  case state of
    Input proposal form -> handleInput context proposal form event
    Preview proposal result form -> handlePreview proposal result form event
    Confirmation proposal preview form ->
      handleConfirmation proposal preview form event

handleInput
  :: AppContext
  -> PlanAdvanceProposal
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleInput context proposal form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
  VtyEvent (V.EvKey V.KEnter []) -> preparePreview context proposal form
  _ -> zoom zoomInputForm (handleFormEvent event) >> pure FlowMaintain

preparePreview
  :: AppContext
  -> PlanAdvanceProposal
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> EventM Name (State AppEvent) FlowAction
preparePreview context proposal form = do
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
          ("Plan completion rejected: "
            <> T.pack (show (NonEmpty.toList errors)))) form)
      Right preview -> put (Preview proposal (PreviewReady preview) form)
  pure FlowMaintain
  where
    state = contextHouseholdState context

handlePreview
  :: PlanAdvanceProposal
  -> PreviewResult PlanCompleteAdvancePreview
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handlePreview proposal result form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'b') []) -> back
  VtyEvent (V.EvKey (V.KChar 'B') []) -> back
  VtyEvent (V.EvKey (V.KChar 'c') []) -> continuePreview
  VtyEvent (V.EvKey (V.KChar 'C') []) -> continuePreview
  VtyEvent (V.EvKey (V.KChar 'q') []) -> pure FlowQuit
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure FlowQuit
  _ -> pure FlowMaintain
  where
    back = put (Input proposal form) >> pure FlowMaintain
    continuePreview = case result of
      PreviewRejected _ -> pure FlowMaintain
      PreviewReady preview ->
        put (Confirmation proposal preview form) >> pure FlowMaintain

handleConfirmation
  :: PlanAdvanceProposal
  -> PlanCompleteAdvancePreview
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleConfirmation proposal preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'n') []) -> back
  VtyEvent (V.EvKey (V.KChar 'N') []) -> back
  VtyEvent (V.EvKey (V.KChar 'y') []) ->
    pure (FlowPublish (proposalPlanId proposal) preview)
  VtyEvent (V.EvKey (V.KChar 'Y') []) ->
    pure (FlowPublish (proposalPlanId proposal) preview)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> pure FlowQuit
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure FlowQuit
  _ -> pure FlowMaintain
  where
    back = put (Preview proposal (PreviewReady preview) form) >> pure FlowMaintain

renderPlanProposal :: PlanAdvanceProposal -> Widget Name
renderPlanProposal proposal =
  vBox
    [ txt ("Plan: " <> T.pack (show (proposalNominalDate proposal))
        <> "  [" <> planIdText (proposalPlanId proposal) <> "]  "
        <> proposalDescription proposal)
    , txt ("Recurrence: " <> recurrenceLabel (proposalRecurrence proposal))
    , str "Planned postings:"
    , vBox (map renderPosting
        (NonEmpty.toList
          (transactionPostings (proposalOriginalTransaction proposal))))
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

renderPosting :: Posting -> Widget Name
renderPosting posting =
  txt ("  " <> accountName (postingAccount posting) <> "  "
    <> renderQuantity (amountQuantity amount) <> " "
    <> commodityCode (amountCommodity amount))
  where
    amount = postingAmount posting
