{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (mkAccount)
import HKernel.Account.Journal (parseAccountJournal)
import HKernel.Editor.BudgetMovementAppend
  ( BudgetJournalMovementAppendError(..)
  , BudgetJournalMovementAppendPreview(..)
  , prepareBudgetJournalMovementAppend
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteError(..)
  , WriteIntent(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithPathAdmission
  )
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..) )
import HKernel.Loader (loadJournal)
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)

main :: IO ()
main = do
  let tests =
        [ ("testNativeBudgetMovement", pure testNativeBudgetMovement)
        , ("testNativeBudgetMovementRejectsNonBudget", pure testNativeBudgetMovementRejectsNonBudget)
        , ("testPathAwareJournalCommit", testPathAwareJournalCommit)
        , ("testPathAwareJournalFailureRestores", testPathAwareJournalFailureRestores)
        ]
  results <- sequence [action | (_, action) <- tests]
  let namedResults = zip (map fst tests) results
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

testMovement :: HouseholdBudgetMovement
testMovement = HouseholdBudgetMovement
  { householdBudgetMovementDate = fromGregorian 2026 8 4
  , householdBudgetMovementMemo = "transfer"
  , householdBudgetMovementFrom = account "budget:from"
  , householdBudgetMovementTo = account "budget:to"
  , householdBudgetMovementAmount =
      mkAmount
        (either (error "bad commodity") id (mkCommodity "JPY"))
        (quantityFromInteger 500)
  }

testNativeBudgetMovement :: Bool
testNativeBudgetMovement =
  case prepareBudgetJournalMovementAppend registry pathAwareRoot testMovement of
    Right preview ->
      budgetJournalCandidateBlock preview == expectedBlock
        && budgetJournalCandidateCompleteSource preview == pathAwareCandidate
    Left err -> error (show err)
  where
    registry = either (error . show) id (parseAccountJournal pathAwareAccounts)
    expectedBlock = T.unlines
      [ "2026-08-04 transfer"
      , "    budget:from  -500 JPY"
      , "    budget:to  500 JPY"
      ]

testNativeBudgetMovementRejectsNonBudget :: Bool
testNativeBudgetMovementRejectsNonBudget =
  case prepareBudgetJournalMovementAppend mixedRegistry pathAwareRoot invalidMovement of
    Left (BudgetJournalMovementNotBudgetAccount found :| _) ->
      found == account "assets:cash"
    _ -> False
  where
    mixedRegistry = either (error . show) id (parseAccountJournal (pathAwareAccounts <> T.unlines
      [ "account assets:cash"
      , "    type: asset"
      , "    commodity: JPY"
      ]))
    invalidMovement = testMovement
      { householdBudgetMovementFrom = account "assets:cash" }

-- The root source is intentionally just an include before the candidate is
-- appended. Pure Text admission cannot prove this graph; the path-aware writer
-- can load the sibling Account declarations after publication.
testPathAwareJournalCommit :: IO Bool
testPathAwareJournalCommit = do
  let rootPath = "tests/fixtures/test_editor_path_budget.journal"
      accountsPath = "tests/fixtures/test_editor_path_accounts.journal"
  cleanup rootPath
  cleanup accountsPath
  TIO.writeFile accountsPath pathAwareAccounts
  TIO.writeFile rootPath pathAwareRoot
  result <- publishWithPathAdmission admitJournalPath
    WriteIntent
      { targetFilePath = rootPath
      , expectedOldBytes = ExpectedSource pathAwareRoot
      , candidateNewBytes = CandidateSource pathAwareCandidate
      }
  current <- TIO.readFile rootPath
  cleanup rootPath
  cleanup accountsPath
  pure (result == Right () && current == pathAwareCandidate)

testPathAwareJournalFailureRestores :: IO Bool
testPathAwareJournalFailureRestores = do
  let rootPath = "tests/fixtures/test_editor_path_reject.journal"
      accountsPath = "tests/fixtures/test_editor_path_accounts.journal"
  cleanup rootPath
  cleanup accountsPath
  TIO.writeFile accountsPath pathAwareAccounts
  TIO.writeFile rootPath pathAwareRoot
  result <- publishWithPathAdmission admitJournalPath
    WriteIntent
      { targetFilePath = rootPath
      , expectedOldBytes = ExpectedSource pathAwareRoot
      , candidateNewBytes = CandidateSource pathAwareInvalidCandidate
      }
  current <- TIO.readFile rootPath
  cleanup rootPath
  cleanup accountsPath
  pure $ case result of
    Left (PostAdmissionFailed _ True) -> current == pathAwareRoot
    _ -> False

data PathAdmissionError = PathAdmissionError
  deriving (Eq, Show)

admitJournalPath path = do
  result <- loadJournal path
  pure $ case result of
    Left _ -> Left (PathAdmissionError :| [])
    Right journal -> Right journal

pathAwareAccounts :: Text
pathAwareAccounts = T.unlines
  [ "account budget:from"
  , "    type: budget"
  , "    commodity: JPY"
  , "account budget:to"
  , "    type: budget"
  , "    commodity: JPY"
  ]

pathAwareRoot :: Text
pathAwareRoot = "include accounts.journal\n"

pathAwareCandidate :: Text
pathAwareCandidate = pathAwareRoot <> T.unlines
  [ ""
  , "2026-08-04 transfer"
  , "    budget:from  -500 JPY"
  , "    budget:to  500 JPY"
  ]

pathAwareInvalidCandidate :: Text
pathAwareInvalidCandidate = pathAwareRoot <> T.unlines
  [ ""
  , "2026-08-04 invalid transfer"
  , "    budget:from  -500 JPY"
  , "    budget:unknown  500 JPY"
  ]

account value = either (error . show) id (mkAccount value)

cleanup :: FilePath -> IO ()
cleanup path = do
  removeIfPresent path
  removeIfPresent (path <> ".backup.tmp")
  removeIfPresent (path <> ".new.tmp")

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  catch
    (removeTextFile defaultWriterFileSystem path)
    (\(_ :: IOException) -> pure ())
