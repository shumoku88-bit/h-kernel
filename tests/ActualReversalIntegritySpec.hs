{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import HKernel.Actual.Journal
import HKernel.Plan.Completion (actualTransactionIdText)
import System.Exit (exitFailure)

main :: IO ()
main = do
  acceptSemanticNegation
  acceptReverseOfReverse
  rejectPostingMismatch
  rejectReversalCycle

acceptSemanticNegation :: IO ()
acceptSemanticNegation =
  right "reversal admission compares Account/Commodity effect, not posting shape"
    (parseActualJournal semanticNegationJournal)

acceptReverseOfReverse :: IO ()
acceptReverseOfReverse =
  right "an acyclic reverse-of-reverse remains valid"
    (parseActualJournal reverseOfReverseJournal)

rejectPostingMismatch :: IO ()
rejectPostingMismatch =
  assertErrors "reverses metadata requires exact accounting negation"
    (\errors -> any isMismatch errors)
    (parseActualJournal postingMismatchJournal)
  where
    isMismatch err = case err of
      ActualReversalPostingMismatch reversalId targetId ->
        actualTransactionIdText reversalId == "actual-reversal"
          && actualTransactionIdText targetId == "actual-original"
      _ -> False

rejectReversalCycle :: IO ()
rejectReversalCycle =
  assertErrors "reversal provenance cannot contain a cycle"
    (\errors -> any isCycle errors)
    (parseActualJournal reversalCycleJournal)
  where
    isCycle err = case err of
      ActualReversalCycle ids ->
        map actualTransactionIdText (NonEmpty.toList ids)
          == ["actual-a", "actual-b"]
      _ -> False

semanticNegationJournal :: T.Text
semanticNegationJournal = declarations <> T.unlines
  [ "2026-08-01 * original"
  , "  ; event-id: actual-original"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi      60 JPY"
  , "  expenses:wifi      40 JPY"
  , ""
  , "2026-08-02 * reversal with merged and reordered postings"
  , "  ; event-id: actual-reversal"
  , "  ; reverses: actual-original"
  , "  expenses:wifi    -100 JPY"
  , "  assets:cash       100 JPY"
  ]

reverseOfReverseJournal :: T.Text
reverseOfReverseJournal = declarations <> T.unlines
  [ "2026-08-01 * original"
  , "  ; event-id: actual-original"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  , ""
  , "2026-08-02 * reversal"
  , "  ; event-id: actual-reversal-1"
  , "  ; reverses: actual-original"
  , "  assets:cash       100 JPY"
  , "  expenses:wifi   -100 JPY"
  , ""
  , "2026-08-03 * restore"
  , "  ; event-id: actual-reversal-2"
  , "  ; reverses: actual-reversal-1"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  ]

postingMismatchJournal :: T.Text
postingMismatchJournal = declarations <> T.unlines
  [ "2026-08-01 * original"
  , "  ; event-id: actual-original"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  , ""
  , "2026-08-02 * not actually a reversal"
  , "  ; event-id: actual-reversal"
  , "  ; reverses: actual-original"
  , "  assets:cash        90 JPY"
  , "  expenses:wifi    -90 JPY"
  ]

reversalCycleJournal :: T.Text
reversalCycleJournal = declarations <> T.unlines
  [ "2026-08-01 * A"
  , "  ; event-id: actual-a"
  , "  ; reverses: actual-b"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  , ""
  , "2026-08-02 * B"
  , "  ; event-id: actual-b"
  , "  ; reverses: actual-a"
  , "  assets:cash       100 JPY"
  , "  expenses:wifi   -100 JPY"
  ]

declarations :: T.Text
declarations = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:wifi"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  ]

assertErrors
  :: Show value
  => String
  -> ([ActualJournalError] -> Bool)
  -> Either (NonEmpty.NonEmpty ActualJournalError) value
  -> IO ()
assertErrors label predicate result = case result of
  Left errors
    | predicate (NonEmpty.toList errors) -> pass label
    | otherwise -> failTest label ("unexpected errors: " ++ show errors)
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

right :: Show error => String -> Either error value -> IO ()
right label result = case result of
  Right _ -> pass label
  Left err -> failTest label ("unexpectedly rejected: " ++ show err)

pass :: String -> IO ()
pass label = putStrLn ("  [PASS] " ++ label)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
