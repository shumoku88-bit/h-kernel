{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Time.Calendar (fromGregorian)
import HKernel.Household.Backing
import HKernel.Money
import HKernel.Period
import System.Exit (exitFailure)

main :: IO ()
main = do
  let jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      food = EnvelopeBackingLine
        { envelopeBackingName = "Food"
        , envelopeEntitlement = one jpy 150
        , envelopeActualConsumption = one jpy 30
        , envelopeActualRefunds = mempty
        , envelopeBudgetRemaining = one jpy 120 <> one usd (-5)
        , envelopeOpenPlanReserve = one jpy 30
        }
      travel = EnvelopeBackingLine
        { envelopeBackingName = "Travel"
        , envelopeEntitlement = one usd 3
        , envelopeActualConsumption = one jpy 20
        , envelopeActualRefunds = mempty
        , envelopeBudgetRemaining = one jpy (-20) <> one usd 3
        , envelopeOpenPlanReserve = mempty
        }
      report = EnvelopeBacking
        { envelopeBackingPeriod = period
        , envelopeBackingObservedOn = fromGregorian 2026 8 10
        , envelopeBackingLines = [food, travel]
        , envelopeFundingBalance = one jpy 200 <> one usd 4
        , envelopeLedgerUnassigned = one jpy 10 <> one usd 1
        , envelopeUnassignedExpenses = []
        }

  assertEqual
    "signed total preserves overspent and positive envelope evidence"
    (one jpy 100 <> one usd (-2))
    (envelopeSignedTotal report)
  assertEqual
    "Backing required does not let negative envelopes cancel positive claims"
    (one jpy 120 <> one usd 3)
    (envelopeBackingRequired report)
  assertEqual
    "Backing surplus compares funding with positive claims per Commodity"
    (one jpy 80 <> one usd 1)
    (envelopeBackingSurplus report)
  assertEqual
    "reconciliation subtracts unassigned Budget evidence and normalizes zero"
    (one jpy 70)
    (envelopeReconciliationDelta report)
  assertEqual
    "post-Plan headroom remains distinct from ledger remaining"
    (one jpy 90 <> one usd (-5))
    (envelopePostPlanHeadroom food)

one :: Commodity -> Integer -> Balance
one commodity value =
  singletonBalance (mkAmount commodity (quantityFromInteger value))

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    actual:   " ++ show actual)
      exitFailure
