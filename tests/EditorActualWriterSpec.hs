{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, catch, throwIO)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import System.Directory (removeFile)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Editor.ActualWriter
import HKernel.Plan.Journal (parsePlanJournal)

main :: IO ()
main = do
  let results =
        [ ("testStaleReject", testStaleReject)
        , ("testActualWrite", testActualWrite)
        , ("testPlanWrite", testPlanWrite)
        , ("testPostAdmissionFailure", testPostAdmissionFailure)
        , ("testPostPublishReadFailureRestores", testPostPublishReadFailureRestores)
        , ("testActualBlockWrite", testActualBlockWrite)
        , ("testActualBlockStaleReject", testActualBlockStaleReject)
        , ( "testActualBlockPostAdmissionFailureRestores"
          , testActualBlockPostAdmissionFailureRestores
          )
        ]
  rs <- sequence [action | (_, action) <- results]
  let namedResults = zip (map fst results) rs
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

withFixture :: FilePath -> Text -> (FilePath -> IO Bool) -> IO Bool
withFixture path initial action = do
  cleanupFixture path
  TIO.writeFile path initial
  result <- action path `catch` (\(_ :: IOException) -> pure False)
  cleanupFixture path
  pure result

cleanupFixture :: FilePath -> IO ()
cleanupFixture path = do
  removeIfPresent path
  removeIfPresent (path <> ".backup.tmp")
  removeIfPresent (path <> ".new.tmp")

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  catch (removeFile path) (\(_ :: IOException) -> pure ())

expectPublished
  :: Show sourceError
  => FilePath
  -> (Text -> Either (NonEmpty sourceError) admitted)
  -> Text
  -> Text
  -> IO Bool
expectPublished path admit oldBytes newBytes =
  withFixture path oldBytes $ \fixturePath -> do
    result <- publishWithAdmission admit
      (WriteIntent fixturePath oldBytes newBytes)
    case result of
      Right () -> (== newBytes) <$> TIO.readFile fixturePath
      Left err -> print err >> pure False

testStaleReject :: IO Bool
testStaleReject =
  withFixture "tests/fixtures/test_writer_stale.journal" "original" $ \path -> do
    let intent = WriteIntent
          { targetFilePath = path
          , expectedOldBytes = "different"
          , candidateNewBytes = "new"
          }
    result <- publishActualAppend intent
    pure $ case result of
      Left StaleFile -> show result == "Left StaleFile"
      _ -> False

testActualWrite :: IO Bool
testActualWrite =
  expectPublished
    "tests/fixtures/test_writer_actual.journal"
    parseActualJournal
    actualOld
    actualNew

testPlanWrite :: IO Bool
testPlanWrite =
  expectPublished
    "tests/fixtures/test_writer_plan.journal"
    parsePlanJournal
    planOld
    planNew

testPostAdmissionFailure :: IO Bool
testPostAdmissionFailure =
  withFixture "tests/fixtures/test_writer_reject.journal" actualOld $ \path -> do
    let invalidBytes = actualOld
          <> "\n2026-08-05 invalid\n"
          <> "  assets:unknown  100 JPY\n"
        intent = WriteIntent path actualOld invalidBytes
    result <- publishWithAdmission parseActualJournal intent
    case result of
      Left (PostAdmissionFailed _ True) ->
        (== actualOld) <$> TIO.readFile path
      _ -> pure False

testPostPublishReadFailureRestores :: IO Bool
testPostPublishReadFailureRestores =
  withFixture "tests/fixtures/test_writer_read_failure.journal" actualOld $ \path -> do
    readCount <- newIORef (0 :: Int)
    let normalFileSystem = defaultWriterFileSystem
        failSecondRead filePath = do
          previous <- atomicModifyIORef' readCount (\count -> (count + 1, count))
          if previous == 0
            then readTextFile normalFileSystem filePath
            else throwIO (userError "simulated post-publish read failure")
        faultingFileSystem = normalFileSystem
          { readTextFile = failSecondRead }
        intent = WriteIntent path actualOld actualNew
    result <- publishWithAdmissionUsing
      faultingFileSystem
      parseActualJournal
      intent
    case result of
      Left (PostPublishReadFailed _ True) ->
        (== actualOld) <$> TIO.readFile path
      _ -> pure False

testActualBlockWrite :: IO Bool
testActualBlockWrite =
  withFixture
    "tests/fixtures/test_writer_actual_block.journal"
    actualOld
    (\path -> do
      result <- publishActualBlock path actualOld actualBlock
      case result of
        Right () -> (== actualNew) <$> TIO.readFile path
        Left err -> print err >> pure False)

testActualBlockStaleReject :: IO Bool
testActualBlockStaleReject =
  withFixture
    "tests/fixtures/test_writer_actual_block_stale.journal"
    actualOld
    (\path -> do
      result <- publishActualBlock path (actualOld <> "\n") actualBlock
      currentSource <- TIO.readFile path
      pure $ case result of
        Left StaleFile -> currentSource == actualOld
        _ -> False)

testActualBlockPostAdmissionFailureRestores :: IO Bool
testActualBlockPostAdmissionFailureRestores =
  withFixture
    "tests/fixtures/test_writer_actual_block_reject.journal"
    actualOld
    (\path -> do
      result <- publishActualBlock path actualOld invalidActualBlock
      currentSource <- TIO.readFile path
      pure $ case result of
        Left (PostAdmissionFailed _ True) -> currentSource == actualOld
        _ -> False)

actualOld :: Text
actualOld =
  "account assets:bank\n"
  <> "  type: Asset\n"
  <> "  commodity: JPY\n"

actualBlock :: Text
actualBlock =
  "2026-08-05 actual write\n"
  <> "  assets:bank  100 JPY\n"
  <> "  assets:bank  -100 JPY\n"

invalidActualBlock :: Text
invalidActualBlock =
  "2026-08-05 invalid actual write\n"
  <> "  assets:unknown  100 JPY\n"
  <> "  assets:bank  -100 JPY\n"

actualNew :: Text
actualNew = actualOld <> "\n" <> actualBlock

planOld :: Text
planOld =
  "account assets:bank\n"
  <> "  type: Asset\n"
  <> "  commodity: JPY\n"
  <> "account expenses:food\n"
  <> "  type: Expense\n"
  <> "  commodity: JPY\n"

planNew :: Text
planNew = planOld
  <> "\n2026-08-06 planned meal\n"
  <> "    ; plan-id: PLAN-1\n"
  <> "  assets:bank  -500 JPY\n"
  <> "  expenses:food  500 JPY\n"
