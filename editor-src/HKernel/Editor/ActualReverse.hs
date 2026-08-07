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
  , actualJournalReversalDeclarations
  , parseActualJournal
  , reversedTransactionId
  , reversalTransactionId
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
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
  ( amountCommodity
  , amountQuantity
  , commodityCode
  , negateAmount
  , renderQuantity
  )
import HKernel.Plan.Completion
  ( ActualTransactionId
  , actualTransactionIdText
  , identifiedActualId
  , identifiedActualTransaction
  )

-- | A request to append one identified reversing transaction.
data ActualReverseIntent = ActualReverseIntent
  { reverseEventId     :: ActualTransactionId
  , reverseTargetId    :: ActualTransactionId
  , reverseDate        :: Day
  , reverseDescription :: Text
  } deriving (Eq, Show)

data ActualReverseError
  = TargetNotFound ActualTransactionId
  | ReversalIdAlreadyExists ActualTransactionId
  | TargetAlreadyReversed ActualTransactionId ActualTransactionId
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
  ensureNewIdentity (reverseEventId intent) journal
  targetTxn <- findTargetTransaction (reverseTargetId intent) journal
  ensureTargetNotReversed (reverseTargetId intent) journal
  newTxn <- reverseTransaction intent targetTxn

  let preview = buildPreview existingSource newTxn intent

  _ <- first (pure . CandidateSourceParseError)
    (parseActualJournal (candidateCompleteSource preview))
  pure preview

parseSource :: Text -> Either (NonEmpty ActualReverseError) ActualJournal
parseSource = first (pure . SourceParseError) . parseActualJournal

ensureNewIdentity
  :: ActualTransactionId
  -> ActualJournal
  -> Either (NonEmpty ActualReverseError) ()
ensureNewIdentity newId journal =
  case Foldable.find
    ((== newId) . identifiedActualId)
    (actualJournalIdentifiedTransactions journal) of
      Nothing -> Right ()
      Just _ -> Left (ReversalIdAlreadyExists newId NonEmpty.:| [])

findTargetTransaction
  :: ActualTransactionId
  -> ActualJournal
  -> Either (NonEmpty ActualReverseError) Transaction
findTargetTransaction targetId journal =
  maybe
    (Left (TargetNotFound targetId NonEmpty.:| []))
    (Right . identifiedActualTransaction)
    (Foldable.find
      ((== targetId) . identifiedActualId)
      (actualJournalIdentifiedTransactions journal))

ensureTargetNotReversed
  :: ActualTransactionId
  -> ActualJournal
  -> Either (NonEmpty ActualReverseError) ()
ensureTargetNotReversed targetId journal =
  case Foldable.find
    ((== targetId) . reversedTransactionId)
    (actualJournalReversalDeclarations journal) of
      Nothing -> Right ()
      Just declaration -> Left
        (TargetAlreadyReversed
          targetId
          (reversalTransactionId declaration)
          NonEmpty.:| [])

reverseTransaction
  :: ActualReverseIntent
  -> Transaction
  -> Either (NonEmpty ActualReverseError) Transaction
reverseTransaction intent targetTxn =
  first (pure . ValidationError) $
    mkTransaction
      (reverseDate intent)
      (reverseDescription intent)
      (reversePosting <$> transactionPostings targetTxn)

buildPreview
  :: Text
  -> Transaction
  -> ActualReverseIntent
  -> ActualReversePreview
buildPreview existingSource newTxn intent =
  ActualReversePreview
    { candidateBlock = block
    , candidateCompleteSource =
        appendSourceBlock existingSource (SourceBlock block)
    }
  where
    block = renderReverseTransaction newTxn intent

reversePosting :: Posting -> Posting
reversePosting posting =
  mkPosting (postingAccount posting) (negateAmount (postingAmount posting))

renderReverseTransaction :: Transaction -> ActualReverseIntent -> Text
renderReverseTransaction transaction intent =
  T.pack
    (formatTime defaultTimeLocale "%Y-%m-%d" (transactionDate transaction))
  <> " " <> transactionDescription transaction <> "\n"
  <> "  ; event-id: "
  <> actualTransactionIdText (reverseEventId intent)
  <> "\n"
  <> "  ; reverses: "
  <> actualTransactionIdText (reverseTargetId intent)
  <> "\n"
  <> T.intercalate "\n"
      (map renderPosting (NonEmpty.toList (transactionPostings transaction)))
  <> "\n"

renderPosting :: Posting -> Text
renderPosting posting =
  "  " <> accountName (postingAccount posting)
  <> "  " <> renderQuantity (amountQuantity amount)
  <> " " <> commodityCode (amountCommodity amount)
  where
    amount = postingAmount posting
