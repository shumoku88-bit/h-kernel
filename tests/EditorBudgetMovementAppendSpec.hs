{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (mkAccount)
import HKernel.Editor.ActualWriter (WriteIntent(..), publishWithAdmission)
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
  TIO.writeFile path fixtureSource
  case prepareBudgetMovementAppend fixtureSource testMovement of
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
