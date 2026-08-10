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
import HKernel.Journal (Journal, parseJournal)
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Money (Commodity, Quantity, mkCommodity, parseQuantity)
import HKernel.Plan (mkPlanId)
import HKernel.Plan.Journal
  ( identifiedPlanId
  , identifiedPlanTransaction
  , parsePlanJournal
  , planJournalTransactions
  )
import HKernel.Ledger
  ( postingAmount
  , transactionDate
  , transactionPostings
  )
import HKernel.Money (amountQuantity)

main :: IO ()
main = do
  let results =
        [ ("testPlanAddSuccess", testPlanAddSuccess)
        , ("testPlanAddUsesPlanAdmissionOnly", testPlanAddUsesPlanAdmissionOnly)
        , ("testPlanAddInvalidSeries", testPlanAddInvalidSeries)
        , ("testPlanEditDateAndAmountPreservesMetadata", testPlanEditDateAndAmountPreservesMetadata)
        , ("testPlanEditDateOnlyPreservesPostingText", testPlanEditDateOnlyPreservesPostingText)
        , ("testPlanEditAmountOnlyPreservesDate", testPlanEditAmountOnlyPreservesDate)
        , ("testPlanEditIgnoresDetachedPlanIdComment", testPlanEditIgnoresDetachedPlanIdComment)
        , ("testPlanEditNoOpRejected", testPlanEditNoOpRejected)
        , ("testPlanEditClosedRejected", testPlanEditClosedRejected)
        , ("testPlanEditMissingRejected", testPlanEditMissingRejected)
        , ("testPlanEditNonPositiveAmount", testPlanEditNonPositiveAmount)
        , ("testResolvedPlanAdd", testResolvedPlanAdd)
        , ("testResolvedPlanAddWithPlanInclude", testResolvedPlanAddWithPlanInclude)
        , ("testResolvedPlanEditCompletion", testResolvedPlanEditCompletion)
        , ("testResolvedPlanEditWithPlanInclude", testResolvedPlanEditWithPlanInclude)
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

planRootFixture :: Text
planRootFixture = T.unlines
  [ "include accounts.journal"
  , ""
  , "2023-01-01 existing plan"
  , "  ; plan-id: plan-2023-01-01-lunch"
  , "  assets:bank  -500 JPY"
  , "  expenses:food  500 JPY"
  ]

metadataRichPlanFixture :: Text
metadataRichPlanFixture = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2023-01-01 existing plan"
  , "  ; plan-id: plan-2023-01-01-lunch"
  , "  ; recur: monthly"
  , "  ; series: lunch-series"
  , "  ; daily-target-id: lunch-target"
  , "  ; reservation-id: lunch-reservation"
  , "  ; reservation-amount: 100"
  , "  ; reservation-commodity: JPY"
  , "  ; human note retained verbatim"
  , "  assets:bank  -500 JPY"
  , "  expenses:food  500 JPY"
  , "  ; trailing human note retained verbatim"
  ]

metadataRichPlanRootFixture :: Text
metadataRichPlanRootFixture = T.unlines
  [ "include accounts.journal"
  , ""
  , "2023-01-01 existing plan"
  , "  ; plan-id: plan-2023-01-01-lunch"
  , "  ; recur: monthly"
  , "  ; series: lunch-series"
  , "  ; daily-target-id: lunch-target"
  , "  ; reservation-id: lunch-reservation"
  , "  ; reservation-amount: 100"
  , "  ; reservation-commodity: JPY"
  , "  ; human note retained verbatim"
  , "  assets:bank  -500 JPY"
  , "  expenses:food  500 JPY"
  , "  ; trailing human note retained verbatim"
  ]

