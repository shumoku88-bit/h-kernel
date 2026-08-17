{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Actual.Daily
  ( State
  , FlowAction(..)
  , drawFlow
  , handleFlowEvent
  , startDaily
  , startIncome
  ) where

import Brick
import Brick.Focus (focusGetCurrent)
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal')

import Data.List (findIndex)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Text.Read (readMaybe)

import qualified HKernel.Account
import HKernel.Actual.Journal (actualJournalValue)
import HKernel.Editor.ActualAppend
  ( ActualAddInput(..)
  , ActualAddPreview(..)
  , prepareActualAddPreviewFromResolvedJournal
  )
import HKernel.Editor.Interaction.ActualAdd
  ( AccountSelectionTarget(..)
  , accountCandidateAt
  , dailyAccountCandidates
  , incomeAccountCandidates
  , initialActualAddInputForDay
  , selectActualAddAccount
  , stepAccountCandidate
  )
import HKernel.Editor.TUI.Actual.AccountSelector
  ( contextActualTransactions
  , flattenCandidateGroups
  , renderInlineAccountSelector
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , contextHouseholdState
  , contextSource
  )
import HKernel.Household.Application (HouseholdState(..))

data EntryKind
  = DailyExpense
  | DailyIncome
  deriving (Eq, Show)

data State event
  = Input EntryKind (Form ActualAddInput event Name)
  | Preview EntryKind ActualAddPreview (Form ActualAddInput event Name)

data FlowAction
  = FlowMaintain
  | FlowReturn
  | FlowQuit
  | FlowPublish Day Text

startDaily :: Day -> State event
startDaily = startEntry DailyExpense

startIncome :: Day -> State event
startIncome = startEntry DailyIncome

startEntry :: EntryKind -> Day -> State event
startEntry kind day = Input kind (mkDailyForm kind day)

addDateTextL :: Lens' ActualAddInput Text
addDateTextL f input =
  (\value -> input { addDateText = value }) <$> f (addDateText input)

addDescriptionTextL :: Lens' ActualAddInput Text
addDescriptionTextL f input =
  (\value -> input { addDescriptionText = value }) <$> f (addDescriptionText input)

addFromAccountTextL :: Lens' ActualAddInput Text
addFromAccountTextL f input =
  (\value -> input { addFromAccountText = value }) <$> f (addFromAccountText input)

addToAccountTextL :: Lens' ActualAddInput Text
addToAccountTextL f input =
  (\value -> input { addToAccountText = value }) <$> f (addToAccountText input)

addAmountTextL :: Lens' ActualAddInput Text
addAmountTextL f input =
  (\value -> input { addAmountText = value }) <$> f (addAmountText input)

mkForm :: EntryKind -> ActualAddInput -> Form ActualAddInput event Name
mkForm kind =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)
      (toLabel, fromLabel) = case kind of
        DailyExpense -> ("Category:", "Pay from:")
        DailyIncome -> ("Receive into:", "Income source:")
  in newForm
      [ label "Amount:"
          @@= editTextField addAmountTextL AmountField (Just 1)
      , label "Description:"
          @@= editTextField addDescriptionTextL DescriptionField (Just 1)
      , label toLabel
          @@= editTextField addToAccountTextL ToAccountField (Just 1)
      , label fromLabel
          @@= editTextField addFromAccountTextL FromAccountField (Just 1)
      , label "Date:"
          @@= editTextField addDateTextL DateField (Just 1)
      ]

mkDailyForm :: EntryKind -> Day -> Form ActualAddInput event Name
mkDailyForm kind day =
  setFormFocus AmountField
    (mkForm kind (initialActualAddInputForDay day))

zoomForm :: Traversal' (State AppEvent) (Form ActualAddInput AppEvent Name)
zoomForm f (Input kind form) = Input kind <$> f form
zoomForm _ state = pure state

drawFlow :: AppContext -> State AppEvent -> Widget Name
drawFlow context state = case state of
  Input kind form ->
    center
      (borderWithLabel (str (entryTitle kind))
        (padAll 1
          (vBox
            [ txt ("Date: " <> dateSummary context (addDateText (formState form)))
            , str "Amount accepts a quantity only when Account defaults determine the commodity."
            , str "Account fields expose existing typed Accounts inline; exact text remains available."
            , str " "
            , renderForm form
            , renderDailyInlineAccountSelector context kind form
            , str " "
            , inputControls form
            ])))
  Preview kind preview _ ->
    center
      (borderWithLabel (str (previewTitle kind))
        (padAll 1
          (renderPreview preview <=> str " " <=> str (previewControls preview))))

entryTitle :: EntryKind -> String
entryTitle kind = case kind of
  DailyExpense -> "Daily Expense"
  DailyIncome -> "Daily Income"

previewTitle :: EntryKind -> String
previewTitle kind = case kind of
  DailyExpense -> "Expense Preview"
  DailyIncome -> "Income Preview"

inputControls :: Form ActualAddInput AppEvent Name -> Widget Name
inputControls form = case selectionTarget form of
  Just _ -> str "[Up/Down] Choose Account | [click] Select | [Enter] Accept | [Tab] Next field | text edits exact Account | [Esc] Actual"
  Nothing -> str "[Tab] Next field | [Enter] Preview | [Esc] Actual"

renderDailyInlineAccountSelector
  :: AppContext
  -> EntryKind
  -> Form ActualAddInput AppEvent Name
  -> Widget Name
