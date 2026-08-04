{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.ActualAppend
  ( ActualEditIntent(..)
  , IntentPosting(..)
  , ActualEditError(..)
  , ActualAppendPreview(..)
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
  ( ActualJournalError
  , actualJournalValue
  , parseActualJournal
  )
import HKernel.Journal
  ( journalAccountRegistry
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
  } deriving (Eq, Show)

data IntentPosting = IntentPosting
  { intentAccount   :: Account
  , intentQuantity  :: Quantity
  , intentCommodity :: Maybe Commodity
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
  actualJournal <- first (pure . SourceParseError) (parseActualJournal existingSource)

  let registry = journalAccountRegistry (actualJournalValue actualJournal)
  
  postings <- case partitionEithers (NonEmpty.toList (fmap (resolvePosting registry) (intentPostings intent))) of
    (err:errs, _) -> Left (err NonEmpty.:| errs)
    ([], validPostings) -> pure (NonEmpty.fromList validPostings)

  transaction <- first (pure . ValidationError) $
    mkTransaction (intentDate intent) (intentDescription intent) postings

  let block = renderTransaction transaction
  let candidateSource = appendBlock existingSource block

  _ <- first (pure . CandidateSourceParseError) (parseActualJournal candidateSource)

  pure (ActualAppendPreview block candidateSource)

resolvePosting
  :: AccountRegistry
  -> IntentPosting
  -> Either ActualEditError Posting
resolvePosting registry (IntentPosting acc qty mComm) = do
  when (isZeroQuantity qty) (Left (ZeroAmount acc))

  decl <- maybe (Left (UndeclaredAccount acc)) pure (lookupAccountDeclaration acc registry)

  let effectiveComm = mComm <|> declaredAccountDefaultCommodity decl
  commodity <- maybe (Left (MissingCommodity acc)) pure effectiveComm

  pure (mkPosting acc (mkAmount commodity qty))

renderTransaction :: Transaction -> Text
renderTransaction txn =
  T.pack (formatTime defaultTimeLocale "%Y-%m-%d" (transactionDate txn))
  <> " " <> transactionDescription txn <> "\n"
  <> T.intercalate "\n" (map renderPosting (NonEmpty.toList (transactionPostings txn)))
  <> "\n"

renderPosting :: Posting -> Text
renderPosting p =
  "  " <> accountName (postingAccount p)
  <> "  " <> renderQuantity (amountQuantity amount)
  <> " " <> commodityCode (amountCommodity amount)
  where
    amount = postingAmount p

appendBlock :: Text -> Text -> Text
appendBlock existing block
  | T.null existing = block
  | T.last existing == '\n' = existing <> "\n" <> block
  | otherwise = existing <> "\n\n" <> block
