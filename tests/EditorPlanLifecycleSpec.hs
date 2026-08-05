{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Either (isLeft, isRight)
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (Account, mkAccount)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Editor.PlanLifecycle
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Money (Commodity, Quantity, mkCommodity, parseQuantity)
import HKernel.Plan.Journal (parsePlanJournal)

main :: IO ()
main = do
  let results =
        [ ("testPlanAddSuccess", testPlanAddSuccess)
        , ("testPlanAddUsesPlanAdmissionOnly", testPlanAddUsesPlanAdmissionOnly)
        , ("testPlanAddInvalidSeries", testPlanAddInvalidSeries)
        , ("testPlanFinishSuccess", testPlanFinishSuccess)
        , ("testPlanFinishMissingAmount", testPlanFinishMissingAmount)
        , ("testPlanFinishNegativeAmount", testPlanFinishNegativeAmount)
        , ("testPlanFinishZeroAmount", testPlanFinishZeroAmount)
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

planFixtureWithActualOnlyMetadata :: Text
planFixtureWithActualOnlyMetadata = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2023-01-01 existing plan"
  , "  ; plan-id: plan-2023-01-01-lunch"
  , "  ; event-id: plan-source-event"
  , "  ; event-id: plan-source-event"
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

positiveQty :: Text -> PositivePlanFinishAmount
positiveQty value =
  either (error "bad positive qty") id
    (mkPositivePlanFinishAmount (qty value))

comm :: Text -> Commodity
comm = either (error "bad comm") id . mkCommodity

planAddIntent :: Maybe Text -> PlanAddIntent
planAddIntent series = PlanAddIntent
  { addDate = fromGregorian 2023 1 3
  , addDescription = "Test Dinner"
  , addPostings =
      IntentPosting accBank (qty "-1500") (Just (comm "JPY"))
      :| [IntentPosting accFood (qty "1500") (Just (comm "JPY"))]
  , addRequestedId = Nothing
  , addSeries = series
  }

testPlanAddSuccess :: Bool
testPlanAddSuccess =
  case preparePlanAdd planFixture actualFixture (planAddIntent Nothing) of
    Right preview ->
      "plan-2023-01-03-test-dinner"
        `T.isInfixOf` addCandidateBlock preview
    Left err -> error (show err)

testPlanAddUsesPlanAdmissionOnly :: Bool
testPlanAddUsesPlanAdmissionOnly =
  isRight (parsePlanJournal planFixtureWithActualOnlyMetadata)
    && isLeft (parseActualJournal planFixtureWithActualOnlyMetadata)
    && case preparePlanAdd
        planFixtureWithActualOnlyMetadata
        actualFixture
        (planAddIntent Nothing) of
          Right preview ->
            "plan-2023-01-03-test-dinner"
              `T.isInfixOf` addCandidateBlock preview
          Left err -> error (show err)

testPlanAddInvalidSeries :: Bool
testPlanAddInvalidSeries =
  case preparePlanAdd planFixture actualFixture
    (planAddIntent (Just "bad series")) of
      Left (AddGeneratedIdError _ :| []) -> True
      _ -> False

testPlanFinishSuccess :: Bool
testPlanFinishSuccess =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-lunch"
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Just (positiveQty "600")
        }
  in case preparePlanFinish planFixture actualFixture intent of
       Right preview ->
         let block = finishCandidateBlock preview
         in "plan-2023-01-01-lunch" `T.isInfixOf` block
              && "600 JPY" `T.isInfixOf` block
              && "-600 JPY" `T.isInfixOf` block
       Left err -> error (show err)

testPlanFinishMissingAmount :: Bool
testPlanFinishMissingAmount =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-lunch"
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
  in case preparePlanFinish planFixture actualFixture intent of
       Right preview ->
         let block = finishCandidateBlock preview
         in "plan-2023-01-01-lunch" `T.isInfixOf` block
              && "500 JPY" `T.isInfixOf` block
              && "-500 JPY" `T.isInfixOf` block
       Left err -> error (show err)

testPlanFinishNegativeAmount :: Bool
testPlanFinishNegativeAmount =
  mkPositivePlanFinishAmount (qty "-1")
    == Left (NonPositivePlanFinishAmount (qty "-1"))

testPlanFinishZeroAmount :: Bool
testPlanFinishZeroAmount =
  mkPositivePlanFinishAmount (qty "0")
    == Left (NonPositivePlanFinishAmount (qty "0"))
