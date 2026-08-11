module Main (main) where

import Test.Support (mustRight, assertEqual)
import Data.Time.Calendar (addDays, fromGregorian)
import HKernel.Period
import System.Exit (exitFailure)

main :: IO ()
main = do
  let start = fromGregorian 2026 6 15
      endExclusive = fromGregorian 2026 8 15
      period = mustRight (mkPeriod start endExclusive)

  assertEqual "period retains its inclusive start"
    start
    (periodStart period)
  assertEqual "period retains its exclusive end"
    endExclusive
    (periodEndExclusive period)
  assertEqual "period includes its start"
    True
    (periodContains period start)
  assertEqual "period includes its final day"
    True
    (periodContains period (addDays (-1) endExclusive))
  assertEqual "period excludes its end boundary"
    False
    (periodContains period endExclusive)
  assertEqual "period excludes dates before its start"
    False
    (periodContains period (addDays (-1) start))

  assertLeft "empty periods are rejected"
    (mkPeriod start start)
  assertLeft "backwards periods are rejected"
    (mkPeriod endExclusive start)



assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure

