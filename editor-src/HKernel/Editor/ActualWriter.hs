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
publishActualAppend intent = catch performWrite handleError
  where
    filePath = targetFilePath intent
    backupPath = filePath <> ".backup.tmp"
    newPath    = filePath <> ".new.tmp"

    performWrite = do
      currentBytes <- T.readFile filePath
      if currentBytes /= expectedOldBytes intent
        then pure (Left (StaleFile currentBytes))
        else do
          T.writeFile backupPath currentBytes
          T.writeFile newPath (candidateNewBytes intent)
          renameFile newPath filePath
          
          -- Post-admission
          postBytes <- T.readFile filePath
          case parseActualJournal postBytes of
            Left errs -> do
              -- Recoverable failure: attempt to restore from backup
              restoreSuccess <- catch (renameFile backupPath filePath >> pure True)
                                      (\(_ :: IOException) -> pure False)
              pure (Left (PostAdmissionFailed errs restoreSuccess))
            Right _ -> do
              -- Success: remove backup
              _ <- catch (removeFile backupPath) (\(_ :: IOException) -> pure ())
              pure (Right ())

    handleError :: IOException -> IO (Either WriteError ())
    handleError e = pure (Left (FileIOError (show e)))