detachedDuplicatePlanIdFixture :: Text
detachedDuplicatePlanIdFixture = metadataRichPlanFixture <> T.unlines
  [ ""
  , "  ; plan-id: plan-2023-01-01-lunch"
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

actualRootFixture :: Text
actualRootFixture = T.unlines
  [ "include accounts.journal"
  , ""
  , "2023-01-02 opening"
  , "  assets:bank  1000 JPY"
  , "  expenses:food  -1000 JPY"
  ]

resolvedActualJournal :: Journal
resolvedActualJournal = either (error . show) id (parseJournal actualFixture)

resolvedPlanJournal :: Journal
resolvedPlanJournal = either (error . show) id (parseJournal planFixture)

resolvedMetadataRichPlanJournal :: Journal
resolvedMetadataRichPlanJournal =
  either (error . show) id (parseJournal metadataRichPlanFixture)

actualClosedRootFixture :: Text
actualClosedRootFixture = actualRootFixture <> T.unlines
  [ ""
  , "2023-01-03 completed lunch"
  , "  ; plan-id: plan-2023-01-01-lunch"
  , "  assets:bank  -500 JPY"
  , "  expenses:food  500 JPY"
  ]

resolvedClosedActualJournal :: Journal
resolvedClosedActualJournal =
  either (error . show) id (parseJournal actualClosedFixture)

actualClosedFixture :: Text
actualClosedFixture = actualFixture <> T.unlines
  [ ""
  , "2023-01-03 completed lunch"
  , "  ; plan-id: plan-2023-01-01-lunch"
  , "  assets:bank  -500 JPY"
  , "  expenses:food  500 JPY"
  ]

accBank :: Account
accBank = either (error "bad account") id (mkAccount "assets:bank")

accFood :: Account
accFood = either (error "bad account") id (mkAccount "expenses:food")

qty :: Text -> Quantity
qty = either (error "bad qty") id . parseQuantity

positiveEditQty :: Text -> PositivePlanEditAmount
positiveEditQty value =
  either (error "bad positive edit qty") id
    (mkPositivePlanEditAmount (qty value))

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

testPlanEditDateAndAmountPreservesMetadata :: Bool
testPlanEditDateAndAmountPreservesMetadata =
  let intent = PlanEditIntent
        { editPlanId = "plan-2023-01-01-lunch"
        , editDate = Just (fromGregorian 2023 1 7)
        , editAmount = Just (positiveEditQty "650")
        }
  in case preparePlanEdit metadataRichPlanFixture actualFixture intent of
       Left err -> error (show err)
       Right preview ->
         let block = editCandidateBlock preview
             candidate = editCandidateCompleteSource preview
             metadata =
               [ "; recur: monthly"
               , "; series: lunch-series"
               , "; daily-target-id: lunch-target"
               , "; reservation-id: lunch-reservation"
               , "; reservation-amount: 100"
               , "; reservation-commodity: JPY"
               , "; human note retained verbatim"
               , "; trailing human note retained verbatim"
               ]
         in "2023-01-07 existing plan" `T.isInfixOf` block
              && "-650 JPY" `T.isInfixOf` block
              && "650 JPY" `T.isInfixOf` block
              && all (`T.isInfixOf` block) metadata
              && case parsePlanJournal candidate of
                   Left _ -> False
                   Right journal -> case planJournalTransactions journal of
                     [identified] ->
                       transactionDate (identifiedPlanTransaction identified)
                         == fromGregorian 2023 1 7
                     _ -> False

testPlanEditDateOnlyPreservesPostingText :: Bool
testPlanEditDateOnlyPreservesPostingText =
  let intent = PlanEditIntent
        { editPlanId = "plan-2023-01-01-lunch"
        , editDate = Just (fromGregorian 2023 1 8)
        , editAmount = Nothing
        }
  in case preparePlanEdit metadataRichPlanFixture actualFixture intent of
       Left err -> error (show err)
       Right preview ->
         let original = editOriginalBlock preview
             candidate = editCandidateBlock preview
         in "assets:bank  -500 JPY" `T.isInfixOf` original
              && "assets:bank  -500 JPY" `T.isInfixOf` candidate
              && "expenses:food  500 JPY" `T.isInfixOf` candidate
              && "; reservation-id: lunch-reservation" `T.isInfixOf` candidate
              && "; trailing human note retained verbatim" `T.isInfixOf` candidate

testPlanEditAmountOnlyPreservesDate :: Bool
testPlanEditAmountOnlyPreservesDate =
  let intent = PlanEditIntent
        { editPlanId = "plan-2023-01-01-lunch"
        , editDate = Nothing
        , editAmount = Just (positiveEditQty "725")
        }
  in case preparePlanEdit metadataRichPlanFixture actualFixture intent of
       Left err -> error (show err)
       Right preview ->
         let block = editCandidateBlock preview
             targetId = either (error "bad plan id") id
               (mkPlanId "plan-2023-01-01-lunch")
         in "2023-01-01 existing plan" `T.isInfixOf` block
              && case parsePlanJournal (editCandidateCompleteSource preview) of
                   Left _ -> False
                   Right journal -> case filter ((== targetId) . identifiedPlanId)
                       (planJournalTransactions journal) of
                     [identified] ->
                       map (amountQuantity . postingAmount)
                         (toList (transactionPostings
                           (identifiedPlanTransaction identified)))
                         == [qty "-725", qty "725"]
                     _ -> False

testPlanEditIgnoresDetachedPlanIdComment :: Bool
testPlanEditIgnoresDetachedPlanIdComment =
  let intent = PlanEditIntent
        { editPlanId = "plan-2023-01-01-lunch"
        , editDate = Just (fromGregorian 2023 1 10)
        , editAmount = Nothing
        }
      planIdLine = "; plan-id: plan-2023-01-01-lunch"
  in case preparePlanEdit detachedDuplicatePlanIdFixture actualFixture intent of
       Left err -> error (show err)
       Right preview ->
         "2023-01-10 existing plan" `T.isInfixOf` editCandidateBlock preview
           && T.count planIdLine (editCandidateCompleteSource preview) == 2

testPlanEditNoOpRejected :: Bool
testPlanEditNoOpRejected =
  let intent = PlanEditIntent
        { editPlanId = "plan-2023-01-01-lunch"
        , editDate = Nothing
        , editAmount = Nothing
        }
  in case preparePlanEdit metadataRichPlanFixture actualFixture intent of
       Left (EditNoChange _ :| []) -> True
       _ -> False

testPlanEditClosedRejected :: Bool
testPlanEditClosedRejected =
  let intent = PlanEditIntent
        { editPlanId = "plan-2023-01-01-lunch"
        , editDate = Just (fromGregorian 2023 1 9)
        , editAmount = Nothing
        }
  in case preparePlanEdit metadataRichPlanFixture actualClosedFixture intent of
       Left (EditPlanAlreadyClosed _ :| []) -> True
       _ -> False

testPlanEditMissingRejected :: Bool
testPlanEditMissingRejected =
  let intent = PlanEditIntent
        { editPlanId = "plan-2099-01-01-missing"
        , editDate = Just (fromGregorian 2023 1 9)
        , editAmount = Nothing
        }
  in case preparePlanEdit metadataRichPlanFixture actualFixture intent of
       Left (EditPlanNotFound _ :| []) -> True
       _ -> False

testPlanEditNonPositiveAmount :: Bool
testPlanEditNonPositiveAmount =
  mkPositivePlanEditAmount (qty "0")
      == Left (NonPositivePlanEditAmount (qty "0"))
    && mkPositivePlanEditAmount (qty "-1")
      == Left (NonPositivePlanEditAmount (qty "-1"))

testResolvedPlanAdd :: Bool
testResolvedPlanAdd =
  isRight (preparePlanAddFromResolvedActualJournal
    resolvedActualJournal
    planFixture
    actualRootFixture
    (planAddIntent Nothing))

testResolvedPlanAddWithPlanInclude :: Bool
testResolvedPlanAddWithPlanInclude =
  isLeft (parsePlanJournal planRootFixture)
    && case preparePlanAddFromResolvedJournals
        resolvedPlanJournal
        resolvedActualJournal
        planRootFixture
        actualRootFixture
        (planAddIntent Nothing) of
      Right preview ->
        "include accounts.journal" `T.isPrefixOf`
          addCandidateCompleteSource preview
          && "plan-2023-01-03-test-dinner"
            `T.isInfixOf` addCandidateBlock preview
      Left err -> error (show err)

testResolvedPlanEditCompletion :: Bool
testResolvedPlanEditCompletion =
  let intent = PlanEditIntent
        { editPlanId = "plan-2023-01-01-lunch"
        , editDate = Just (fromGregorian 2023 1 9)
        , editAmount = Nothing
        }
  in case preparePlanEditFromResolvedActualJournal
      resolvedClosedActualJournal
      metadataRichPlanFixture
      actualClosedRootFixture
      intent of
    Left (EditPlanAlreadyClosed _ :| []) -> True
    _ -> False

testResolvedPlanEditWithPlanInclude :: Bool
testResolvedPlanEditWithPlanInclude =
  let intent = PlanEditIntent
        { editPlanId = "plan-2023-01-01-lunch"
        , editDate = Just (fromGregorian 2023 1 7)
        , editAmount = Just (positiveEditQty "650")
        }
      retainedMetadata =
        [ "; recur: monthly"
        , "; series: lunch-series"
        , "; daily-target-id: lunch-target"
        , "; reservation-id: lunch-reservation"
        , "; reservation-amount: 100"
        , "; reservation-commodity: JPY"
        , "; human note retained verbatim"
        , "; trailing human note retained verbatim"
        ]
  in isLeft (parsePlanJournal metadataRichPlanRootFixture)
      && case preparePlanEditFromResolvedJournals
          resolvedMetadataRichPlanJournal
          resolvedActualJournal
          metadataRichPlanRootFixture
          actualRootFixture
          intent of
        Right preview ->
          let block = editCandidateBlock preview
              candidate = editCandidateCompleteSource preview
          in "include accounts.journal" `T.isPrefixOf` candidate
              && "2023-01-07 existing plan" `T.isInfixOf` block
              && "-650 JPY" `T.isInfixOf` block
              && "650 JPY" `T.isInfixOf` block
              && all (`T.isInfixOf` block) retainedMetadata
        Left err -> error (show err)

toList :: NonEmpty a -> [a]
toList (x :| xs) = x : xs