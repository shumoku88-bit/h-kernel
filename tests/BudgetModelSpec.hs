{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import Data.Time.Calendar (addDays, fromGregorian)
import HKernel.Budget
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeBudgetCycle
  characterizeBudgetObservation
  characterizeEnvelopeIdentity
  characterizeBudgetChange

characterizeBudgetCycle :: IO ()
characterizeBudgetCycle = do
  let start = fromGregorian 2026 8 15
      endExclusive = fromGregorian 2026 10 15
      cycle = mustRight (mkBudgetCycle start endExclusive)

  assertEqual "cycle retains its inclusive start"
    start
    (budgetCycleStart cycle)
  assertEqual "cycle retains its exclusive end"
    endExclusive
    (budgetCycleEndExclusive cycle)
  assertEqual "cycle includes its start"
    True
    (budgetCycleContains cycle start)
  assertEqual "cycle includes its final day"
    True
    (budgetCycleContains cycle (addDays (-1) endExclusive))
  assertEqual "cycle excludes its end boundary"
    False
    (budgetCycleContains cycle endExclusive)
  assertEqual "cycle excludes dates before its start"
    False
    (budgetCycleContains cycle (addDays (-1) start))

  assertLeft "empty cycles are rejected"
    (mkBudgetCycle start start)
  assertLeft "backwards cycles are rejected"
    (mkBudgetCycle endExclusive start)

characterizeBudgetObservation :: IO ()
characterizeBudgetObservation = do
  let start = fromGregorian 2026 8 15
      observedThrough = fromGregorian 2026 9 1
      endExclusive = fromGregorian 2026 10 15
      cycle = mustRight (mkBudgetCycle start endExclusive)
      observation = mustRight (mkBudgetObservation cycle observedThrough)

  assertEqual "observation retains its budget cycle"
    cycle
    (budgetObservationCycle observation)
  assertEqual "observation retains its inclusive horizon"
    observedThrough
    (budgetObservationObservedThrough observation)
  assertEqual "observation includes the cycle start"
    True
    (budgetObservationContains observation start)
  assertEqual "observation includes its horizon day"
    True
    (budgetObservationContains observation observedThrough)
  assertEqual "observation excludes later days in the same cycle"
    False
    (budgetObservationContains observation (addDays 1 observedThrough))
  assertEqual "observation excludes dates before the cycle"
    False
    (budgetObservationContains observation (addDays (-1) start))

  assertLeft "an observation before the cycle is rejected"
    (mkBudgetObservation cycle (addDays (-1) start))
  assertLeft "the exclusive cycle end cannot be an inclusive observation day"
    (mkBudgetObservation cycle endExclusive)

characterizeEnvelopeIdentity :: IO ()
characterizeEnvelopeIdentity = do
  let stockFood = mustRight (mkEnvelopeId "stock-food")

  assertEqual "envelope identity retains its stable text"
    "stock-food"
    (envelopeIdText stockFood)
  assertLeft "empty envelope identity is rejected"
    (mkEnvelopeId "")
  assertLeft "surrounding whitespace is rejected"
    (mkEnvelopeId " food")
  assertLeft "embedded whitespace is rejected"
    (mkEnvelopeId "stock food")
  assertLeft "control characters are rejected"
    (mkEnvelopeId "stock\tfood")
  assertLeft "derived Unallocated cannot become spendable"
    (mkEnvelopeId "unallocated")
  assertLeft "the Unallocated reservation is case insensitive"
    (mkEnvelopeId "Unallocated")

  assertEqual "the first pacing modes remain distinct"
    False
    (Daily == Flex)

characterizeBudgetChange :: IO ()
characterizeBudgetChange = do
  let start = fromGregorian 2026 8 15
      endExclusive = fromGregorian 2026 10 15
      cycle = mustRight (mkBudgetCycle start endExclusive)
      food = mustRight (mkEnvelopeId "food")
      jpy = mustRight (mkCommodity "JPY")
      adjustment = mkAmount jpy (quantityFromInteger (-5000))
      note = "move to stock food"
      change = mustRight
        (mkBudgetChange start cycle food adjustment note)

  assertEqual "change retains its effective date"
    start
    (budgetChangeDate change)
  assertEqual "change retains its cycle"
    cycle
    (budgetChangeCycle change)
  assertEqual "change retains its spendable envelope"
    food
    (budgetChangeEnvelope change)
  assertEqual "negative exact amounts represent adjustments"
    adjustment
    (budgetChangeAmount change)
  assertEqual "change retains its optional human note"
    note
    (budgetChangeNote change)

  assertRight "the final included day accepts a budget change"
    (mkBudgetChange
      (addDays (-1) endExclusive)
      cycle
      food
      adjustment
      note)
  assertLeft "the exclusive end rejects a budget change"
    (mkBudgetChange endExclusive cycle food adjustment note)
  assertLeft "dates before the cycle reject a budget change"
    (mkBudgetChange (addDays (-1) start) cycle food adjustment note)



assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure

assertRight :: Show error => String -> Either error value -> IO ()
assertRight label result = case result of
  Right _ -> putStrLn ("  [PASS] " ++ label)
  Left err -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly rejected: " ++ show err)
    exitFailure

