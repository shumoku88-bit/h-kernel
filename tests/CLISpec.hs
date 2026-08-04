{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Time.Calendar (fromGregorian)
import HKernel.CLI
import HKernel.Engine (mkDateRange)
import HKernel.Period (mkPeriod)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let today = fromGregorian 2026 8 15
      day1 = fromGregorian 2026 8 1
      rangeMonth = mustRight (mkDateRange day1 today)
      rangeCustom = mustRight
        (mkDateRange (fromGregorian 2026 4 1) (fromGregorian 2026 7 31))
      recentAsOf = fromGregorian 2026 7 31
      journal command = Right ("journal.journal", RunJournal command)
      myJournal command = Right ("my.journal", RunJournal command)

  assertEqual
    "no args retains the as-of policy for default all-reports"
    (journal (RunDefaultReportBook today))
    (parseArguments today [])

  assertEqual
    "single arg all defaults to the Journal command"
    (journal (RunDefaultReportBook today))
    (parseArguments today ["all"])

  assertEqual
    "single journal path defaults to all-reports"
    (myJournal (RunDefaultReportBook today))
    (parseArguments today ["my.journal"])

  assertEqual
    "single date defaults to the Journal report book"
    (journal (RunDefaultReportBook today))
    (parseArguments today ["2026-08-15"])

  assertEqual
    "journal path and all retain the flexible form"
    (myJournal (RunDefaultReportBook today))
    (parseArguments today ["my.journal", "all"])

  assertEqual
    "mode and date may omit the Journal path"
    (journal (RunDailyFlow ExplicitDate rangeMonth))
    (parseArguments today ["daily", "2026-08-15"])

  assertEqual
    "journal path, all, and one date retain the default as-of policy"
    (myJournal (RunDefaultReportBook today))
    (parseArguments today ["my.journal", "all", "2026-08-15"])

  assertEqual
    "all-reports accepts an explicit range"
    (myJournal (RunReportBook rangeCustom))
    (parseArguments today
      ["my.journal", "all-reports", "2026-04-01", "2026-07-31"])

  assertEqual
    "daily-flow accepts an explicit range"
    (myJournal (RunDailyFlow ExplicitDate rangeCustom))
    (parseArguments today
      ["my.journal", "daily-flow", "2026-04-01", "2026-07-31"])

  assertEqual
    "monthly selects month-to-date monthly accounts"
    (journal (RunMonthlyAccounts DefaultedDate rangeMonth))
    (parseArguments today ["monthly"])

  assertEqual
    "recent accepts an explicit as-of date"
    (myJournal (RunRecentTransactions ExplicitDate recentAsOf))
    (parseArguments today
      ["my.journal", "recent-transactions", "2026-07-31"])

  let previousCycle = mustRight
        (mkPeriod (fromGregorian 2026 4 15) (fromGregorian 2026 6 15))
      currentCycle = mustRight
        (mkPeriod (fromGregorian 2026 6 15) (fromGregorian 2026 8 15))
  assertEqual
    "cycle accounts retains two explicit half-open periods"
    (myJournal (RunCycleAccounts currentCycle previousCycle))
    (parseArguments today
      [ "my.journal"
      , "cycle-accounts"
      , "2026-04-15"
      , "2026-06-15"
      , "2026-06-15"
      , "2026-08-15"
      ])

  assertEqual
    "envelope budget retains the separate policy path and explicit range"
    (Right
      ( "my.journal"
      , RunEnvelopeBudget "envelope-policy.tsv" rangeCustom
      ))
    (parseArguments today
      [ "my.journal"
      , "envelope-budget"
      , "envelope-policy.tsv"
      , "2026-04-01"
      , "2026-07-31"
      ])

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
