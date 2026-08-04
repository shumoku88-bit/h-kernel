-- | A small, typed sparse matrix for exact accounting balances.
--
-- The matrix owns only coordinate aggregation. Report-specific meaning,
-- filtering, presentation, and derived accounting totals remain in their
-- named report models.
module HKernel.Report.Matrix
  ( BalanceMatrix
  , BalanceRow(..)
  , emptyBalanceMatrix
  , singletonBalanceMatrix
  , balanceMatrixFromCoordinates
  , balanceMatrixRows
  , balanceMatrixColumnTotal
  , balanceRowAt
  , balanceRowTotal
  , balanceRowIsZero
  ) where

import qualified Data.Foldable as Foldable
import qualified Data.Map.Strict as Map
import HKernel.Money

-- | A sparse matrix whose row and column axes are carried by their types.
newtype BalanceMatrix row column = BalanceMatrix
  (Map.Map row (Map.Map column Balance))
  deriving (Eq, Show)

-- | One row projected from a 'BalanceMatrix'.
data BalanceRow row column = BalanceRow
  { balanceRowKey   :: row
  , balanceRowCells :: Map.Map column Balance
  } deriving (Eq, Show)

instance (Ord row, Ord column) => Semigroup (BalanceMatrix row column) where
  BalanceMatrix left <> BalanceMatrix right = BalanceMatrix
    (Map.unionWith (Map.unionWith (<>)) left right)

instance (Ord row, Ord column) => Monoid (BalanceMatrix row column) where
  mempty = emptyBalanceMatrix

emptyBalanceMatrix :: BalanceMatrix row column
emptyBalanceMatrix = BalanceMatrix Map.empty

-- | Place one exact balance at one typed coordinate.
singletonBalanceMatrix
  :: row
  -> column
  -> Balance
  -> BalanceMatrix row column
singletonBalanceMatrix row column balance = BalanceMatrix
  (Map.singleton row (Map.singleton column balance))

-- | Aggregate coordinates without exposing insertion order or mutation.
balanceMatrixFromCoordinates
  :: (Foldable f, Ord row, Ord column)
  => f (row, column, Balance)
  -> BalanceMatrix row column
balanceMatrixFromCoordinates = Foldable.foldMap toSingleton
  where
    toSingleton (row, column, balance) =
      singletonBalanceMatrix row column balance

-- | Project rows in ascending row-key order.
balanceMatrixRows
  :: BalanceMatrix row column
  -> [BalanceRow row column]
balanceMatrixRows (BalanceMatrix rows) =
  map (uncurry BalanceRow) (Map.toAscList rows)

-- | Derive one column total across every row.
balanceMatrixColumnTotal
  :: Ord column
  => column
  -> BalanceMatrix row column
  -> Balance
balanceMatrixColumnTotal column (BalanceMatrix rows) =
  Foldable.foldMap
    (Map.findWithDefault mempty column)
    (Map.elems rows)

-- | Read one cell, using the canonical empty balance for a sparse absence.
balanceRowAt :: Ord column => column -> BalanceRow row column -> Balance
balanceRowAt column =
  Map.findWithDefault mempty column . balanceRowCells

-- | Derive a row total without storing a second source of truth.
balanceRowTotal :: BalanceRow row column -> Balance
balanceRowTotal = Foldable.fold . Map.elems . balanceRowCells

-- | Test whether every retained coordinate in a row is zero.
balanceRowIsZero :: BalanceRow row column -> Bool
balanceRowIsZero = all isZeroBalance . Map.elems . balanceRowCells
