-- | A pure, bounded view of recent validated transactions.
--
-- This report preserves whole transactions. It does not flatten them into
-- postings and then call the result a transaction report.
module HKernel.Report.RecentTransactions
  ( RecentCount
  , RecentCountError(..)
  , mkRecentCount
  , recentCountValue
  , defaultRecentCount
  , RecentTransactionBasis
  , prepareRecentTransactionBasis
  , recentTransactionsFromBasis
  , RecentTransactions
  , recentTransactionsAsOf
  , recentTransactionsCount
  , recentTransactionItems
  , recentTransactions
  ) where

import Data.List (sortOn)
import Data.Ord (Down(..))
import Data.Time.Calendar (Day)
import HKernel.Engine.Facts
  ( AccountingFacts
  , accountingFactsTransactions
  , prepareAccountingFacts
  )
import HKernel.Journal (Journal)
import HKernel.Ledger (Transaction, transactionDate)

-- | A strictly positive maximum number of transactions.
--
-- The constructor is hidden so zero and negative limits cannot enter a report.
newtype RecentCount = RecentCount Int
  deriving (Eq, Ord, Show)

data RecentCountError = RecentCountMustBePositive Int
  deriving (Eq, Show)

mkRecentCount :: Int -> Either RecentCountError RecentCount
mkRecentCount count
  | count > 0 = Right (RecentCount count)
  | otherwise = Left (RecentCountMustBePositive count)

recentCountValue :: RecentCount -> Int
recentCountValue (RecentCount count) = count

defaultRecentCount :: RecentCount
defaultRecentCount = RecentCount 5

-- | Whole-transaction facts eligible at one explicit as-of date.
--
-- The constructor stays hidden. Preparation performs the date selection and
-- stable newest-first ordering once; bounded reports then differ only by count.
data RecentTransactionBasis = RecentTransactionBasis
  { recentBasisAsOf        :: Day
  , recentBasisNewestFirst :: [Transaction]
  }

prepareRecentTransactionBasis
  :: Day
  -> AccountingFacts
  -> RecentTransactionBasis
prepareRecentTransactionBasis asOf facts = RecentTransactionBasis
  { recentBasisAsOf = asOf
  , recentBasisNewestFirst = sortOn
      (Down . transactionDate)
      eligible
  }
  where
    eligible = filter
      ((<= asOf) . transactionDate)
      (accountingFactsTransactions facts)

-- | Recent transactions as of one explicit date.
--
-- The constructor is hidden so callers cannot create a result whose items
-- exceed the requested count, lie after the as-of date, or use another order.
data RecentTransactions = RecentTransactions
  { recentTransactionsAsOf  :: Day
  , recentTransactionsCount :: RecentCount
  , recentTransactionItems  :: [Transaction]
  } deriving (Eq, Show)

recentTransactionsFromBasis
  :: RecentCount
  -> RecentTransactionBasis
  -> RecentTransactions
recentTransactionsFromBasis count basis = RecentTransactions
  { recentTransactionsAsOf = recentBasisAsOf basis
  , recentTransactionsCount = count
  , recentTransactionItems =
      take (recentCountValue count) (recentBasisNewestFirst basis)
  }

-- | Select the newest validated transactions at or before the as-of date.
--
-- Results are newest first. 'sortOn' is stable, so transactions sharing a date
-- retain their journal order rather than acquiring an arbitrary tie-breaker.
recentTransactions :: RecentCount -> Day -> Journal -> RecentTransactions
recentTransactions count asOf journal =
  recentTransactionsFromBasis
    count
    (prepareRecentTransactionBasis asOf (prepareAccountingFacts journal))
