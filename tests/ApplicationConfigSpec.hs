{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import HKernel.Application.Config
import System.Exit (exitFailure)

main :: IO ()
main = do
  let canonical = mustRight (parseApplicationConfig
        "# retained profile\nDEFAULT_CURRENCY=JPY\nACTUAL_JOURNAL_FILE=actual.journal\n")
  assertEqual "the selected Actual Journal remains typed"
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

  assertLeft "the source selection remains required"
    0
    "ACTUAL_JOURNAL_FILE is required"
    (parseApplicationConfig "DEFAULT_CURRENCY=JPY\n")

  assertLeft "another Actual Journal path is rejected"
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

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("invalid test fixture: " ++ show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
