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
  , startSelectedReverse
  , toggleWorkspaceFocus
  ) where

import Brick
import Brick.Focus (focusGetCurrent)
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import Control.Monad.IO.Class (liftIO)
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal')

import Data.List (findIndex)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import qualified Data.Vector as Vec
import System.IO.Error (isDoesNotExistError, tryIOError)
import Text.Read (readMaybe)

import qualified HKernel.Account
import HKernel.Actual.Journal
  ( ActualTransactionEntry
  , actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntryIdentity
  , actualTransactionEntryTransaction
  )
import HKernel.Application.Config (HouseholdRoot, HouseholdSourcePaths(..))
import HKernel.Editor.ActualAppend
  ( ActualAddInput(..)
  , ActualAddPreview(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , ActualMultiAddInput(..)
  , ActualMultiAddPreview(..)
  , ActualPostingInput(..)
  , buildActualMultiAddIntentWithRegistry
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
import HKernel.Editor.ActualWorkspace
  ( ActualReverseAvailability(..)
  , actualReverseAvailability
  , newestTransactionEntriesForAccount
  )
import HKernel.Editor.Interaction.ActualAdd
  ( AccountSelectionTarget(..)
  , accountCandidateAt
  , actualMultiPostingAt
  , commitMultiAccountCandidate
  , dailyAccountCandidates
  , filterMultiAccountCandidates
  , groupAccountCandidates
  , incomeAccountCandidates
  , initialActualAddInputForDay
  , initialActualMultiAddInputForDay
  , moveMultiAccountCandidateCursor
  , multiAccountCandidates
  , resetMultiAccountCandidateCursor
  , resizeActualMultiPostings
  , selectActualAddAccount
  , setActualMultiPostingAccountText
  , setActualMultiPostingAmount
  , stepAccountCandidate
  )
import HKernel.Editor.IssueRealize
  ( IssueRealizeIntent(..)
  , IssueRealizePreview(..)
  , IssueRealizeWriteIntent(..)
  , admitIssueRelationSource
  , prepareIssueRealize
  , publishIssueRealize
  )
import HKernel.Editor.SourcePublication (publishActualBlockWithPathAdmission)
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , WorkspaceFocus(..)
  , contextHouseholdState
  , contextIssuesSource
  , contextSource
  , contextSourcePath
  , contextWorkspaceAccountsL
  , contextWorkspaceListL
  , reloadWorkspaceContext
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , loadCanonicalHousehold
  )
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , householdIssueId
  , householdIssueText
  , issueIdText
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

data RecordPurpose
  = OrdinaryRecord
  | RealizeIssue HouseholdIssue
  deriving (Eq, Show)

-- | Brick-local interaction coordinates around the one authoritative Actual
-- draft. Row selection and unfinished posting-count text are delivery state.
-- RecordPurpose changes only the final household operation; the transaction
-- draft and posting editor remain shared.
data MultiFormState = MultiFormState
  { multiFormInput                  :: ActualMultiAddInput
  , multiFormSelectedPosting        :: Int
  , multiFormPostingCountText       :: Text
  , multiFormAccountCandidateCursor :: Maybe Int
  , multiFormPurpose                :: RecordPurpose
  , multiFormClosedDateText         :: Text
  , multiFormDecisionMemoText       :: Text
  } deriving (Eq, Show)

data RecordPreview
  = RecordActualPreview ActualMultiAddPreview
  | RecordIssueRealizeRejected Text
  | RecordIssueRealizeReady IssueRealizePreview IssueRealizeWriteIntent
  deriving (Eq, Show)

data PublishRequest
  = PublishActual Day Text
  | PublishIssueRealize Day IssueRealizeWriteIntent

data DailyEntryKind
  = DailyExpense
  | DailyIncome
  deriving (Eq, Show)

data State event
  = DailyInput DailyEntryKind (Form ActualAddInput event Name)
  | DailyPreview DailyEntryKind ActualAddPreview (Form ActualAddInput event Name)
  | RecordInput (Form MultiFormState event Name)
  | RecordPreview RecordPreview (Form MultiFormState event Name)
  | ReverseInput ActualTransactionId Transaction (Form ActualReverseInput event Name)
  | ReversePreview ActualTransactionId Transaction ActualReverseInputPreview (Form ActualReverseInput event Name)
  | ReverseUnavailable Text
  | WriteOutcome ActualAddWriteOutcome
  | RealizeWriteOutcome Text
  | ReturnToWorkspace
  | PublishRequested PublishRequest
  | QuitRequested

data PublishResult
  = Published AppContext
  | PublicationFailed ActualAddWriteOutcome
  | RealizationFailed Text
  | ReloadFailed

startDaily :: Day -> State event
startDaily = startDailyEntry DailyExpense

startIncome :: Day -> State event
startIncome = startDailyEntry DailyIncome

startDailyEntry :: DailyEntryKind -> Day -> State event
startDailyEntry kind day = DailyInput kind (mkDailyForm kind day)

startRecord :: Day -> State event
startRecord day =
  RecordInput (mkMultiForm (initialMultiFormState OrdinaryRecord day))

startIssueRealize :: Day -> HouseholdIssue -> State event
startIssueRealize day issue =
  RecordInput (mkMultiForm (initialMultiFormState (RealizeIssue issue) day))

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

multiDateTextL :: Lens' MultiFormState Text
multiDateTextL f state =
  (\value -> state { multiFormInput = input { multiAddDateText = value } })
    <$> f (multiAddDateText input)
  where
    input = multiFormInput state

multiDescriptionTextL :: Lens' MultiFormState Text
multiDescriptionTextL f state =
  (\value -> state
      { multiFormInput = input { multiAddDescriptionText = value } })
    <$> f (multiAddDescriptionText input)
  where
    input = multiFormInput state

multiPostingCountTextL :: Lens' MultiFormState Text
multiPostingCountTextL f state =
  (\value -> state { multiFormPostingCountText = value })
    <$> f (multiFormPostingCountText state)

multiAccountTextL :: Lens' MultiFormState Text
multiAccountTextL f state =
  (\value -> state
      { multiFormInput =
          setActualMultiPostingAccountText selected value input
      , multiFormAccountCandidateCursor = resetMultiAccountCandidateCursor
          current value (multiFormAccountCandidateCursor state)
      })
    <$> f current
  where
    input = multiFormInput state
    selected = multiFormSelectedPosting state
    posting = actualMultiPostingAt selected input
    current = multiPostingAccountText posting

multiAmountTextL :: Lens' MultiFormState Text
multiAmountTextL f state =
  (\value -> state
      { multiFormInput = setActualMultiPostingAmount selected value input })
    <$> f (multiPostingAmountText posting)
  where
    input = multiFormInput state
    selected = multiFormSelectedPosting state
    posting = actualMultiPostingAt selected input

multiClosedDateTextL :: Lens' MultiFormState Text
multiClosedDateTextL f state =
  (\value -> state { multiFormClosedDateText = value })
    <$> f (multiFormClosedDateText state)

multiDecisionMemoTextL :: Lens' MultiFormState Text
multiDecisionMemoTextL f state =
  (\value -> state { multiFormDecisionMemoText = value })
    <$> f (multiFormDecisionMemoText state)

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

initialMultiFormState :: RecordPurpose -> Day -> MultiFormState
initialMultiFormState purpose day = MultiFormState
  { multiFormInput = input
  , multiFormSelectedPosting = 0
  , multiFormPostingCountText =
      T.pack (show (NonEmpty.length (multiAddPostings input)))
  , multiFormAccountCandidateCursor = Nothing
  , multiFormPurpose = purpose
  , multiFormClosedDateText = T.pack (show day)
  , multiFormDecisionMemoText = ""
  }
  where
    baseInput = initialActualMultiAddInputForDay day
    input = case purpose of
      OrdinaryRecord -> baseInput
      RealizeIssue issue ->
        baseInput { multiAddDescriptionText = householdIssueText issue }

mkMultiForm :: MultiFormState -> Form MultiFormState event Name
mkMultiForm state =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)
      baseFields =
        [ label "Date:"
            @@= editTextField multiDateTextL MultiDateField (Just 1)
        , label "Description:"
            @@= editTextField multiDescriptionTextL MultiDescriptionField (Just 1)
        , label "Posting count:"
            @@= editTextField multiPostingCountTextL MultiPostingCountField (Just 1)
        , label "Selected account:"
            @@= editTextField multiAccountTextL MultiAccountField (Just 1)
        , label "Selected amount:"
            @@= editTextField multiAmountTextL MultiAmountField (Just 1)
        ]
      realizationFields = case multiFormPurpose state of
        OrdinaryRecord -> []
        RealizeIssue _ ->
          [ label "Closed:"
              @@= editTextField multiClosedDateTextL IssueClosedDateField (Just 1)
          , label "Decision memo:"
              @@= editTextField multiDecisionMemoTextL IssueDecisionMemoField (Just 1)
          ]
      form = newForm (baseFields <> realizationFields) state
  in setFormFocus MultiDescriptionField form

