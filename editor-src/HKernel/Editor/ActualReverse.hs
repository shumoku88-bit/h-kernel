{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.ActualReverse
  ( ActualReverseIntent(..)
  , ActualReverseError(..)
  , ActualReversePreview(..)
  , prepareActualReverse
  ) where

import Data.Bifunctor (first)
import qualified Data.Foldable as Foldable
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Account (accountName)
import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalIdentifiedTransactions
  , parseActualJournal
  )
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
  ( negateAmount
  , renderQuantity
  , commodityCode
  , amountQuantity
  , amountCommodity
  )
import HKernel.Plan.Completion
  ( ActualTransactionId
  , actualTransactionIdText
  , identifiedActualId
  , identifiedActualTransaction
  )
import HKernel.Editor.ActualAppend
  ( appendBlock
  )

-- | A request to append a reversing transaction.
data ActualReverseIntent = ActualReverseIntent
  { reverseTargetId    :: ActualTransactionId
  , reverseDate        :: Day
  , reverseDescription :: Text
  } deriving (Eq, Show)

data ActualReverseError
  = TargetNotFound ActualTransactionId
  | SourceParseError (NonEmpty ActualJournalError)
  | CandidateSourceParseError (NonEmpty ActualJournalError)
  | ValidationError TransactionError
  deriving (Eq, Show)

data ActualReversePreview = ActualReversePreview
  { candidateBlock          :: Text
  , candidateCompleteSource :: Text
  } deriving (Eq, Show)

prepareActualReverse
  :: Text
  -> ActualReverseIntent
  -> Either (NonEmpty ActualReverseError) ActualReversePreview
prepareActualReverse existingSource intent = do
  journal <- parseSource existingSource
  targetTxn <- findTargetTransaction (reverseTargetId intent) journal
  newTxn <- reverseTransaction intent targetTxn
  
  let preview = buildPreview existingSource newTxn (reverseTargetId intent)
  
  _ <- first (pure . CandidateSourceParseError) (parseActualJournal (candidateCompleteSource preview))
  pure preview

parseSource :: Text -> Either (NonEmpty ActualReverseError) ActualJournal
parseSource = first (pure . SourceParseError) . parseActualJournal

findTargetTransaction :: ActualTransactionId -> ActualJournal -> Either (NonEmpty ActualReverseError) Transaction
findTargetTransaction targetId journal =
  maybe (Left (TargetNotFound targetId NonEmpty.:| [])) (Right . identifiedActualTransaction) $
    Foldable.find (\it -> identifiedActualId it == targetId) (actualJournalIdentifiedTransactions journal)

reverseTransaction :: ActualReverseIntent -> Transaction -> Either (NonEmpty ActualReverseError) Transaction
reverseTransaction intent targetTxn =
  first (pure . ValidationError) $
    mkTransaction
      (reverseDate intent)
      (reverseDescription intent)
      (reversePosting <$> transactionPostings targetTxn)

buildPreview :: Text -> Transaction -> ActualTransactionId -> ActualReversePreview
buildPreview existingSource newTxn targetId =
  ActualReversePreview
    { candidateBlock = block
    , candidateCompleteSource = appendBlock existingSource block
    }
  where
    block = renderReverseTransaction newTxn targetId

reversePosting :: Posting -> Posting
reversePosting p = mkPosting (postingAccount p) (negateAmount (postingAmount p))

renderReverseTransaction :: Transaction -> ActualTransactionId -> Text
renderReverseTransaction txn targetId =
  T.pack (formatTime defaultTimeLocale "%Y-%m-%d" (transactionDate txn))
  <> " " <> transactionDescription txn <> "\n"
  <> "  ; reverses: " <> actualTransactionIdText targetId <> "\n"
  <> T.intercalate "\n" (map renderPosting (NonEmpty.toList (transactionPostings txn)))
  <> "\n"

renderPosting :: Posting -> Text
renderPosting p =
  "  " <> accountName (postingAccount p)
  <> "  " <> renderQuantity (amountQuantity amount)
  <> " " <> commodityCode (amountCommodity amount)
  where
    amount = postingAmount p
