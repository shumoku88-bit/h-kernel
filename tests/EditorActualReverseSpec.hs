{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Actual.Journal (ActualJournalError(..), parseActualJournal)
import HKernel.Editor.ActualReverse
import HKernel.Plan.Completion (mkActualTransactionId)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let reverseDay = fromGregorian 2026 8 5
      targetId = mustRight (mkActualTransactionId "event-123")
      missingId = mustRight (mkActualTransactionId "event-999")

  let validIntent = ActualReverseIntent
        { reverseTargetId = targetId
        , reverseDate = reverseDay
        , reverseDescription = "Reverse mistaken expense"
        }

  let missingIntent = ActualReverseIntent
        { reverseTargetId = missingId
        , reverseDate = reverseDay
        , reverseDescription = "Should not be appended"
        }

  -- 1. Valid append block preview
  -- exact amounts are negated properly (100 -> -100, -100 -> 100)
  -- postings order is preserved (Cash first, then Expense)
  -- reverses metadata is rendered
  let preview = mustRight (prepareActualReverse fixtureSource validIntent)
      expectedBlock = T.unlines
        [ "2026-08-05 Reverse mistaken expense"
        , "  ; reverses: event-123"
        , "  assets:cash  -100 JPY"
        , "  expenses:food  100 JPY"
        ]

  assertEqual "render exact reversed postings and provenance metadata"
    expectedBlock
    (candidateBlock preview)

  -- 2. candidate complete source is re-parseable
  let reParsed = parseActualJournal (candidateCompleteSource preview)
  case reParsed of
    Left errs -> do
      putStrLn "  [FAIL] candidate complete source should be parseable"
      print errs
      exitFailure
    Right _ -> putStrLn "  [PASS] candidate complete source is parseable"

  -- 3. TargetNotFound rejection
  assertLeftEqual "reject reverse when target ID is not found"
    [TargetNotFound missingId]
    (prepareActualReverse fixtureSource missingIntent)

fixtureSource :: Text
fixtureSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2026-08-04 Grocery shopping"
  , "  ; event-id: event-123"
  , "  assets:cash  100 JPY"
  , "  expenses:food  -100 JPY"
  ]

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Left err -> error ("invalid test setup: " ++ show err)
  Right value -> value

assertLeftEqual
  :: (Eq error, Show error)
  => String
  -> [error]
  -> Either (NonEmpty.NonEmpty error) value
  -> IO ()
assertLeftEqual label expected result = case result of
  Left errors -> assertEqual label expected (NonEmpty.toList errors)
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly succeeded"
    exitFailure

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
