{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight)
import Control.Monad (unless)
import qualified Data.Foldable as Foldable
import Data.Text (Text)
import HKernel.Money
import System.Exit (exitFailure)
import Test.QuickCheck
  ( Arbitrary(..)
  , isSuccess
  , quickCheckResult
  )

-- | Three independent commodity coordinates keep every law check genuinely
-- multi-commodity while letting QuickCheck generate small, readable inputs.
data BalanceSample = BalanceSample Int Int Int
  deriving (Show)

instance Arbitrary BalanceSample where
  arbitrary = BalanceSample <$> arbitrary <*> arbitrary <*> arbitrary

main :: IO ()
main = do
  putStrLn "== h-kernel Balance laws =="
  results <- sequence
    [ quickCheckResult propSemigroupAssociative
    , quickCheckResult propMonoidLeftIdentity
    , quickCheckResult propMonoidRightIdentity
    , quickCheckResult propBalanceCommutative
    , quickCheckResult propBalanceInverse
    , quickCheckResult propZeroNormalization
    , quickCheckResult propNamedAdditionAgreesWithSemigroup
    , quickCheckResult propSumBalancesAgreesWithFold
    , quickCheckResult propAmountFoldHomomorphism
    ]
  unless (all isSuccess results) exitFailure

propSemigroupAssociative
  :: BalanceSample
  -> BalanceSample
  -> BalanceSample
  -> Bool
propSemigroupAssociative first second third =
  (toBalance first <> toBalance second) <> toBalance third
    == toBalance first <> (toBalance second <> toBalance third)

propMonoidLeftIdentity :: BalanceSample -> Bool
propMonoidLeftIdentity sample =
  mempty <> toBalance sample == toBalance sample

propMonoidRightIdentity :: BalanceSample -> Bool
propMonoidRightIdentity sample =
  toBalance sample <> mempty == toBalance sample

propBalanceCommutative :: BalanceSample -> BalanceSample -> Bool
propBalanceCommutative left right =
  toBalance left <> toBalance right
    == toBalance right <> toBalance left

propBalanceInverse :: BalanceSample -> Bool
propBalanceInverse sample =
  toBalance sample <> negateBalance (toBalance sample) == mempty

propZeroNormalization :: BalanceSample -> Bool
propZeroNormalization sample =
  balanceEntries
    (toBalance sample <> negateBalance (toBalance sample))
      == []

propNamedAdditionAgreesWithSemigroup
  :: BalanceSample
  -> BalanceSample
  -> Bool
propNamedAdditionAgreesWithSemigroup left right =
  addBalance (toBalance left) (toBalance right)
    == toBalance left <> toBalance right

propSumBalancesAgreesWithFold
  :: BalanceSample
  -> BalanceSample
  -> BalanceSample
  -> Bool
propSumBalancesAgreesWithFold first second third =
  sumBalances balances == Foldable.fold balances
  where
    balances = map toBalance [first, second, third]

-- | Lifting Amount collections into Balance preserves concatenation. This is
-- the concrete accounting reason 'balanceFromAmounts' is a foldMap.
propAmountFoldHomomorphism
  :: BalanceSample
  -> BalanceSample
  -> Bool
propAmountFoldHomomorphism left right =
  balanceFromAmounts (toAmounts left ++ toAmounts right)
    == toBalance left <> toBalance right

toBalance :: BalanceSample -> Balance
toBalance = balanceFromAmounts . toAmounts

toAmounts :: BalanceSample -> [Amount]
toAmounts (BalanceSample jpy usd btc) =
  [ amount "JPY" jpy
  , amount "USD" usd
  , amount "BTC" btc
  ]

amount :: Text -> Int -> Amount
amount code value =
  mkAmount
    (mustRight (mkCommodity code))
    (quantityFromInteger (toInteger value))

