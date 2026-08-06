{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Either (isLeft, isRight)
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (Account, mkAccount)
import HKernel.Actual.Journal
  ( ActualTransactionIdentity(..)
  , ActualTransactionRecord(..)
  , actualJournalCompletionDeclarations
  , actualJournalRecords
  , parseActualJournal
  )
import HKernel.Editor.ActualIdentity (admitActualEventIdentityText)
import HKernel.Editor.PlanLifecycle
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Money (Commodity, Quantity, mkCommodity, parseQuantity)
import HKernel.Plan (mkPlanId)
import HKernel.Plan.Completion
  ( ActualTransactionId
  , declaredCompletionPlanId
  , mkActualTransactionId
  )
import HKernel.Plan.Journal (parsePlanJournal)

main :: IO ()
main = do
  let results =
        [ ("testPlanAddSuccess", testPlanAddSuccess)
        , ("testPlanAddUsesPlanAdmissionOnly", testPlanAddUsesPlanAdmissionOnly)
        , ("testPlanAddInvalidSeries", testPlanAddInvalidSeries)
        , ("testPlanFinishSuccess", testPlanFinishSuccess)
        , ("testPlanFinishMetadataAndRelation", testPlanFinishMetadataAndRelation)
        , ("testPlanFinishMissingAmount", testPlanFinishMissingAmount)
        , ("testPlanFinishNegativeAmount", testPlanFinishNegativeAmount)
        , ("testPlanFinishZeroAmount", testPlanFinishZeroAmount)
        , ("testPlanFinishDirectPreparationBypassRejected", testPlanFinishDirectPreparationBypassRejected)
        , ("testPlanFinishCollisionRejected", testPlanFinishCollisionRejected)
        , ("testPlanFinishAlreadyClosed", testPlanFinishAlreadyClosed)
        , ("testPlanFinishNotFound", testPlanFinishNotFound)
        , ("testPlanFinishHistoricalPlanIdOnlyCompletionValid", testPlanFinishHistoricalPlanIdOnlyCompletionValid)
        , ("testPlanFinishInvalidPlanIdPrecedesInvalidEventId", testPlanFinishInvalidPlanIdPrecedesInvalidEventId)
        , ("testPlanFinishAlreadyClosedPrecedesEventIdCollision", testPlanFinishAlreadyClosedPrecedesEventIdCollision)
        , ("testPlanFinishNotFoundPrecedesInvalidEventId", testPlanFinishNotFoundPrecedesInvalidEventId)
        , ("testPlanFinishNotFoundPrecedesEventIdCollision", testPlanFinishNotFoundPrecedesEventIdCollision)
        , ("testPlanFinishAmountApplicabilityPrecedesInvalidEventId", testPlanFinishAmountApplicabilityPrecedesInvalidEventId)
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
  , ""
  , "2023-01-02 another plan"
  , "  ; plan-id: plan-2023-01-02-dinner"
  , "  assets:bank  -1000 JPY"
  , "  expenses:food  1000 JPY"
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

actualFixtureWithHistoricalCompletion :: Text
actualFixtureWithHistoricalCompletion = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2023-01-02 historical plan completion"
  , "  ; plan-id: plan-2023-01-01-lunch"
  , "  assets:bank  -500 JPY"
  , "  expenses:food  500 JPY"
  ]

actualFixtureWithExistingEventId :: Text
actualFixtureWithExistingEventId = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2023-01-02 existing actual with explicit id"
  , "  ; event-id: evt-550e8400-e29b-41d4-a716-446655440100"
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

sampleEventId :: ActualTransactionId
sampleEventId = either (error "bad event id") id
  (admitActualEventIdentityText "evt-550e8400-e29b-41d4-a716-446655440100")

sampleEventId2 :: ActualTransactionId
sampleEventId2 = either (error "bad event id") id
  (admitActualEventIdentityText "evt-550e8400-e29b-41d4-a716-446655440101")

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
        , finishActualEventId = sampleEventId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Just (positiveQty "600")
        }
  in case preparePlanFinish planFixture actualFixture intent of
       Right preview ->
         let block = finishCandidateBlock preview
         in "plan-2023-01-01-lunch" `T.isInfixOf` block
              && "evt-550e8400-e29b-41d4-a716-446655440100" `T.isInfixOf` block
              && "600 JPY" `T.isInfixOf` block
              && "-600 JPY" `T.isInfixOf` block
       Left err -> error (show err)

