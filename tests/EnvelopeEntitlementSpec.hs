{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Envelope.Entitlement
import HKernel.Envelope.EntitlementHistory (mkEnvelopeEntitlementHistory)
import HKernel.Envelope.EntitlementTransfer
import HKernel.Envelope.Identity
import HKernel.Money
import HKernel.Period
import System.Exit (exitFailure)

main :: IO ()
main = do
  observationBoundary
  projectionLaws

observationBoundary :: IO ()
observationBoundary = do
  let emptyHistory = mustRight (mkEnvelopeEntitlementHistory [])
  left "observation before Period is rejected"
    (observeEnvelopeEntitlement period (day 14) emptyHistory)
  left "Period end remains exclusive"
    (observeEnvelopeEntitlement period (fromGregorian 2026 10 15) emptyHistory)

projectionLaws :: IO ()
projectionLaws = do
  let food = envelope "food"
      stock = envelope "stock-food"
      temporary = envelope "temporary"
      absent = envelope "absent"
      jpy = commodity "JPY"
      usd = commodity "USD"
      nextPeriod = mustRight
        (mkPeriod (fromGregorian 2026 10 15) (fromGregorian 2026 12 15))
      transfers =
        [ transfer (fromGregorian 2026 6 15) Unallocated (Spendable food) jpy 40000 "pre-period June grant"
        , transfer (fromGregorian 2026 7 10) (Spendable food) (Spendable stock) jpy 5000 "pre-period July reallocation"
        , transfer (fromGregorian 2026 7 20) (Spendable stock) Unallocated jpy 1000 "pre-period July release"
        , transfer (day 15) Unallocated (Spendable food) jpy 10000 "grant JPY"
        , transfer (day 15) Unallocated (Spendable food) usd 5 "grant USD"
        , transfer (day 18) (Spendable temporary) Unallocated jpy 100 "release same day"
        , transfer (day 18) Unallocated (Spendable temporary) jpy 100 "grant same day"
        , transfer (day 20) (Spendable food) (Spendable stock) jpy 2000 "move"
        , transfer (day 25) (Spendable stock) Unallocated jpy 500 "release later"
        , transfer (fromGregorian 2026 9 1) Unallocated (Spendable food) jpy 3000 "future within period"
        , transfer (fromGregorian 2026 10 20) Unallocated (Spendable food) jpy 999 "future in next period"
        ]
      history = mustRight (mkEnvelopeEntitlementHistory transfers)
      observed = mustRight (observeEnvelopeEntitlement period (day 20) history)
      later = mustRight (observeEnvelopeEntitlement period (day 25) history)
      nextPeriodObserved = mustRight
        (observeEnvelopeEntitlement nextPeriod (fromGregorian 2026 10 25) history)
      expectedFood = balance
        [ mkAmount jpy (quantityFromInteger 43000)
        , mkAmount usd (quantityFromInteger 5)
        ]

  equal "projection retains explicit Period coordinate"
    period
    (envelopeEntitlementPeriod observed)
  equal "observation horizon is inclusive"
    (day 20)
    (envelopeEntitlementObservedThrough observed)
  equal "pre-period grants, reallocations, and current movements carry into Entitlement"
    expectedFood
    (envelopeEntitlementBalance food observed)
  equal "pre-period reallocation and release carry into destination Entitlement"
    (balance [mkAmount jpy (quantityFromInteger 6000)])
    (envelopeEntitlementBalance stock observed)
  equal "later release is excluded before its date"
    (balance [mkAmount jpy (quantityFromInteger 6000)])
    (envelopeEntitlementBalance stock observed)
  equal "later release is visible on its date"
    (balance [mkAmount jpy (quantityFromInteger 5500)])
    (envelopeEntitlementBalance stock later)
  equal "future transfer is excluded from earlier observation"
    expectedFood
    (envelopeEntitlementBalance food observed)
  equal "multiple historical Period boundaries carry forward into later Period observation"
    (balance [mkAmount jpy (quantityFromInteger 46999), mkAmount usd (quantityFromInteger 5)])
    (envelopeEntitlementBalance food nextPeriodObserved)
  equal "untouched Envelope lookup is canonical zero"
    emptyBalance
    (envelopeEntitlementBalance absent observed)
  equal "fully released Envelope lookup is canonical zero"
    emptyBalance
    (envelopeEntitlementBalance temporary observed)
  assert "zero coordinates are omitted from sparse entries"
    (all ((/= temporary) . fst) (envelopeEntitlementEntries observed))

period :: Period
period = mustRight
  (mkPeriod (fromGregorian 2026 8 15) (fromGregorian 2026 10 15))

day :: Int -> Day
day = fromGregorian 2026 8

envelope :: String -> EnvelopeId
envelope = mustRight . mkEnvelopeId . T.pack

commodity :: String -> Commodity
commodity = mustRight . mkCommodity . T.pack

transfer
  :: Day
  -> EnvelopeEndpoint
  -> EnvelopeEndpoint
  -> Commodity
  -> Integer
  -> String
  -> EnvelopeEntitlementTransfer
transfer effectiveDay fromEndpoint toEndpoint unit quantity note =
  mustRight
    (mkEnvelopeEntitlementTransfer
      effectiveDay
      fromEndpoint
      toEndpoint
      (mkAmount unit (quantityFromInteger quantity))
      (T.pack note))

balance :: [Amount] -> Balance
balance = balanceFromAmounts

left :: Show value => String -> Either error value -> IO ()
left label result = case result of
  Left _ -> pass label
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

assert :: String -> Bool -> IO ()
assert label condition
  | condition = pass label
  | otherwise = failTest label "condition was false"

equal :: (Eq value, Show value) => String -> value -> value -> IO ()
equal label expected actual
  | expected == actual = pass label
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actual)

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

pass :: String -> IO ()
pass label = putStrLn ("  [PASS] " ++ label)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