applyMultiPostingCount :: MultiFormState -> MultiFormState
applyMultiPostingCount state = state
  { multiFormInput = resized
  , multiFormSelectedPosting = clampMultiPostingIndex selected resized
  , multiFormPostingCountText =
      T.pack (show (NonEmpty.length (multiAddPostings resized)))
  }
  where
    input = multiFormInput state
    currentCount = NonEmpty.length (multiAddPostings input)
    requestedCount = fromMaybe currentCount
      (readMaybe (T.unpack (T.strip (multiFormPostingCountText state))))
    resized = resizeActualMultiPostings requestedCount input
    selected = multiFormSelectedPosting state

selectMultiPosting :: Int -> MultiFormState -> MultiFormState
selectMultiPosting requested state = state
  { multiFormSelectedPosting = clampMultiPostingIndex requested input
  , multiFormAccountCandidateCursor = Nothing
  }
  where
    input = multiFormInput state

clampMultiPostingIndex :: Int -> ActualMultiAddInput -> Int
clampMultiPostingIndex requested input =
  max 0 (min requested (NonEmpty.length (multiAddPostings input) - 1))

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

zoomMultiForm :: Traversal' (State AppEvent) (Form MultiFormState AppEvent Name)
zoomMultiForm f (RecordInput form) = RecordInput <$> f form
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
  RecordInput form ->
    let multiState = formState form
        input = multiFormInput multiState
    in center
      (borderWithLabel (str (recordInputTitle multiState))
        (hLimit 86
          (padAll 1
            (vBox
              ( recordPurposeHeader context multiState
                ++ [ txt ("Date: " <> dateSummary context
                      (multiAddDateText input))
                   , str "Use two postings for an ordinary transaction, or increase the posting count when needed."
                   , str "Each posting owns its sign. The complete transaction must balance to zero."
                   , str " "
                   , renderMultiPostingRows multiState
                   , str " "
                   , txt ("Editing posting "
                       <> T.pack (show (multiFormSelectedPosting multiState + 1))
                       <> " of "
                       <> T.pack (show (NonEmpty.length (multiAddPostings input))))
                   , renderForm form
                   , renderMultiInlineAccountSelector context form
                   , str " "
                   , str "Validation: press Enter outside the Account field to check admission and balance."
                   , multiInputControls form
                   ])))))
  RecordPreview preview form ->
    center
      (borderWithLabel (str (recordPreviewTitle (formState form)))
        (hLimit 86
          (padAll 1
            (renderRecordPreview preview <=> str " " <=> str (recordPreviewControls preview)))))
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
  RealizeWriteOutcome message ->
    center
      (borderWithLabel (str "Issue Realize Result")
        (hLimit 86
          (padAll 1
            (withAttr (attrName "error") (txt message)
              <=> str " " <=> str "[Esc] Issues | [Q] Quit"))))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ -> emptyWidget
  QuitRequested -> emptyWidget

