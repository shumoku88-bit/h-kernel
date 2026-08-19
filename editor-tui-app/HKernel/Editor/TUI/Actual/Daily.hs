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
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal')

import Data.List (findIndex)
import Data.List.NonEmpty (NonEmpty((:|)))
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
  , ActualExpenseInput(..)
  , ActualExpenseItemInput(..)
  , ActualExpensePreview(..)
  , prepareActualAddPreviewFromResolvedJournal
  , prepareActualExpensePreviewFromResolvedJournal
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

data ExpenseFormState = ExpenseFormState
  { expenseFormInput        :: ActualExpenseInput
  , expenseFormSelectedItem :: Int
  , expenseFormItemCountText :: Text
  } deriving (Eq, Show)

data ExpenseAccountTarget
  = ExpensePaymentTarget
  | ExpenseItemTarget
  deriving (Eq, Show)

data State event
  = ExpenseInput (Form ExpenseFormState event Name)
  | ExpensePreview ActualExpensePreview (Form ExpenseFormState event Name)
  | IncomeInput (Form ActualAddInput event Name)
  | IncomePreview ActualAddPreview (Form ActualAddInput event Name)

data FlowAction
  = FlowMaintain
  | FlowReturn
  | FlowQuit
  | FlowPublish Day Text

startDaily :: Day -> State event
startDaily day = ExpenseInput (mkExpenseForm day)

startIncome :: Day -> State event
startIncome day = IncomeInput (mkIncomeForm day)

-- Expense --------------------------------------------------------------------

initialExpenseInput :: Day -> ActualExpenseInput
initialExpenseInput day = ActualExpenseInput
  { expenseDateText = T.pack (show day)
  , expenseDescriptionText = ""
  , expensePaymentAccountText = ""
  , expenseItems = ActualExpenseItemInput "" "" :| []
  }

initialExpenseFormState :: Day -> ExpenseFormState
initialExpenseFormState day = ExpenseFormState
  { expenseFormInput = initialExpenseInput day
  , expenseFormSelectedItem = 0
  , expenseFormItemCountText = "1"
  }

expenseDescriptionTextL :: Lens' ExpenseFormState Text
expenseDescriptionTextL f state =
  (\value -> state
      { expenseFormInput = input { expenseDescriptionText = value } })
    <$> f (expenseDescriptionText input)
  where
    input = expenseFormInput state

expensePaymentAccountTextL :: Lens' ExpenseFormState Text
expensePaymentAccountTextL f state =
  (\value -> state
      { expenseFormInput = input { expensePaymentAccountText = value } })
    <$> f (expensePaymentAccountText input)
  where
    input = expenseFormInput state

expenseItemCountTextL :: Lens' ExpenseFormState Text
expenseItemCountTextL f state =
  (\value -> state { expenseFormItemCountText = value })
    <$> f (expenseFormItemCountText state)

expenseItemAccountTextL :: Lens' ExpenseFormState Text
expenseItemAccountTextL f state =
  (\value -> setSelectedExpenseItem
      (item { expenseItemAccountText = value }) state)
    <$> f (expenseItemAccountText item)
  where
    item = selectedExpenseItem state

expenseItemAmountTextL :: Lens' ExpenseFormState Text
expenseItemAmountTextL f state =
  (\value -> setSelectedExpenseItem
      (item { expenseItemAmountText = value }) state)
    <$> f (expenseItemAmountText item)
  where
    item = selectedExpenseItem state

mkExpenseForm :: Day -> Form ExpenseFormState event Name
mkExpenseForm day =
  setFormFocus ExpenseDescriptionField
    (newForm
      [ label "Description:"
          @@= editTextField expenseDescriptionTextL ExpenseDescriptionField (Just 1)
      , label "Pay from:"
          @@= editTextField expensePaymentAccountTextL ExpensePaymentField (Just 1)
      , label "Breakdown count:"
          @@= editTextField expenseItemCountTextL ExpenseItemCountField (Just 1)
      , label "Selected category:"
          @@= editTextField expenseItemAccountTextL ExpenseItemAccountField (Just 1)
      , label "Selected amount:"
          @@= editTextField expenseItemAmountTextL ExpenseItemAmountField (Just 1)
      ]
      (initialExpenseFormState day))
  where
    label labelText widget =
      padBottom (Pad 1)
        ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)

