-- | Pure comparison between an externally observed Account balance and the
-- canonical ledger balance at the same day.
--
-- External observations are evidence for comparison only. They are not Journal
-- facts, do not alter canonical Actual, and carry no writer authority.
module HKernel.Account.Reconciliation
  ( ExternalBalanceObservation
  , observeExternalBalance
  , externalBalanceAccount
  , externalBalanceObservedOn
  , externalBalanceValue
  , AccountReconciliation
  , reconcileAccountBalance
  , reconciliationExternalObservation
  , reconciliationLedgerBalance
  , reconciliationDifference
  , reconciliationMatches
  ) where

import Data.Time.Calendar (Day)
import HKernel.Account (Account)
import HKernel.Engine
  ( accountBalance
  , accountBalancesThrough
  )
import HKernel.Journal (Journal)
import HKernel.Money
  ( Balance
  , isZeroBalance
  , subtractBalance
  )

-- | One balance observed outside the canonical ledger.
--
-- The source may be a human reading a bank/wallet application today or a future
-- statement adapter. Keeping this value distinct prevents reconciliation
-- evidence from masquerading as an accounting fact.
data ExternalBalanceObservation = ExternalBalanceObservation
  { externalBalanceAccount    :: Account
  , externalBalanceObservedOn :: Day
  , externalBalanceValue      :: Balance
  } deriving (Eq, Show)

observeExternalBalance
  :: Account
  -> Day
  -> Balance
  -> ExternalBalanceObservation
observeExternalBalance = ExternalBalanceObservation

-- | Comparison result for exactly one Account and observation day.
--
-- Difference is deliberately @external - ledger@. A positive coordinate means
-- the external source contains more than the canonical ledger for that
-- commodity; a negative coordinate means the ledger contains more.
data AccountReconciliation = AccountReconciliation
  { reconciliationExternalObservation :: ExternalBalanceObservation
  , reconciliationLedgerBalance       :: Balance
  , reconciliationDifference          :: Balance
  } deriving (Eq, Show)

reconcileAccountBalance
  :: Journal
  -> ExternalBalanceObservation
  -> AccountReconciliation
reconcileAccountBalance journal external =
  AccountReconciliation
    { reconciliationExternalObservation = external
    , reconciliationLedgerBalance = ledgerBalance
    , reconciliationDifference =
        externalBalanceValue external `subtractBalance` ledgerBalance
    }
  where
    ledgerBalance = accountBalance
      (externalBalanceAccount external)
      (accountBalancesThrough (externalBalanceObservedOn external) journal)

reconciliationMatches :: AccountReconciliation -> Bool
reconciliationMatches = isZeroBalance . reconciliationDifference
