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

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
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

-- | A validated transaction. The constructor is hidden so an unbalanced
-- transaction cannot enter the rest of the accounting engine.
data Transaction = Transaction
  { transactionDate        :: Day
  , transactionDescription :: Text
  , transactionPostings    :: NonEmpty Posting
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
  | postingCount < 2             = Left (TooFewPostings postingCount)
  | not (isZeroBalance balance)  = Left (UnbalancedTransaction balance)
  | otherwise                    = Right (Transaction date description postings)
  where
    postingCount = NonEmpty.length postings
    balance = postingCollectionBalance postings

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