selectedExpenseItem :: ExpenseFormState -> ActualExpenseItemInput
selectedExpenseItem state =
  rows !! clampExpenseItemIndex
    (expenseFormSelectedItem state) (expenseFormInput state)
  where
    rows = NonEmpty.toList (expenseItems (expenseFormInput state))

setSelectedExpenseItem
  :: ActualExpenseItemInput
  -> ExpenseFormState
  -> ExpenseFormState
setSelectedExpenseItem updated state = state
  { expenseFormInput = input
      { expenseItems = toExpenseNonEmpty
          [ if index == selected then updated else item
          | (index, item) <- zip [0 ..] rows
          ]
      }
  }
  where
    input = expenseFormInput state
    rows = NonEmpty.toList (expenseItems input)
    selected = clampExpenseItemIndex (expenseFormSelectedItem state) input

applyExpenseItemCount :: ExpenseFormState -> ExpenseFormState
applyExpenseItemCount state = state
  { expenseFormInput = resizedInput
  , expenseFormSelectedItem = clampExpenseItemIndex selected resizedInput
  , expenseFormItemCountText = T.pack (show desired)
  }
  where
    input = expenseFormInput state
    rows = NonEmpty.toList (expenseItems input)
    currentCount = length rows
    requestedCount = fromMaybe currentCount
      (readMaybe (T.unpack (T.strip (expenseFormItemCountText state))))
    desired = max 1 requestedCount
    blanks = replicate (max 0 (desired - currentCount))
      (ActualExpenseItemInput "" "")
    resizedInput = input
      { expenseItems = toExpenseNonEmpty (take desired (rows <> blanks)) }
    selected = expenseFormSelectedItem state

selectExpenseItem :: Int -> ExpenseFormState -> ExpenseFormState
selectExpenseItem requested state = state
  { expenseFormSelectedItem = clampExpenseItemIndex requested (expenseFormInput state) }

clampExpenseItemIndex :: Int -> ActualExpenseInput -> Int
clampExpenseItemIndex requested input =
  max 0 (min requested (NonEmpty.length (expenseItems input) - 1))

toExpenseNonEmpty :: [ActualExpenseItemInput] -> NonEmpty ActualExpenseItemInput
toExpenseNonEmpty values = case NonEmpty.nonEmpty values of
  Just result -> result
  Nothing -> ActualExpenseItemInput "" "" :| []

expenseAccountTarget
  :: Form ExpenseFormState event Name
  -> Maybe ExpenseAccountTarget
expenseAccountTarget form = case focusGetCurrent (formFocus form) of
  Just ExpensePaymentField -> Just ExpensePaymentTarget
  Just ExpenseItemAccountField -> Just ExpenseItemTarget
  _ -> Nothing

expenseAccountText :: ExpenseAccountTarget -> ExpenseFormState -> Text
expenseAccountText target state = case target of
  ExpensePaymentTarget ->
    expensePaymentAccountText (expenseFormInput state)
  ExpenseItemTarget ->
    expenseItemAccountText (selectedExpenseItem state)

expenseCandidates
  :: AppContext
  -> ExpenseAccountTarget
  -> [HKernel.Account.Account]
expenseCandidates context target =
  flattenCandidateGroups context
    (dailyAccountCandidates registry transactions accountTarget)
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)
    transactions = contextActualTransactions context
    accountTarget = case target of
      ExpensePaymentTarget -> SelectFromAccount
      ExpenseItemTarget -> SelectToAccount

setExpenseAccount
  :: ExpenseAccountTarget
  -> HKernel.Account.Account
  -> ExpenseFormState
  -> ExpenseFormState
setExpenseAccount target account state = case target of
  ExpensePaymentTarget -> state
    { expenseFormInput = input
        { expensePaymentAccountText = HKernel.Account.accountName account }
    }
  ExpenseItemTarget -> setSelectedExpenseItem
    (item { expenseItemAccountText = HKernel.Account.accountName account }) state
  where
    input = expenseFormInput state
    item = selectedExpenseItem state

