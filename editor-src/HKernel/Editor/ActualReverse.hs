{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.ActualReverse
  ( ActualReverseIntent(..)
  , ActualReverseError(..)
  , ActualReversePreview(..)
  , prepareActualReverse
  , prepareActualReverseFromResolvedJournal
  , ActualReverseInput(..)
  , ActualReverseInputError(..)
  , ActualReverseInputPreview(..)
  , buildActualReverseIntent
  , suggestActualReverseEventIdText
  , prepareActualReverseInputFromResolvedJournal
  ) where

import Data.Bifunctor (first)
import qualified Data.Foldable as Foldable
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)

import HKernel.Account (accountName)
import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalIdentifiedTransactions
  , actualJournalReversalDeclarations
  , actualJournalValue
  , admitActualJournalFromResolvedJournal
  , parseActualJournal
  , reversedTransactionId
  , reversalTransactionId
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Journal (Journal, appendJournalTransaction)
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
  , mkActualTransactionId
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

-- | Delivery-neutral text input for a selected reversal target. The target
-- identity itself is intentionally not free-form text: a delivery adapter must
-- obtain it from an admitted Actual transaction entry.
data ActualReverseInput = ActualReverseInput
  { reverseInputEventIdText     :: Text
  , reverseInputDateText        :: Text
  , reverseInputDescriptionText :: Text
  } deriving (Eq, Show)

data ActualReverseInputError
  = ActualReverseInvalidEventId
  | ActualReverseInvalidDate
  deriving (Eq, Show)

data ActualReverseInputPreview
  = ActualReverseInputRejected ActualReverseInputError
  | ActualReverseCandidateRejected (NonEmpty ActualReverseError)
  | ActualReverseCandidateReady Text
  deriving (Eq, Show)

buildActualReverseIntent
  :: ActualTransactionId
  -> ActualReverseInput
  -> Either ActualReverseInputError ActualReverseIntent
buildActualReverseIntent targetId input = do
  reversalId <- first (const ActualReverseInvalidEventId)
    (mkActualTransactionId (reverseInputEventIdText input))
  date <- maybe (Left ActualReverseInvalidDate) Right
    (parseDayText (reverseInputDateText input))
  pure ActualReverseIntent
    { reverseEventId = reversalId
    , reverseTargetId = targetId
    , reverseDate = date
    , reverseDescription = reverseInputDescriptionText input
    }

-- | Suggest a valid, source-local reversal identity without asking a delivery
-- surface to expose identity bookkeeping to the person using it. Domain
-- admission remains authoritative: this is only a collision-avoiding default.
suggestActualReverseEventIdText
  :: [ActualTransactionId]
  -> ActualTransactionId
  -> Text
suggestActualReverseEventIdText existingIds targetId = go 1
  where
    used = Set.fromList (map actualTransactionIdText existingIds)
    stem = actualTransactionIdText targetId <> "-reversal"

    candidate :: Int -> Text
    candidate 1 = stem
    candidate index = stem <> "-" <> T.pack (show index)

    go :: Int -> Text
    go index
      | candidate index `Set.member` used = go (index + 1)
      | otherwise = candidate index

prepareActualReverseInputFromResolvedJournal
  :: Journal
  -> Text
  -> ActualTransactionId
  -> ActualReverseInput
  -> ActualReverseInputPreview
prepareActualReverseInputFromResolvedJournal resolvedJournal source targetId input =
  case buildActualReverseIntent targetId input of
    Left inputError -> ActualReverseInputRejected inputError
    Right intent -> case prepareActualReverseFromResolvedJournal
        resolvedJournal source intent of
      Left sourceErrors -> ActualReverseCandidateRejected sourceErrors
      Right preview -> ActualReverseCandidateReady (candidateBlock preview)

prepareActualReverse
  :: Text
  -> ActualReverseIntent
  -> Either (NonEmpty ActualReverseError) ActualReversePreview
prepareActualReverse existingSource intent = do
  journal <- parseSource existingSource
  prepareActualReverseFromJournal journal existingSource intent

-- | Prepare a reversal against the resolved Actual Journal. Durable identity
-- and reversal provenance remain owned by Actual root metadata.
prepareActualReverseFromResolvedJournal
  :: Journal
  -> Text
  -> ActualReverseIntent
  -> Either (NonEmpty ActualReverseError) ActualReversePreview
prepareActualReverseFromResolvedJournal resolvedJournal existingSource intent = do
  journal <- first (pure . SourceParseError)
    (admitActualJournalFromResolvedJournal resolvedJournal existingSource)
  prepareActualReverseFromJournal journal existingSource intent

prepareActualReverseFromJournal
  :: ActualJournal
  -> Text
  -> ActualReverseIntent
  -> Either (NonEmpty ActualReverseError) ActualReversePreview
prepareActualReverseFromJournal journal existingSource intent = do
  ensureNewIdentity (reverseEventId intent) journal
  targetTxn <- findTargetTransaction (reverseTargetId intent) journal
  ensureTargetNotReversed (reverseTargetId intent) journal
  newTxn <- reverseTransaction intent targetTxn

  let preview = buildPreview existingSource newTxn intent
      candidateJournal = appendJournalTransaction
        newTxn
        (actualJournalValue journal)

  _ <- first (pure . CandidateSourceParseError)
    (admitActualJournalFromResolvedJournal
      candidateJournal
      (candidateCompleteSource preview))
  pure preview

parseSource :: Text -> Either (NonEmpty ActualReverseError) ActualJournal
parseSource = first (pure . SourceParseError) . parseActualJournal

parseDayText :: Text -> Maybe Day
parseDayText = parseTimeM True defaultTimeLocale "%Y-%m-%d" . T.unpack

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
