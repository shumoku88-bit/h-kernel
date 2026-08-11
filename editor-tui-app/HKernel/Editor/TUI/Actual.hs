{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module HKernel.Editor.TUI.Actual
  ( PublishResult(..)
  , State(..)
  , applyWorkspaceAccountFilter
  , drawFlow
  , drawWorkspace
  , handleFlowEvent
  , publishCandidate
  , startDaily
  , startIncome
  , startMulti
  , startSelectedReverse
  , toggleWorkspaceFocus
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
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import qualified Data.Vector as Vec
import Text.Read (readMaybe)

import qualified HKernel.Account
import HKernel.Actual.Journal
  ( ActualTransactionEntry
  , actualJournalReversalDeclarations
  , actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntryIdentity
  , actualTransactionEntryTransaction
  , reversedTransactionId
  , reversalTransactionId
  )
import HKernel.Editor.ActualAppend
  ( ActualAddInput(..)
  , ActualAddPreview(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , ActualPostingInput(..)
  , ActualMultiAddInput(..)
  , ActualMultiAddPreview(..)
  , classifyActualAddWriteResult
  , prepareActualAddPreviewFromResolvedJournal
  , prepareActualMultiAddPreviewFromResolvedJournal
  )
import HKernel.Editor.ActualReverse
  ( ActualReverseInput(..)
  , ActualReverseInputPreview(..)
  , prepareActualReverseInputFromResolvedJournal
  , suggestActualReverseEventIdText
  )
import HKernel.Editor.ActualWorkspace (transactionEntriesForAccount)
import HKernel.Editor.ActualWriter (publishActualBlockWithPathAdmission)
import HKernel.Editor.Interaction.ActualAdd
  ( AccountSelectionTarget(..)
  , ActualMultiAddState(..)
  , dailyAccountCandidates
  , groupAccountCandidates
  , incomeAccountCandidates
  , initialActualAddInputForDay
  , initialActualMultiAddStateForDay
  , multiAccountCandidates
  , resizeActualMultiPostings
  , selectActualAddAccount
  , selectActualMultiPosting
  , selectedActualMultiPosting
  , setActualMultiDateText
  , setActualMultiDescription
  , setSelectedActualMultiAccountText
  , setSelectedActualMultiAmount
  , stepAccountCandidate
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , WorkspaceFocus(..)
  , contextHouseholdState
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

data MultiEditInput = MultiEditInput
  { multiEditDateText         :: Text
  , multiEditDescriptionText  :: Text
  , multiEditPostingCountText :: Text
  , multiEditAccountText      :: Text
  , multiEditAmountText       :: Text
  } deriving (Eq, Show)

data DailyEntryKind
  = DailyExpense
  | DailyIncome
  deriving (Eq, Show)

data State event
  = DailyInput DailyEntryKind (Form ActualAddInput event Name)
  | DailyPreview DailyEntryKind ActualAddPreview (Form ActualAddInput event Name)
  | MultiInput ActualMultiAddState (Form MultiEditInput event Name)
  | MultiPreview ActualMultiAddPreview ActualMultiAddState (Form MultiEditInput event Name)
  | ReverseInput ActualTransactionId Transaction (Form ActualReverseInput event Name)
  | ReversePreview ActualTransactionId Transaction ActualReverseInputPreview (Form ActualReverseInput event Name)
  | ReverseUnavailable Text
  | WriteOutcome ActualAddWriteOutcome
  | ReturnToWorkspace
  | PublishRequested Day Text
  | QuitRequested

data PublishResult
  = Published AppContext
  | PublicationFailed ActualAddWriteOutcome
  | ReloadFailed

startDaily :: Day -> State event
startDaily = startDailyEntry DailyExpense

startIncome :: Day -> State event
startIncome = startDailyEntry DailyIncome

startDailyEntry :: DailyEntryKind -> Day -> State event
startDailyEntry kind day = DailyInput kind (mkDailyForm kind day)

startMulti :: Day -> State event
startMulti day =
  let state = initialActualMultiAddStateForDay day
  in MultiInput state (mkMultiForm state)

startSelectedReverse :: AppContext -> State event
startSelectedReverse context = case selectedWorkspaceReverseTarget context of
  Left message -> ReverseUnavailable message
  Right (targetId, transaction) ->
    let existingIds =
          [ identity
          | entry <- actualJournalTransactionEntries
              (householdStateActualJournal (contextHouseholdState context))
          , Just identity <- [actualTransactionEntryIdentity entry]
          ]
        eventIdText = suggestActualReverseEventIdText existingIds targetId
    in ReverseInput targetId transaction
        (mkReverseForm (contextObservationDay context) eventIdText transaction)

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

multiEditDateTextL :: Lens' MultiEditInput Text
multiEditDateTextL f input =
  (\value -> input { multiEditDateText = value }) <$> f (multiEditDateText input)

multiEditDescriptionTextL :: Lens' MultiEditInput Text
multiEditDescriptionTextL f input =
  (\value -> input { multiEditDescriptionText = value })
    <$> f (multiEditDescriptionText input)

multiEditPostingCountTextL :: Lens' MultiEditInput Text
multiEditPostingCountTextL f input =
  (\value -> input { multiEditPostingCountText = value })
    <$> f (multiEditPostingCountText input)

multiEditAccountTextL :: Lens' MultiEditInput Text
multiEditAccountTextL f input =
  (\value -> input { multiEditAccountText = value })
    <$> f (multiEditAccountText input)

multiEditAmountTextL :: Lens' MultiEditInput Text
multiEditAmountTextL f input =
  (\value -> input { multiEditAmountText = value })
    <$> f (multiEditAmountText input)

reverseInputDateTextL :: Lens' ActualReverseInput Text
reverseInputDateTextL f input =
  (\value -> input { reverseInputDateText = value })
    <$> f (reverseInputDateText input)

reverseInputDescriptionTextL :: Lens' ActualReverseInput Text
reverseInputDescriptionTextL f input =
  (\value -> input { reverseInputDescriptionText = value })
    <$> f (reverseInputDescriptionText input)

mkForm :: DailyEntryKind -> ActualAddInput -> Form ActualAddInput event Name
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

mkDailyForm :: DailyEntryKind -> Day -> Form ActualAddInput event Name
mkDailyForm kind day =
  setFormFocus AmountField
    (mkForm kind (initialActualAddInputForDay day))

multiEditInputFor :: ActualMultiAddState -> MultiEditInput
multiEditInputFor state = MultiEditInput
  { multiEditDateText = multiAddDateText input
  , multiEditDescriptionText = multiAddDescriptionText input
  , multiEditPostingCountText = T.pack (show (NonEmpty.length (multiAddPostings input)))
  , multiEditAccountText = multiPostingAccountText selected
  , multiEditAmountText = multiPostingAmountText selected
  }
  where
    input = actualMultiAddInput state
    selected = selectedActualMultiPosting state

mkMultiForm :: ActualMultiAddState -> Form MultiEditInput event Name
mkMultiForm state =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)
      form = newForm
        [ label "Date:"
            @@= editTextField multiEditDateTextL MultiDateField (Just 1)
        , label "Description:"
            @@= editTextField multiEditDescriptionTextL MultiDescriptionField (Just 1)
        , label "Posting count:"
            @@= editTextField multiEditPostingCountTextL MultiPostingCountField (Just 1)
        , label "Selected account:"
            @@= editTextField multiEditAccountTextL MultiAccountField (Just 1)
        , label "Selected amount:"
            @@= editTextField multiEditAmountTextL MultiAmountField (Just 1)
        ]
  in setFormFocus MultiDescriptionField (form (multiEditInputFor state))

commitMultiForm
  :: ActualMultiAddState
  -> Form MultiEditInput event Name
  -> ActualMultiAddState
commitMultiForm state form =
  let editInput = formState form
      currentInput = actualMultiAddInput state
      currentCount = NonEmpty.length (multiAddPostings currentInput)
      requestedCount = fromMaybe currentCount
        (readMaybe (T.unpack (T.strip (multiEditPostingCountText editInput))))
      resized = resizeActualMultiPostings requestedCount state
      withDate = setActualMultiDateText (multiEditDateText editInput) resized
      withDescription = setActualMultiDescription
        (multiEditDescriptionText editInput) withDate
      withAccount = setSelectedActualMultiAccountText
        (multiEditAccountText editInput) withDescription
  in setSelectedActualMultiAmount (multiEditAmountText editInput) withAccount

syncMultiForm
  :: ActualMultiAddState
  -> Form MultiEditInput event Name
  -> Form MultiEditInput event Name
syncMultiForm state = updateFormState (multiEditInputFor state)

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

zoomDailyForm :: Traversal' (State AppEvent) (Form ActualAddInput AppEvent Name)
zoomDailyForm f (DailyInput kind form) = DailyInput kind <$> f form
zoomDailyForm _ state = pure state

zoomMultiForm :: Traversal' (State AppEvent) (Form MultiEditInput AppEvent Name)
zoomMultiForm f (MultiInput state form) = MultiInput state <$> f form
zoomMultiForm _ state = pure state

zoomReverseForm :: Traversal' (State AppEvent) (Form ActualReverseInput AppEvent Name)
zoomReverseForm f (ReverseInput target transaction form) =
  ReverseInput target transaction <$> f form
zoomReverseForm _ state = pure state

drawFlow :: AppContext -> State AppEvent -> Widget Name
drawFlow context state = case state of
  DailyInput kind form ->
    center
      (borderWithLabel (str (dailyEntryTitle kind))
        (padAll 1
          (vBox
            [ txt ("Date: " <> dateSummary context (addDateText (formState form)))
            , str "Amount accepts a quantity only when Account defaults determine the commodity."
            , str "Account fields expose existing typed Accounts inline; exact text remains available."
            , str " "
            , renderForm form
            , renderDailyInlineAccountSelector context kind form
            , str " "
            , dailyInputControls form
            ])))
  DailyPreview kind preview _ ->
    center
      (borderWithLabel (str (dailyPreviewTitle kind))
        (padAll 1 (renderPreview preview <=> str " " <=> str (previewControls preview))))
  MultiInput multiState form ->
    center
      (borderWithLabel (str "Multi-posting Actual")
        (hLimit 86
          (padAll 1
            (vBox
              [ txt ("Date: " <> dateSummary context
                  (multiAddDateText (actualMultiAddInput multiState)))
              , str "Each posting owns its sign. The complete transaction must balance to zero."
              , str " "
              , renderMultiPostingRows multiState
              , str " "
              , txt ("Editing posting "
                  <> T.pack (show (actualMultiSelectedPosting multiState + 1))
                  <> " of "
                  <> T.pack (show (NonEmpty.length
                    (multiAddPostings (actualMultiAddInput multiState)))))
              , renderForm form
              , renderMultiInlineAccountSelector context form
              , str " "
              , multiInputControls form
              ]))))
  MultiPreview preview _ _ ->
    center
      (borderWithLabel (str "Multi-posting Preview")
        (hLimit 86
          (padAll 1
            (renderMultiPreview preview <=> str " " <=> str (multiPreviewControls preview)))))
  ReverseInput targetId transaction form ->
    center
      (borderWithLabel (str "Reverse Actual")
        (hLimit 86
          (padAll 1
            (vBox
              [ renderReverseTarget targetId transaction
              , str " "
              , str "The original transaction stays immutable; Reverse appends its exact inverse."
              , str "Reversal identity is generated automatically."
              , str " "
              , renderForm form
              , str " "
              , str "[Tab] Next field | [Esc] Actual | [Enter] Preview"
              ]))))
  ReversePreview targetId transaction preview _ ->
    center
      (borderWithLabel (str "Reverse Preview")
        (hLimit 86
          (padAll 1
            ( renderReverseTarget targetId transaction
              <=> str " "
              <=> renderReversePreview preview
              <=> str " "
              <=> str (reversePreviewControls preview)))))
  ReverseUnavailable message ->
    center
      (borderWithLabel (str "Reverse unavailable")
        (hLimit 80
          (padAll 1
            ( withAttr (attrName "warning") (txt message)
              <=> str " "
              <=> str "[Enter/Esc] Back to Actual | [Q] Quit"))))
  WriteOutcome outcome ->
    center
      (borderWithLabel (str "Actual Write Result")
        (padAll 1 (renderWriteOutcome outcome <=> str " " <=> str "[Esc] Actual | [Q] Quit")))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ _ -> emptyWidget
  QuitRequested -> emptyWidget

dailyEntryTitle :: DailyEntryKind -> String
dailyEntryTitle kind = case kind of
  DailyExpense -> "Daily Expense"
  DailyIncome -> "Daily Income"

dailyPreviewTitle :: DailyEntryKind -> String
dailyPreviewTitle kind = case kind of
  DailyExpense -> "Expense Preview"
  DailyIncome -> "Income Preview"

dailyInputControls :: Form ActualAddInput AppEvent Name -> Widget Name
dailyInputControls form = case dailySelectionTarget form of
  Just _ -> str "[Up/Down] Choose Account | [Enter] Accept | [Tab] Next field | text edits exact Account | [Esc] Actual"
  Nothing -> str "[Tab] Next field | [Enter] Preview | [Esc] Actual"

multiInputControls :: Form MultiEditInput AppEvent Name -> Widget Name
multiInputControls form
  | multiAccountFocused form =
      str "[Up/Down] Choose Account | [Enter] Accept | [Tab] Next field | text edits exact Account | [Esc] Actual"
  | otherwise =
      str "[Tab] Next field | [Up/Down] Previous/next posting row | [Enter] Preview | [Esc] Actual"

renderDailyInlineAccountSelector
  :: AppContext
  -> DailyEntryKind
  -> Form ActualAddInput AppEvent Name
  -> Widget Name
renderDailyInlineAccountSelector context kind form = case dailySelectionTarget form of
  Nothing -> emptyWidget
  Just target ->
    renderInlineAccountSelector context label current candidates
    where
      input = formState form
      current = dailyAccountText target input
      candidates = dailyCandidates context kind target
      label = case (kind, target) of
        (DailyExpense, SelectToAccount) -> "Expense Accounts"
        (DailyExpense, SelectFromAccount) -> "Payment Accounts"
        (DailyIncome, SelectToAccount) -> "Receiving Accounts"
        (DailyIncome, SelectFromAccount) -> "Income Accounts"

renderMultiInlineAccountSelector
  :: AppContext
  -> Form MultiEditInput AppEvent Name
  -> Widget Name
renderMultiInlineAccountSelector context form
  | multiAccountFocused form =
      renderInlineAccountSelector context "Posting Accounts"
        (multiEditAccountText (formState form)) (multiCandidates context)
  | otherwise = emptyWidget

renderInlineAccountSelector
  :: AppContext
  -> String
  -> Text
  -> [HKernel.Account.Account]
  -> Widget Name
renderInlineAccountSelector context label current candidates =
  borderWithLabel (str label)
    (hLimit 82
      (padAll 1
        (vBox
          ( map renderCandidate visible
            ++ [ str " "
               , str "Existing Accounts are grouped by typed meaning; recent use ranks within each group."
               ]
          ))))
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)
    visible = candidateWindow 9 current candidates
    normalizedCurrent = T.strip current
    renderCandidate account =
      let selected = HKernel.Account.accountName account == normalizedCurrent
          accountType = HKernel.Account.accountTypeFor account registry
          row = txt
            (accountTypeLabel accountType <> "  " <> HKernel.Account.accountName account)
      in if selected then withAttr L.listSelectedAttr row else row

accountTypeLabel :: Maybe HKernel.Account.AccountType -> Text
accountTypeLabel maybeType = case maybeType of
  Just HKernel.Account.Asset -> "Assets     "
  Just HKernel.Account.Liability -> "Liabilities"
  Just HKernel.Account.Equity -> "Equity     "
  Just HKernel.Account.Income -> "Income     "
  Just HKernel.Account.Expense -> "Expenses   "
  Just HKernel.Account.Budget -> "Budget     "
  Nothing -> "Unknown    "

candidateWindow
  :: Int
  -> Text
  -> [HKernel.Account.Account]
  -> [HKernel.Account.Account]
candidateWindow limit current candidates =
  take limit (drop start candidates)
  where
    selectedIndex = fromMaybe 0
      (findIndex ((== T.strip current) . HKernel.Account.accountName) candidates)
    maximumStart = max 0 (length candidates - limit)
    centeredStart = max 0 (selectedIndex - limit `div` 2)
    start = min maximumStart centeredStart

dailySelectionTarget
  :: Form ActualAddInput event Name
  -> Maybe AccountSelectionTarget
dailySelectionTarget form = case focusGetCurrent (formFocus form) of
  Just ToAccountField -> Just SelectToAccount
  Just FromAccountField -> Just SelectFromAccount
  _ -> Nothing

multiAccountFocused :: Form MultiEditInput event Name -> Bool
multiAccountFocused form =
  focusGetCurrent (formFocus form) == Just MultiAccountField

dailyAccountText :: AccountSelectionTarget -> ActualAddInput -> Text
dailyAccountText target input = case target of
  SelectToAccount -> addToAccountText input
  SelectFromAccount -> addFromAccountText input

dailyCandidates
  :: AppContext
  -> DailyEntryKind
  -> AccountSelectionTarget
  -> [HKernel.Account.Account]
dailyCandidates context kind target =
  flattenCandidateGroups context (candidates registry transactions target)
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)
    transactions = contextActualTransactions context
    candidates = case kind of
      DailyExpense -> dailyAccountCandidates
      DailyIncome -> incomeAccountCandidates

multiCandidates :: AppContext -> [HKernel.Account.Account]
multiCandidates context =
  flattenCandidateGroups context
    (multiAccountCandidates registry (contextActualTransactions context))
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)