expenseAccountField :: ExpenseAccountTarget -> Name
expenseAccountField target = case target of
  ExpensePaymentTarget -> ExpensePaymentField
  ExpenseItemTarget -> ExpenseItemAccountField

expenseNextField :: ExpenseAccountTarget -> Name
expenseNextField target = case target of
  ExpensePaymentTarget -> ExpenseItemCountField
  ExpenseItemTarget -> ExpenseItemAmountField

zoomExpenseForm
  :: Traversal' (State AppEvent) (Form ExpenseFormState AppEvent Name)
zoomExpenseForm f (ExpenseInput form) = ExpenseInput <$> f form
zoomExpenseForm _ state = pure state

drawExpenseInput :: AppContext -> Form ExpenseFormState AppEvent Name -> Widget Name
drawExpenseInput context form =
  center
    (borderWithLabel (str "Expense")
      (hLimit 86
        (padAll 1
          (vBox
            [ txt ("Entry day: " <> T.pack (show (contextEntryDay context)))
            , strWrap "The entry day is already fixed by the current TUI context."
            , strWrap "One payment can be divided across one or more Expense categories."
            , strWrap "Breakdown amounts stay positive; the balancing payment posting is derived exactly at preview."
            , str " "
            , renderExpenseRows state
            , str " "
            , txt ("Editing breakdown "
                <> T.pack (show (expenseFormSelectedItem state + 1))
                <> " of "
                <> T.pack (show (NonEmpty.length
                    (expenseItems (expenseFormInput state)))))
            , renderForm form
            , renderExpenseInlineAccountSelector context form
            , str " "
            , expenseInputControls form
            ]))))
  where
    state = formState form

renderExpenseRows :: ExpenseFormState -> Widget Name
renderExpenseRows state =
  vBox
    [ renderRow index item
    | (index, item) <- zip [0 ..]
        (NonEmpty.toList (expenseItems (expenseFormInput state)))
    ]
  where
    selected = expenseFormSelectedItem state
    renderRow index item =
      let accountText
            | T.null (expenseItemAccountText item) = "(expense category)"
            | otherwise = expenseItemAccountText item
          amountText
            | T.null (expenseItemAmountText item) = "(amount)"
            | otherwise = expenseItemAmountText item
          row = txtWrap
            (T.pack (show (index + 1)) <> ".  " <> accountText <> "  " <> amountText)
      in if index == selected then withAttr L.listSelectedAttr row else row

renderExpenseInlineAccountSelector
  :: AppContext
  -> Form ExpenseFormState AppEvent Name
  -> Widget Name
renderExpenseInlineAccountSelector context form = case expenseAccountTarget form of
  Nothing -> emptyWidget
  Just target ->
    renderInlineAccountSelector context label selectedCursor candidates
    where
      state = formState form
      current = expenseAccountText target state
      candidates = expenseCandidates context target
      selectedCursor = findIndex
        ((== T.strip current) . HKernel.Account.accountName) candidates
      label = case target of
        ExpensePaymentTarget -> "Payment Accounts"
        ExpenseItemTarget -> "Expense Accounts"

expenseInputControls :: Form ExpenseFormState AppEvent Name -> Widget Name
expenseInputControls form = case expenseAccountTarget form of
  Just _ ->
    strWrap "[Up/Down] Choose Account | [click] Select | [Enter] Accept | [Tab] Next field | [Esc] Actual"
  Nothing
    | focusGetCurrent (formFocus form) == Just ExpenseItemCountField ->
        strWrap "[Enter] Apply breakdown count | [Tab] Next field | [Esc] Actual"
    | otherwise ->
        strWrap "[Up/Down] Previous/next breakdown | [Tab] Next field | [Enter] Preview | [Esc] Actual"

