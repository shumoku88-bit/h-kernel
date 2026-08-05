{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (mkAccount)
import HKernel.Editor.ActualWriter
  ( WriteIntent(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithAdmission
  )
import HKernel.Editor.BudgetMovementAppend
  ( BudgetMovementAppendPreview(..)
  , prepareBudgetMovementAppend
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.BudgetMovement.TSV
  ( parseHouseholdBudgetMovements )
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)

main :: IO ()
main = do
  let tests =
        [ ("testValidBudgetMovement", pure testValidBudgetMovement)
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
          , expectedOldBytes = fixtureSource
          , candidateNewBytes = candidateCompleteSource preview
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
