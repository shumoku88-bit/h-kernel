{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Time.Calendar (fromGregorian)
import HKernel.Backing
import HKernel.Backing.Identity
import HKernel.Envelope.Identity (mkEnvelopeId)
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
      foodId = mustRight (mkEnvelopeId "food")
      travelId = mustRight (mkEnvelopeId "travel")
      cashPoolId = mustRight (mkBackingPoolId "cash")
      reservePoolId = mustRight (mkBackingPoolId "reserve")
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
      cashPool = mustRight (deriveBackingPoolPosition
        cashPoolId
        (one jpy 100)
        (one jpy 40)
        [ BackedEnvelopeClaim
            { backedEnvelopeId = foodId
            , backedEnvelopeRemaining = envelopeLedgerRemaining food
            , backedEnvelopeHeadroom = envelopePostPlanHeadroom food
            }
        ])
      reservePool = mustRight (deriveBackingPoolPosition
        reservePoolId
        (one jpy 150 <> one usd 4)
        mempty
        [ BackedEnvelopeClaim
            { backedEnvelopeId = travelId
            , backedEnvelopeRemaining = envelopeLedgerRemaining travel
            , backedEnvelopeHeadroom = envelopePostPlanHeadroom travel
            }
        ])
      report = EnvelopeBacking
        { envelopeBackingPeriod = period
        , envelopeBackingObservedOn = fromGregorian 2026 8 10
        , envelopeBackingLines = [food, travel]
        , envelopeBackingPools = [cashPool, reservePool]
        , envelopeLedgerUnassigned = one jpy 10 <> one usd 1
        , envelopeUnassignedExpenses = []
        }

  assertEqual
    "signed total preserves overspent and positive envelope evidence"
    (one jpy 100 <> one usd (-2))
    (envelopeSignedTotal report)
  assertEqual
    "native pool positions preserve aggregate funding without becoming one owner"
    (one jpy 250 <> one usd 4)
    (envelopeFundingBalance report)
  assertEqual
    "Backing required does not let negative envelopes cancel positive claims"
    (one jpy 120 <> one usd 3)
    (envelopeBackingRequired report)
  assertEqual
    "gross Household summary remains available"
    (one jpy 130 <> one usd 1)
    (envelopeBackingSurplus report)
  assertEqual
    "available Household summary includes source funding and Envelope commitments"
    (one jpy 120 <> one usd 1)
    (envelopeAvailableBackingSurplus report)
  assertEqual
    "reconciliation subtracts unassigned Budget evidence and normalizes zero"
    (one jpy 120)
    (envelopeReconciliationDelta report)
  assertEqual
    "post-Plan headroom remains distinct from ledger remaining"
    (one jpy 90 <> one usd (-5))
    (envelopePostPlanHeadroom food)
  assertEqual
    "pool-local shortage survives despite another pool's surplus"
    (one jpy (-20))
    (backingPoolGrossSurplus cashPool)
  assertEqual
    "pool-local available shortage keeps source funding commitment separate"
    (one jpy (-30))
    (backingPoolAvailableSurplus cashPool)
  assertEqual
    "another pool keeps its independent surplus coordinates"
    (one jpy 150 <> one usd 1)
    (backingPoolAvailableSurplus reservePool)

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
