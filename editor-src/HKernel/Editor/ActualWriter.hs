{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HKernel.Editor.ActualWriter
  ( ExpectedSource(..)
  , CandidateSource(..)
  , WriteIntent(..)
  , WriteError(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithAdmission
  , publishWithAdmissionUsing
  , publishActualAppend
  , publishActualBlock
  ) where

import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text.IO as TextIO
import System.Directory (renameFile, removeFile)

import HKernel.Actual.Journal
  ( ActualJournalError
  , parseActualJournal
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)

-- | The complete source snapshot that the caller observed before preview.
--
-- This is a temporal coordinate rather than a validation claim. Keeping it
-- distinct from the candidate prevents the safe-writer boundary from accepting
-- the two source roles interchangeably.
newtype ExpectedSource = ExpectedSource Text
  deriving (Eq, Show)

-- | The complete source proposed for publication after preview preparation.
--
-- This is a semantic/temporal coordinate rather than an admission claim. The
-- supplied admission function still owns validation of the complete source.
newtype CandidateSource = CandidateSource Text
  deriving (Eq, Show)

data WriteIntent = WriteIntent
  { targetFilePath    :: FilePath
  , expectedOldBytes  :: ExpectedSource
  , candidateNewBytes :: CandidateSource
  } deriving (Eq, Show)

data WriteError sourceError
  = StaleFile
  | PostAdmissionFailed
      { failedSourceError  :: NonEmpty sourceError
      , restoredFromBackup :: Bool
      }
  | PostPublishReadFailed
      { failedReadMessage  :: String
      , restoredFromBackup :: Bool
      }
  | FileIOError String
  deriving (Eq, Show)

-- | File effects used by the writer.
--
-- Keeping these operations explicit makes the recovery path testable without
-- weakening the ordinary IO entry point.
data WriterFileSystem = WriterFileSystem
  { readTextFile   :: FilePath -> IO Text
  , writeTextFile  :: FilePath -> Text -> IO ()
  , renameTextFile :: FilePath -> FilePath -> IO ()
  , removeTextFile :: FilePath -> IO ()
  }

defaultWriterFileSystem :: WriterFileSystem
defaultWriterFileSystem = WriterFileSystem
  { readTextFile = TextIO.readFile
  , writeTextFile = TextIO.writeFile
  , renameTextFile = renameFile
  , removeTextFile = removeFile
  }

publishWithAdmission
  :: (Text -> Either (NonEmpty sourceError) admitted)
  -> WriteIntent
  -> IO (Either (WriteError sourceError) ())
publishWithAdmission = publishWithAdmissionUsing defaultWriterFileSystem

publishWithAdmissionUsing
  :: WriterFileSystem
  -> (Text -> Either (NonEmpty sourceError) admitted)
  -> WriteIntent
  -> IO (Either (WriteError sourceError) ())
publishWithAdmissionUsing fileSystem admit intent =
  catch (checkStaleAndWrite fileSystem admit intent) handleError
  where
    handleError :: IOException -> IO (Either (WriteError sourceError) ())
    handleError err = pure (Left (FileIOError (show err)))

publishActualAppend
  :: WriteIntent
  -> IO (Either (WriteError ActualJournalError) ())
publishActualAppend = publishWithAdmission parseActualJournal

-- | Place an already validated Actual transaction block and delegate all file
-- safety behavior to the existing Actual writer.
--
-- The caller owns confirmation and must supply the exact source bytes used to
-- produce the preview. This function owns only the bridge from confirmed block
-- to source placement and safe publication.
publishActualBlock
  :: FilePath
  -> Text
  -> Text
  -> IO (Either (WriteError ActualJournalError) ())
publishActualBlock filePath expectedSource block =
  publishActualAppend
    (WriteIntent
      { targetFilePath = filePath
      , expectedOldBytes = ExpectedSource expectedSource
      , candidateNewBytes = CandidateSource
          (appendSourceBlock expectedSource (SourceBlock block))
      })

checkStaleAndWrite
  :: WriterFileSystem
  -> (Text -> Either (NonEmpty sourceError) admitted)
  -> WriteIntent
  -> IO (Either (WriteError sourceError) ())
checkStaleAndWrite fileSystem admit intent = do
  currentBytes <- readTextFile fileSystem (targetFilePath intent)
  if currentBytes /= expectedSourceText (expectedOldBytes intent)
    then pure (Left StaleFile)
    else withAtomicSwap fileSystem admit intent

withAtomicSwap
  :: WriterFileSystem
  -> (Text -> Either (NonEmpty sourceError) admitted)
  -> WriteIntent
  -> IO (Either (WriteError sourceError) ())
withAtomicSwap fileSystem admit intent = do
  let filePath = targetFilePath intent
      backupPath = filePath <> ".backup.tmp"
      newPath = filePath <> ".new.tmp"
      expectedSource = expectedSourceText (expectedOldBytes intent)
      candidateSource = candidateSourceText (candidateNewBytes intent)

  writeTextFile fileSystem backupPath expectedSource
  writeTextFile fileSystem newPath candidateSource
  renameTextFile fileSystem newPath filePath

  verifyOrRollback fileSystem admit filePath backupPath

verifyOrRollback
  :: WriterFileSystem
  -> (Text -> Either (NonEmpty sourceError) admitted)
  -> FilePath
  -> FilePath
  -> IO (Either (WriteError sourceError) ())
verifyOrRollback fileSystem admit filePath backupPath = do
  postRead <- catch
    (Right <$> readTextFile fileSystem filePath)
    (pure . Left)
  case postRead of
    Left (readError :: IOException) -> do
      restored <- restoreBackup fileSystem backupPath filePath
      pure (Left (PostPublishReadFailed (show readError) restored))
    Right postBytes -> case admit postBytes of
      Left errs -> do
        restored <- restoreBackup fileSystem backupPath filePath
        pure (Left (PostAdmissionFailed errs restored))
      Right _ -> do
        _ <- catch
          (removeTextFile fileSystem backupPath)
          (\(_ :: IOException) -> pure ())
        pure (Right ())

restoreBackup :: WriterFileSystem -> FilePath -> FilePath -> IO Bool
restoreBackup fileSystem backupPath filePath =
  catch
    (renameTextFile fileSystem backupPath filePath >> pure True)
    (\(_ :: IOException) -> pure False)

expectedSourceText :: ExpectedSource -> Text
expectedSourceText (ExpectedSource source) = source

candidateSourceText :: CandidateSource -> Text
candidateSourceText (CandidateSource source) = source