recordInputTitle :: MultiFormState -> String
recordInputTitle state = case multiFormPurpose state of
  OrdinaryRecord -> "Record"
  RealizeIssue _ -> "Realize Issue as Actual"

recordPreviewTitle :: MultiFormState -> String
recordPreviewTitle state = case multiFormPurpose state of
  OrdinaryRecord -> "Record Preview"
  RealizeIssue _ -> "Issue Realize Preview"

recordPurposeHeader :: AppContext -> MultiFormState -> [Widget Name]
recordPurposeHeader context state = case multiFormPurpose state of
  OrdinaryRecord -> []
  RealizeIssue issue ->
    [ txt ("Issue: " <> issueIdText (householdIssueId issue)
        <> "  " <> householdIssueText issue)
    , txt ("Relation recorded: " <> T.pack (show (contextEntryDay context)))
    , str "Issue amount is not copied into the transaction; postings remain explicit."
    , str " "
    ]

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
  Just _ -> str "[Up/Down] Choose Account | [click] Select | [Enter] Accept | [Tab] Next field | text edits exact Account | [Esc] Actual"
  Nothing -> str "[Tab] Next field | [Enter] Preview | [Esc] Actual"

multiInputControls :: Form MultiFormState AppEvent Name -> Widget Name
multiInputControls form
  | multiAccountFocused form =
      str "[Up/Down] Choose Account | [click] Select | [Enter] Accept | [Tab] Next field | text edits exact Account | [Esc] Back"
  | otherwise =
      str "[Tab] Next field | [Up/Down] Previous/next posting row | [Enter] Preview | [Esc] Back"