handleExpenseInput
  :: AppContext
  -> Form ExpenseFormState AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleExpenseInput context form event = case event of
  MouseDown (AccountCandidate index) V.BLeft _ _
    | Just target <- expenseAccountTarget form ->
        selectExpenseCandidateAt context target index form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
  VtyEvent (V.EvKey V.KUp [])
    | Just target <- expenseAccountTarget form ->
        moveExpenseCandidate context (-1) target form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KDown [])
    | Just target <- expenseAccountTarget form ->
        moveExpenseCandidate context 1 target form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter [])
    | Just target <- expenseAccountTarget form ->
        acceptExpenseAccount target form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter [])
    | focusGetCurrent (formFocus form) == Just ExpenseItemCountField ->
        applyExpenseCount form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KUp []) ->
    moveExpenseSelection (-1) form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KDown []) ->
    moveExpenseSelection 1 form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter []) -> do
    let applied = applyExpenseItemCount (formState form)
        updatedForm = updateFormState applied form
        resolvedJournal = actualJournalValue
          (householdStateActualJournal (contextHouseholdState context))
        preview = prepareActualExpensePreviewFromResolvedJournal
          resolvedJournal (contextSource context) (expenseFormInput applied)
    put (ExpensePreview preview updatedForm)
    pure FlowMaintain
  _ -> zoom zoomExpenseForm (handleFormEvent event) >> pure FlowMaintain

moveExpenseCandidate
  :: AppContext
  -> Int
  -> ExpenseAccountTarget
  -> Form ExpenseFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
moveExpenseCandidate context offset target form =
  case stepAccountCandidate offset current candidates of
    Nothing -> pure ()
    Just account ->
      let updatedState = setExpenseAccount target account state
          updatedForm = setFormFocus (expenseAccountField target)
            (updateFormState updatedState form)
      in put (ExpenseInput updatedForm)
  where
    state = formState form
    current = expenseAccountText target state
    candidates = expenseCandidates context target

selectExpenseCandidateAt
  :: AppContext
  -> ExpenseAccountTarget
  -> Int
  -> Form ExpenseFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
selectExpenseCandidateAt context target index form =
  case accountCandidateAt index (expenseCandidates context target) of
    Nothing -> pure ()
    Just account ->
      let updatedState = setExpenseAccount target account (formState form)
          updatedForm = setFormFocus (expenseNextField target)
            (updateFormState updatedState form)
      in put (ExpenseInput updatedForm)

acceptExpenseAccount
  :: ExpenseAccountTarget
  -> Form ExpenseFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
acceptExpenseAccount target form
  | T.null (T.strip (expenseAccountText target (formState form))) = pure ()
  | otherwise =
      put (ExpenseInput (setFormFocus (expenseNextField target) form))

applyExpenseCount
  :: Form ExpenseFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
applyExpenseCount form =
  let applied = applyExpenseItemCount (formState form)
  in put (ExpenseInput
      (setFormFocus ExpenseItemAccountField (updateFormState applied form)))

moveExpenseSelection
  :: Int
  -> Form ExpenseFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
moveExpenseSelection offset form =
  let applied = applyExpenseItemCount (formState form)
      selected = expenseFormSelectedItem applied + offset
      moved = selectExpenseItem selected applied
  in put (ExpenseInput (updateFormState moved form))

handleExpensePreview
  :: AppContext
  -> ActualExpensePreview
  -> Form ExpenseFormState AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleExpensePreview context preview form event = case event of
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
    back = put (ExpenseInput form) >> pure FlowMaintain
    publish = case preview of
      ActualExpenseCandidateReady block ->
        pure (FlowPublish (contextEntryDay context) block)
      _ -> pure FlowMaintain

renderExpensePreview :: ActualExpensePreview -> Widget Name
renderExpensePreview preview = case preview of
  ActualExpenseInputRejected inputError ->
    withAttr (attrName "error")
      (txtWrap ("Input rejected: " <> T.pack (show inputError)))
  ActualExpenseCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txtWrap (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualExpenseCandidateReady block ->
    withAttr (attrName "success")
      (strWrap "Validation successful. Source unmodified. Payment posting derived from breakdown.")
      <=> str " " <=> txtWrap block

expensePreviewControls :: ActualExpensePreview -> String
expensePreviewControls preview = case preview of
  ActualExpenseCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"

-- Income ---------------------------------------------------------------------

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

mkIncomeForm :: Day -> Form ActualAddInput event Name
mkIncomeForm day =
  setFormFocus AmountField
    (newForm
      [ label "Amount:"
          @@= editTextField addAmountTextL AmountField (Just 1)
      , label "Description:"
          @@= editTextField addDescriptionTextL DescriptionField (Just 1)
      , label "Receive into:"
          @@= editTextField addToAccountTextL ToAccountField (Just 1)
      , label "Income source:"
          @@= editTextField addFromAccountTextL FromAccountField (Just 1)
      ]
      (initialActualAddInputForDay day))
  where
    label labelText widget =
      padBottom (Pad 1)
        ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)

