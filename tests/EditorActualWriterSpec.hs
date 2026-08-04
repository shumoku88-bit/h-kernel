{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (removeFile)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Editor.ActualWriter

main :: IO ()
main = do
  let results = [ ("testStaleReject", testStaleReject)
                , ("testSuccessfulWrite", testSuccessfulWrite)
                , ("testPostAdmissionFailure", testPostAdmissionFailure)
                ]
  rs <- sequence [ f | (_, f) <- results ]
  let namedResults = zip (map fst results) rs
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

testFilePath :: FilePath
testFilePath = "tests/fixtures/test_actual_writer.journal"

withFixture :: Text -> (FilePath -> IO Bool) -> IO Bool
withFixture initial action = do
  TIO.writeFile testFilePath initial
  res <- action testFilePath `catch` (\(_ :: IOException) -> pure False)
  -- Cleanup
  _ <- catch (removeFile testFilePath) (\(_ :: IOException) -> pure ())
  _ <- catch (removeFile (testFilePath <> ".backup.tmp")) (\(_ :: IOException) -> pure ())
  _ <- catch (removeFile (testFilePath <> ".new.tmp")) (\(_ :: IOException) -> pure ())
  pure res

testStaleReject :: IO Bool
testStaleReject = withFixture "original" $ \path -> do
  let intent = WriteIntent
        { targetFilePath = path
        , expectedOldBytes = "different"
        , candidateNewBytes = "new"
        }
  res <- publishActualAppend intent
  pure $ case res of
    Left (StaleFile "original") -> True
    _ -> False

testSuccessfulWrite :: IO Bool
testSuccessfulWrite = withFixture "account assets:bank\n  type: Asset\n  commodity: JPY\n" $ \path -> do
  let oldBytes = "account assets:bank\n  type: Asset\n  commodity: JPY\n"
      newBytes = oldBytes <> "\n2023-01-01 test\n  assets:bank  100 JPY\n  assets:bank  -100 JPY\n"
      intent = WriteIntent path oldBytes newBytes
  res <- publishActualAppend intent
  case res of
    Right () -> do
      content <- TIO.readFile path
      pure (content == newBytes)
    Left err -> do
      print err
      pure False

testPostAdmissionFailure :: IO Bool
testPostAdmissionFailure = withFixture "account assets:bank\n  type: Asset\n  commodity: JPY\n" $ \path -> do
  let oldBytes = "account assets:bank\n  type: Asset\n  commodity: JPY\n"
      -- Syntactically invalid transaction to trigger post-admission failure
      newBytes = oldBytes <> "\n2023-01-01 invalid\n  assets:unknown  100 JPY\n"
      intent = WriteIntent path oldBytes newBytes
  res <- publishActualAppend intent
  case res of
    Left (PostAdmissionFailed _ restoreSuccess) -> do
      content <- TIO.readFile path
      -- Should be restored to oldBytes
      pure (restoreSuccess && content == oldBytes)
    _ -> pure False