renderDailyInlineAccountSelector
  :: AppContext
  -> DailyEntryKind
  -> Form ActualAddInput AppEvent Name
  -> Widget Name
renderDailyInlineAccountSelector context kind form = case dailySelectionTarget form of
  Nothing -> emptyWidget
  Just target ->
    renderInlineAccountSelector context label selectedCursor candidates
    where
      input = formState form
      current = dailyAccountText target input
      candidates = dailyCandidates context kind target
      selectedCursor = findIndex
        ((== T.strip current) . HKernel.Account.accountName) candidates
      label = case (kind, target) of
        (DailyExpense, SelectToAccount) -> "Expense Accounts"
        (DailyExpense, SelectFromAccount) -> "Payment Accounts"
        (DailyIncome, SelectToAccount) -> "Receiving Accounts"
        (DailyIncome, SelectFromAccount) -> "Income Accounts"

renderMultiInlineAccountSelector
  :: AppContext
  -> Form MultiFormState AppEvent Name
  -> Widget Name
renderMultiInlineAccountSelector context form
  | multiAccountFocused form =
      renderInlineAccountSelector context "Posting Accounts"
        (multiFormAccountCandidateCursor state)
        (filterMultiAccountCandidates current (multiCandidates context))
  | otherwise = emptyWidget
  where
    state = formState form
    selectedPosting = actualMultiPostingAt
      (multiFormSelectedPosting state) (multiFormInput state)
    current = multiPostingAccountText selectedPosting

renderInlineAccountSelector
  :: AppContext
  -> String
  -> Maybe Int
  -> [HKernel.Account.Account]
  -> Widget Name
renderInlineAccountSelector context label cursor candidates =
  borderWithLabel (str label)
    (hLimit 82
      (padAll 1
        (vBox
          ( map renderCandidate visibleCandidates
            ++ [ str " "
               , str "Existing Accounts are grouped by typed meaning; recent use ranks within each group."
               ]
          ))))
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)
    indexedCandidates = zip [0 ..] candidates
    visibleCandidates = candidateWindow 9 cursor indexedCandidates
    renderCandidate (index, account) =
      clickable (AccountCandidate index) highlighted
      where
        selected = cursor == Just index
        accountType = HKernel.Account.accountTypeFor account registry
        row = txt
          (accountTypeLabel accountType <> "  " <> HKernel.Account.accountName account)
        highlighted = if selected then withAttr L.listSelectedAttr row else row

accountTypeLabel :: Maybe HKernel.Account.AccountType -> Text
accountTypeLabel maybeType = case maybeType of
  Just HKernel.Account.Asset -> "Assets     "
  Just HKernel.Account.Liability -> "Liabilities"
  Just HKernel.Account.Equity -> "Equity     "
  Just HKernel.Account.Income -> "Income     "
  Just HKernel.Account.Expense -> "Expenses   "
  Just HKernel.Account.Budget -> "Budget     "
  Nothing -> "Unknown    "

candidateWindow :: Int -> Maybe Int -> [a] -> [a]
candidateWindow limit cursor candidates =
  take limit (drop start candidates)
  where
    selectedIndex = fromMaybe 0 cursor
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

multiAccountFocused :: Form MultiFormState event Name -> Bool
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
    , vBox
        [ txtWrap "Navigate: [1-7] Sections  [Tab/Left/Right] Focus  [j/k/Arrows] Move"
        , txtWrap "Record:   [r] Record (2+ postings)  [a] Expense  [i] Income"
        , txtWrap "Action:   [Enter] Reverse selected  [q] Quit"
        ]
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
    RecordInput form -> handleMultiInput context form event
    RecordPreview preview form -> handleMultiPreview context preview form event
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
    RealizeWriteOutcome _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      _ -> pure ()
    ReturnToWorkspace -> pure ()
    PublishRequested _ -> pure ()
    QuitRequested -> pure ()

