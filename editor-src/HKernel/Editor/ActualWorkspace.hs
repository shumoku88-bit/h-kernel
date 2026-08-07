-- | Pure projection for the Actual transaction workspace.
--
-- Delivery adapters choose how an Account is selected and how transactions are
-- presented. This module owns only the meaning of applying an optional Account
-- filter to admitted Actual transactions.
module HKernel.Editor.ActualWorkspace
  ( transactionsForAccount
  ) where

import qualified Data.List.NonEmpty as NonEmpty

import HKernel.Account (Account)
import HKernel.Ledger
  ( Transaction
  , postingAccount
  , transactionPostings
  )

transactionsForAccount :: Maybe Account -> [Transaction] -> [Transaction]
transactionsForAccount Nothing = id
transactionsForAccount (Just selectedAccount) =
  filter
    (any
      ((== selectedAccount) . postingAccount)
      . NonEmpty.toList
      . transactionPostings)