testPlanFinishMetadataAndRelation :: Bool
testPlanFinishMetadataAndRelation =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-lunch"
        , finishActualEventId = sampleEventId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Just (positiveQty "600")
        }
  in case preparePlanFinish planFixture actualFixture intent of
       Right preview ->
         let block = finishCandidateBlock preview
             completeSource = finishCandidateCompleteSource preview
             eventIdPos = T.breakOn "evt-550e8400-e29b-41d4-a716-446655440100" block
             planIdPos = T.breakOn "plan-2023-01-01-lunch" block
         in case parseActualJournal completeSource of
              Right admittedJ ->
                let decls = actualJournalCompletionDeclarations admittedJ
                    records = actualJournalRecords admittedJ
                    expectedPlanId = either (error "bad plan id") id (mkPlanId "plan-2023-01-01-lunch")
                in T.length (fst eventIdPos) < T.length (fst planIdPos)
                     && map declaredCompletionPlanId decls == [expectedPlanId]
                     && case reverse records of
                          (lastRec:_) -> actualRecordIdentity lastRec == ActualWithExplicitEventIdentity sampleEventId
                          [] -> False
              Left _ -> False
       Left err -> error (show err)

testPlanFinishMissingAmount :: Bool
testPlanFinishMissingAmount =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-lunch"
        , finishActualEventId = sampleEventId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
  in case preparePlanFinish planFixture actualFixture intent of
       Right preview ->
         let block = finishCandidateBlock preview
         in "plan-2023-01-01-lunch" `T.isInfixOf` block
              && "evt-550e8400-e29b-41d4-a716-446655440100" `T.isInfixOf` block
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

testPlanFinishDirectPreparationBypassRejected :: Bool
testPlanFinishDirectPreparationBypassRejected =
  let legacyId = either (error "bad id") id (mkActualTransactionId "legacy-plan-finish-event")
      intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-lunch"
        , finishActualEventId = legacyId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
  in case preparePlanFinish planFixture actualFixture intent of
       Left (FinishInvalidActualEventIdentity :| []) -> True
       _ -> False

testPlanFinishCollisionRejected :: Bool
testPlanFinishCollisionRejected =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-lunch"
        , finishActualEventId = sampleEventId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
  in case preparePlanFinish planFixture actualFixtureWithExistingEventId intent of
       Left (FinishActualEventIdentityAlreadyExists :| []) -> True
       _ -> False

testPlanFinishAlreadyClosed :: Bool
testPlanFinishAlreadyClosed =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-lunch"
        , finishActualEventId = sampleEventId2
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
  in case preparePlanFinish planFixture actualFixtureWithHistoricalCompletion intent of
       Left (FinishPlanAlreadyClosed pId :| []) ->
         pId == either (error "bad plan id") id (mkPlanId "plan-2023-01-01-lunch")
       _ -> False

testPlanFinishNotFound :: Bool
testPlanFinishNotFound =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-99-nonexistent"
        , finishActualEventId = sampleEventId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
  in case preparePlanFinish planFixture actualFixture intent of
       Left (FinishPlanNotFound _ :| []) -> True
       _ -> False