zoomIncomeForm
  :: Traversal' (State AppEvent) (Form ActualAddInput AppEvent Name)
zoomIncomeForm f (IncomeInput form) = IncomeInput <$> f form
zoomIncomeForm _ state = pure state

incomeSelectionTarget
  :: Form ActualAddInput event Name
  -> Maybe AccountSelectionTarget
incomeSelectionTarget form = case focusGetCurrent (formFocus form) of
  Just ToAccountField -> Just SelectToAccount
  Just FromAccountField -> Just SelectFromAccount
  _ -> Nothing

incomeAccountText :: AccountSelectionTarget -> ActualAddInput -> Text
incomeAccountText target input = case target of
  SelectToAccount -> addToAccountText input
  SelectFromAccount -> addFromAccountText input

incomeCandidates
  :: AppContext
  -> AccountSelectionTarget
  -> [HKernel.Account.Account]
incomeCandidates context target =
  flattenCandidateGroups context
    (incomeAccountCandidates registry transactions target)
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)
    transactions = contextActualTransactions context

incomeFieldName :: AccountSelectionTarget -> Name
incomeFieldName target = case target of
  SelectToAccount -> ToAccountField
  SelectFromAccount -> FromAccountField

incomeNextField :: AccountSelectionTarget -> Name
incomeNextField target = case target of
  SelectToAccount -> FromAccountField
  SelectFromAccount -> AmountField

drawIncomeInput :: AppContext -> Form ActualAddInput AppEvent Name -> Widget Name
drawIncomeInput context form =
  center
    (borderWithLabel (str "Income")
      (padAll 1
        (vBox
          [ txt ("Entry day: " <> T.pack (show (contextEntryDay context)))
          , strWrap "The entry day is already fixed by the current TUI context."
          , strWrap "Amount accepts a quantity only when Account defaults determine the commodity."
          , strWrap "Account fields expose existing typed Accounts inline; exact text remains available."
          , str " "
          , renderForm form
          , renderIncomeInlineAccountSelector context form
          , str " "
          , incomeInputControls form
          ])))

renderIncomeInlineAccountSelector
  :: AppContext
  -> Form ActualAddInput AppEvent Name
  -> Widget Name
renderIncomeInlineAccountSelector context form = case incomeSelectionTarget form of
  Nothing -> emptyWidget
  Just target ->
    renderInlineAccountSelector context label selectedCursor candidates
    where
      input = formState form
      current = incomeAccountText target input
      candidates = incomeCandidates context target
      selectedCursor = findIndex
        ((== T.strip current) . HKernel.Account.accountName) candidates
      label = case target of
        SelectToAccount -> "Receiving Accounts"
        SelectFromAccount -> "Income Accounts"

incomeInputControls :: Form ActualAddInput AppEvent Name -> Widget Name
incomeInputControls form = case incomeSelectionTarget form of
  Just _ -> strWrap "[Up/Down] Choose Account | [click] Select | [Enter] Accept | [Tab] Next field | text edits exact Account | [Esc] Actual"
  Nothing -> strWrap "[Tab] Next field | [Enter] Preview | [Esc] Actual"

