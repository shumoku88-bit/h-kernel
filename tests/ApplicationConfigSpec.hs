{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import HKernel.Application.Config
import System.Exit (exitFailure)

main :: IO ()
main = do
  let root = mustRight (mkHouseholdRoot "private/household")
      sources = householdSourcePaths root

  assertEqual "Household root retains one normalized application coordinate"
    "private/household"
    (householdRootPath root)
  assertEqual "Account declarations resolve from the canonical root"
    "private/household/accounts.journal"
    (householdAccountsJournalPath sources)
  assertEqual "Actual facts resolve from the canonical root"
    "private/household/actual.journal"
    (householdActualJournalPath sources)
  assertEqual "Plan facts resolve from the canonical root"
    "private/household/plan.journal"
    (householdPlanJournalPath sources)
  assertEqual "Budget movements resolve from the canonical root"
    "private/household/budget.journal"
    (householdBudgetJournalPath sources)
  assertEqual "Budget policy resolves from the canonical root"
    "private/household/budget.toml"
    (householdBudgetConfigPath sources)
  assertEqual "Household policy resolves from the canonical root"
    "private/household/household.toml"
    (householdPolicyConfigPath sources)
  assertEqual "Report application policy resolves from the canonical root"
    "private/household/report.toml"
    (householdReportConfigPath sources)
  assertEqual "Household notebook resolves from the canonical root"
    "private/household/issues.tsv"
    (householdIssuesPath sources)
  assertEqual "an empty bootstrap path is not a Household root"
    (Left EmptyHouseholdRootPath)
    (mkHouseholdRoot "")

  let canonical = mustRight (parseApplicationConfig
        "# retained profile\nDEFAULT_CURRENCY=JPY\nACTUAL_JOURNAL_FILE=actual.journal\n")
  assertEqual "the retained selected Actual Journal remains typed"
    "actual.journal"
    (applicationActualJournalFile canonical)

  assertRight "unknown retained keys remain compatible"
    (parseApplicationConfig
      "UNUSED_KEY=value\nACTUAL_JOURNAL_FILE=actual.journal\n")

  assertRight "the final duplicate value retains current last-write-wins behavior"
    (parseApplicationConfig
      "ACTUAL_JOURNAL_FILE=old.journal\nACTUAL_JOURNAL_FILE=actual.journal\n")

  assertLeft "a later duplicate still governs source selection"
    0
    "ACTUAL_JOURNAL_FILE must be actual.journal, got old.journal"
    (parseApplicationConfig
      "ACTUAL_JOURNAL_FILE=actual.journal\nACTUAL_JOURNAL_FILE=old.journal\n")

  assertLeft "malformed rows retain their physical line"
    3
    "expected KEY=VALUE"
    (parseApplicationConfig
      "# comment\n\nbroken\nACTUAL_JOURNAL_FILE=actual.journal\n")

  assertLeft "the retained source selection remains required"
    0
    "ACTUAL_JOURNAL_FILE is required"
    (parseApplicationConfig "DEFAULT_CURRENCY=JPY\n")

  assertLeft "another retained Actual Journal path is rejected"
    0
    "ACTUAL_JOURNAL_FILE must be actual.journal, got private.journal"
    (parseApplicationConfig "ACTUAL_JOURNAL_FILE=private.journal\n")

assertRight
  :: Show error
  => String
  -> Either error value
  -> IO ()
assertRight label result = case result of
  Right _ -> putStrLn ("  [PASS] " ++ label)
  Left err -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly rejected source: " ++ show err)
    exitFailure

assertLeft
  :: String
  -> Int
  -> Text
  -> Either (NonEmpty.NonEmpty ApplicationConfigError) value
  -> IO ()
assertLeft label expectedLine expectedMessage result = case result of
  Left errors ->
    case NonEmpty.toList errors of
      [err]
        | applicationConfigErrorLine err == expectedLine
        , applicationConfigErrorMessage err == expectedMessage ->
            putStrLn ("  [PASS] " ++ label)
      actual -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    unexpected errors: " ++ show actual)
        exitFailure
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted source"
    exitFailure