handleDailyInput
  :: AppContext
  -> DailyEntryKind
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleDailyInput context kind form event = case event of
  MouseDown (AccountCandidate index) V.BLeft _ _
    | Just target <- dailySelectionTarget form ->
        selectDailyAccountCandidateAt context kind target index form
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

selectDailyAccountCandidateAt
  :: AppContext
  -> DailyEntryKind
  -> AccountSelectionTarget
  -> Int
  -> Form ActualAddInput AppEvent Name
  -> EventM Name (State AppEvent) ()
selectDailyAccountCandidateAt context kind target index form =
  case accountCandidateAt index (dailyCandidates context kind target) of
    Nothing -> pure ()
    Just account ->
      let updatedInput = selectActualAddAccount target account (formState form)
          updatedForm = setFormFocus (dailyNextField target)
            (updateFormState updatedInput form)
      in put (DailyInput kind updatedForm)

acceptDailyAccount
  :: DailyEntryKind
  -> AccountSelectionTarget
  -> Form ActualAddInput AppEvent Name
  -> EventM Name (State AppEvent) ()
acceptDailyAccount kind target form
  | T.null (T.strip (dailyAccountText target (formState form))) = pure ()
  | otherwise = put (DailyInput kind (setFormFocus (dailyNextField target) form))

dailyFieldName :: AccountSelectionTarget -> Name
dailyFieldName target = case target of
  SelectToAccount -> ToAccountField
  SelectFromAccount -> FromAccountField

dailyNextField :: AccountSelectionTarget -> Name
dailyNextField target = case target of
  SelectToAccount -> FromAccountField
  SelectFromAccount -> DateField

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
        in put (PublishRequested (PublishActual stickyDay block))
      _ -> pure ()

handleMultiInput
  :: AppContext
  -> Form MultiFormState AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleMultiInput context form event = case event of
  MouseDown (AccountCandidate index) V.BLeft _ _
    | multiAccountFocused form -> selectMultiAccountCandidateAt context index form
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KUp [])
    | multiAccountFocused form -> moveMultiAccountCandidate context (-1) form
  VtyEvent (V.EvKey V.KDown [])
    | multiAccountFocused form -> moveMultiAccountCandidate context 1 form
  VtyEvent (V.EvKey V.KEnter [])
    | multiAccountFocused form -> acceptMultiAccount context form
  VtyEvent (V.EvKey V.KEnter []) -> prepareMultiPreview context form
  VtyEvent (V.EvKey V.KUp []) -> moveMultiSelection (-1) form
  VtyEvent (V.EvKey V.KDown []) -> moveMultiSelection 1 form
  _ -> zoom zoomMultiForm (handleFormEvent event)

moveMultiAccountCandidate
  :: AppContext
  -> Int
  -> Form MultiFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
moveMultiAccountCandidate context offset form =
  let nextCursor = moveMultiAccountCandidateCursor
        offset current (multiFormAccountCandidateCursor state) candidates
      updatedState = state { multiFormAccountCandidateCursor = nextCursor }
      updatedForm = setFormFocus MultiAccountField
        (updateFormState updatedState form)
  in put (RecordInput updatedForm)
  where
    state = formState form
    input = multiFormInput state
    selected = multiFormSelectedPosting state
    current = multiPostingAccountText (actualMultiPostingAt selected input)
    candidates = multiCandidates context

selectMultiAccountCandidateAt
  :: AppContext
  -> Int
  -> Form MultiFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
selectMultiAccountCandidateAt context index form =
  case commitMultiAccountCandidate selected current index candidates input of
    Nothing -> pure ()
    Just updatedInput ->
      let updatedState = state
            { multiFormInput = updatedInput
            , multiFormAccountCandidateCursor = Nothing
            }
          updatedForm = setFormFocus MultiAmountField
            (updateFormState updatedState form)
      in put (RecordInput updatedForm)
  where
    state = formState form
    input = multiFormInput state
    selected = multiFormSelectedPosting state
    current = multiPostingAccountText (actualMultiPostingAt selected input)
    candidates = filterMultiAccountCandidates current (multiCandidates context)

