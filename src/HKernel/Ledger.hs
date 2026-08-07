{-# LANGUAGE OverloadedStrings #-}

-- | Validated double-entry ledger primitives.
--
-- A 'Transaction' can only be constructed when every commodity balances to
-- zero independently. This prevents an amount in one currency from silently
-- cancelling an amount in another currency.
module HKernel.Ledger
  ( Account
  , AccountError(..)
  , mkAccount
  , accountName
  , Posting
  , mkPosting
  , postingAccount
  , postingAmount
  , Transaction
  , TransactionError(..)
  , mkTransaction
  , transactionDate
  , transactionDescription
  , transactionPostings
  , transactionBalance
  ) where

import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import HKernel.Account
import HKernel.Money

-- | One account movement in exactly one commodity.
data Posting = Posting
  { postingAccount :: Account
  , postingAmount  :: Amount
  } deriving (Eq, Show)

mkPosting :: Account -> Amount -> Posting
mkPosting = Posting

-- | A structurally non-empty posting collection with at least two entries.
-- The constructor stays private so every accepted 'Transaction' carries the
-- double-entry minimum in its representation, not only as a checked runtime
-- condition.
data Postings = Postings Posting Posting [Posting]
  deriving (Eq, Show)

postingsFromNonEmpty :: NonEmpty Posting -> Either TransactionError Postings
postingsFromNonEmpty (_ :| []) = Left (TooFewPostings 1)
postingsFromNonEmpty (first :| second : rest) =
  Right (Postings first second rest)

postingsToNonEmpty :: Postings -> NonEmpty Posting
postingsToNonEmpty (Postings first second rest) =
  first :| (second : rest)

-- | A validated transaction. The constructor is hidden so an unbalanced
-- transaction cannot enter the rest of the accounting engine. Its internal
-- 'Postings' value also guarantees that a validated transaction contains at
-- least two postings.
data Transaction = Transaction
  { transactionDate        :: Day
  , transactionDescription :: Text
  , transactionPostingSet  :: Postings
  } deriving (Eq, Show)

data TransactionError
  = EmptyTransactionDescription
  | TooFewPostings Int
  | UnbalancedTransaction Balance
  deriving (Eq, Show)

-- | Construct a transaction after checking its structural and accounting
-- invariants. Every commodity must independently sum to zero.
mkTransaction
  :: Day
  -> Text
  -> NonEmpty Posting
  -> Either TransactionError Transaction
mkTransaction date description postings
  | T.null (T.strip description) = Left EmptyTransactionDescription
  | otherwise = do
      checkedPostings <- postingsFromNonEmpty postings
      let balance = postingCollectionBalance (postingsToNonEmpty checkedPostings)
      if isZeroBalance balance
        then Right (Transaction date description checkedPostings)
        else Left (UnbalancedTransaction balance)

-- | Observe validated postings in their original order. The public projection
-- remains 'NonEmpty' for compatibility; the 'Transaction' representation is
-- stronger and always contains at least two entries.
transactionPostings :: Transaction -> NonEmpty Posting
transactionPostings = postingsToNonEmpty . transactionPostingSet

-- | Recalculate the per-commodity balance of a validated transaction.
-- This is always zero, but exposing the calculation is useful for auditing and
-- for stating the invariant in tests.
transactionBalance :: Transaction -> Balance
transactionBalance = postingCollectionBalance . transactionPostings

-- | Lift each Posting amount into the Balance monoid and combine the
-- collection. Posting order remains available on the Transaction itself; this
-- projection deliberately forgets order because balance addition is
-- commutative.
postingCollectionBalance :: Foldable f => f Posting -> Balance
postingCollectionBalance =
  foldMap (singletonBalance . postingAmount)