testPlanFinishHistoricalPlanIdOnlyCompletionValid :: Bool
testPlanFinishHistoricalPlanIdOnlyCompletionValid =
  case parseActualJournal actualFixtureWithHistoricalCompletion of
    Right actualJ ->
      let decls = actualJournalCompletionDeclarations actualJ
          records = actualJournalRecords actualJ
          isDerivedOrigin rec = case actualRecordIdentity rec of
            ActualWithPlanDerivedRuntimeIdentity _ _ -> True
            _ -> False
      in length decls == 1
           && any isDerivedOrigin records
    Left _ -> False

planFixtureWithThreePostings :: Text
planFixtureWithThreePostings = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , "account expenses:tax"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2023-01-01 multi posting plan"
  , "  ; plan-id: plan-2023-01-01-multi"
  , "  assets:bank  -1100 JPY"
  , "  expenses:food  1000 JPY"
  , "  expenses:tax  100 JPY"
  ]

testPlanFinishInvalidPlanIdPrecedesInvalidEventId :: Bool
testPlanFinishInvalidPlanIdPrecedesInvalidEventId =
  let legacyId = either (error "bad id") id (mkActualTransactionId "legacy-plan-finish-event")
      intent = PlanFinishIntent
        { finishPlanId = "invalid plan id format!!"
        , finishActualEventId = legacyId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
  in case preparePlanFinish planFixture actualFixture intent of
       Left (FinishInvalidId _ :| []) -> True
       _ -> False

testPlanFinishAlreadyClosedPrecedesEventIdCollision :: Bool
testPlanFinishAlreadyClosedPrecedesEventIdCollision =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-lunch"
        , finishActualEventId = sampleEventId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
      fixtureWithClosedAndCollision = T.unlines
        [ actualFixtureWithHistoricalCompletion
        , ""
        , "2023-01-02 existing actual with explicit id"
        , "  ; event-id: evt-550e8400-e29b-41d4-a716-446655440100"
        , "  assets:bank  1000 JPY"
        , "  expenses:food  -1000 JPY"
        ]
  in case preparePlanFinish planFixture fixtureWithClosedAndCollision intent of
       Left (FinishPlanAlreadyClosed pId :| []) ->
         pId == either (error "bad plan id") id (mkPlanId "plan-2023-01-01-lunch")
       _ -> False

testPlanFinishNotFoundPrecedesInvalidEventId :: Bool
testPlanFinishNotFoundPrecedesInvalidEventId =
  let legacyId = either (error "bad id") id (mkActualTransactionId "legacy-plan-finish-event")
      intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-99-nonexistent"
        , finishActualEventId = legacyId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
  in case preparePlanFinish planFixture actualFixture intent of
       Left (FinishPlanNotFound pId :| []) ->
         pId == either (error "bad plan id") id (mkPlanId "plan-2023-01-99-nonexistent")
       _ -> False

testPlanFinishNotFoundPrecedesEventIdCollision :: Bool
testPlanFinishNotFoundPrecedesEventIdCollision =
  let intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-99-nonexistent"
        , finishActualEventId = sampleEventId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Nothing
        }
  in case preparePlanFinish planFixture actualFixtureWithExistingEventId intent of
       Left (FinishPlanNotFound pId :| []) ->
         pId == either (error "bad plan id") id (mkPlanId "plan-2023-01-99-nonexistent")
       _ -> False

testPlanFinishAmountApplicabilityPrecedesInvalidEventId :: Bool
testPlanFinishAmountApplicabilityPrecedesInvalidEventId =
  let legacyId = either (error "bad id") id (mkActualTransactionId "legacy-plan-finish-event")
      intent = PlanFinishIntent
        { finishPlanId = "plan-2023-01-01-multi"
        , finishActualEventId = legacyId
        , finishActualDate = fromGregorian 2023 1 2
        , finishActualAmount = Just (positiveQty "600")
        }
  in case preparePlanFinish planFixtureWithThreePostings actualFixture intent of
       Left (FinishActualAmountOnlyForBinaryPlan :| []) -> True
       _ -> False