acceptMultiAccount
  :: AppContext
  -> Form MultiFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
acceptMultiAccount context form =
  case multiFormAccountCandidateCursor state >>= commitCandidate of
    Nothing -> pure ()
    Just updatedInput ->
      let updatedState = state
            { multiFormInput = updatedInput
            , multiFormAccountCandidateCursor = Nothing
            }
      in put (RecordInput
          (setFormFocus MultiAmountField (updateFormState updatedState form)))
  where
    state = formState form
    input = multiFormInput state
    selected = multiFormSelectedPosting state
    current = multiPostingAccountText (actualMultiPostingAt selected input)
    candidates = multiCandidates context
    commitCandidate index =
      commitMultiAccountCandidate selected current index candidates input

moveMultiSelection
  :: Int
  -> Form MultiFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
moveMultiSelection offset form =
  let applied = applyMultiPostingCount (formState form)
      selected = multiFormSelectedPosting applied + offset
      moved = selectMultiPosting selected applied
  in put (RecordInput (updateFormState moved form))

prepareMultiPreview
  :: AppContext
  -> Form MultiFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
prepareMultiPreview context form = do
  let applied = applyMultiPostingCount (formState form)
      updatedForm = updateFormState applied form
      resolvedJournal = actualJournalValue
        (householdStateActualJournal (contextHouseholdState context))
  preview <- case multiFormPurpose applied of
    OrdinaryRecord -> pure
      (RecordActualPreview
        (prepareActualMultiAddPreviewFromResolvedJournal
          resolvedJournal (contextSource context) (multiFormInput applied)))
    RealizeIssue issue -> liftIO
      (prepareIssueRealizeRecordPreview context issue applied)
  put (RecordPreview preview updatedForm)

prepareIssueRealizeRecordPreview
  :: AppContext
  -> HouseholdIssue
  -> MultiFormState
  -> IO RecordPreview
prepareIssueRealizeRecordPreview context issue formState = do
  let state = contextHouseholdState context
      paths = householdStatePaths state
      registry = householdStateAccountsRegistry state
      memo = T.strip (multiFormDecisionMemoText formState)
  case buildActualMultiAddIntentWithRegistry registry (multiFormInput formState) of
    Left inputError -> pure
      (RecordIssueRealizeRejected
        ("Actual input rejected: " <> T.pack (show inputError)))
    Right actualIntent -> case parseRealizeClosedDay context formState of
      Left message -> pure (RecordIssueRealizeRejected message)
      Right closedOn
        | T.null memo -> pure
            (RecordIssueRealizeRejected "Decision memo is required for Issue realization.")
        | otherwise -> do
            relationResult <- readOptionalRelationSource
              (householdIssueRelationsPath paths)
            case relationResult of
              Left message -> pure (RecordIssueRealizeRejected message)
              Right (relationExists, relationSource) -> do
                let intent = IssueRealizeIntent
                      { realizeIssueId = householdIssueId issue
                      , realizeRecordedOn = contextEntryDay context
                      , realizeClosedOn = closedOn
                      , realizeActualIntent = actualIntent
                      , realizeDecisionMemo = memo
                      }
                pure $ case prepareIssueRealize
                    (householdStateActualJournal state)
                    (householdStatePlanJournal state)
                    (contextSource context)
                    relationSource
                    (contextIssuesSource context)
                    intent of
                  Left errors -> RecordIssueRealizeRejected
                    ("Issue realization rejected: "
                      <> T.pack (show (NonEmpty.toList errors)))
                  Right preview -> RecordIssueRealizeReady preview
                    IssueRealizeWriteIntent
                      { writeRealizeActualPath = householdActualJournalPath paths
                      , writeRealizeExpectedActual = contextSource context
                      , writeRealizeCandidateActual = realizedActualCandidateSource preview
                      , writeRealizeRelationPath = householdIssueRelationsPath paths
                      , writeRealizeExpectedRelationExists = relationExists
                      , writeRealizeExpectedRelation = relationSource
                      , writeRealizeCandidateRelation = realizedRelationCandidateSource preview
                      , writeRealizeIssuesPath = householdIssuesPath paths
                      , writeRealizeExpectedIssues = contextIssuesSource context
                      , writeRealizeCandidateIssues = realizedIssuesCandidateSource preview
                      }

