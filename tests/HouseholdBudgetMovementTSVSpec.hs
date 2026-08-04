{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Household.BudgetMovement
import HKernel.Household.BudgetMovement.TSV
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeAcceptedMovements
  characterizeSourceFailures

characterizeAcceptedMovements :: IO ()
characterizeAcceptedMovements = do
  let jpy = mustRight (mkCommodity "JPY")
      opening = mustRight (mkAccount "budget:opening")
      food = mustRight (mkAccount "budget:food")
      unassigned = mustRight (mkAccount "budget:unassigned")
      movements = mustRight (parseHouseholdBudgetMovements validBudget)
      expected =
        [ householdBudgetMovement
            (fromGregorian 2026 6 15)
            "allocate"
            opening
            food
            (mkAmount jpy (quantityFromInteger 1000))
        , householdBudgetMovement
            (fromGregorian 2026 6 16)
            "return"
            food
            unassigned
            (mkAmount jpy (quantityFromInteger 250))
        ]

  assertEqual
    "physical row order becomes ordered source-independent movements"
    expected
    movements
  assertEqual
    "blank and comment-only source admits no movements"
    []
    (mustRight (parseHouseholdBudgetMovements "\n# no allocation movements\n"))

characterizeSourceFailures :: IO ()
characterizeSourceFailures = do
  assertLeftAt "date retains its physical line coordinate"
    2
    "invalid date"
    (parseHouseholdBudgetMovements invalidDateBudget)
  assertLeftAt "currency remains required metadata"
    1
    "missing currency"
    (parseHouseholdBudgetMovements missingCurrencyBudget)
  assertLeftAt "row width remains explicit"
    1
    "expected date, memo, from, to, amount, and currency"
    (parseHouseholdBudgetMovements narrowBudget)
  assertLeftOnLine "Account smart constructor owns Account validity"
    1
    (parseHouseholdBudgetMovements invalidAccountBudget)
  assertLeftOnLine "Money parser owns exact quantity validity"
    1
    (parseHouseholdBudgetMovements invalidQuantityBudget)
  assertLeftOnLine "Commodity smart constructor owns Commodity validity"
    1
    (parseHouseholdBudgetMovements invalidCommodityBudget)

validBudget :: T.Text
validBudget = T.unlines
  [ "# retained household allocation evidence"
  , "2026-06-15\tallocate\tbudget:opening\tbudget:food\t1000\tcurrency=JPY\tnote=ignored"
  , ""
  , "2026-06-16\treturn\tbudget:food\tbudget:unassigned\t250\tcurrency=JPY"
  ]

invalidDateBudget :: T.Text
invalidDateBudget = T.unlines
  [ "# line coordinates retain comments"
  , "2026-02-30\tallocate\tbudget:opening\tbudget:food\t1000\tcurrency=JPY"
  ]

missingCurrencyBudget :: T.Text
missingCurrencyBudget =
  "2026-06-15\tallocate\tbudget:opening\tbudget:food\t1000\n"

narrowBudget :: T.Text
narrowBudget = "2026-06-15\tallocate\tbudget:opening\n"

invalidAccountBudget :: T.Text
invalidAccountBudget =
  "2026-06-15\tallocate\t\tbudget:food\t1000\tcurrency=JPY\n"

invalidQuantityBudget :: T.Text
invalidQuantityBudget =
  "2026-06-15\tallocate\tbudget:opening\tbudget:food\tnot-a-number\tcurrency=JPY\n"

invalidCommodityBudget :: T.Text
invalidCommodityBudget =
  "2026-06-15\tallocate\tbudget:opening\tbudget:food\t1000\tcurrency=\n"

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("invalid test fixture: " ++ show err)

assertLeftAt
  :: String
  -> Int
  -> T.Text
  -> Either (NonEmpty.NonEmpty HouseholdBudgetMovementTSVError) value
  -> IO ()
assertLeftAt label expectedLine expectedMessage result = case result of
  Left errors
    | any matches (NonEmpty.toList errors) ->
        putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    expected line/message: "
          ++ show expectedLine ++ " / " ++ T.unpack expectedMessage)
        putStrLn ("    actual errors: " ++ show errors)
        exitFailure
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted source"
    exitFailure
  where
    matches err =
      householdBudgetMovementTSVErrorLine err == expectedLine
        && householdBudgetMovementTSVErrorMessage err == expectedMessage

assertLeftOnLine
  :: String
  -> Int
  -> Either (NonEmpty.NonEmpty HouseholdBudgetMovementTSVError) value
  -> IO ()
assertLeftOnLine label expectedLine result = case result of
  Left errors
    | any ((== expectedLine) . householdBudgetMovementTSVErrorLine)
        (NonEmpty.toList errors) ->
          putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    expected an error on line " ++ show expectedLine)
        putStrLn ("    actual errors: " ++ show errors)
        exitFailure
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted source"
    exitFailure

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
