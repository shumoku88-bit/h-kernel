{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (Account, mkAccount)
import HKernel.Editor.ActualAppend (IntentPosting(..))
import HKernel.Editor.PlanLifecycle
import HKernel.Money (Commodity, Quantity, mkCommodity, parseQuantity)

main :: IO ()
main = do
  let results = [ ("testPlanAddSuccess", testPlanAddSuccess)
                , ("testPlanFinishSuccess", testPlanFinishSuccess)
                , ("testPlanFinishMissingAmount", testPlanFinishMissingAmount)
                ]
  mapM_ print results
  if all snd results
    then exitSuccess
    else exitFailure

planFixture :: Text
planFixture = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2023-01-01 existing plan"
  , "  ; plan-id: plan-2023-01-01-lunch"
  , "  assets:bank  -500 JPY"
  , "  expenses:food  500 JPY"
  ]

actualFixture :: Text
actualFixture = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2023-01-02 opening"
  , "  assets:bank  1000 JPY"
  , "  expenses:food  -1000 JPY"
  ]

accBank :: Account
accBank = either (error "bad account") id (mkAccount "assets:bank")

accFood :: Account
accFood = either (error "bad account") id (mkAccount "expenses:food")

qty :: Text -> Quantity
qty = either (error "bad qty") id . parseQuantity

comm :: Text -> Commodity
comm = either (error "bad comm") id . mkCommodity

testPlanAddSuccess :: Bool
testPlanAddSuccess =
  let intent = PlanAddIntent
        { addDate = fromGregorian 2023 1 3
        , addDescription = "Test Dinner"
        , addPostings = IntentPosting accBank (qty "-1500") (Just (comm "JPY"))
                     :| [IntentPosting accFood (qty "1500") (Just (comm "JPY"))]
        , addRequestedId = Nothing
        , addSeries = Nothing
        }
      result = preparePlanAdd planFixture actualFixture intent
  in case result of
       Right preview -> 
         let block = addCandidateBlock preview
         in "plan-2023-01-03-test-dinner" `T.isInfixOf` block
       Left err -> error (show err)

testPlanFinishSuccess :: Bool
testPlanFinishSuccess =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-lunch"
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Just (qty "600")
        }
      result = preparePlanFinish planFixture actualFixture intent
  in case result of
       Right preview -> 
         let block = finishCandidateBlock preview
         in "plan-2023-01-01-lunch" `T.isInfixOf` block && "600 JPY" `T.isInfixOf` block && "-600 JPY" `T.isInfixOf` block
       Left err -> error (show err)

testPlanFinishMissingAmount :: Bool
testPlanFinishMissingAmount =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-lunch"
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
      result = preparePlanFinish planFixture actualFixture intent
  in case result of
       Right preview -> 
         let block = finishCandidateBlock preview
         in "plan-2023-01-01-lunch" `T.isInfixOf` block && "500 JPY" `T.isInfixOf` block && "-500 JPY" `T.isInfixOf` block
       Left err -> error (show err)
