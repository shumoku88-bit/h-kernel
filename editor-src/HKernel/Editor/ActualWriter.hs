{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HKernel.Editor.ActualWriter
  ( WriteIntent(..)
  , WriteError(..)
  , publishActualAppend
  ) where

import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text.IO as T
import System.Directory (renameFile, removeFile)

import HKernel.Actual.Journal (ActualJournalError, parseActualJournal)

data WriteIntent = WriteIntent
  { targetFilePath    :: FilePath
  , expectedOldBytes  :: Text
  , candidateNewBytes :: Text
  } deriving (Eq, Show)

data WriteError
  = StaleFile { staleActualBytes :: Text }
  | PostAdmissionFailed
      { failedJournalError :: NonEmpty ActualJournalError
      , restoredFromBackup :: Bool
      }
  | FileIOError String
  deriving (Eq, Show)

publishActualAppend :: WriteIntent -> IO (Either WriteError ())
publishActualAppend intent = catch (checkStaleAndWrite intent) handleError
  where
    handleError :: IOException -> IO (Either WriteError ())
    handleError e = pure (Left (FileIOError (show e)))

checkStaleAndWrite :: WriteIntent -> IO (Either WriteError ())
checkStaleAndWrite intent = do
  currentBytes <- T.readFile (targetFilePath intent)
  if currentBytes /= expectedOldBytes intent
    then pure (Left (StaleFile currentBytes))
    else withAtomicSwap intent

withAtomicSwap :: WriteIntent -> IO (Either WriteError ())
withAtomicSwap intent = do
  let filePath = targetFilePath intent
      backupPath = filePath <> ".backup.tmp"
      newPath    = filePath <> ".new.tmp"
      
  T.writeFile backupPath (expectedOldBytes intent)
  T.writeFile newPath (candidateNewBytes intent)
  renameFile newPath filePath
  
  verifyOrRollback filePath backupPath

verifyOrRollback :: FilePath -> FilePath -> IO (Either WriteError ())
verifyOrRollback filePath backupPath = do
  postBytes <- T.readFile filePath
  case parseActualJournal postBytes of
    Left errs -> Left <$> rollback errs
    Right _   -> Right <$> commit
  where
    rollback errs = do
      restored <- catch (renameFile backupPath filePath >> pure True)
                        (\(_ :: IOException) -> pure False)
      pure (PostAdmissionFailed errs restored)
      
    commit = do
      _ <- catch (removeFile backupPath) (\(_ :: IOException) -> pure ())
      pure ()
