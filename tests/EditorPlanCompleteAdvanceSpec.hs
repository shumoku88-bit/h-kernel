{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
import HKernel.Editor.ActualWriter
  ( WriterFileSystem(..)
  , defaultWriterFileSystem
  )
import HKernel.Editor.Interaction.PlanCompleteAdvance
  ( PlanCompleteAdvanceInput(..)
  , initialPlanCompleteAdvanceInput
  , parsePlanCompleteAdvanceInput
  )
import HKernel.Editor.PlanCompleteAdvance
import HKernel.Editor.PlanLifecycle
  ( PositivePlanFinishAmount
  , mkPositivePlanFinishAmount
  )
import HKernel.Journal (parseJournal)
import HKernel.Money (parseQuantity)
import HKernel.Plan (PlanId, mkPlanId)
import HKernel.Plan.Journal
  ( PlanJournal
  , admitPlanJournalFromResolvedJournal
  )

main :: IO ()
main = do
  let pureResults =
        [ ("monthly proposal uses nominal date", testMonthlyNominalDate)
        , ("interaction defaults to today and nominal successor", testInteractionDefaults)
        , ("interaction keeps four editable coordinates independent", testInteractionOverrides)
        , ("actual amount does not rewrite successor default", testAmountSeparation)
        , ("daily-target identity refreshes", testDailyTargetRefresh)
        , ("once recurrence forbids successor", testOnceNoSuccessor)
        , ("cycle recurrence requires explicit date", testCycleManualDate)
        ]
  writerResults <- sequence
    [ namedIO "coordinated writer publishes both" testWriterSuccess
    , namedIO "coordinated writer rejects stale input" testWriterStale
    , namedIO "coordinated writer rejects stale input after staging" testWriterPrePublishStale
    , namedIO "coordinated writer protects Plan change between installs" testWriterPlanChangesBetweenInstalls
    , namedIO "coordinated writer protects Actual change before admission" testWriterActualChangesBeforeAdmission
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

resolvedSource :: Text -> Text
resolvedSource root = accountsResolved <> "\n" <> T.unlines (drop 1 (T.lines root))

admitPlan :: Text -> Maybe PlanJournal
admitPlan root = do
  journal <- either (const Nothing) Just (parseJournal (resolvedSource root))
  either (const Nothing) Just (admitPlanJournalFromResolvedJournal journal root)

admitActual :: Maybe ActualJournal
admitActual = do
  journal <- either (const Nothing) Just (parseJournal accountsResolved)
  either (const Nothing) Just (admitActualJournalFromResolvedJournal journal actualRoot)

planId :: Text -> Maybe PlanId
planId value = either (const Nothing) Just (mkPlanId value)

positive :: Text -> Maybe PositivePlanFinishAmount
positive value = do
  quantity <- either (const Nothing) Just (parseQuantity value)
  either (const Nothing) Just (mkPositivePlanFinishAmount quantity)

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
  case proposePlanAdvance planJournal monthlyPlanSource target of
    Right proposal ->
      proposalNominalDate proposal == fromGregorian 2031 1 17
        && proposalSuggestedNextDate proposal == Just (fromGregorian 2031 2 17)
        && proposalRecurrence proposal == PlanRecursMonthly
    Left _ -> False

testInteractionDefaults :: Bool
testInteractionDefaults = withMonthly $ \planJournal _ target ->
  case proposePlanAdvance planJournal monthlyPlanSource target of
    Left _ -> False
    Right proposal ->
      let input = initialPlanCompleteAdvanceInput (fromGregorian 2031 1 16) proposal
      in planActualDateText input == "2031-01-16"
          && planActualAmountText input == ""
          && planSuccessorDateText input == "2031-02-17"
          && planSuccessorAmountText input == ""

testInteractionOverrides :: Bool
testInteractionOverrides = withMonthly $ \planJournal _ target ->
  case proposePlanAdvance planJournal monthlyPlanSource target of
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

testOnceNoSuccessor :: Bool
testOnceNoSuccessor = case
    (admitPlan oncePlanSource, admitActual, planId "plan-2031-02-03-sample-once") of
  (Just planJournal, Just actualJournal, Just target) ->
    case proposePlanAdvance planJournal oncePlanSource target of
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
    case proposePlanAdvance planJournal cyclePlanSource target of
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

-- | A change that lands while the four unique sibling files are being staged
-- must be observed by the immediate pre-publication fence. Neither candidate is
-- installed, and every staged sibling created by this attempt is removed.
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

-- | A Plan write that lands after Actual has been installed but before Plan is
-- installed must win. The operation restores its own Actual candidate and never
-- overwrites the later Plan bytes.
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

-- | An Actual write that lands after both candidate renames but before whole-
-- Household admission must also win. The candidate fence restores Plan only and
-- preserves the later Actual bytes.
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

-- | If another writer replaces Actual during whole-Household admission, the
-- coordinated rollback must not overwrite it. Plan is still this operation's
-- candidate, so only Plan is restored to the expected source.
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

-- | Failure of the second install rename leaves Actual temporarily published.
-- Recovery is candidate-guarded and returns both sources to their expected
-- bytes without relying on fixed staging filenames.
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
