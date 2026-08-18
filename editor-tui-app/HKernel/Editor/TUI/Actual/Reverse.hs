{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Actual.Reverse
  ( State
  , FlowAction(..)
  , drawFlow
  , handleFlowEvent
  , startSelected
  ) where

import Brick
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal')

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)

import qualified HKernel.Account
import HKernel.Actual.Journal
  ( actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntryIdentity
  )
import HKernel.Editor.ActualReverse
  ( ActualReverseInput(..)
  , ActualReverseInputPreview(..)
  , prepareActualReverseInputFromResolvedJournal
  , suggestActualReverseEventIdText
  )
import HKernel.Editor.TUI.Actual.Workspace (selectedWorkspaceReverseTarget)
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , contextHouseholdState
  , contextSource
  )
import HKernel.Household.Application (HouseholdState(..))
import HKernel.Ledger
  ( Posting
  , Transaction
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
import HKernel.Plan.Completion
  ( ActualTransactionId
  , actualTransactionIdText
  )

data State event
  = Input ActualTransactionId Transaction (Form ActualReverseInput event Name)
  | Preview ActualTransactionId Transaction ActualReverseInputPreview (Form ActualReverseInput event Name)
  | Unavailable Text

data FlowAction
  = FlowMaintain
  | FlowReturn
  | FlowQuit
  | FlowPublish Text

startSelected :: AppContext -> State event
startSelected context = case selectedWorkspaceReverseTarget context of
  Left message -> Unavailable message
  Right (targetId, transaction) ->
    let existingIds =
          [ identity
          | entry <- actualJournalTransactionEntries
              (householdStateActualJournal (contextHouseholdState context))
          , Just identity <- [actualTransactionEntryIdentity entry]
          ]
        eventIdText = suggestActualReverseEventIdText existingIds targetId
    in Input targetId transaction
        (mkReverseForm (contextObservationDay context) eventIdText transaction)

reverseInputDateTextL :: Lens' ActualReverseInput Text
reverseInputDateTextL f input =
  (\value -> input { reverseInputDateText = value })
    <$> f (reverseInputDateText input)

reverseInputDescriptionTextL :: Lens' ActualReverseInput Text
reverseInputDescriptionTextL f input =
  (\value -> input { reverseInputDescriptionText = value })
    <$> f (reverseInputDescriptionText input)

initialReverseInput :: Day -> Text -> Transaction -> ActualReverseInput
initialReverseInput day eventIdText transaction = ActualReverseInput
  { reverseInputEventIdText = eventIdText
  , reverseInputDateText = T.pack (show day)
  , reverseInputDescriptionText = "Reverse: " <> transactionDescription transaction
  }

mkReverseForm
  :: Day
  -> Text
  -> Transaction
  -> Form ActualReverseInput event Name
mkReverseForm day eventIdText transaction =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)
      form = newForm
        [ label "Date:"
            @@= editTextField reverseInputDateTextL ReverseDateField (Just 1)
        , label "Description:"
            @@= editTextField reverseInputDescriptionTextL ReverseDescriptionField (Just 1)
        ]
  in setFormFocus ReverseDescriptionField
      (form (initialReverseInput day eventIdText transaction))

zoomForm :: Traversal' (State AppEvent) (Form ActualReverseInput AppEvent Name)
zoomForm f (Input target transaction form) =
  Input target transaction <$> f form
zoomForm _ state = pure state

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  Input targetId transaction form ->
    center
      (borderWithLabel (str "Reverse Actual")
        (hLimit 86
          (padAll 1
            (vBox
              [ renderReverseTarget targetId transaction
              , str " "
              , strWrap "The original transaction stays immutable; Reverse appends its exact inverse."
              , strWrap "Reversal identity is generated automatically."
              , str " "
              , renderForm form
              , str " "
              , strWrap "[Tab] Next field | [Esc] Actual | [Enter] Preview"
              ]))))
  Preview targetId transaction preview _ ->
    center
      (borderWithLabel (str "Reverse Preview")
        (hLimit 86
          (padAll 1
            ( renderReverseTarget targetId transaction
              <=> str " "
              <=> renderReversePreview preview
              <=> str " "
              <=> strWrap (previewControls preview)))))
  Unavailable message ->
    center
      (borderWithLabel (str "Reverse unavailable")
        (hLimit 80
          (padAll 1
            ( withAttr (attrName "warning") (txtWrap message)
              <=> str " "
              <=> strWrap "[Enter/Esc] Back to Actual | [Q] Quit"))))

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleFlowEvent context event = do
  state <- get
  case state of
    Input targetId transaction form -> handleInput context targetId transaction form event
    Preview targetId transaction preview form ->
      handlePreview targetId transaction preview form event
    Unavailable _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
      VtyEvent (V.EvKey V.KEnter []) -> pure FlowReturn
      VtyEvent (V.EvKey (V.KChar 'q') []) -> pure FlowQuit
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure FlowQuit
      _ -> pure FlowMaintain

handleInput
  :: AppContext
  -> ActualTransactionId
  -> Transaction
  -> Form ActualReverseInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleInput context targetId transaction form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
  VtyEvent (V.EvKey V.KEnter []) -> do
    let resolvedJournal = actualJournalValue
          (householdStateActualJournal (contextHouseholdState context))
        preview = prepareActualReverseInputFromResolvedJournal
          resolvedJournal (contextSource context) targetId (formState form)
    put (Preview targetId transaction preview form)
    pure FlowMaintain
  _ -> zoom zoomForm (handleFormEvent event) >> pure FlowMaintain

handlePreview
  :: ActualTransactionId
  -> Transaction
  -> ActualReverseInputPreview
  -> Form ActualReverseInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handlePreview targetId transaction preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'b') []) -> back
  VtyEvent (V.EvKey (V.KChar 'B') []) -> back
  VtyEvent (V.EvKey V.KEnter []) -> publish
  VtyEvent (V.EvKey (V.KChar 'y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'q') []) -> pure FlowQuit
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure FlowQuit
  _ -> pure FlowMaintain
  where
    back = put (Input targetId transaction form) >> pure FlowMaintain
    publish = case preview of
      ActualReverseCandidateReady block -> pure (FlowPublish block)
      _ -> pure FlowMaintain

renderReverseTarget :: ActualTransactionId -> Transaction -> Widget Name
renderReverseTarget targetId transaction =
  vBox
    ( txtWrap (T.pack (show (transactionDate transaction))
        <> "  [" <> actualTransactionIdText targetId <> "]  "
        <> transactionDescription transaction)
      : map renderPosting (NonEmpty.toList (transactionPostings transaction))
    )

renderPosting :: Posting -> Widget Name
renderPosting posting =
  txtWrap ("  " <> HKernel.Account.accountName (postingAccount posting) <> "  "
    <> renderQuantity (amountQuantity amount) <> " "
    <> commodityCode (amountCommodity amount))
  where
    amount = postingAmount posting

renderReversePreview :: ActualReverseInputPreview -> Widget Name
renderReversePreview preview = case preview of
  ActualReverseInputRejected inputError ->
    withAttr (attrName "error")
      (txtWrap ("Input rejected: " <> T.pack (show inputError)))
  ActualReverseCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txtWrap (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualReverseCandidateReady block ->
    withAttr (attrName "success")
      (strWrap "Validation successful. Source unmodified.")
      <=> str " " <=> txtWrap block

previewControls :: ActualReverseInputPreview -> String
previewControls preview = case preview of
  ActualReverseCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"