parseRealizeClosedDay :: AppContext -> MultiFormState -> Either Text Day
parseRealizeClosedDay context state
  | T.null raw = Right (contextEntryDay context)
  | otherwise = maybe
      (Left "Closed must be YYYY-MM-DD.")
      Right
      (readMaybe (T.unpack raw))
  where
    raw = T.strip (multiFormClosedDateText state)

readOptionalRelationSource :: FilePath -> IO (Either Text (Bool, Text))
readOptionalRelationSource path = do
  result <- tryIOError (TIO.readFile path)
  pure $ case result of
    Right source -> Right (True, source)
    Left errorValue
      | isDoesNotExistError errorValue -> Right (False, "")
      | otherwise -> Left ("Relation source read failed: " <> T.pack (show errorValue))

handleMultiPreview
  :: AppContext
  -> RecordPreview
  -> Form MultiFormState AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleMultiPreview context preview form event = case event of
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
    state = formState form
    stickyDay = fromMaybe (contextEntryDay context)
      (readMaybe (T.unpack (multiAddDateText (multiFormInput state))))
    back = put (RecordInput form)
    publish = case preview of
      RecordActualPreview (ActualMultiAddCandidateReady block) ->
        put (PublishRequested (PublishActual stickyDay block))
      RecordIssueRealizeReady _ writeIntent ->
        put (PublishRequested (PublishIssueRealize stickyDay writeIntent))
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
        put (PublishRequested (PublishActual (contextEntryDay context) block))
      _ -> pure ()

publishCandidate :: AppContext -> PublishRequest -> IO PublishResult
publishCandidate context request = case request of
  PublishActual stickyDay block -> publishActualCandidate stickyDay block
  PublishIssueRealize stickyDay writeIntent ->
    publishRealizeCandidate stickyDay writeIntent
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
    publishRealizeCandidate stickyDay writeIntent = do
      writeResult <- publishIssueRealize
        (admitIssueRealizeAfterWrite root (writeRealizeRelationPath writeIntent))
        writeIntent
      case writeResult of
        Right () -> reloadAfter (context { contextEntryDay = stickyDay })
        Left writeError -> pure
          (RealizationFailed ("Issue realization write failed: " <> T.pack (show writeError)))
    reloadAfter stickyContext = do
      reloadedContext <- reloadWorkspaceContext stickyContext
      pure (maybe ReloadFailed Published reloadedContext)

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
  newestTransactionEntriesForAccount
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
  Just entry -> case actualReverseAvailability actualJournal entry of
    ActualReverseIdentityMissing -> Left
      "Reverse unavailable: this transaction has no durable Actual identity."
    ActualReverseAvailable targetId ->
      Right (targetId, actualTransactionEntryTransaction entry)
    ActualReverseAlreadyReversed _ reversalId -> Left
      ("Already reversed by " <> actualTransactionIdText reversalId
        <> ". Select that reversal if you need to restore the original effect.")
  where
    actualJournal =
      householdStateActualJournal (contextHouseholdState context)

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
renderReverseAvailability context entry =
  case actualReverseAvailability actualJournal entry of
    ActualReverseIdentityMissing -> withAttr (attrName "warning")
      (str "Reverse unavailable: no durable Actual identity.")
    ActualReverseAlreadyReversed _ reversalId -> withAttr (attrName "warning")
      (txt ("Already reversed by " <> actualTransactionIdText reversalId
        <> ". Select that reversal to reverse it."))
    ActualReverseAvailable targetId -> withAttr (attrName "success")
      (txt ("[Enter] Reverse  event-id: " <> actualTransactionIdText targetId))
  where
    actualJournal =
      householdStateActualJournal (contextHouseholdState context)

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

renderMultiPostingRows :: MultiFormState -> Widget Name
renderMultiPostingRows state =
  vBox
    [ renderRow index posting
    | (index, posting) <- zip [0 ..]
        (NonEmpty.toList (multiAddPostings (multiFormInput state)))
    ]
  where
    selected = multiFormSelectedPosting state
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

