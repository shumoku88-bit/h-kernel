{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovementJournalError(..)
  , admitHouseholdBudgetMovementJournalFromResolvedJournal
  )
import HKernel.Journal (parseJournal)
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeResolvedBudgetAdmission
  rejectResolvedBudgetEqualCountTransactionDrift

characterizeResolvedBudgetAdmission :: IO ()
characterizeResolvedBudgetAdmission = do
  let resolvedJournal = mustRight (parseJournal budgetJournal)
  case admitHouseholdBudgetMovementJournalFromResolvedJournal
      resolvedJournal
      budgetJournal of
    Right _ -> putStrLn
      "  [PASS] resolved Budget movement admission accepts matching source evidence"
    Left errors -> do
      putStrLn
        "  [FAIL] resolved Budget movement admission accepts matching source evidence"
      putStrLn ("    unexpectedly rejected: " ++ show errors)
      exitFailure

rejectResolvedBudgetEqualCountTransactionDrift :: IO ()
rejectResolvedBudgetEqualCountTransactionDrift =
  assertLeftSatisfies
    "resolved Budget admission rejects equal-count source evidence for a different transaction"
    (any isSourceMismatch . NonEmpty.toList)
    (admitHouseholdBudgetMovementJournalFromResolvedJournal
      resolvedJournal
      equalCountDifferentBudgetSource)
  where
    resolvedJournal = mustRight (parseJournal budgetJournal)
    isSourceMismatch err = case err of
      BudgetMovementJournalTransactionSourceAlignmentMismatch 1 -> True
      _ -> False

budgetJournal :: T.Text
budgetJournal = declarations <> T.unlines
  [ "2026-08-01 Move to reserve"
  , "    budget:daily    -100 JPY"
  , "    budget:reserve   100 JPY"
  ]

equalCountDifferentBudgetSource :: T.Text
equalCountDifferentBudgetSource = declarations <> T.unlines
  [ "2026-08-01 Different move"
  , "    budget:daily    -101 JPY"
  , "    budget:reserve   101 JPY"
  ]

declarations :: T.Text
declarations = T.unlines
  [ "account budget:daily"
  , "    type: budget"
  , "    commodity: JPY"
  , ""
  , "account budget:reserve"
  , "    type: budget"
  , "    commodity: JPY"
  , ""
  ]

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

assertLeftSatisfies
  :: (Show error, Show value)
  => String
  -> (NonEmpty.NonEmpty error -> Bool)
  -> Either (NonEmpty.NonEmpty error) value
  -> IO ()
assertLeftSatisfies label predicate result = case result of
  Left errors
    | predicate errors -> putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    errors did not satisfy predicate: " ++ show errors)
        exitFailure
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure
