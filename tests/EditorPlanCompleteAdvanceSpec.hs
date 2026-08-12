{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (IOException, catch, throwIO)
import Control.Monad (when)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Directory (doesFileExist, removeFile)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Actual.Journal
  ( ActualJournal
  , admitActualJournalFromResolvedJournal
  )
import HKernel.Editor.SourcePublication
  ( WriterFileSystem(..)
  , defaultWriterFileSystem
  )
import HKernel.Editor.Interaction.PlanCompleteAdvance
  ( PlanCompleteAdvanceInput(..)
  , initialPlanCompleteAdvanceInput
  , parsePlanCompleteAdvanceInput
  )
import HKernel.Editor.PlanCompleteAdvance
import HKernel.Journal (parseJournal)
import HKernel.Money (parseQuantity)
import HKernel.Plan (PlanId, mkPlanId)
import HKernel.Plan.Journal
  ( PlanJournal
  , admitPlanJournalFromResolvedJournal
  , identifiedPlanId
  )

main :: IO ()
main = do
  let pureResults =
        [ ("monthly proposal uses nominal date", testMonthlyNominalDate)
        , ("interaction defaults to today and nominal successor", testInteractionDefaults)
        , ("interaction keeps four editable coordinates independent", testInteractionOverrides)
        , ("Plan magnitude requires positive quantity", testPlanMagnitudeAdmission)
        , ("actual amount does not rewrite successor default", testAmountSeparation)
        , ("daily-target identity refreshes", testDailyTargetRefresh)
        , ("completion ignores advance-only recurrence admission", testCompletionDoesNotAdmitRecurrence)
        , ("completion keeps original amount and Plan source", testCompletionUsesOriginalAmount)
        , ("completion applies explicit binary amount", testCompletionAmountOverride)
        , ("completion rejects already closed Plan", testCompletionClosed)
        , ("completion rejects missing Plan", testCompletionMissing)
        , ("once recurrence forbids successor", testOnceNoSuccessor)
        , ("cycle recurrence requires explicit date", testCycleManualDate)
        , ("series relation derives active members and latest", testSeriesSafetyAssessment)
        , ("duplicate-looking active successor fails closed", testDuplicateActiveSuccessor)
        , ("closed duplicate no longer blocks successor", testClosedDuplicateIgnored)
        , ("exact relation fallback guards duplicate without series", testExactFallbackDuplicate)
        ]
  writerResults <- sequence
    [ namedIO "coordinated writer publishes both" testWriterSuccess
    , namedIO "coordinated writer rejects stale input" testWriterStale
    , namedIO "coordinated writer rejects stale input after staging" testWriterPrePublishStale
    , namedIO "coordinated writer protects Plan change between installs" testWriterPlanChangesBetweenInstalls
    , namedIO "coordinated writer protects Actual change before admission" testWriterActualChangesBeforeAdmission
    , namedIO "successful admission cannot mask later Actual" testWriterSuccessAdmissionDoesNotMaskLaterActual
    , namedIO "coordinated writer rolls both back" testWriterRollback
    , namedIO "coordinated rollback protects later writer" testWriterRollbackProtectsLaterWrite
    , namedIO "partial installation restores expected roots" testWriterPartialInstallFailure
    ]
  let results = pureResults ++ writerResults
  mapM_ print results
  if all snd results then exitSuccess else exitFailure
  where
    namedIO name action = do
      result <- action
      pure (name, result)

monthlyPlanSource :: Text
monthlyPlanSource = T.unlines
  [ "include accounts.journal"
  , ""
  , "2031-01-17 sample recurring payment"
  , "  ; plan-id: plan-2031-01-17-sample-series"
  , "  ; daily-target-id: sample-target-001"
  , "  ; series: sample-series"
  , "  ; recur: monthly"
  , "  ; currency: JPY"
  , "  expenses:test-service  1234 JPY"
  , "  assets:test-bank  -1234 JPY"
  ]

invalidRecurrencePlanSource :: Text
invalidRecurrencePlanSource = T.replace
  "  ; recur: monthly"
  "  ; recur: every-third-moon"
  monthlyPlanSource

duplicateSeriesPlanSource :: Text
duplicateSeriesPlanSource = monthlyPlanSource <> T.unlines
  [ ""
  , "2031-02-17 sample recurring payment"
  , "  ; plan-id: plan-2031-02-17-sample-series-existing"
  , "  ; series: sample-series"
  , "  ; recur: monthly"
  , "  expenses:test-service  1234 JPY"
  , "  assets:test-bank  -1234 JPY"
  , ""
  , "2031-02-17 sample recurring payment"
  , "  ; plan-id: plan-2031-02-17-other-series"
  , "  ; series: other-series"
  , "  ; recur: monthly"
  , "  expenses:test-service  1234 JPY"
  , "  assets:test-bank  -1234 JPY"
  ]

seriesSafetyPlanSource :: Text
seriesSafetyPlanSource = monthlyPlanSource <> T.unlines
  [ ""
  , "2031-02-17 changed amount in same series"
  , "  ; plan-id: plan-2031-02-17-sample-series-changed"
  , "  ; series: sample-series"
  , "  ; recur: monthly"
  , "  expenses:test-service  1300 JPY"
  , "  assets:test-bank  -1300 JPY"
  , ""
  , "2031-03-17 later member in same series"
  , "  ; plan-id: plan-2031-03-17-sample-series-latest"
  , "  ; series: sample-series"
  , "  ; recur: monthly"
  , "  expenses:test-service  1400 JPY"
  , "  assets:test-bank  -1400 JPY"
  , ""
  , "2031-04-17 unrelated member"
  , "  ; plan-id: plan-2031-04-17-other-series"
  , "  ; series: other-series"
  , "  ; recur: monthly"
  , "  expenses:test-service  1500 JPY"
  , "  assets:test-bank  -1500 JPY"
  ]

exactFallbackPlanSource :: Text
exactFallbackPlanSource = T.unlines
  [ "include accounts.journal"
  , ""
  , "2031-04-10 exact fallback payment"
  , "  ; plan-id: exact-fallback-current"
  , "  ; recur: monthly"
  , "  expenses:test-service  777 JPY"
  , "  assets:test-bank  -777 JPY"
  , ""
  , "2031-05-10 exact fallback payment"
  , "  ; plan-id: exact-fallback-existing"
  , "  expenses:test-service  777 JPY"
  , "  assets:test-bank  -777 JPY"
  ]

oncePlanSource :: Text
oncePlanSource = T.unlines
  [ "include accounts.journal"
  , ""
  , "2031-02-03 sample one-off"
  , "  ; plan-id: plan-2031-02-03-sample-once"
  , "  ; recur: once"
  , "  expenses:test-service  2222 JPY"
  , "  assets:test-bank  -2222 JPY"
  ]

cyclePlanSource :: Text
cyclePlanSource = T.unlines
  [ "include accounts.journal"
  , ""
  , "2031-03-05 sample cycle payment"
  , "  ; plan-id: plan-2031-03-05-sample-cycle"
  , "  ; series: sample-cycle"
  , "  ; recur: cycle"
  , "  ; anchor: income:test-cycle-anchor"
  , "  ; offset: 0"
  , "  expenses:test-service  4321 JPY"
  , "  assets:test-bank  -4321 JPY"
  ]

accountsResolved :: Text
accountsResolved = T.unlines
  [ "account assets:test-bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:test-service"
  , "  type: Expense"
  , "  commodity: JPY"
  , "account income:test-cycle-anchor"
  , "  type: Income"
  , "  commodity: JPY"
  ]

actualRoot :: Text
actualRoot = "include accounts.journal\n"

closedMonthlyActualSource :: Text
closedMonthlyActualSource = T.unlines
  [ "include accounts.journal"
  , ""
  , "2031-01-17 sample recurring payment"
  , "  ; plan-id: plan-2031-01-17-sample-series"
  , "  expenses:test-service  1234 JPY"
  , "  assets:test-bank  -1234 JPY"
  ]

closedDuplicateActualSource :: Text
closedDuplicateActualSource = T.unlines
  [ "include accounts.journal"
  , ""
  , "2031-02-17 sample recurring payment"
  , "  ; plan-id: plan-2031-02-17-sample-series-existing"
  , "  expenses:test-service  1234 JPY"
  , "  assets:test-bank  -1234 JPY"
  ]

resolvedSource :: Text -> Text
resolvedSource root = accountsResolved <> "\n" <> T.unlines (drop 1 (T.lines root))

admitPlan :: Text -> Maybe PlanJournal
admitPlan root = do
  journal <- either (const Nothing) Just (parseJournal (resolvedSource root))
  either (const Nothing) Just (admitPlanJournalFromResolvedJournal journal root)

admitActualSource :: Text -> Maybe ActualJournal
admitActualSource root = do
  journal <- either (const Nothing) Just (parseJournal (resolvedSource root))
  either (const Nothing) Just (admitActualJournalFromResolvedJournal journal root)

admitActual :: Maybe ActualJournal
admitActual = admitActualSource actualRoot

planId :: Text -> Maybe PlanId
planId value = either (const Nothing) Just (mkPlanId value)

positive :: Text -> Maybe PositivePlanMagnitude
positive value = do
  quantity <- either (const Nothing) Just (parseQuantity value)
  either (const Nothing) Just (mkPositivePlanMagnitude quantity)

testPlanMagnitudeAdmission :: Bool
testPlanMagnitudeAdmission =
  case (parseQuantity "0", parseQuantity "-1") of
    (Right zero, Right negative) ->
      mkPositivePlanMagnitude zero == Left (NonPositivePlanMagnitude zero)
        && mkPositivePlanMagnitude negative
          == Left (NonPositivePlanMagnitude negative)
    _ -> False

withMonthly
  :: (PlanJournal -> ActualJournal -> PlanId -> Bool)
  -> Bool
withMonthly check = case
    (admitPlan monthlyPlanSource, admitActual, planId "plan-2031-01-17-sample-series") of
  (Just planJournal, Just actualJournal, Just target) ->
    check planJournal actualJournal target
  _ -> False

testMonthlyNominalDate :: Bool
testMonthlyNominalDate = withMonthly $ \planJournal _ target ->
  case proposePlanAdvance planJournal target of
    Right proposal ->
      proposalNominalDate proposal == fromGregorian 2031 1 17
        && proposalSuggestedNextDate proposal == Just (fromGregorian 2031 2 17)
        && proposalRecurrence proposal == PlanRecursMonthly
    Left _ -> False

testInteractionDefaults :: Bool
testInteractionDefaults = withMonthly $ \planJournal _ target ->
  case proposePlanAdvance planJournal target of
    Left _ -> False
    Right proposal ->
      let input = initialPlanCompleteAdvanceInput (fromGregorian 2031 1 16) proposal
      in planActualDateText input == "2031-01-16"
          && planActualAmountText input == ""
          && planSuccessorDateText input == "2031-02-17"
          && planSuccessorAmountText input == ""

testInteractionOverrides :: Bool
testInteractionOverrides = withMonthly $ \planJournal _ target ->
  case proposePlanAdvance planJournal target of
    Left _ -> False
    Right proposal ->
      let input = PlanCompleteAdvanceInput
            { planActualDateText = "2031-01-16"
            , planActualAmountText = "1201"
            , planSuccessorDateText = "2031-02-18"
            , planSuccessorAmountText = "1307"
            }
      in case parsePlanCompleteAdvanceInput proposal input of
          Left _ -> False
          Right intent ->
            completeAdvancePlanId intent == target
              && completeAdvanceActualDate intent == fromGregorian 2031 1 16
              && completeAdvanceActualAmount intent == positive "1201"
              && completeAdvanceSuccessorDate intent == Just (fromGregorian 2031 2 18)
              && completeAdvanceSuccessorAmount intent == positive "1307"

testAmountSeparation :: Bool
testAmountSeparation = withMonthly $ \planJournal actualJournal target ->
  case positive "1201" of
    Nothing -> False
    Just actualAmount ->
      case preparePlanCompleteAdvance
          planJournal
          actualJournal
          monthlyPlanSource
          actualRoot
          PlanCompleteAdvanceIntent
            { completeAdvancePlanId = target
            , completeAdvanceActualDate = fromGregorian 2031 1 16
            , completeAdvanceActualAmount = Just actualAmount
            , completeAdvanceSuccessorDate = Just (fromGregorian 2031 2 17)
            , completeAdvanceSuccessorAmount = Nothing
            } of
        Left _ -> False
        Right preview ->
          "1201 JPY" `T.isInfixOf` completeAdvanceActualBlock preview
            && maybe False ("1234 JPY" `T.isInfixOf`)
              (completeAdvanceSuccessorBlock preview)
            && not (maybe False ("1201 JPY" `T.isInfixOf`)
              (completeAdvanceSuccessorBlock preview))

testDailyTargetRefresh :: Bool
testDailyTargetRefresh = withMonthly $ \planJournal actualJournal target ->
  case preparePlanCompleteAdvance
      planJournal
      actualJournal
      monthlyPlanSource
      actualRoot
      PlanCompleteAdvanceIntent
        { completeAdvancePlanId = target
        , completeAdvanceActualDate = fromGregorian 2031 1 16
        , completeAdvanceActualAmount = Nothing
        , completeAdvanceSuccessorDate = Just (fromGregorian 2031 2 17)
        , completeAdvanceSuccessorAmount = Nothing
        } of
    Left _ -> False
    Right preview -> case completeAdvanceSuccessorBlock preview of
      Nothing -> False
      Just block ->
        "daily-target-id: plan-2031-02-17-sample-series-daily-target" `T.isInfixOf` block
          && not ("daily-target-id: sample-target-001" `T.isInfixOf` block)
          && "recur: monthly" `T.isInfixOf` block
          && "series: sample-series" `T.isInfixOf` block

testCompletionDoesNotAdmitRecurrence :: Bool
testCompletionDoesNotAdmitRecurrence = case
    ( admitPlan invalidRecurrencePlanSource
    , admitActual
    , planId "plan-2031-01-17-sample-series"
    ) of
  (Just planJournal, Just actualJournal, Just target) ->
    let completionOnly = preparePlanCompleteAdvance
          planJournal
          actualJournal
          invalidRecurrencePlanSource
          actualRoot
          PlanCompleteAdvanceIntent
            { completeAdvancePlanId = target
            , completeAdvanceActualDate = fromGregorian 2031 1 16
            , completeAdvanceActualAmount = Nothing
            , completeAdvanceSuccessorDate = Nothing
            , completeAdvanceSuccessorAmount = Nothing
            }
        advanceRequested = preparePlanCompleteAdvance
          planJournal
          actualJournal
          invalidRecurrencePlanSource
          actualRoot
          PlanCompleteAdvanceIntent
            { completeAdvancePlanId = target
            , completeAdvanceActualDate = fromGregorian 2031 1 16
            , completeAdvanceActualAmount = Nothing
            , completeAdvanceSuccessorDate = Just (fromGregorian 2031 2 17)
            , completeAdvanceSuccessorAmount = Nothing
            }
    in case (completionOnly, advanceRequested) of
      (Right preview, Left errors) ->
        completeAdvanceSuccessorBlock preview == Nothing
          && completeAdvancePlanSource preview == invalidRecurrencePlanSource
          && CompleteAdvanceInvalidRecurrence "every-third-moon"
            `elem` NonEmpty.toList errors
      _ -> False
  _ -> False

testCompletionUsesOriginalAmount :: Bool
testCompletionUsesOriginalAmount = withMonthly $ \planJournal actualJournal target ->
  case preparePlanCompleteAdvance
      planJournal
      actualJournal
      monthlyPlanSource
      actualRoot
      PlanCompleteAdvanceIntent
        { completeAdvancePlanId = target
        , completeAdvanceActualDate = fromGregorian 2031 1 16
        , completeAdvanceActualAmount = Nothing
        , completeAdvanceSuccessorDate = Nothing
        , completeAdvanceSuccessorAmount = Nothing
        } of
    Right preview ->
      "; plan-id: plan-2031-01-17-sample-series"
        `T.isInfixOf` completeAdvanceActualBlock preview
        && "1234 JPY" `T.isInfixOf` completeAdvanceActualBlock preview
        && "-1234 JPY" `T.isInfixOf` completeAdvanceActualBlock preview
        && completeAdvanceSuccessorBlock preview == Nothing
        && completeAdvancePlanSource preview == monthlyPlanSource
    Left _ -> False

testCompletionAmountOverride :: Bool
testCompletionAmountOverride = withMonthly $ \planJournal actualJournal target ->
  case positive "1300" of
    Nothing -> False
    Just replacement -> case preparePlanCompleteAdvance
        planJournal
        actualJournal
        monthlyPlanSource
        actualRoot
        PlanCompleteAdvanceIntent
          { completeAdvancePlanId = target
          , completeAdvanceActualDate = fromGregorian 2031 1 16
          , completeAdvanceActualAmount = Just replacement
          , completeAdvanceSuccessorDate = Nothing
          , completeAdvanceSuccessorAmount = Nothing
          } of
      Right preview ->
        "1300 JPY" `T.isInfixOf` completeAdvanceActualBlock preview
          && "-1300 JPY" `T.isInfixOf` completeAdvanceActualBlock preview
          && not ("1234 JPY" `T.isInfixOf` completeAdvanceActualBlock preview)
          && completeAdvancePlanSource preview == monthlyPlanSource
      Left _ -> False

testCompletionClosed :: Bool
testCompletionClosed = case
    ( admitPlan monthlyPlanSource
    , admitActualSource closedMonthlyActualSource
    , planId "plan-2031-01-17-sample-series"
    ) of
  (Just planJournal, Just actualJournal, Just target) ->
    case preparePlanCompleteAdvance
        planJournal
        actualJournal
        monthlyPlanSource
        closedMonthlyActualSource
        PlanCompleteAdvanceIntent
          { completeAdvancePlanId = target
          , completeAdvanceActualDate = fromGregorian 2031 1 18
          , completeAdvanceActualAmount = Nothing
          , completeAdvanceSuccessorDate = Nothing
          , completeAdvanceSuccessorAmount = Nothing
          } of
      Left errors -> CompleteAdvancePlanAlreadyClosed target
        `elem` NonEmpty.toList errors
      Right _ -> False
  _ -> False

testCompletionMissing :: Bool
testCompletionMissing = case
    ( admitPlan monthlyPlanSource
    , admitActual
    , planId "plan-missing"
    ) of
  (Just planJournal, Just actualJournal, Just missing) ->
    case preparePlanCompleteAdvance
        planJournal
        actualJournal
        monthlyPlanSource
        actualRoot
        PlanCompleteAdvanceIntent
          { completeAdvancePlanId = missing
          , completeAdvanceActualDate = fromGregorian 2031 1 16
          , completeAdvanceActualAmount = Nothing
          , completeAdvanceSuccessorDate = Nothing
          , completeAdvanceSuccessorAmount = Nothing
          } of
      Left errors -> CompleteAdvancePlanNotFound missing
        `elem` NonEmpty.toList errors
      Right _ -> False
  _ -> False

testOnceNoSuccessor :: Bool
testOnceNoSuccessor = case
    (admitPlan oncePlanSource, admitActual, planId "plan-2031-02-03-sample-once") of
  (Just planJournal, Just actualJournal, Just target) ->
    case proposePlanAdvance planJournal target of
      Left _ -> False
      Right proposal ->
        proposalSuggestedNextDate proposal == Nothing
          && case preparePlanCompleteAdvance
              planJournal
              actualJournal
              oncePlanSource
              actualRoot
              PlanCompleteAdvanceIntent
                { completeAdvancePlanId = target
                , completeAdvanceActualDate = fromGregorian 2031 2 3
                , completeAdvanceActualAmount = Nothing
                , completeAdvanceSuccessorDate = Just (fromGregorian 2031 3 3)
                , completeAdvanceSuccessorAmount = Nothing
                } of
              Left errors ->
                CompleteAdvanceSuccessorForbiddenForOnce
                  `elem` NonEmpty.toList errors
              Right _ -> False
  _ -> False

testCycleManualDate :: Bool
testCycleManualDate = case
    (admitPlan cyclePlanSource, admitActual, planId "plan-2031-03-05-sample-cycle") of
  (Just planJournal, Just actualJournal, Just target) ->
    case proposePlanAdvance planJournal target of
      Left _ -> False
      Right proposal ->
        proposalRecurrence proposal == PlanRecursByHouseholdCycle
          && proposalSuggestedNextDate proposal == Nothing
          && case preparePlanCompleteAdvance
              planJournal
              actualJournal
              cyclePlanSource
              actualRoot
              PlanCompleteAdvanceIntent
                { completeAdvancePlanId = target
                , completeAdvanceActualDate = fromGregorian 2031 3 4
                , completeAdvanceActualAmount = Nothing
                , completeAdvanceSuccessorDate = Just (fromGregorian 2031 5 7)
                , completeAdvanceSuccessorAmount = Nothing
                } of
              Right preview -> maybe False
                ("2031-05-07 sample cycle payment" `T.isInfixOf`)
                (completeAdvanceSuccessorBlock preview)
              Left _ -> False
  _ -> False

testSeriesSafetyAssessment :: Bool
testSeriesSafetyAssessment = case
    ( admitPlan seriesSafetyPlanSource
    , admitActual
    , planId "plan-2031-01-17-sample-series"
    , planId "plan-2031-02-17-sample-series-changed"
    , planId "plan-2031-03-17-sample-series-latest"
    ) of
  (Just planJournal, Just actualJournal, Just target, Just februaryId, Just marchId) ->
    case assessPlanAdvanceSafety planJournal actualJournal target of
      Left _ -> False
      Right safety ->
        map identifiedPlanId (advanceRelatedActivePlans safety) == [februaryId, marchId]
          && fmap identifiedPlanId (advanceLatestRelatedActivePlan safety) == Just marchId
  _ -> False

testDuplicateActiveSuccessor :: Bool
testDuplicateActiveSuccessor = case
    ( admitPlan duplicateSeriesPlanSource
    , admitActual
    , planId "plan-2031-01-17-sample-series"
    , planId "plan-2031-02-17-sample-series-existing"
    ) of
  (Just planJournal, Just actualJournal, Just target, Just conflict) ->
    case preparePlanCompleteAdvance
        planJournal
        actualJournal
        duplicateSeriesPlanSource
        actualRoot
        PlanCompleteAdvanceIntent
          { completeAdvancePlanId = target
          , completeAdvanceActualDate = fromGregorian 2031 1 17
          , completeAdvanceActualAmount = Nothing
          , completeAdvanceSuccessorDate = Just (fromGregorian 2031 2 17)
          , completeAdvanceSuccessorAmount = Nothing
          } of
      Left errors -> CompleteAdvanceDuplicateLookingSuccessor conflict
        `elem` NonEmpty.toList errors
      Right _ -> False
  _ -> False

testClosedDuplicateIgnored :: Bool
testClosedDuplicateIgnored = case
    ( admitPlan duplicateSeriesPlanSource
    , admitActualSource closedDuplicateActualSource
    , planId "plan-2031-01-17-sample-series"
    ) of
  (Just planJournal, Just actualJournal, Just target) ->
    case preparePlanCompleteAdvance
        planJournal
        actualJournal
        duplicateSeriesPlanSource
        closedDuplicateActualSource
        PlanCompleteAdvanceIntent
          { completeAdvancePlanId = target
          , completeAdvanceActualDate = fromGregorian 2031 1 17
          , completeAdvanceActualAmount = Nothing
          , completeAdvanceSuccessorDate = Just (fromGregorian 2031 2 17)
          , completeAdvanceSuccessorAmount = Nothing
          } of
      Right preview -> case completeAdvanceSuccessorPlanId preview of
        Just successorId -> successorId /= target
        Nothing -> False
      Left _ -> False
  _ -> False

testExactFallbackDuplicate :: Bool
testExactFallbackDuplicate = case
    ( admitPlan exactFallbackPlanSource
    , admitActual
    , planId "exact-fallback-current"
    , planId "exact-fallback-existing"
    ) of
  (Just planJournal, Just actualJournal, Just target, Just conflict) ->
    case preparePlanCompleteAdvance
        planJournal
        actualJournal
        exactFallbackPlanSource
        actualRoot
        PlanCompleteAdvanceIntent
          { completeAdvancePlanId = target
          , completeAdvanceActualDate = fromGregorian 2031 4 10
          , completeAdvanceActualAmount = Nothing
          , completeAdvanceSuccessorDate = Just (fromGregorian 2031 5 10)
          , completeAdvanceSuccessorAmount = Nothing
          } of
      Left errors -> CompleteAdvanceDuplicateLookingSuccessor conflict
        `elem` NonEmpty.toList errors
      Right _ -> False
  _ -> False

actualFixture :: FilePath
actualFixture = "tests/fixtures/complete-advance-actual.journal"

planFixture :: FilePath
planFixture = "tests/fixtures/complete-advance-plan.journal"

withWriterFixtures :: (FilePath -> FilePath -> IO Bool) -> IO Bool
withWriterFixtures action = do
  cleanup
  TIO.writeFile actualFixture "actual-old"
  TIO.writeFile planFixture "plan-old"
  result <- action actualFixture planFixture
    `catch` (\(_ :: IOException) -> pure False)
  cleanup
  pure result

cleanup :: IO ()
cleanup = mapM_ removeIfPresent
  [ actualFixture
  , planFixture
  , actualFixture <> ".complete-advance.backup.tmp"
  , actualFixture <> ".complete-advance.new.tmp"
  , planFixture <> ".complete-advance.backup.tmp"
  , planFixture <> ".complete-advance.new.tmp"
  ]

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  catch (removeFile path) (\(_ :: IOException) -> pure ())

writerIntent :: FilePath -> FilePath -> PlanCompleteAdvanceWriteIntent
writerIntent actualPath planPath = PlanCompleteAdvanceWriteIntent
  { writeActualPath = actualPath
  , writeExpectedActual = "actual-old"
  , writeCandidateActual = "actual-new"
  , writePlanPath = planPath
  , writeExpectedPlan = "plan-old"
  , writeCandidatePlan = "plan-new"
  }

testWriterSuccess :: IO Bool
testWriterSuccess = withWriterFixtures $ \actualPath planPath -> do
  result <- publishPlanCompleteAdvance
    (pure (Right () :: Either String ()))
    (writerIntent actualPath planPath)
  actual <- TIO.readFile actualPath
  plan <- TIO.readFile planPath
  pure (result == Right () && actual == "actual-new" && plan == "plan-new")

testWriterStale :: IO Bool
testWriterStale = withWriterFixtures $ \actualPath planPath -> do
  let intent = (writerIntent actualPath planPath)
        { writeExpectedActual = "not-current" }
  result <- publishPlanCompleteAdvance
    (pure (Right () :: Either String ()))
    intent
  actual <- TIO.readFile actualPath
  plan <- TIO.readFile planPath
  pure $ case result of
    Left PlanCompleteAdvanceActualStale ->
      actual == "actual-old" && plan == "plan-old"
    _ -> False

testWriterPrePublishStale :: IO Bool
testWriterPrePublishStale = withWriterFixtures $ \actualPath planPath -> do
  stageCount <- newIORef (0 :: Int)
  stagedPaths <- newIORef ([] :: [FilePath])
  let normalFileSystem = defaultWriterFileSystem
      stageAndIntervene targetPath role source = do
        staged <- stageSiblingTextFile normalFileSystem targetPath role source
        atomicModifyIORef' stagedPaths (\paths -> (staged : paths, ()))
        previous <- atomicModifyIORef' stageCount (\count -> (count + 1, count))
        when (previous == 3) (TIO.writeFile planPath "plan-later")
        pure staged
      fileSystem = normalFileSystem
        { stageSiblingTextFile = stageAndIntervene }
  result <- publishPlanCompleteAdvanceUsing
    fileSystem
    (pure (Right () :: Either String ()))
    (writerIntent actualPath planPath)
  actual <- TIO.readFile actualPath
  plan <- TIO.readFile planPath
  staged <- readIORef stagedPaths
  leftovers <- mapM doesFileExist staged
  pure $ case result of
    Left PlanCompleteAdvancePlanStale ->
      actual == "actual-old"
        && plan == "plan-later"
        && length staged == 4
        && not (or leftovers)
    _ -> False

testWriterPlanChangesBetweenInstalls :: IO Bool
testWriterPlanChangesBetweenInstalls = withWriterFixtures $ \actualPath planPath -> do
  renameCount <- newIORef (0 :: Int)
  let normalFileSystem = defaultWriterFileSystem
      laterPlan = "plan-from-later-writer"
      renameAndIntervene source target = do
        previous <- atomicModifyIORef' renameCount (\count -> (count + 1, count))
        renameTextFile normalFileSystem source target
        when (previous == 0) (TIO.writeFile planPath laterPlan)
      fileSystem = normalFileSystem
        { renameTextFile = renameAndIntervene }
  result <- publishPlanCompleteAdvanceUsing
    fileSystem
    (pure (Right () :: Either String ()))
    (writerIntent actualPath planPath)
  actual <- TIO.readFile actualPath
  plan <- TIO.readFile planPath
  pure $ case result of
    Left PlanCompleteAdvancePlanStale ->
      actual == "actual-old" && plan == laterPlan
    _ -> False

testWriterActualChangesBeforeAdmission :: IO Bool
testWriterActualChangesBeforeAdmission = withWriterFixtures $ \actualPath planPath -> do
  renameCount <- newIORef (0 :: Int)
  let normalFileSystem = defaultWriterFileSystem
      laterActual = "actual-from-later-writer-before-admission"
      renameAndIntervene source target = do
        previous <- atomicModifyIORef' renameCount (\count -> (count + 1, count))
        renameTextFile normalFileSystem source target
        when (previous == 1) (TIO.writeFile actualPath laterActual)
      fileSystem = normalFileSystem
        { renameTextFile = renameAndIntervene }
  result <- publishPlanCompleteAdvanceUsing
    fileSystem
    (pure (Right () :: Either String ()))
    (writerIntent actualPath planPath)
  actual <- TIO.readFile actualPath
  plan <- TIO.readFile planPath
  pure $ case result of
    Left PlanCompleteAdvanceActualStale ->
      actual == laterActual && plan == "plan-old"
    _ -> False

testWriterSuccessAdmissionDoesNotMaskLaterActual :: IO Bool
testWriterSuccessAdmissionDoesNotMaskLaterActual =
  withWriterFixtures $ \actualPath planPath -> do
    let laterActual = "actual-from-later-writer-during-successful-admission"
        admitThenReplace = do
          TIO.writeFile actualPath laterActual
          pure (Right () :: Either String ())
    result <- publishPlanCompleteAdvance
      admitThenReplace
      (writerIntent actualPath planPath)
    actual <- TIO.readFile actualPath
    plan <- TIO.readFile planPath
    pure $ case result of
      Left PlanCompleteAdvanceActualStale ->
        actual == laterActual && plan == "plan-old"
      _ -> False

testWriterRollback :: IO Bool
testWriterRollback = withWriterFixtures $ \actualPath planPath -> do
  result <- publishPlanCompleteAdvance
    (pure (Left "whole household rejected" :: Either String ()))
    (writerIntent actualPath planPath)
  actual <- TIO.readFile actualPath
  plan <- TIO.readFile planPath
  pure $ case result of
    Left (PlanCompleteAdvancePostAdmissionFailed _ True True) ->
      actual == "actual-old" && plan == "plan-old"
    _ -> False

testWriterRollbackProtectsLaterWrite :: IO Bool
testWriterRollbackProtectsLaterWrite = withWriterFixtures $ \actualPath planPath -> do
  let laterActual = "actual-from-later-writer"
      rejectAfterLaterWrite = do
        TIO.writeFile actualPath laterActual
        pure (Left "whole household rejected" :: Either String ())
  result <- publishPlanCompleteAdvance
    rejectAfterLaterWrite
    (writerIntent actualPath planPath)
  actual <- TIO.readFile actualPath
  plan <- TIO.readFile planPath
  pure $ case result of
    Left (PlanCompleteAdvancePostAdmissionFailed _ False True) ->
      actual == laterActual && plan == "plan-old"
    _ -> False

testWriterPartialInstallFailure :: IO Bool
testWriterPartialInstallFailure = withWriterFixtures $ \actualPath planPath -> do
  renameCount <- newIORef (0 :: Int)
  let normalFileSystem = defaultWriterFileSystem
      failSecondRename source target = do
        previous <- atomicModifyIORef' renameCount (\count -> (count + 1, count))
        if previous == 1
          then throwIO (userError "simulated Plan install failure")
          else renameTextFile normalFileSystem source target
      fileSystem = normalFileSystem
        { renameTextFile = failSecondRename }
  result <- publishPlanCompleteAdvanceUsing
    fileSystem
    (pure (Right () :: Either String ()))
    (writerIntent actualPath planPath)
  actual <- TIO.readFile actualPath
  plan <- TIO.readFile planPath
  pure $ case result of
    Left (PlanCompleteAdvanceFileIOError _ True True) ->
      actual == "actual-old" && plan == "plan-old"
    _ -> False