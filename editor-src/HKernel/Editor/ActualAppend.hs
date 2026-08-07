{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.ActualAppend
  ( ActualEditIntent(..)
  , ActualEditError(..)
  , ActualAppendPreview(..)
  , prepareActualAppend
  , prepareActualAppendFromResolvedJournal
  , ActualAddInput(..)
  , ActualAddInputError(..)
  , ActualAddPreview(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , emptyActualAddInput
  , buildActualAddIntent
  , buildActualAddIntentWithRegistry
  , prepareActualAddPreview
  , prepareActualAddPreviewFromResolvedJournal
  , classifyActualAddWriteResult
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import HKernel.Account
  ( Account
  , AccountRegistry
  , declaredAccountDefaultCommodity
  , lookupAccountDeclaration
  , mkAccount
  )
import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalValue
  , admitActualJournalFromResolvedJournal
  , parseActualJournal
  )
import HKernel.Editor.ActualWriter (WriteError(..))
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Editor.TransactionBlock
  ( IntentPosting(..)
  , PreparedTransactionBlock(..)
  , TransactionBlockError(..)
  , TransactionBlockIntent(..)
  , prepareTransactionBlock
  )
import HKernel.Journal
  ( Journal
  , appendJournalTransaction
  , journalAccountRegistry
  )
import HKernel.Ledger (TransactionError)
import HKernel.Money
  ( Commodity
  , Quantity
  , mkCommodity
  , negateQuantity
  , parseQuantity
  , quantityToRational
  )

-- | A request to append a new transaction to the Actual journal.
data ActualEditIntent = ActualEditIntent
  { intentDate        :: Day
  , intentDescription :: Text
  , intentPostings    :: NonEmpty IntentPosting
  , intentMetadata    :: [(Text, Text)]
  } deriving (Eq, Show)

data ActualEditError
  = SourceParseError (NonEmpty ActualJournalError)
  | CandidateSourceParseError (NonEmpty ActualJournalError)
  | UndeclaredAccount Account
  | MissingCommodity Account
  | ZeroAmount Account
  | ValidationError TransactionError
  deriving (Eq, Show)

data ActualAppendPreview = ActualAppendPreview
  { candidateBlock          :: Text
  , candidateCompleteSource :: Text
  } deriving (Eq, Show)

prepareActualAppend
  :: Text
  -> ActualEditIntent
  -> Either (NonEmpty ActualEditError) ActualAppendPreview
prepareActualAppend existingSource intent = do
  journal <- parseSource existingSource
  prepareActualAppendFromJournal journal existingSource intent

-- | Prepare an Actual append using declarations and transactions from the
-- resolved Journal while retaining Actual-owned metadata from the root source.
prepareActualAppendFromResolvedJournal
  :: Journal
  -> Text
  -> ActualEditIntent
  -> Either (NonEmpty ActualEditError) ActualAppendPreview
prepareActualAppendFromResolvedJournal resolvedJournal existingSource intent = do
  journal <- first (pure . SourceParseError)
    (admitActualJournalFromResolvedJournal resolvedJournal existingSource)
  prepareActualAppendFromJournal journal existingSource intent

prepareActualAppendFromJournal
  :: ActualJournal
  -> Text
  -> ActualEditIntent
  -> Either (NonEmpty ActualEditError) ActualAppendPreview
prepareActualAppendFromJournal journal existingSource intent = do
  prepared <- first (fmap toActualEditError)
    (prepareTransactionBlock
      (journalAccountRegistry (actualJournalValue journal))
      (toTransactionBlockIntent intent))

  let block = preparedTransactionBlock prepared
      preview = ActualAppendPreview
        { candidateBlock = block
        , candidateCompleteSource =
            appendSourceBlock existingSource (SourceBlock block)
        }
      candidateJournal = appendJournalTransaction
        (preparedTransaction prepared)
        (actualJournalValue journal)

  _ <- first (pure . CandidateSourceParseError)
    (admitActualJournalFromResolvedJournal
      candidateJournal
      (candidateCompleteSource preview))
  pure preview

parseSource :: Text -> Either (NonEmpty ActualEditError) ActualJournal
parseSource = first (pure . SourceParseError) . parseActualJournal

toTransactionBlockIntent :: ActualEditIntent -> TransactionBlockIntent
toTransactionBlockIntent intent = TransactionBlockIntent
  { blockDate = intentDate intent
  , blockDescription = intentDescription intent
  , blockPostings = intentPostings intent
  , blockMetadata = intentMetadata intent
  }

toActualEditError :: TransactionBlockError -> ActualEditError
toActualEditError blockError = case blockError of
  BlockUndeclaredAccount account -> UndeclaredAccount account
  BlockMissingCommodity account -> MissingCommodity account
  BlockZeroAmount account -> ZeroAmount account
  BlockValidationError transactionError -> ValidationError transactionError

-- | Delivery-neutral text input for the ordinary two-posting Actual add
-- operation. Brick, Haskeline, HTTP, or another adapter can construct the same
-- value before calling this shared owner.
data ActualAddInput = ActualAddInput
  { addDateText        :: Text
  , addDescriptionText :: Text
  , addFromAccountText :: Text
  , addToAccountText   :: Text
  , addAmountText      :: Text
  } deriving (Eq, Show)

data ActualAddInputError
  = ActualAddInvalidDate
  | ActualAddInvalidFromAccount
  | ActualAddInvalidToAccount
  | ActualAddInvalidAmountShape
  | ActualAddInvalidQuantity
  | ActualAddAmountMustBePositive
  | ActualAddInvalidCommodity
  | ActualAddMissingDefaultCommodity
  | ActualAddConflictingDefaultCommodity
  deriving (Eq, Show)

-- | Delivery-neutral preview retaining only the candidate transaction block.
data ActualAddPreview
  = ActualAddInputRejected ActualAddInputError
  | ActualAddCandidateRejected (NonEmpty ActualEditError)
  | ActualAddCandidateReady Text
  deriving (Eq, Show)

data ActualAddWriteFailure
  = ActualAddPostAdmissionFailure
  | ActualAddPostPublishReadFailure
  deriving (Eq, Show)

data ActualAddWriteOutcome
  = ActualAddWriteSucceeded
  | ActualAddWriteStale
  | ActualAddWriteRecovered ActualAddWriteFailure
  | ActualAddWriteFailed ActualAddWriteFailure
  | ActualAddWriteFileIOFailed
  deriving (Eq, Show)

emptyActualAddInput :: ActualAddInput
emptyActualAddInput = ActualAddInput "" "" "" "" ""

-- | Preserve the explicit CLI/text contract: callers that do not supply a
-- registry must state both positive quantity and commodity.
buildActualAddIntent
  :: ActualAddInput
  -> Either ActualAddInputError ActualEditIntent
buildActualAddIntent input = do
  (date, fromAccount, toAccount) <- parseActualAddCoordinates input
  (quantityText, commodityText) <- case T.words (addAmountText input) of
    [quantityValue, commodityValue] -> Right (quantityValue, commodityValue)
    _ -> Left ActualAddInvalidAmountShape
  quantity <- parsePositiveQuantity quantityText
  commodity <- first (const ActualAddInvalidCommodity)
    (mkCommodity commodityText)
  pure (makeActualAddIntent input date fromAccount toAccount quantity commodity)

-- | Daily entry may omit the commodity when the selected canonical Account
-- declarations supply one unambiguous default. A single available default is
-- enough because the other Account can still accept an explicitly rendered
-- commodity; two different defaults are rejected before candidate creation.
buildActualAddIntentWithRegistry
  :: AccountRegistry
  -> ActualAddInput
  -> Either ActualAddInputError ActualEditIntent
buildActualAddIntentWithRegistry registry input = do
  (date, fromAccount, toAccount) <- parseActualAddCoordinates input
  (quantityText, commodity) <- case T.words (addAmountText input) of
    [quantityValue, commodityValue] -> do
      parsedCommodity <- first (const ActualAddInvalidCommodity)
        (mkCommodity commodityValue)
      Right (quantityValue, parsedCommodity)
    [quantityValue] -> do
      inferred <- inferDefaultCommodity registry fromAccount toAccount
      Right (quantityValue, inferred)
    _ -> Left ActualAddInvalidAmountShape
  quantity <- parsePositiveQuantity quantityText
  pure (makeActualAddIntent input date fromAccount toAccount quantity commodity)

parseActualAddCoordinates
  :: ActualAddInput
  -> Either ActualAddInputError (Day, Account, Account)
parseActualAddCoordinates input = do
  date <- maybe (Left ActualAddInvalidDate) Right
    (parseTimeM
      True
      defaultTimeLocale
      "%Y-%m-%d"
      (T.unpack (addDateText input)) :: Maybe Day)
  fromAccount <- first (const ActualAddInvalidFromAccount)
    (mkAccount (addFromAccountText input))
  toAccount <- first (const ActualAddInvalidToAccount)
    (mkAccount (addToAccountText input))
  pure (date, fromAccount, toAccount)

parsePositiveQuantity
  :: Text
  -> Either ActualAddInputError Quantity
parsePositiveQuantity quantityText = do
  quantity <- first (const ActualAddInvalidQuantity)
    (parseQuantity quantityText)
  if quantityToRational quantity <= 0
    then Left ActualAddAmountMustBePositive
    else Right quantity

inferDefaultCommodity
  :: AccountRegistry
  -> Account
  -> Account
  -> Either ActualAddInputError Commodity
inferDefaultCommodity registry fromAccount toAccount =
  case catMaybes (map defaultFor [fromAccount, toAccount]) of
    [] -> Left ActualAddMissingDefaultCommodity
    commodity : rest
      | all (== commodity) rest -> Right commodity
      | otherwise -> Left ActualAddConflictingDefaultCommodity
  where
    defaultFor account =
      declaredAccountDefaultCommodity =<<
        lookupAccountDeclaration account registry

makeActualAddIntent
  :: ActualAddInput
  -> Day
  -> Account
  -> Account
  -> Quantity
  -> Commodity
  -> ActualEditIntent
makeActualAddIntent input date fromAccount toAccount quantity commodity =
  ActualEditIntent
    date
    (addDescriptionText input)
    ( IntentPosting toAccount quantity (Just commodity)
      :| [IntentPosting fromAccount (negateQuantity quantity) (Just commodity)]
    )
    []

prepareActualAddPreview :: Text -> ActualAddInput -> ActualAddPreview
prepareActualAddPreview source input =
  prepareActualAddPreviewWith
    buildActualAddIntent
    (prepareActualAppend source)
    input

prepareActualAddPreviewFromResolvedJournal
  :: Journal
  -> Text
  -> ActualAddInput
  -> ActualAddPreview
prepareActualAddPreviewFromResolvedJournal resolvedJournal source input =
  prepareActualAddPreviewWith
    (buildActualAddIntentWithRegistry (journalAccountRegistry resolvedJournal))
    (prepareActualAppendFromResolvedJournal resolvedJournal source)
    input

prepareActualAddPreviewWith
  :: (ActualAddInput -> Either ActualAddInputError ActualEditIntent)
  -> (ActualEditIntent
      -> Either (NonEmpty ActualEditError) ActualAppendPreview)
  -> ActualAddInput
  -> ActualAddPreview
prepareActualAddPreviewWith build prepare input =
  case build input of
    Left inputError -> ActualAddInputRejected inputError
    Right intent -> case prepare intent of
      Left sourceErrors -> ActualAddCandidateRejected sourceErrors
      Right preview -> ActualAddCandidateReady (candidateBlock preview)

-- | Collapse the safe writer result into a finite delivery-neutral outcome.
classifyActualAddWriteResult
  :: Either (WriteError sourceError) ()
  -> ActualAddWriteOutcome
classifyActualAddWriteResult result = case result of
  Right () -> ActualAddWriteSucceeded
  Left StaleFile -> ActualAddWriteStale
  Left (PostAdmissionFailed { restoredFromBackup = True }) ->
    ActualAddWriteRecovered ActualAddPostAdmissionFailure
  Left (PostAdmissionFailed { restoredFromBackup = False }) ->
    ActualAddWriteFailed ActualAddPostAdmissionFailure
  Left (PostPublishReadFailed { restoredFromBackup = True }) ->
    ActualAddWriteRecovered ActualAddPostPublishReadFailure
  Left (PostPublishReadFailed { restoredFromBackup = False }) ->
    ActualAddWriteFailed ActualAddPostPublishReadFailure
  Left (FileIOError _) ->
    ActualAddWriteFileIOFailed