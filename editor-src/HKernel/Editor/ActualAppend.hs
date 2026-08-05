{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.ActualAppend
  ( ActualEditIntent(..)
  , TransactionBlockIntent(..)
  , IntentPosting(..)
  , TransactionBlockError(..)
  , ActualEditError(..)
  , ActualAppendPreview(..)
  , prepareTransactionBlock
  , prepareActualAppend
  , appendBlock
  ) where

import Control.Applicative ((<|>))
import Control.Monad (when)
import Data.Bifunctor (first)
import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Account
  ( Account
  , AccountRegistry
  , accountName
  , declaredAccountDefaultCommodity
  , lookupAccountDeclaration
  )
import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalValue
  , parseActualJournal
  )
import HKernel.Journal (journalAccountRegistry)
import HKernel.Ledger
  ( Posting
  , Transaction
  , TransactionError
  , mkPosting
  , mkTransaction
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( Commodity
  , Quantity
  , amountCommodity
  , amountQuantity
  , commodityCode
  , isZeroQuantity
  , mkAmount
  , renderQuantity
  )

-- | A request to append a new transaction to the Actual journal.
data ActualEditIntent = ActualEditIntent
  { intentDate        :: Day
  , intentDescription :: Text
  , intentPostings    :: NonEmpty IntentPosting
  , intentMetadata    :: [(Text, Text)]
  } deriving (Eq, Show)

-- | Source-neutral input for one validated Journal transaction block.
--
-- Actual and Plan append paths may share this validation and rendering step,
-- while each source owner remains responsible for its own admission before and
-- after the block is appended.
data TransactionBlockIntent = TransactionBlockIntent
  { blockDate        :: Day
  , blockDescription :: Text
  , blockPostings    :: NonEmpty IntentPosting
  , blockMetadata    :: [(Text, Text)]
  } deriving (Eq, Show)

data IntentPosting = IntentPosting
  { intentAccount   :: Account
  , intentQuantity  :: Quantity
  , intentCommodity :: Maybe Commodity
  } deriving (Eq, Show)

data TransactionBlockError
  = BlockUndeclaredAccount Account
  | BlockMissingCommodity Account
  | BlockZeroAmount Account
  | BlockValidationError TransactionError
  deriving (Eq, Show)

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

prepareTransactionBlock
  :: AccountRegistry
  -> TransactionBlockIntent
  -> Either (NonEmpty TransactionBlockError) Text
prepareTransactionBlock registry intent = do
  postings <- resolvePostings registry (blockPostings intent)
  transaction <- buildTransaction intent postings
  pure (renderTransaction (blockMetadata intent) transaction)

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
        , candidateCompleteSource = appendBlock existingSource block
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

resolvePostings
  :: AccountRegistry
  -> NonEmpty IntentPosting
  -> Either (NonEmpty TransactionBlockError) (NonEmpty Posting)
resolvePostings registry intents =
  case partitionEithers
    (NonEmpty.toList (fmap (resolvePosting registry) intents)) of
    (err : errs, _) -> Left (err NonEmpty.:| errs)
    ([], posting : postings) -> Right (posting NonEmpty.:| postings)
    ([], []) -> error "unreachable: input was NonEmpty"

buildTransaction
  :: TransactionBlockIntent
  -> NonEmpty Posting
  -> Either (NonEmpty TransactionBlockError) Transaction
buildTransaction intent postings =
  first (pure . BlockValidationError)
    (mkTransaction (blockDate intent) (blockDescription intent) postings)

resolvePosting
  :: AccountRegistry
  -> IntentPosting
  -> Either TransactionBlockError Posting
resolvePosting registry (IntentPosting account quantity maybeCommodity) = do
  when (isZeroQuantity quantity) (Left (BlockZeroAmount account))

  declaration <- maybe
    (Left (BlockUndeclaredAccount account))
    pure
    (lookupAccountDeclaration account registry)

  let effectiveCommodity =
        maybeCommodity <|> declaredAccountDefaultCommodity declaration
  commodity <- maybe
    (Left (BlockMissingCommodity account))
    pure
    effectiveCommodity

  pure (mkPosting account (mkAmount commodity quantity))

renderTransaction :: [(Text, Text)] -> Transaction -> Text
renderTransaction metadata transaction =
  T.pack
    (formatTime defaultTimeLocale "%Y-%m-%d" (transactionDate transaction))
  <> " " <> transactionDescription transaction <> "\n"
  <> (if null metadata
        then ""
        else T.intercalate "\n" (map renderMetadata metadata) <> "\n")
  <> T.intercalate "\n"
      (map renderPosting (NonEmpty.toList (transactionPostings transaction)))
  <> "\n"

renderMetadata :: (Text, Text) -> Text
renderMetadata (key, value) = "    ; " <> key <> ": " <> value

renderPosting :: Posting -> Text
renderPosting posting =
  "  " <> accountName (postingAccount posting)
  <> "  " <> renderQuantity (amountQuantity amount)
  <> " " <> commodityCode (amountCommodity amount)
  where
    amount = postingAmount posting

appendBlock :: Text -> Text -> Text
appendBlock existing block
  | T.null existing = block
  | T.last existing == '\n' = existing <> "\n" <> block
  | otherwise = existing <> "\n\n" <> block