renderDailyInlineAccountSelector context kind form = case selectionTarget form of
  Nothing -> emptyWidget
  Just target ->
    renderInlineAccountSelector context label selectedCursor candidates
    where
      input = formState form
      current = accountText target input
      candidates = candidateAccounts context kind target
      selectedCursor = findIndex
        ((== T.strip current) . HKernel.Account.accountName) candidates
      label = case (kind, target) of
        (DailyExpense, SelectToAccount) -> "Expense Accounts"
        (DailyExpense, SelectFromAccount) -> "Payment Accounts"
        (DailyIncome, SelectToAccount) -> "Receiving Accounts"
        (DailyIncome, SelectFromAccount) -> "Income Accounts"

selectionTarget
  :: Form ActualAddInput event Name
  -> Maybe AccountSelectionTarget
selectionTarget form = case focusGetCurrent (formFocus form) of
  Just ToAccountField -> Just SelectToAccount
  Just FromAccountField -> Just SelectFromAccount
  _ -> Nothing

accountText :: AccountSelectionTarget -> ActualAddInput -> Text
accountText target input = case target of
  SelectToAccount -> addToAccountText input
  SelectFromAccount -> addFromAccountText input

candidateAccounts
  :: AppContext
  -> EntryKind
  -> AccountSelectionTarget
  -> [HKernel.Account.Account]
candidateAccounts context kind target =
  flattenCandidateGroups context (candidates registry transactions target)
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)
    transactions = contextActualTransactions context
    candidates = case kind of
      DailyExpense -> dailyAccountCandidates
      DailyIncome -> incomeAccountCandidates

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleFlowEvent context event = do
  state <- get
  case state of
    Input kind form -> handleInput context kind form event
    Preview kind preview form -> handlePreview context kind preview form event

handleInput
  :: AppContext
  -> EntryKind
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleInput context kind form event = case event of
  MouseDown (AccountCandidate index) V.BLeft _ _
    | Just target <- selectionTarget form ->
        selectAccountCandidateAt context kind target index form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
  VtyEvent (V.EvKey V.KUp [])
    | Just target <- selectionTarget form ->
        moveAccountCandidate context kind (-1) target form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KDown [])
    | Just target <- selectionTarget form ->
        moveAccountCandidate context kind 1 target form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter [])
    | Just target <- selectionTarget form ->
        acceptAccount kind target form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter []) -> do
    let input = formState form
        resolvedJournal = actualJournalValue
          (householdStateActualJournal (contextHouseholdState context))
        preview = prepareActualAddPreviewFromResolvedJournal
          resolvedJournal (contextSource context) input
    put (Preview kind preview form)
    pure FlowMaintain
  _ -> zoom zoomForm (handleFormEvent event) >> pure FlowMaintain

moveAccountCandidate
  :: AppContext
  -> EntryKind
  -> Int
  -> AccountSelectionTarget
  -> Form ActualAddInput AppEvent Name
  -> EventM Name (State AppEvent) ()
moveAccountCandidate context kind offset target form =
  case stepAccountCandidate offset current candidates of
    Nothing -> pure ()
    Just account ->
      let updatedInput = selectActualAddAccount target account input
          updatedForm = setFormFocus (fieldName target)
            (updateFormState updatedInput form)
      in put (Input kind updatedForm)
  where
    input = formState form
    current = accountText target input
    candidates = candidateAccounts context kind target

selectAccountCandidateAt
  :: AppContext
  -> EntryKind
  -> AccountSelectionTarget
  -> Int
  -> Form ActualAddInput AppEvent Name
  -> EventM Name (State AppEvent) ()
selectAccountCandidateAt context kind target index form =
  case accountCandidateAt index (candidateAccounts context kind target) of
    Nothing -> pure ()
    Just account ->
      let updatedInput = selectActualAddAccount target account (formState form)
          updatedForm = setFormFocus (nextField target)
            (updateFormState updatedInput form)
      in put (Input kind updatedForm)

acceptAccount
  :: EntryKind
  -> AccountSelectionTarget
  -> Form ActualAddInput AppEvent Name
  -> EventM Name (State AppEvent) ()
acceptAccount kind target form
  | T.null (T.strip (accountText target (formState form))) = pure ()
  | otherwise = put (Input kind (setFormFocus (nextField target) form))

fieldName :: AccountSelectionTarget -> Name
fieldName target = case target of
  SelectToAccount -> ToAccountField
  SelectFromAccount -> FromAccountField

nextField :: AccountSelectionTarget -> Name
nextField target = case target of
  SelectToAccount -> FromAccountField
  SelectFromAccount -> DateField

handlePreview
  :: AppContext
  -> EntryKind
  -> ActualAddPreview
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handlePreview context kind preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'b') []) -> back
  VtyEvent (V.EvKey (V.KChar 'B') []) -> back
  VtyEvent (V.EvKey V.KEnter []) -> publish
  VtyEvent (V.EvKey (V.KChar 'y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'c') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'C') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'q') []) -> pure FlowQuit
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure FlowQuit
  _ -> pure FlowMaintain
  where
    back = put (Input kind form) >> pure FlowMaintain
    publish = case preview of
      ActualAddCandidateReady block ->
        let stickyDay = fromMaybe (contextEntryDay context)
              (readMaybe (T.unpack (addDateText (formState form))))
        in pure (FlowPublish stickyDay block)
      _ -> pure FlowMaintain

renderPreview :: ActualAddPreview -> Widget Name
renderPreview preview = case preview of
  ActualAddInputRejected inputError ->
    withAttr (attrName "error")
      (txt ("Input rejected: " <> T.pack (show inputError)))
  ActualAddCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txt (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualAddCandidateReady block ->
    withAttr (attrName "success")
      (str "Validation successful. Source unmodified.")
      <=> str " " <=> txt block

previewControls :: ActualAddPreview -> String
previewControls preview = case preview of
  ActualAddCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"

dateSummary :: AppContext -> Text -> Text
dateSummary context value
  | value == T.pack (show today) = "Today  " <> value
  | otherwise = "Other  " <> value
  where
    today = contextObservationDay context