flattenCandidateGroups
  :: AppContext
  -> [HKernel.Account.Account]
  -> [HKernel.Account.Account]
flattenCandidateGroups context candidates =
  concatMap snd (groupAccountCandidates registry candidates)
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)

contextActualTransactions :: AppContext -> [Transaction]
contextActualTransactions context =
  map actualTransactionEntryTransaction
    (actualJournalTransactionEntries
      (householdStateActualJournal (contextHouseholdState context)))

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ hBox
        [ hLimit 30
            (borderWithLabel (workspacePaneLabel context AccountsFocus "Accounts")
              (vLimit 16
                (L.renderList renderWorkspaceAccount
                  (contextWorkspaceFocus context == AccountsFocus)
                  (contextWorkspaceAccounts context))))
        , padLeft (Pad 1)
            (padRight Max
              (borderWithLabel (workspacePaneLabel context TransactionsFocus "Transactions")
                (vLimit 16
                  (L.renderList renderWorkspaceTransaction
                    (contextWorkspaceFocus context == TransactionsFocus)
                    (contextWorkspaceList context)))))
        ]
    , borderWithLabel (str "Selected transaction")
        (padAll 1 (renderWorkspaceSelection context))
    , txt ("Filter: " <> workspaceFilterText context)
    , str "[1-7] Sections   [Tab/Left/Right] Focus   [j/k/Arrows] Move   [Enter] Reverse selected   [a] Expense   [i] Income   [m] Multi Actual   [q] Quit"
    ]

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleFlowEvent context event = do
  state <- get
  case state of
    DailyInput kind form -> handleDailyInput context kind form event
    DailyPreview kind preview form -> handleDailyPreview context kind preview form event
    MultiInput multiState form -> handleMultiInput context multiState form event
    MultiPreview preview multiState form -> handleMultiPreview context preview multiState form event
    ReverseInput targetId transaction form ->
      handleReverseInput context targetId transaction form event
    ReversePreview targetId transaction preview form ->
      handleReversePreview context targetId transaction preview form event
    ReverseUnavailable _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey V.KEnter []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      _ -> pure ()
    WriteOutcome _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      _ -> pure ()
    ReturnToWorkspace -> pure ()
    PublishRequested _ _ -> pure ()
    QuitRequested -> pure ()

