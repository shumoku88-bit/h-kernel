{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (mkAccount)
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Editor.BudgetMovementAppend (prepareBudgetMovementAppend, candidateBlock, BudgetMovementAppendPreview)

main :: IO ()
main = do
  let results = [ ("testValidBudgetMovement", testValidBudgetMovement) ]
  mapM_ print results
  if all snd results
    then exitSuccess
    else exitFailure

fixtureSource :: Text
fixtureSource = T.unlines
  [ "2026-08-01\topening\tbudget:living\tbudget:food\t1000\tcurrency=JPY"
  ]

testMovement :: HouseholdBudgetMovement
testMovement = HouseholdBudgetMovement
  { householdBudgetMovementDate   = fromGregorian 2026 8 4
  , householdBudgetMovementMemo   = "transfer"
  , householdBudgetMovementFrom   = either (error "bad from") id (mkAccount "budget:food")
  , householdBudgetMovementTo     = either (error "bad to") id (mkAccount "budget:living")
  , householdBudgetMovementAmount = mkAmount (either (error "bad comm") id (mkCommodity "JPY")) (quantityFromInteger 500)
  }

testValidBudgetMovement :: Bool
testValidBudgetMovement =
  let result = prepareBudgetMovementAppend fixtureSource testMovement
  in case result of
       Right preview ->
         let block = candidateBlock preview
         in "2026-08-04\ttransfer\tbudget:food\tbudget:living\t500\tcurrency=JPY" == block
       Left err -> error (show err)
