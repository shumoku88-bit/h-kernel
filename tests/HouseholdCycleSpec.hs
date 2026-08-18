{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Household.Cycle
  ( HouseholdCycleError(..)
  , householdCycleCurrentPeriod
  , householdCyclePreviousPeriod
  , observeHouseholdCycle
  )
import HKernel.Household.Policy (incomeAnchorCyclePolicy)
import HKernel.Period (periodEndExclusive, periodStart)
import HKernel.Plan (mkPlanId)
import HKernel.Plan.Journal (parsePlanJournal)
import System.Exit (exitFailure)

main :: IO ()
main = do
  testUnrelatedPlanShapeDoesNotConstrainCycle
  testRelevantPlanShapeFailsLocally
  testRetiredFutureAnchorDoesNotDefineCycle

testUnrelatedPlanShapeDoesNotConstrainCycle :: IO ()
testUnrelatedPlanShapeDoesNotConstrainCycle = do
  let income = mustRight (mkAccount "income:salary")
      actual = mustRight (parseActualJournal (declarations <>
        T.unlines
          [ ""
          , "2026-06-01 income"
          , "  income:salary  -100 JPY"
          , "  assets:cash     100 JPY"
          , ""
          , "2026-07-01 income"
          , "  income:salary  -100 JPY"
          , "  assets:cash     100 JPY"
          ]))
      plans = mustRight (parsePlanJournal (declarations <>
        T.unlines
          [ ""
          , "2026-08-01 next income"
          , "  ; plan-id: plan-income"
          , "  income:salary  -100 JPY"
          , "  assets:cash     100 JPY"
          , ""
          , "2026-07-25 reserve adjustment"
          , "  ; plan-id: plan-equity"
          , "  assets:cash    -20 JPY"
          , "  equity:reserve  20 JPY"
          ]))
      observed = mustRight
        (observeHouseholdCycle
          (fromGregorian 2026 7 20)
          actual
          plans
          (incomeAnchorCyclePolicy income))
  assertEqual "unrelated Plan shape does not constrain cycle observation"
    (fromGregorian 2026 7 1, fromGregorian 2026 8 1)
    ( periodStart (householdCycleCurrentPeriod observed)
    , periodEndExclusive (householdCycleCurrentPeriod observed)
    )
  assertEqual "previous cycle remains explicit"
    (fromGregorian 2026 6 1, fromGregorian 2026 7 1)
    ( periodStart (householdCyclePreviousPeriod observed)
    , periodEndExclusive (householdCyclePreviousPeriod observed)
    )

testRelevantPlanShapeFailsLocally :: IO ()
testRelevantPlanShapeFailsLocally = do
  let income = mustRight (mkAccount "income:salary")
      actual = mustRight (parseActualJournal (declarations <>
        T.unlines
          [ ""
          , "2026-06-01 income"
          , "  income:salary  -100 JPY"
          , "  assets:cash     100 JPY"
          , ""
          , "2026-07-01 income"
          , "  income:salary  -100 JPY"
          , "  assets:cash     100 JPY"
          ]))
      badPlanId = mustRight (mkPlanId "plan-bad-income")
      plans = mustRight (parsePlanJournal (declarations <>
        T.unlines
          [ ""
          , "2026-08-01 malformed cycle candidate"
          , "  ; plan-id: plan-bad-income"
          , "  income:salary  -100 JPY"
          , "  equity:reserve  100 JPY"
          ]))
  case observeHouseholdCycle
      (fromGregorian 2026 7 20)
      actual
      plans
      (incomeAnchorCyclePolicy income) of
    Left errors -> case NonEmpty.head errors of
      HouseholdCyclePlanShapeError found
        | found == badPlanId -> pure ()
      other -> failTest "relevant Plan shape" ("unexpected error: " <> show other)
    Right _ -> failTest "relevant Plan shape" "invalid cycle candidate was accepted"

testRetiredFutureAnchorDoesNotDefineCycle :: IO ()
testRetiredFutureAnchorDoesNotDefineCycle = do
  let income = mustRight (mkAccount "income:salary")
      actual = mustRight (parseActualJournal (declarations <>
        T.unlines
          [ ""
          , "2026-06-01 income"
          , "  income:salary  -100 JPY"
          , "  assets:cash     100 JPY"
          , ""
          , "2026-07-01 income"
          , "  income:salary  -100 JPY"
          , "  assets:cash     100 JPY"
          ]))
      plans = mustRight (parsePlanJournal (declarations <>
        T.unlines
          [ ""
          , "2026-08-01 retired next income"
          , "  ; plan-id: plan-retired-income"
          , "  ; cancelled-on: 2026-07-15"
          , "  income:salary  -100 JPY"
          , "  assets:cash     100 JPY"
          , ""
          , "2026-09-01 active next income"
          , "  ; plan-id: plan-active-income"
          , "  income:salary  -100 JPY"
          , "  assets:cash     100 JPY"
          ]))
      observed = mustRight
        (observeHouseholdCycle
          (fromGregorian 2026 7 20)
          actual
          plans
          (incomeAnchorCyclePolicy income))
  assertEqual "retired future anchor is excluded at observation day"
    (fromGregorian 2026 7 1, fromGregorian 2026 9 1)
    ( periodStart (householdCycleCurrentPeriod observed)
    , periodEndExclusive (householdCycleCurrentPeriod observed)
    )

declarations :: T.Text
declarations = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "account income:salary"
  , "  type: Income"
  , "account equity:reserve"
  , "  type: Equity"
  ]

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = failTest label
      ("expected: " ++ show expected ++ "\n    actual:   " ++ show actual)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