handleDailyInput
  :: AppContext
  -> DailyEntryKind
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleDailyInput context kind form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KUp [])
    | Just target <- dailySelectionTarget form ->
        moveDailyAccountCandidate context kind (-1) target form
  VtyEvent (V.EvKey V.KDown [])
    | Just target <- dailySelectionTarget form ->
        moveDailyAccountCandidate context kind 1 target form
  VtyEvent (V.EvKey V.KEnter [])
    | Just target <- dailySelectionTarget form ->
        acceptDailyAccount kind target form
  VtyEvent (V.EvKey V.KEnter []) -> do
    let input = formState form
        resolvedJournal = actualJournalValue
          (householdStateActualJournal (contextHouseholdState context))
        preview = prepareActualAddPreviewFromResolvedJournal
          resolvedJournal (contextSource context) input
    put (DailyPreview kind preview form)
  _ -> zoom zoomDailyForm (handleFormEvent event)

moveDailyAccountCandidate
  :: AppContext
  -> DailyEntryKind
  -> Int
  -> AccountSelectionTarget
  -> Form ActualAddInput AppEvent Name
  -> EventM Name (State AppEvent) ()
moveDailyAccountCandidate context kind offset target form =
  case stepAccountCandidate offset current candidates of
    Nothing -> pure ()
    Just account ->
      let updatedInput = selectActualAddAccount target account input
          updatedForm = setFormFocus (dailyFieldName target)
            (updateFormState updatedInput form)
      in put (DailyInput kind updatedForm)
  where
    input = formState form
    current = dailyAccountText target input
    candidates = dailyCandidates context kind target

