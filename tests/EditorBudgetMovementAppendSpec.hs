{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (mkAccount)
import HKernel.Editor.ActualWriter
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteError(..)
  , WriteIntent(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithAdmission
  , publishWithPathAdmission
  )
import HKernel.Editor.BudgetMovementAppend
  ( BudgetMovementAppendPreview(..)
  , prepareBudgetMovementAppend
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.BudgetMovement.TSV
  ( parseHouseholdBudgetMovements )
import HKernel.Loader (loadJournal)
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)

main :: IO ()
main = do
  let tests =
        [ ("testValidBudgetMovement", pure testValidBudgetMovement)
        , ("testBudgetMovementCommit", testBudgetMovementCommit)
        , ("testPathAwareJournalCommit", testPathAwareJournalCommit)
        , ("testPathAwareJournalFailureRestores", testPathAwareJournalFailureRestores)
        ]
  results <- sequence [action | (_, action) <- tests]
  let namedResults = zip (map fst tests) results
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

fixtureSource :: Text
fixtureSource = T.unlines
  [ "2026-08-01\topening\tbudget:living\tbudget:food\t1000\tcurrency=JPY"
  ]

testMovement :: HouseholdBudgetMovement
testMovement = HouseholdBudgetMovement
  { householdBudgetMovementDate = fromGregorian 2026 8 4
  , householdBudgetMovementMemo = "transfer"
  , householdBudgetMovementFrom =
      either (error "bad from") id (mkAccount "budget:food")
  , householdBudgetMovementTo =
      either (error "bad to") id (mkAccount "budget:living")
  , householdBudgetMovementAmount =
      mkAmount
        (either (error "bad comm") id (mkCommodity "JPY"))
        (quantityFromInteger 500)
  }

testValidBudgetMovement :: Bool
testValidBudgetMovement =
  case prepareBudgetMovementAppend fixtureSource testMovement of
    Right preview ->
      candidateBlock preview
        == "2026-08-04\ttransfer\tbudget:food\tbudget:living\t500\tcurrency=JPY"
    Left err -> error (show err)

testBudgetMovementCommit :: IO Bool
testBudgetMovementCommit = do
  let path = "tests/fixtures/test_editor_budget_commit.tsv"
  cleanup path
  TIO.writeFile path fixtureSource
  result <- case prepareBudgetMovementAppend fixtureSource testMovement of
    Left err -> print err >> pure False
    Right preview -> do
      writeResult <- publishWithAdmission
        parseHouseholdBudgetMovements
        WriteIntent
          { targetFilePath = path
          , expectedOldBytes = ExpectedSource fixtureSource
          , candidateNewBytes = CandidateSource (candidateCompleteSource preview)
          }
      case writeResult of
        Left err -> print err >> pure False
        Right () ->
          (== candidateCompleteSource preview) <$> TIO.readFile path
  cleanup path
  pure result

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
pathAwareRoot = "include test_editor_path_accounts.journal\n"

pathAwareCandidate :: Text
pathAwareCandidate = pathAwareRoot <> T.unlines
  [ ""
  , "2026-08-04 transfer"
  , "    budget:from    -500 JPY"
  , "    budget:to       500 JPY"
  ]

pathAwareInvalidCandidate :: Text
pathAwareInvalidCandidate = pathAwareRoot <> T.unlines
  [ ""
  , "2026-08-04 invalid transfer"
  , "    budget:from       -500 JPY"
  , "    budget:unknown     500 JPY"
  ]

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