renderRecordPreview :: RecordPreview -> Widget Name
renderRecordPreview preview = case preview of
  RecordActualPreview actualPreview -> renderMultiPreview actualPreview
  RecordIssueRealizeRejected message ->
    withAttr (attrName "error") (txt message)
  RecordIssueRealizeReady realization _ ->
    withAttr (attrName "success")
      (str "All three candidates admitted. Sources unmodified.")
      <=> str " "
      <=> str "--- Actual ---"
      <=> txt (realizedActualBlock realization)
      <=> str "--- Relation ---"
      <=> txt (realizedRelationBlock realization)
      <=> str "--- Issue ---"
      <=> txt (realizedIssueBlock realization)

recordPreviewControls :: RecordPreview -> String
recordPreviewControls preview = case preview of
  RecordActualPreview actualPreview -> multiPreviewControls actualPreview
  RecordIssueRealizeReady _ _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  RecordIssueRealizeRejected _ -> "[Esc/B] Back | [Q] Quit"

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

data WorkspaceAction
  = MaintainContext
  | OpenDaily
  | OpenIncome
  | OpenRecord
  | OpenReverse

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext WorkspaceAction
handleWorkspaceEvent event = case event of
  MouseDown WorkspaceAccountList V.BScrollUp _ _ ->
    selectAccountEvent (V.EvKey V.KUp [])
  MouseDown WorkspaceAccountList V.BScrollDown _ _ ->
    selectAccountEvent (V.EvKey V.KDown [])
  MouseDown WorkspaceAccountList V.BLeft _ (Location (_, row)) -> do
    zoom contextWorkspaceAccountsL (modify (L.listMoveTo row))
    modify (\ctx -> applyWorkspaceAccountFilter (ctx { contextWorkspaceFocus = AccountsFocus }))
    pure MaintainContext
  MouseDown WorkspaceTransactionList V.BScrollUp _ _ ->
    selectTransactionEvent (V.EvKey V.KUp [])
  MouseDown WorkspaceTransactionList V.BScrollDown _ _ ->
    selectTransactionEvent (V.EvKey V.KDown [])
  MouseDown WorkspaceTransactionList V.BLeft _ (Location (_, row)) -> do
    zoom contextWorkspaceListL (modify (L.listMoveTo row))
    modify (\ctx -> ctx { contextWorkspaceFocus = TransactionsFocus })
    pure MaintainContext
  VtyEvent (V.EvKey (V.KChar 'a') []) -> pure OpenDaily
  VtyEvent (V.EvKey (V.KChar 'A') []) -> pure OpenDaily
  VtyEvent (V.EvKey (V.KChar 'i') []) -> pure OpenIncome
  VtyEvent (V.EvKey (V.KChar 'I') []) -> pure OpenIncome
  VtyEvent (V.EvKey (V.KChar 'r') []) -> pure OpenRecord
  VtyEvent (V.EvKey (V.KChar 'R') []) -> pure OpenRecord
  VtyEvent (V.EvKey V.KEnter []) -> do
    context <- get
    if contextWorkspaceFocus context == AccountsFocus
      then do
        modify (\ctx -> ctx { contextWorkspaceFocus = TransactionsFocus })
        pure MaintainContext
      else pure OpenReverse
  VtyEvent (V.EvKey (V.KChar '\t') []) -> do
    modify toggleWorkspaceFocus
    pure MaintainContext
  VtyEvent (V.EvKey V.KLeft []) -> do
    modify (\ctx -> ctx { contextWorkspaceFocus = AccountsFocus })
    pure MaintainContext
  VtyEvent (V.EvKey V.KRight []) -> do
    modify (\ctx -> ctx { contextWorkspaceFocus = TransactionsFocus })
    pure MaintainContext
  VtyEvent (V.EvKey vtyKey vtyMods) -> do
    context <- get
    case contextWorkspaceFocus context of
      AccountsFocus -> selectAccountEvent (V.EvKey vtyKey vtyMods)
      TransactionsFocus -> selectTransactionEvent (V.EvKey vtyKey vtyMods)
  _ -> pure MaintainContext
  where
    selectAccountEvent ev = do
      zoom contextWorkspaceAccountsL (L.handleListEventVi L.handleListEvent ev)
      modify (\ctx -> applyWorkspaceAccountFilter (ctx { contextWorkspaceFocus = AccountsFocus }))
      pure MaintainContext
    selectTransactionEvent ev = do
      zoom contextWorkspaceListL (L.handleListEventVi L.handleListEvent ev)
      modify (\ctx -> ctx { contextWorkspaceFocus = TransactionsFocus })
      pure MaintainContext