acceptDailyAccount
  :: DailyEntryKind
  -> AccountSelectionTarget
  -> Form ActualAddInput AppEvent Name
  -> EventM Name (State AppEvent) ()
acceptDailyAccount kind target form
  | T.null (T.strip (dailyAccountText target (formState form))) = pure ()
  | otherwise = put (DailyInput kind (setFormFocus nextField form))
  where
    nextField = case target of
      SelectToAccount -> FromAccountField
      SelectFromAccount -> DateField

dailyFieldName :: AccountSelectionTarget -> Name
dailyFieldName target = case target of
  SelectToAccount -> ToAccountField
  SelectFromAccount -> FromAccountField

handleDailyPreview
  :: AppContext
  -> DailyEntryKind
  -> ActualAddPreview
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleDailyPreview context kind preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'b') []) -> back
  VtyEvent (V.EvKey (V.KChar 'B') []) -> back
  VtyEvent (V.EvKey V.KEnter []) -> publish
  VtyEvent (V.EvKey (V.KChar 'y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'c') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'C') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
  _ -> pure ()
  where
    back = put (DailyInput kind form)
    publish = case preview of
      ActualAddCandidateReady block ->
        let stickyDay = fromMaybe (contextEntryDay context)
              (readMaybe (T.unpack (addDateText (formState form))))
        in put (PublishRequested stickyDay block)
      _ -> pure ()

handleMultiInput
  :: AppContext
  -> ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleMultiInput context state form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KUp [])
    | multiAccountFocused form -> moveMultiAccountCandidate context (-1) state form
  VtyEvent (V.EvKey V.KDown [])
    | multiAccountFocused form -> moveMultiAccountCandidate context 1 state form
  VtyEvent (V.EvKey V.KEnter [])
    | multiAccountFocused form -> acceptMultiAccount state form
  VtyEvent (V.EvKey V.KEnter []) -> prepareMultiPreview context state form
  VtyEvent (V.EvKey V.KUp []) -> moveMultiSelection (-1) state form
  VtyEvent (V.EvKey V.KDown []) -> moveMultiSelection 1 state form
  _ -> zoom zoomMultiForm (handleFormEvent event)

moveMultiAccountCandidate
  :: AppContext
  -> Int
  -> ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> EventM Name (State AppEvent) ()
moveMultiAccountCandidate context offset state form =
  case stepAccountCandidate offset current candidates of
    Nothing -> pure ()
    Just account ->
      let updatedEdit = editInput
            { multiEditAccountText = HKernel.Account.accountName account }
          updatedForm = setFormFocus MultiAccountField
            (updateFormState updatedEdit form)
      in put (MultiInput state updatedForm)
  where
    editInput = formState form
    current = multiEditAccountText editInput
    candidates = multiCandidates context

acceptMultiAccount
  :: ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> EventM Name (State AppEvent) ()
acceptMultiAccount state form
  | T.null (T.strip (multiEditAccountText (formState form))) = pure ()
  | otherwise = put (MultiInput state (setFormFocus MultiAmountField form))

moveMultiSelection
  :: Int
  -> ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> EventM Name (State AppEvent) ()
moveMultiSelection offset state form =
  let committed = commitMultiForm state form
      selected = actualMultiSelectedPosting committed + offset
      moved = selectActualMultiPosting selected committed
  in put (MultiInput moved (syncMultiForm moved form))

prepareMultiPreview
  :: AppContext
  -> ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> EventM Name (State AppEvent) ()
prepareMultiPreview context state form = do
  let committed = commitMultiForm state form
      resolvedJournal = actualJournalValue
        (householdStateActualJournal (contextHouseholdState context))
      preview = prepareActualMultiAddPreviewFromResolvedJournal
        resolvedJournal (contextSource context) (actualMultiAddInput committed)
  put (MultiPreview preview committed (syncMultiForm committed form))

handleMultiPreview
  :: AppContext
  -> ActualMultiAddPreview
  -> ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleMultiPreview context preview state form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'b') []) -> back
  VtyEvent (V.EvKey (V.KChar 'B') []) -> back
  VtyEvent (V.EvKey V.KEnter []) -> publish
  VtyEvent (V.EvKey (V.KChar 'y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'c') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'C') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
  _ -> pure ()
  where
    back = put (MultiInput state form)
    publish = case preview of
      ActualMultiAddCandidateReady block ->
        let stickyDay = fromMaybe (contextEntryDay context)
              (readMaybe (T.unpack (multiAddDateText (actualMultiAddInput state))))
        in put (PublishRequested stickyDay block)
      _ -> pure ()

handleReverseInput
  :: AppContext
  -> ActualTransactionId
  -> Transaction
  -> Form ActualReverseInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleReverseInput context targetId transaction form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) -> do
    let resolvedJournal = actualJournalValue
          (householdStateActualJournal (contextHouseholdState context))
        preview = prepareActualReverseInputFromResolvedJournal
          resolvedJournal (contextSource context) targetId (formState form)
    put (ReversePreview targetId transaction preview form)
  _ -> zoom zoomReverseForm (handleFormEvent event)

handleReversePreview
  :: AppContext
  -> ActualTransactionId
  -> Transaction
  -> ActualReverseInputPreview
  -> Form ActualReverseInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleReversePreview context targetId transaction preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'b') []) -> back
  VtyEvent (V.EvKey (V.KChar 'B') []) -> back
  VtyEvent (V.EvKey V.KEnter []) -> publish
  VtyEvent (V.EvKey (V.KChar 'y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
  _ -> pure ()
  where
    back = put (ReverseInput targetId transaction form)
    publish = case preview of
      ActualReverseCandidateReady block ->
        put (PublishRequested (contextEntryDay context) block)
      _ -> pure ()

publishCandidate :: AppContext -> Day -> Text -> IO PublishResult
publishCandidate context stickyDay block = do
  let state = contextHouseholdState context
      root = householdStateRoot state
      stickyContext = context { contextEntryDay = stickyDay }
      postAdmission _ = loadCanonicalHousehold root
  writeResult <- publishActualBlockWithPathAdmission
    postAdmission
    (contextSourcePath context)
    (contextSource context)
    block
  let writeOutcome = classifyActualAddWriteResult writeResult
  case writeOutcome of
    ActualAddWriteSucceeded -> do
      reloadedContext <- reloadWorkspaceContext stickyContext
      pure (maybe ReloadFailed Published reloadedContext)
    _ -> pure (PublicationFailed writeOutcome)

toggleWorkspaceFocus :: AppContext -> AppContext
toggleWorkspaceFocus context = context
  { contextWorkspaceFocus = case contextWorkspaceFocus context of
      AccountsFocus -> TransactionsFocus
      TransactionsFocus -> AccountsFocus
  }

applyWorkspaceAccountFilter :: AppContext -> AppContext
applyWorkspaceAccountFilter context = context
  { contextWorkspaceList =
      L.list WorkspaceTransactionList (Vec.fromList filteredTransactions) 1
  }
  where
    filteredTransactions =
      map actualTransactionEntryTransaction (filteredWorkspaceEntries context)

workspacePaneLabel :: AppContext -> WorkspaceFocus -> String -> Widget Name
workspacePaneLabel context pane labelText
  | contextWorkspaceFocus context == pane = str (labelText <> " *")
  | otherwise = str labelText

renderWorkspaceAccount :: Bool -> Maybe HKernel.Account.Account -> Widget Name
renderWorkspaceAccount selected maybeAccount
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = case maybeAccount of
      Nothing -> str "All accounts"
      Just account -> txt (HKernel.Account.accountName account)

workspaceFilterText :: AppContext -> Text
workspaceFilterText context = case selectedWorkspaceAccount context of
  Nothing -> "All accounts"
  Just account -> HKernel.Account.accountName account

selectedWorkspaceAccount :: AppContext -> Maybe HKernel.Account.Account
selectedWorkspaceAccount context = case L.listSelectedElement (contextWorkspaceAccounts context) of
  Nothing -> Nothing
  Just (_, maybeAccount) -> maybeAccount

filteredWorkspaceEntries :: AppContext -> [ActualTransactionEntry]
filteredWorkspaceEntries context =
  transactionEntriesForAccount
    (selectedWorkspaceAccount context)
    (actualJournalTransactionEntries
      (householdStateActualJournal (contextHouseholdState context)))

selectedWorkspaceEntry :: AppContext -> Maybe ActualTransactionEntry
selectedWorkspaceEntry context = do
  (selectedIndex, _) <- L.listSelectedElement (contextWorkspaceList context)
  listToMaybe (drop selectedIndex (filteredWorkspaceEntries context))

selectedWorkspaceReverseTarget
  :: AppContext
  -> Either Text (ActualTransactionId, Transaction)
selectedWorkspaceReverseTarget context = case selectedWorkspaceEntry context of
  Nothing -> Left "No Actual transaction is selected."
  Just entry -> case actualTransactionEntryIdentity entry of
    Nothing -> Left
      "Reverse unavailable: this transaction has no durable Actual identity."
    Just targetId -> case directReversalFor context targetId of
      Nothing -> Right (targetId, actualTransactionEntryTransaction entry)
      Just reversalId -> Left
        ("Already reversed by " <> actualTransactionIdText reversalId
          <> ". Select that reversal if you need to restore the original effect.")

directReversalFor :: AppContext -> ActualTransactionId -> Maybe ActualTransactionId
directReversalFor context targetId = listToMaybe
  [ reversalTransactionId declaration
  | declaration <- actualJournalReversalDeclarations
      (householdStateActualJournal (contextHouseholdState context))
  , reversedTransactionId declaration == targetId
  ]

renderWorkspaceTransaction :: Bool -> Transaction -> Widget Name
renderWorkspaceTransaction selected transaction
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = txt (T.pack (show (transactionDate transaction)) <> "  "
      <> transactionDescription transaction)

renderWorkspaceSelection :: AppContext -> Widget Name
renderWorkspaceSelection context = case selectedWorkspaceEntry context of
  Nothing -> str "No Actual transactions for this account."
  Just entry ->
    let transaction = actualTransactionEntryTransaction entry
    in vBox
      ( [ txt (T.pack (show (transactionDate transaction)) <> "  "
            <> transactionDescription transaction)
        ]
        ++ map renderPosting (NonEmpty.toList (transactionPostings transaction))
        ++ [str " ", renderReverseAvailability context entry]
      )

renderReverseAvailability :: AppContext -> ActualTransactionEntry -> Widget Name
renderReverseAvailability context entry = case actualTransactionEntryIdentity entry of
  Nothing -> withAttr (attrName "warning")
    (str "Reverse unavailable: no durable Actual identity.")
  Just targetId -> case directReversalFor context targetId of
    Just reversalId -> withAttr (attrName "warning")
      (txt ("Already reversed by " <> actualTransactionIdText reversalId
        <> ". Select that reversal to reverse it."))
    Nothing -> withAttr (attrName "success")
      (txt ("[Enter] Reverse  event-id: " <> actualTransactionIdText targetId))

renderPosting :: Posting -> Widget Name
renderPosting posting =
  txt ("  " <> HKernel.Account.accountName (postingAccount posting) <> "  "
    <> renderQuantity (amountQuantity amount) <> " "
    <> commodityCode (amountCommodity amount))
  where
    amount = postingAmount posting

dateSummary :: AppContext -> Text -> Text
dateSummary context value
  | value == T.pack (show today) = "Today  " <> value
  | otherwise = "Other  " <> value
  where
    today = contextObservationDay context

renderMultiPostingRows :: ActualMultiAddState -> Widget Name
renderMultiPostingRows state =
  vBox
    [ renderRow index posting
    | (index, posting) <- zip [0 ..]
        (NonEmpty.toList (multiAddPostings (actualMultiAddInput state)))
    ]
  where
    selected = actualMultiSelectedPosting state
    renderRow index posting =
      let accountText
            | T.null (multiPostingAccountText posting) = "(enter account)"
            | otherwise = multiPostingAccountText posting
          amountText
            | T.null (multiPostingAmountText posting) = "(amount)"
            | otherwise = multiPostingAmountText posting
          row = txt
            (T.pack (show (index + 1)) <> ".  " <> accountText <> "  " <> amountText)
      in if index == selected then withAttr L.listSelectedAttr row else row

renderPreview :: ActualAddPreview -> Widget Name
renderPreview preview = case preview of
  ActualAddInputRejected inputError ->
    withAttr (attrName "error") (txt ("Input rejected: " <> T.pack (show inputError)))
  ActualAddCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txt (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualAddCandidateReady block ->
    withAttr (attrName "success") (str "Validation successful. Source unmodified.")
      <=> str " " <=> txt block

previewControls :: ActualAddPreview -> String
previewControls preview = case preview of
  ActualAddCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"

renderMultiPreview :: ActualMultiAddPreview -> Widget Name
renderMultiPreview preview = case preview of
  ActualMultiAddInputRejected inputError ->
    withAttr (attrName "error") (txt ("Input rejected: " <> T.pack (show inputError)))
  ActualMultiAddCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txt (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualMultiAddCandidateReady block ->
    withAttr (attrName "success") (str "Validation successful. Source unmodified.")
      <=> str " " <=> txt block

multiPreviewControls :: ActualMultiAddPreview -> String
multiPreviewControls preview = case preview of
  ActualMultiAddCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"

renderReverseTarget :: ActualTransactionId -> Transaction -> Widget Name
renderReverseTarget targetId transaction =
  vBox
    ( txt (T.pack (show (transactionDate transaction))
        <> "  [" <> actualTransactionIdText targetId <> "]  "
        <> transactionDescription transaction)
      : map renderPosting (NonEmpty.toList (transactionPostings transaction))
    )

renderReversePreview :: ActualReverseInputPreview -> Widget Name
renderReversePreview preview = case preview of
  ActualReverseInputRejected inputError ->
    withAttr (attrName "error")
      (txt ("Input rejected: " <> T.pack (show inputError)))
  ActualReverseCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txt (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualReverseCandidateReady block ->
    withAttr (attrName "success")
      (str "Validation successful. Source unmodified.")
      <=> str " " <=> txt block

reversePreviewControls :: ActualReverseInputPreview -> String
reversePreviewControls preview = case preview of
  ActualReverseCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"

renderWriteOutcome :: ActualAddWriteOutcome -> Widget Name
renderWriteOutcome outcome = case outcome of
  ActualAddWriteSucceeded -> withAttr (attrName "success")
    (str "Published and post-admitted successfully.")
  ActualAddWriteStale -> withAttr (attrName "error")
    (vBox
      [ str "Source changed after preview. Nothing was written."
      , str "Return to Actual and preview the current source before retrying."
      ])
  ActualAddWriteRecovered failure -> withAttr (attrName "warning")
    (vBox [str "Publication failed, and the backup was restored.", txt (writeFailureText failure)])
  ActualAddWriteFileIOFailed -> withAttr (attrName "error")
    (vBox
      [ str "The writer could not complete because of a filesystem error."
      , str "No source-local error detail is retained in the TUI state."
      ])
  ActualAddWriteFailed failure -> withAttr (attrName "error")
    (vBox [str "Publication failed and automatic recovery did not complete.", txt (writeFailureText failure)])

writeFailureText :: ActualAddWriteFailure -> Text
writeFailureText failure = case failure of
  ActualAddPostAdmissionFailure -> "The published candidate failed complete-source admission."
  ActualAddPostPublishReadFailure -> "The published source could not be read for post-admission."
