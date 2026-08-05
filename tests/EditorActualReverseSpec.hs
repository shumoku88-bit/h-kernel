{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Actual.Journal
  ( actualJournalReversalDeclarations
  , parseActualJournal
  , reversedTransactionId
  , reversalTransactionId
  )
import HKernel.Editor.ActualReverse
import HKernel.Plan.Completion
  ( actualTransactionIdText
  , mkActualTransactionId
  )
import System.Exit (exitFailure)

main :: IO ()
main = do
  let reverseDay = fromGregorian 2026 8 5
      targetId = mustRight (mkActualTransactionId "event-123")
      reversalId = mustRight (mkActualTransactionId "event-123-reversal-1")
      secondReversalId = mustRight
        (mkActualTransactionId "event-123-reversal-2")
      missingId = mustRight (mkActualTransactionId "event-999")

  let validIntent = ActualReverseIntent
        { reverseEventId = reversalId
        , reverseTargetId = targetId
        , reverseDate = reverseDay
        , reverseDescription = "Reverse mistaken expense"
        }

  let missingIntent = ActualReverseIntent
        { reverseEventId = secondReversalId
        , reverseTargetId = missingId
        , reverseDate = reverseDay
        , reverseDescription = "Should not be appended"
        }

  -- 1. Valid append block preview retains both identities.
  -- Exact amounts are negated properly and posting order is preserved.
  let preview = mustRight (prepareActualReverse fixtureSource validIntent)
      expectedBlock = T.unlines
        [ "2026-08-05 Reverse mistaken expense"
        , "  ; event-id: event-123-reversal-1"
        , "  ; reverses: event-123"
        , "  assets:cash  -100 JPY"
        , "  expenses:food  100 JPY"
        ]

  assertEqual "render durable reversal identity and provenance"
    expectedBlock
    (candidateBlock preview)

  -- 2. Candidate complete source is re-parseable and provenance remains typed.
  case parseActualJournal (candidateCompleteSource preview) of
    Left errs -> do
      putStrLn "  [FAIL] candidate complete source should be parseable"
      print errs
      exitFailure
    Right admitted -> do
      assertEqual "parse-back retains one typed reversal edge"
        [("event-123-reversal-1", "event-123")]
        [ ( actualTransactionIdText (reversalTransactionId declaration)
          , actualTransactionIdText (reversedTransactionId declaration)
          )
        | declaration <- actualJournalReversalDeclarations admitted
        ]

  -- 3. TargetNotFound rejection.
  assertLeftEqual "reject reverse when target ID is not found"
    [TargetNotFound missingId]
    (prepareActualReverse fixtureSource missingIntent)

  -- 4. Reversal identity cannot reuse an existing Actual identity.
  let duplicateIdentityIntent = validIntent
        { reverseEventId = targetId }
  assertLeftEqual "reject reversal ID already present in source"
    [ReversalIdAlreadyExists targetId]
    (prepareActualReverse fixtureSource duplicateIdentityIntent)

  -- 5. The same target cannot be reversed directly twice.
  let duplicateTargetIntent = ActualReverseIntent
        { reverseEventId = secondReversalId
        , reverseTargetId = targetId
        , reverseDate = reverseDay
        , reverseDescription = "Duplicate direct reversal"
        }
  assertLeftEqual "reject a second direct reversal of one target"
    [TargetAlreadyReversed targetId reversalId]
    (prepareActualReverse
      (candidateCompleteSource preview)
      duplicateTargetIntent)

  -- 6. A reversal can itself be reversed through its own durable identity.
  let reverseOfReverseIntent = ActualReverseIntent
        { reverseEventId = secondReversalId
        , reverseTargetId = reversalId
        , reverseDate = reverseDay
        , reverseDescription = "Restore original effect"
        }
      reverseOfReversePreview = mustRight
        (prepareActualReverse
          (candidateCompleteSource preview)
          reverseOfReverseIntent)
  assertEqual "allow reverse-of-reverse as a new provenance edge"
    True
    ("; event-id: event-123-reversal-2"
      `T.isInfixOf` candidateBlock reverseOfReversePreview
      && "; reverses: event-123-reversal-1"
        `T.isInfixOf` candidateBlock reverseOfReversePreview)

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
