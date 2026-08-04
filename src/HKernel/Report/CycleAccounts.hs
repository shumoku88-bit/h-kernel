-- | Exact Expense-account movement compared across two explicit periods.
--
-- This report owns only the semantic comparison. It does not infer cycle
-- boundaries, resolve recurring rules, render a terminal table, inspect Plan or
-- budget policy, or convert commodities. Accounts are aligned by their full
-- typed identity before exact current, previous, and delta balances are
-- published.
module HKernel.Report.CycleAccounts
  ( CycleAccountRow(..)
  , cycleAccountRowDelta
  , CycleAccounts(..)
  , cycleAccountsCurrentTotal
  , cycleAccountsPreviousTotal
  , cycleAccountsDeltaTotal
  , cycleAccounts
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import HKernel.Account
  ( Account
  , AccountType(..)
  , accountTypeFor
  )
import HKernel.Engine
  ( AccountBalances
  , LedgerEntry(..)
  , accountBalance
  , accountBalanceEntries
  , journalEntries
  )
import HKernel.Engine.Facts
  ( accountBalancesFromEntries
  )
import HKernel.Journal
  ( Journal
  , journalAccountRegistry
  )
import HKernel.Money
  ( Balance
  , subtractBalance
  , sumBalances
  )
import HKernel.Period
  ( Period
  , periodContains
  )

-- | One Expense-account coordinate aligned across the two selected periods.
--
-- A canonical empty balance is retained when the account appears in only one
-- period. Delta is derived so it cannot disagree with the two source balances.
data CycleAccountRow = CycleAccountRow
  { cycleAccountRowAccount  :: Account
  , cycleAccountRowCurrent  :: Balance
  , cycleAccountRowPrevious :: Balance
  } deriving (Eq, Show)

cycleAccountRowDelta :: CycleAccountRow -> Balance
cycleAccountRowDelta row =
  subtractBalance
    (cycleAccountRowCurrent row)
    (cycleAccountRowPrevious row)

-- | Exact Expense movement for one current and one previous observation period.
--
-- Declared non-Expense accounts are deliberately outside this report.
-- Programmatically constructed undeclared accounts remain visible as separate
-- evidence instead of being classified from their names.
data CycleAccounts = CycleAccounts
  { cycleAccountsCurrentPeriod     :: Period
  , cycleAccountsPreviousPeriod    :: Period
  , cycleAccountsRows              :: [CycleAccountRow]
  , cycleAccountsUnclassifiedRows  :: [CycleAccountRow]
  } deriving (Eq, Show)

cycleAccountsCurrentTotal :: CycleAccounts -> Balance
cycleAccountsCurrentTotal =
  sumBalances . map cycleAccountRowCurrent . cycleAccountsRows

cycleAccountsPreviousTotal :: CycleAccounts -> Balance
cycleAccountsPreviousTotal =
  sumBalances . map cycleAccountRowPrevious . cycleAccountsRows

cycleAccountsDeltaTotal :: CycleAccounts -> Balance
cycleAccountsDeltaTotal report =
  subtractBalance
    (cycleAccountsCurrentTotal report)
    (cycleAccountsPreviousTotal report)

-- | Compare exact Expense-account movement across two explicit half-open periods.
--
-- The calculation has four semantic stages:
--
-- * select posting-grain facts belonging to each period,
-- * reduce both selections into canonical per-account balances,
-- * align the union of account identities observed in either period,
-- * partition declared Expense rows from undeclared evidence.
--
-- Account rows are published in canonical identity order. Commodity identity
-- remains inside each exact 'Balance'. Cycle definition, resolution, storage,
-- and selection remain outside this pure report; it receives only resolved
-- observation periods.
cycleAccounts :: Period -> Period -> Journal -> CycleAccounts
cycleAccounts currentPeriod previousPeriod journal = CycleAccounts
  { cycleAccountsCurrentPeriod = currentPeriod
  , cycleAccountsPreviousPeriod = previousPeriod
  , cycleAccountsRows = rowsWithType (Just Expense)
  , cycleAccountsUnclassifiedRows = rowsWithType Nothing
  }
  where
    registry = journalAccountRegistry journal
    currentBalances = balancesInPeriod currentPeriod journal
    previousBalances = balancesInPeriod previousPeriod journal
    alignedRows =
      [ CycleAccountRow
          { cycleAccountRowAccount = account
          , cycleAccountRowCurrent = accountBalance account currentBalances
          , cycleAccountRowPrevious = accountBalance account previousBalances
          }
      | account <- Set.toAscList
          (observedAccounts currentBalances previousBalances)
      ]
    rowsWithType accountType =
      [ row
      | row <- alignedRows
      , accountTypeFor (cycleAccountRowAccount row) registry == accountType
      ]

balancesInPeriod :: Period -> Journal -> AccountBalances
balancesInPeriod period =
  accountBalancesFromEntries
    . filter (periodContains period . entryDate)
    . journalEntries

observedAccounts :: AccountBalances -> AccountBalances -> Set Account
observedAccounts current previous =
  Set.fromList
    (map fst (accountBalanceEntries current)
      ++ map fst (accountBalanceEntries previous))
