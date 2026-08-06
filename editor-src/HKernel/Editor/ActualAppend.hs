{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.ActualAppend
  ( ActualEditIntent(..)
  , ActualEditError(..)
  , ActualAppendPreview(..)
  , prepareActualAppend
  , ActualAddInput(..)
  , ActualAddInputError(..)
  , ActualAddPreview(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , emptyActualAddInput
  , buildActualAddIntent
  , prepareActualAddPreview
  , classifyActualAddWriteResult
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import HKernel.Account (Account, mkAccount)
import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalValue
  , parseActualJournal
  )
import HKernel.Editor.ActualWriter (WriteError(..))
import HKernel.Editor.SourceAppend (appendSourceBlock)
import HKernel.Editor.TransactionBlock
  ( IntentPosting(..)
  , TransactionBlockError(..)
  , TransactionBlockIntent(..)
  , prepareTransactionBlock
  )
import HKernel.Journal (journalAccountRegistry)
import HKernel.Ledger (TransactionError)
import HKernel.Money
  ( mkCommodity
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
  block <- first (fmap toActualEditError)
    (prepareTransactionBlock
      (journalAccountRegistry (actualJournalValue journal))
      (toTransactionBlockIntent intent))

  let preview = ActualAppendPreview
        { candidateBlock = block
        , candidateCompleteSource = appendSourceBlock existingSource block
        }

  _ <- first (pure . CandidateSourceParseError)
    (parseActualJournal (candidateCompleteSource preview))
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

-- | Admit a positive magnitude and derive the balancing source posting by
-- negating the parsed Quantity value, never by manipulating its input text.
buildActualAddIntent
  :: ActualAddInput
  -> Either ActualAddInputError ActualEditIntent
buildActualAddIntent input = do
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
  (quantityText, commodityText) <- case T.words (addAmountText input) of
    [quantityValue, commodityValue] -> Right (quantityValue, commodityValue)
    _ -> Left ActualAddInvalidAmountShape
  quantity <- first (const ActualAddInvalidQuantity)
    (parseQuantity quantityText)
  if quantityToRational quantity <= 0
    then Left ActualAddAmountMustBePositive
    else pure ()
  commodity <- first (const ActualAddInvalidCommodity)
    (mkCommodity commodityText)
  pure
    (ActualEditIntent
      date
      (addDescriptionText input)
      ( IntentPosting toAccount quantity (Just commodity)
        :| [IntentPosting fromAccount (negateQuantity quantity) (Just commodity)]
      )
      [])

prepareActualAddPreview :: Text -> ActualAddInput -> ActualAddPreview
prepareActualAddPreview source input =
  case buildActualAddIntent input of
    Left inputError -> ActualAddInputRejected inputError
    Right intent -> case prepareActualAppend source intent of
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
