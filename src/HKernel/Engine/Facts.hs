-- | Canonical accounting facts prepared once from a validated journal.
--
-- This module is internal. 'HKernel.Engine' remains the public query facade;
-- report construction may share an 'AccountingFacts' value without publishing
-- its still-evolving representation as part of the library API.
module HKernel.Engine.Facts
  ( LedgerEntry(..)
  , journalEntries
  , AccountingFacts
  , prepareAccountingFacts
  , accountingFactsEntries
  , accountingFactsRegistry
  , accountingFactsTransactions
  , DateRange
  , DateRangeError(..)
  , mkDateRange
  , rangeStart
  , rangeEnd
  , entriesInRange
  , entriesThrough
  , entriesInRangeFacts
  , entriesThroughFacts
  , AccountBalances
  , accountBalances
  , accountBalancesInRange
  , accountBalancesThrough
  , accountBalancesFacts
  , accountBalancesInRangeFacts
  , accountBalancesThroughFacts
  , accountBalancesFromEntries
  , accountBalance
  , accountBalanceEntries
  , accountsWithin
  , journalBalance
  ) where

import qualified Data.Foldable as Foldable
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import HKernel.Account (AccountRegistry)
import HKernel.Journal
  ( Journal
  , journalAccountRegistry
  , journalTransactions
  )
import HKernel.Ledger
import HKernel.Money

-- | A posting together with context inherited from its transaction.
data LedgerEntry = LedgerEntry
  { entryDate        :: Day
  , entryDescription :: Text
  , entryAccount     :: Account
  , entryAmount      :: Amount
  } deriving (Eq, Show)

-- | Report-neutral facts retained from one validated journal preparation.
--
-- Entries preserve posting grain, while transactions remain available for
-- reports whose semantic grain is the whole transaction. The account registry
-- remains the single source of declared account meaning.
data AccountingFacts = AccountingFacts
  { accountingFactsEntries      :: [LedgerEntry]
  , accountingFactsRegistry     :: AccountRegistry
  , accountingFactsTransactions :: [Transaction]
  }

prepareAccountingFacts :: Journal -> AccountingFacts
prepareAccountingFacts journal = AccountingFacts
  { accountingFactsEntries = concatMap transactionEntries transactions
  , accountingFactsRegistry = journalAccountRegistry journal
  , accountingFactsTransactions = transactions
  }
  where
    transactions = journalTransactions journal

    transactionEntries transaction =
      [ LedgerEntry
          { entryDate = transactionDate transaction
          , entryDescription = transactionDescription transaction
          , entryAccount = postingAccount posting
          , entryAmount = postingAmount posting
          }
      | posting <- NonEmpty.toList (transactionPostings transaction)
      ]

journalEntries :: Journal -> [LedgerEntry]
journalEntries = accountingFactsEntries . prepareAccountingFacts

data DateRange = DateRange
  { rangeStart :: Day
  , rangeEnd   :: Day
  } deriving (Eq, Show)

data DateRangeError = RangeStartsAfterEnd
  { invalidRangeStart :: Day
  , invalidRangeEnd   :: Day
  } deriving (Eq, Show)

mkDateRange :: Day -> Day -> Either DateRangeError DateRange
mkDateRange start end
  | start <= end = Right (DateRange start end)
  | otherwise    = Left (RangeStartsAfterEnd start end)

entriesInRange :: DateRange -> Journal -> [LedgerEntry]
entriesInRange dateRange =
  entriesInRangeFacts dateRange . prepareAccountingFacts

entriesThrough :: Day -> Journal -> [LedgerEntry]
entriesThrough day = entriesThroughFacts day . prepareAccountingFacts

entriesInRangeFacts :: DateRange -> AccountingFacts -> [LedgerEntry]
entriesInRangeFacts dateRange = filter within . accountingFactsEntries
  where
    within entry =
      entryDate entry >= rangeStart dateRange
        && entryDate entry <= rangeEnd dateRange

entriesThroughFacts :: Day -> AccountingFacts -> [LedgerEntry]
entriesThroughFacts day =
  filter ((<= day) . entryDate) . accountingFactsEntries

-- | Per-account balances. Each account can itself contain several currencies.
-- Accounts whose balance reaches zero are removed from the canonical map.
newtype AccountBalances = AccountBalances (Map Account Balance)
  deriving (Eq, Show)

accountBalances :: Journal -> AccountBalances
accountBalances = accountBalancesFacts . prepareAccountingFacts

accountBalancesInRange :: DateRange -> Journal -> AccountBalances
accountBalancesInRange dateRange =
  accountBalancesInRangeFacts dateRange . prepareAccountingFacts

accountBalancesThrough :: Day -> Journal -> AccountBalances
accountBalancesThrough day =
  accountBalancesThroughFacts day . prepareAccountingFacts

accountBalancesFacts :: AccountingFacts -> AccountBalances
accountBalancesFacts = accountBalancesFromEntries . accountingFactsEntries

accountBalancesInRangeFacts
  :: DateRange
  -> AccountingFacts
  -> AccountBalances
accountBalancesInRangeFacts dateRange =
  accountBalancesFromEntries . entriesInRangeFacts dateRange

accountBalancesThroughFacts :: Day -> AccountingFacts -> AccountBalances
accountBalancesThroughFacts day =
  accountBalancesFromEntries . entriesThroughFacts day

-- | Reduce selected posting-grain facts into canonical per-account balances.
--
-- This remains internal so reports can select their own semantic coordinates
-- while sharing one exact account reduction and one canonical zero rule.
accountBalancesFromEntries
  :: Foldable collection
  => collection LedgerEntry
  -> AccountBalances
accountBalancesFromEntries = AccountBalances . Foldable.foldl' addEntry Map.empty
  where
    addEntry balances entry =
      Map.alter (update (entryAmount entry)) (entryAccount entry) balances

    update amount current =
      let newBalance = addBalance
            (maybe emptyBalance id current)
            (singletonBalance amount)
      in if isZeroBalance newBalance then Nothing else Just newBalance

accountBalance :: Account -> AccountBalances -> Balance
accountBalance account (AccountBalances balances) =
  Map.findWithDefault emptyBalance account balances

accountBalanceEntries :: AccountBalances -> [(Account, Balance)]
accountBalanceEntries (AccountBalances balances) = Map.toAscList balances

-- | Restrict balances to an account and its descendants. Matching respects
-- account segment boundaries: @assets@ matches @assets:cash@ but not
-- @assets-old@.
accountsWithin :: Account -> AccountBalances -> AccountBalances
accountsWithin parent (AccountBalances balances) =
  AccountBalances (Map.filterWithKey (\account _ -> isWithin parent account) balances)

-- | Sum every posting in a journal without discarding commodity information.
-- For a journal made only from validated transactions this is always zero.
journalBalance :: Journal -> Balance
journalBalance = balanceFacts . prepareAccountingFacts

-- | Journal-wide balance is a commutative projection of posting-grain facts.
-- Entry order remains available in 'AccountingFacts'; this projection only
-- forgets order because the target Balance monoid has no sequencing meaning.
balanceFacts :: AccountingFacts -> Balance
balanceFacts =
  Foldable.foldMap (singletonBalance . entryAmount)
    . accountingFactsEntries

isWithin :: Account -> Account -> Bool
isWithin parent candidate =
  candidateName == parentName
    || T.snoc parentName ':' `T.isPrefixOf` candidateName
  where
    parentName = accountName parent
    candidateName = accountName candidate
