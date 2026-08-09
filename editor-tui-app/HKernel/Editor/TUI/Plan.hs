{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module HKernel.Editor.TUI.Plan
  ( PublishResult(..)
  , State(..)
  , drawFlow
  , drawWorkspace
  , handleFlowEvent
  , publishCandidate
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
import HKernel.Application.Config (HouseholdSourcePaths(..))
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
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
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
  , renderQuantity
  )
import HKernel.Plan (planIdText)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , identifiedPlanId
  , identifiedPlanTransaction
  )

data PreviewResult
  = PreviewRejected Text
  | PreviewReady PlanCompleteAdvancePreview

data State event
  = Input PlanAdvanceProposal (Form PlanCompleteAdvanceInput event Name)
  | Preview PlanAdvanceProposal PreviewResult (Form PlanCompleteAdvanceInput event Name)
  | Confirmation PlanAdvanceProposal PlanCompleteAdvancePreview (Form PlanCompleteAdvanceInput event Name)
  | WriteOutcome Text
  | ReturnToWorkspace
  | PublishRequested PlanCompleteAdvancePreview
  | QuitRequested

data PublishResult
  = Published AppContext
  | PublicationFailed Text
  | ReloadFailed

startSelectedCompletion :: AppContext -> Maybe (State event)
startSelectedCompletion context = do
  (_, identified) <- L.listSelectedElement (contextPlanList context)
  pure $ case proposePlanAdvance
      (householdStatePlanJournal (contextHouseholdState context))
      (contextPlanSource context)
      (identifiedPlanId identified) of
    Left errors -> WriteOutcome
      ("Cannot prepare selected Plan: " <> T.pack (show (NonEmpty.toList errors)))
    Right proposal -> Input proposal
      (mkPlanCompleteForm (contextObservationDay context) proposal)

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

mkPlanCompleteForm
  :: Day
  -> PlanAdvanceProposal
  -> Form PlanCompleteAdvanceInput event Name
mkPlanCompleteForm today proposal =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 23 (str labelText <+> fill ' '))) <+> widget)
      form = newForm
        [ label "Actual date:"
            @@= editTextField planActualDateTextL PlanActualDateField (Just 1)
        , label "Actual amount override:"
            @@= editTextField planActualAmountTextL PlanActualAmountField (Just 1)
        , label "Next nominal date:"
            @@= editTextField planSuccessorDateTextL PlanSuccessorDateField (Just 1)
        , label "Next amount override:"
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
              <=> str "Edit Actual date directly; no modified or function keys are required."
              <=> str "[Tab] Next field | [Esc] Plans | [Enter] Preview"))))
  Preview _ result _ ->
    center
      (borderWithLabel (str "Complete & Advance Preview")
        (hLimit 86
          (vLimit 30
            (padAll 1
              (renderPreviewResult result
                <=> str " "
                <=> str (previewControls result))))))
  Confirmation _ preview _ ->
    center
      (borderWithLabel (str "Confirm Complete & Advance")
        (hLimit 86
          (vLimit 30
            (padAll 1
              ( str "This will update Actual and, when present, append the successor Plan as one operation."
                <=> str "Both complete candidates have already been validated."
                <=> str " "
                <=> renderCompletePreview preview
                <=> str " "
                <=> str "[Y] Publish both | [N/Esc] Back | [Q] Quit")))))
  WriteOutcome message ->
    center
      (borderWithLabel (str "Plan Complete & Advance Result")
        (padAll 1 (txt message <=> str " " <=> str "[Esc] Plans | [Q] Quit")))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ -> emptyWidget
  QuitRequested -> emptyWidget

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ borderWithLabel (str "Open Plans (plan.journal)")
        (vLimit 18
          (L.renderList renderPlanItem True (contextPlanList context)))
    , borderWithLabel (str "Selected Plan")
        (padAll 1 (renderSelectedPlan context))
    , str "[j/k/Arrows] Move   [Enter/C] Complete & Advance   [1-7] Sections   [q] Quit"
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
  -> PreviewResult
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
  VtyEvent (V.EvKey (V.KChar 'y') []) -> put (PublishRequested preview)
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> put (PublishRequested preview)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
  _ -> pure ()
  where
    back = put (Preview proposal (PreviewReady preview) form)

publishCandidate :: AppContext -> PlanCompleteAdvancePreview -> IO PublishResult
publishCandidate context preview = do
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
    Right () -> do
      reloaded <- reloadWorkspaceContext
        (context { contextCurrentSection = PlansSection })
      pure $ case reloaded of
        Nothing -> ReloadFailed
        Just freshContext -> Published
          (freshContext { contextCurrentSection = PlansSection })
    Left writeError -> pure (PublicationFailed (renderWriteError writeError))

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
  Just (_, identified) ->
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

renderPreviewResult :: PreviewResult -> Widget Name
renderPreviewResult result = case result of
  PreviewRejected message -> withAttr (attrName "error") (txt message)
  PreviewReady preview -> renderCompletePreview preview

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

previewControls :: PreviewResult -> String
previewControls result = case result of
  PreviewReady _ -> "[Esc/B] Back | [C] Continue to confirmation | [Q] Quit"
  PreviewRejected _ -> "[Esc/B] Back | [Q] Quit"

renderPosting :: Posting -> Widget Name
renderPosting posting =
  txt ("  " <> accountName (postingAccount posting) <> "  "
    <> renderQuantity (amountQuantity amount) <> " "
    <> commodityCode (amountCommodity amount))
  where
    amount = postingAmount posting
