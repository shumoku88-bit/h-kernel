{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (mkAccount)
import HKernel.Editor.ActualWriter
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteIntent(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithAdmission
  )
import HKernel.Editor.BudgetMovementAppend
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.BudgetMovement.TSV
  ( parseHouseholdBudgetMovements )
import HKernel.Journal (parseJournal)
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)

main :: IO ()
main = do
  let tests =
        [ ("testNativeBudgetJournalCandidate", pure testNativeBudgetJournalCandidate)
        , ("testNativeBudgetJournalRejectsNonBudgetEndpoint", pure testNativeBudgetJournalRejectsNonBudgetEndpoint)
        , ("testValidBudgetMovement", pure testValidBudgetMovement)
        , ("testBudgetMovementCommit", testBudgetMovementCommit)
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

nativeRootSource :: Text
nativeRootSource = "include accounts.journal\n"

nativeLoadedSource :: Text
nativeLoadedSource = T.unlines
  [ "account budget:food"
  , "    type: budget"
  , "    commodity: JPY"
  , "account budget:living"
  , "    type: budget"
  , "    commodity: JPY"
  , "account assets:cash"
  , "    type: asset"
  , "    commodity: JPY"
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

testNativeBudgetJournalCandidate :: Bool
testNativeBudgetJournalCandidate =
  case prepareBudgetJournalMovementAppend
      (mustRight (parseJournal nativeLoadedSource))
      nativeRootSource
      testMovement of
    Left err -> error (show err)
    Right preview ->
      budgetJournalCandidateBlock preview == T.unlines
        [ "2026-08-04 transfer"
        , "    budget:food    -500 JPY"
        , "    budget:living    500 JPY"
        ]
      && nativeRootSource `T.isPrefixOf`
          budgetJournalCandidateCompleteSource preview

testNativeBudgetJournalRejectsNonBudgetEndpoint :: Bool
testNativeBudgetJournalRejectsNonBudgetEndpoint =
  let invalid = testMovement
        { householdBudgetMovementFrom =
            either (error "bad account") id (mkAccount "assets:cash")
        }
  in case prepareBudgetJournalMovementAppend
      (mustRight (parseJournal nativeLoadedSource))
      nativeRootSource
      invalid of
    Left (BudgetJournalEndpointNotBudget BudgetJournalFrom :| []) -> True
    _ -> False

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

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid fixture: " ++ show err)
