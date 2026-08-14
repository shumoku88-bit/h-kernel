{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import Data.Time.Calendar (Day, addDays, fromGregorian)
import HKernel.Budget
import HKernel.Budget.History
import HKernel.Envelope.EntitlementHistory
import HKernel.Envelope.EntitlementTransfer
import HKernel.Money
import HKernel.Period (Period, mkPeriod)
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeAdmittedHistory
  characterizeNegativeHistory
  characterizeNativeEnvelopeTransfer
  characterizeNativeEnvelopeHistory

characterizeAdmittedHistory :: IO ()
characterizeAdmittedHistory = do
  let cycle = testCycle
      food = mustRight (mkEnvelopeId "food")
      initial = change cycle food (day 15) 10000 "initial"
      laterReduction = change cycle food (day 32) (-5000) "later reduction"
      history = mustRight (mkBudgetHistory [laterReduction, initial])
      sameDayOffset =
        [ change cycle food (day 15) (-5000) "same-day reduction"
        , change cycle food (day 15) 5000 "same-day allocation"
        ]

  assertEqual "admitted history preserves source order"
    [laterReduction, initial]
    (budgetHistoryChanges history)
  assertRight "effective dates, not source order, govern admission"
    (mkBudgetHistory [laterReduction, initial])
  assertRight "same-day changes combine before admission"
    (mkBudgetHistory sameDayOffset)
  assertEqual "an empty history is valid evidence"
    []
    (budgetHistoryChanges (mustRight (mkBudgetHistory [])))

characterizeNegativeHistory :: IO ()
characterizeNegativeHistory = do
  let cycle = testCycle
      food = mustRight (mkEnvelopeId "food")
      jpy = mustRight (mkCommodity "JPY")
      temporarilyNegative =
        [ change cycle food (day 15) 10000 "initial"
        , change cycle food (day 32) (-15000) "too much removed"
        , change cycle food (day 33) 10000 "later restoration"
        ]
      expectedQuantity = quantityFromInteger (-5000)

  assertSingleError
    "later restoration does not hide a negative entitlement date"
    (\err -> case err of
      BudgetHistoryNegativeEntitlement
          actualCycle
          actualEnvelope
          actualCommodity
          actualDay
          actualQuantity ->
        actualCycle == cycle
          && actualEnvelope == food
          && actualCommodity == jpy
          && actualDay == day 32
          && actualQuantity == expectedQuantity)
    (mkBudgetHistory temporarilyNegative)

characterizeNativeEnvelopeTransfer :: IO ()
characterizeNativeEnvelopeTransfer = do
  let period = testPeriod
      food = mustRight (mkEnvelopeId "food")
      stock = mustRight (mkEnvelopeId "stock-food")
      jpy = mustRight (mkCommodity "JPY")
      amount = mkAmount jpy (quantityFromInteger 1000)
      allocation = mustRight
        (mkEnvelopeEntitlementTransfer
          (day 15)
          period
          Unallocated
          (Spendable food)
          amount
          "initial allocation")
      moved = mustRight
        (mkEnvelopeEntitlementTransfer
          (day 16)
          period
          (Spendable food)
          (Spendable stock)
          amount
          "move to stock")

  assertEqual "allocation retains derived Unallocated as its source"
    Unallocated
    (entitlementTransferFrom allocation)
  assertEqual "an Envelope-to-Envelope move stays one atomic record"
    (Spendable food, Spendable stock)
    (entitlementTransferFrom moved, entitlementTransferTo moved)
  assertLeft "same endpoint is not an entitlement transfer"
    (mkEnvelopeEntitlementTransfer
      (day 16) period (Spendable food) (Spendable food) amount "same")
  assertLeft "zero entitlement transfer is rejected"
    (mkEnvelopeEntitlementTransfer
      (day 16)
      period
      Unallocated
      (Spendable food)
      (mkAmount jpy zeroQuantity)
      "zero")
  assertLeft "negative amount does not carry a second direction"
    (mkEnvelopeEntitlementTransfer
      (day 16)
      period
      Unallocated
      (Spendable food)
      (mkAmount jpy (quantityFromInteger (-1)))
      "negative")
  assertLeft "transfer date must belong to its explicit historical period"
    (mkEnvelopeEntitlementTransfer
      (fromGregorian 2026 10 15)
      period
      Unallocated
      (Spendable food)
      amount
      "outside")

characterizeNativeEnvelopeHistory :: IO ()
characterizeNativeEnvelopeHistory = do
  let period = testPeriod
      food = mustRight (mkEnvelopeId "food")
      stock = mustRight (mkEnvelopeId "stock-food")
      jpy = mustRight (mkCommodity "JPY")
      grant n effectiveDay note = mustRight
        (mkEnvelopeEntitlementTransfer
          effectiveDay
          period
          Unallocated
          (Spendable food)
          (mkAmount jpy (quantityFromInteger n))
          note)
      move n effectiveDay note = mustRight
        (mkEnvelopeEntitlementTransfer
          effectiveDay
          period
          (Spendable food)
          (Spendable stock)
          (mkAmount jpy (quantityFromInteger n))
          note)
      initial = grant 10000 (day 15) "initial"
      laterMove = move 5000 (day 32) "move later"
      sourceReversed = [laterMove, initial]
      admitted = mustRight (mkEnvelopeEntitlementHistory sourceReversed)
      sameDayFunded =
        [ move 5000 (day 20) "same-day move"
        , grant 5000 (day 20) "same-day grant"
        ]
      overdrawn =
        [ initial
        , move 15000 (day 32) "too much moved"
        , grant 10000 (day 33) "later restoration"
        ]

  assertEqual "native history preserves source order as provenance"
    sourceReversed
    (envelopeEntitlementHistoryTransfers admitted)
  assertRight "native history validates by effective date rather than source order"
    (mkEnvelopeEntitlementHistory sourceReversed)
  assertRight "same-day endpoint deltas combine before negativity is checked"
    (mkEnvelopeEntitlementHistory sameDayFunded)
  assertRight "Unallocated is not invented as a stored funding balance"
    (mkEnvelopeEntitlementHistory [grant 1000000 (day 15) "large claim"])
  assertNativeSingleError
    "later funding does not hide a negative Envelope entitlement date"
    (\err -> case err of
      EnvelopeEntitlementBecameNegative
          actualPeriod
          actualEnvelope
          actualCommodity
          actualDay
          actualQuantity ->
        actualPeriod == period
          && actualEnvelope == food
          && actualCommodity == jpy
          && actualDay == day 32
          && actualQuantity == quantityFromInteger (-5000))
    (mkEnvelopeEntitlementHistory overdrawn)

testCycle :: BudgetCycle
testCycle = mustRight
  (mkBudgetCycle (fromGregorian 2026 8 15) (fromGregorian 2026 10 15))

testPeriod :: Period
testPeriod = mustRight
  (mkPeriod (fromGregorian 2026 8 15) (fromGregorian 2026 10 15))

-- | Day offset from 2026-08-01, keeping fixtures visually compact.
day :: Integer -> Day
day offset = addDays offset (fromGregorian 2026 8 1)

change
  :: BudgetCycle
  -> EnvelopeId
  -> Day
  -> Integer
  -> Text
  -> BudgetChange
change cycle envelope effectiveDay quantity note = mustRight
  (mkBudgetChange
    effectiveDay
    cycle
    envelope
    (mkAmount
      (mustRight (mkCommodity "JPY"))
      (quantityFromInteger quantity))
    note)

assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> pass label
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

assertRight :: Show error => String -> Either error value -> IO ()
assertRight label result = case result of
  Right _  -> pass label
  Left err -> failTest label ("unexpectedly rejected: " ++ show err)

assertSingleError
  :: Show value
  => String
  -> (BudgetHistoryError -> Bool)
  -> Either (NonEmpty.NonEmpty BudgetHistoryError) value
  -> IO ()
assertSingleError label predicate result = case result of
  Left errors -> case NonEmpty.toList errors of
    [err] | predicate err -> pass label
    unexpected -> failTest label ("unexpected errors: " ++ show unexpected)
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

assertNativeSingleError
  :: Show value
  => String
  -> (EnvelopeEntitlementHistoryError -> Bool)
  -> Either (NonEmpty.NonEmpty EnvelopeEntitlementHistoryError) value
  -> IO ()
assertNativeSingleError label predicate result = case result of
  Left errors -> case NonEmpty.toList errors of
    [err] | predicate err -> pass label
    unexpected -> failTest label ("unexpected errors: " ++ show unexpected)
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pass label
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actual)

pass :: String -> IO ()
pass label = putStrLn ("  [PASS] " ++ label)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