handleIncomeInput
  :: AppContext
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleIncomeInput context form event = case event of
  MouseDown (AccountCandidate index) V.BLeft _ _
    | Just target <- incomeSelectionTarget form ->
        selectIncomeCandidateAt context target index form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
  VtyEvent (V.EvKey V.KUp [])
    | Just target <- incomeSelectionTarget form ->
        moveIncomeCandidate context (-1) target form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KDown [])
    | Just target <- incomeSelectionTarget form ->
        moveIncomeCandidate context 1 target form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter [])
    | Just target <- incomeSelectionTarget form ->
        acceptIncomeAccount target form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter []) -> do
    let input = formState form
        resolvedJournal = actualJournalValue
          (householdStateActualJournal (contextHouseholdState context))
        preview = prepareActualAddPreviewFromResolvedJournal
          resolvedJournal (contextSource context) input
    put (IncomePreview preview form)
    pure FlowMaintain
  _ -> zoom zoomIncomeForm (handleFormEvent event) >> pure FlowMaintain

moveIncomeCandidate
  :: AppContext
  -> Int
  -> AccountSelectionTarget
  -> Form ActualAddInput AppEvent Name
  -> EventM Name (State AppEvent) ()
moveIncomeCandidate context offset target form =
  case stepAccountCandidate offset current candidates of
    Nothing -> pure ()
    Just account ->
      let updatedInput = selectActualAddAccount target account input
          updatedForm = setFormFocus (incomeFieldName target)
            (updateFormState updatedInput form)
      in put (IncomeInput updatedForm)
  where
    input = formState form
    current = incomeAccountText target input
    candidates = incomeCandidates context target

selectIncomeCandidateAt
  :: AppContext
  -> AccountSelectionTarget
  -> Int
  -> Form ActualAddInput AppEvent Name
  -> EventM Name (State AppEvent) ()
selectIncomeCandidateAt context target index form =
  case accountCandidateAt index (incomeCandidates context target) of
    Nothing -> pure ()
    Just account ->
      let updatedInput = selectActualAddAccount target account (formState form)
          updatedForm = setFormFocus (incomeNextField target)
            (updateFormState updatedInput form)
      in put (IncomeInput updatedForm)

acceptIncomeAccount
  :: AccountSelectionTarget
  -> Form ActualAddInput AppEvent Name
  -> EventM Name (State AppEvent) ()
acceptIncomeAccount target form
  | T.null (T.strip (incomeAccountText target (formState form))) = pure ()
  | otherwise = put (IncomeInput (setFormFocus (incomeNextField target) form))

handleIncomePreview
  :: AppContext
  -> ActualAddPreview
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleIncomePreview context preview form event = case event of
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
    back = put (IncomeInput form) >> pure FlowMaintain
    publish = case preview of
      ActualAddCandidateReady block ->
        pure (FlowPublish (contextEntryDay context) block)
      _ -> pure FlowMaintain

renderIncomePreview :: ActualAddPreview -> Widget Name
renderIncomePreview preview = case preview of
  ActualAddInputRejected inputError ->
    withAttr (attrName "error")
      (txtWrap ("Input rejected: " <> T.pack (show inputError)))
  ActualAddCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txtWrap (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualAddCandidateReady block ->
    withAttr (attrName "success")
      (strWrap "Validation successful. Source unmodified.")
      <=> str " " <=> txtWrap block

incomePreviewControls :: ActualAddPreview -> String
incomePreviewControls preview = case preview of
  ActualAddCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"

-- Shared ---------------------------------------------------------------------

drawFlow :: AppContext -> State AppEvent -> Widget Name
drawFlow context state = case state of
  ExpenseInput form -> drawExpenseInput context form
  ExpensePreview preview _ ->
    center
      (borderWithLabel (str "Expense Preview")
        (hLimit 86
          (padAll 1
            (renderExpensePreview preview <=> str " "
              <=> strWrap (expensePreviewControls preview)))))
  IncomeInput form -> drawIncomeInput context form
  IncomePreview preview _ ->
    center
      (borderWithLabel (str "Income Preview")
        (padAll 1
          (renderIncomePreview preview <=> str " "
            <=> strWrap (incomePreviewControls preview))))

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleFlowEvent context event = do
  state <- get
  case state of
    ExpenseInput form -> handleExpenseInput context form event
    ExpensePreview preview form -> handleExpensePreview context preview form event
    IncomeInput form -> handleIncomeInput context form event
    IncomePreview preview form -> handleIncomePreview context preview form event
