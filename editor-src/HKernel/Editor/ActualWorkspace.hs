-- | Pure projection for the Actual transaction workspace.
--
-- Delivery adapters choose how an Account is selected and how transactions are
-- presented. This module owns only the meaning of applying an optional Account
-- filter to admitted Actual transaction entries while preserving their durable
-- identity for correction and reversal surfaces.
module HKernel.Editor.ActualWorkspace
  ( transactionEntriesForAccount
  ) where

import qualified Data.List.NonEmpty as NonEmpty

import HKernel.Account (Account)
import HKernel.Actual.Journal
  ( ActualTransactionEntry
  , actualTransactionEntryTransaction
  )
import HKernel.Ledger
  ( Transaction
  , postingAccount
  , transactionPostings
  )

transactionEntriesForAccount
  :: Maybe Account
  -> [ActualTransactionEntry]
  -> [ActualTransactionEntry]
transactionEntriesForAccount Nothing = id
transactionEntriesForAccount (Just selectedAccount) =
  filter
    (transactionMatchesAccount selectedAccount
      . actualTransactionEntryTransaction)

transactionMatchesAccount :: Account -> Transaction -> Bool
transactionMatchesAccount selectedAccount =
  any
    ((== selectedAccount) . postingAccount)
    . NonEmpty.toList
    . transactionPostings
