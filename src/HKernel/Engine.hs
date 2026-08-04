-- | Pure, currency-safe accounting queries over validated journals.
--
-- This public module is the stable facade. Canonical fact preparation remains
-- internal so its representation can evolve without widening the library API.
module HKernel.Engine
  ( LedgerEntry(..)
  , journalEntries
  , DateRange
  , DateRangeError(..)
  , mkDateRange
  , rangeStart
  , rangeEnd
  , entriesInRange
  , entriesThrough
  , AccountBalances
  , accountBalances
  , accountBalancesInRange
  , accountBalancesThrough
  , accountBalance
  , accountBalanceEntries
  , accountsWithin
  , journalBalance
  ) where

import HKernel.Engine.Facts
