{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import Data.Time.Calendar (Day, addDays, fromGregorian)
import HKernel.Budget
import HKernel.Budget.History
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeAdmittedHistory
  characterizeNegativeHistory

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

testCycle :: BudgetCycle
testCycle = mustRight
  (mkBudgetCycle (fromGregorian 2026 8 15) (fromGregorian 2026 10 15))

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
