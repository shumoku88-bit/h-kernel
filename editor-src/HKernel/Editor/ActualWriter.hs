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
  , publishWithPathAdmission
  , publishWithPathAdmissionUsing
  , ActualSourceAdmissionError(..)
  , admitActualJournalPath
  , publishActualAppend
  , publishActualAppendFromResolvedJournal
  , publishActualBlock
  ) where

import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text.IO as TextIO
import System.Directory (renameFile, removeFile)

import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , admitActualJournalFromResolvedJournal
  , parseActualJournal
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Loader (LoadError, loadJournal)

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

-- | Publish a source whose complete admission is pure and depends only on its
-- text. This remains the ordinary boundary for Actual and other single-source
-- formats.
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
publishWithAdmissionUsing fileSystem admit =
  publishUsing fileSystem admission
  where
    admission _ source = pure (fmap (const ()) (admit source))

-- | Publish a source whose complete admission is owned by its filesystem path.
--
-- This is the boundary for source graphs such as a Journal that contains
-- relative @include@ directives. The safe writer still owns stale detection,
-- backup, atomic publication, post-admission, and rollback; the supplied
-- function owns only path-aware admission of the published source graph.
publishWithPathAdmission
  :: (FilePath -> IO (Either (NonEmpty sourceError) admitted))
  -> WriteIntent
  -> IO (Either (WriteError sourceError) ())
publishWithPathAdmission =
  publishWithPathAdmissionUsing defaultWriterFileSystem

publishWithPathAdmissionUsing
  :: WriterFileSystem
  -> (FilePath -> IO (Either (NonEmpty sourceError) admitted))
  -> WriteIntent
  -> IO (Either (WriteError sourceError) ())
publishWithPathAdmissionUsing fileSystem admit =
  publishUsing fileSystem admission
  where
    admission path _ = fmap (fmap (const ())) (admit path)

data ActualSourceAdmissionError
  = ActualSourceLoadError LoadError
  | ActualSourceJournalError ActualJournalError
  deriving (Show)

-- | Admit an Actual root through its filesystem-resolved Journal graph.
-- Accounting declarations and transactions come from the resolved Journal;
-- Actual-owned metadata comes from the root source bytes.
admitActualJournalPath
  :: FilePath
  -> IO (Either (NonEmpty ActualSourceAdmissionError) ActualJournal)
admitActualJournalPath sourceFile = do
  source <- TextIO.readFile sourceFile
  resolved <- loadJournal sourceFile
  pure $ case resolved of
    Left loadError -> Left (pure (ActualSourceLoadError loadError))
    Right journal -> case admitActualJournalFromResolvedJournal journal source of
      Left errors -> Left (fmap ActualSourceJournalError errors)
      Right actualJournal -> Right actualJournal

publishActualAppend
  :: WriteIntent
  -> IO (Either (WriteError ActualJournalError) ())
publishActualAppend = publishWithAdmission parseActualJournal

-- | Publish an Actual root and re-admit the complete resolved source graph.
publishActualAppendFromResolvedJournal
  :: WriteIntent
  -> IO (Either (WriteError ActualSourceAdmissionError) ())
publishActualAppendFromResolvedJournal =
  publishWithPathAdmission admitActualJournalPath

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

type Admission sourceError =
  FilePath -> Text -> IO (Either (NonEmpty sourceError) ())

publishUsing
  :: WriterFileSystem
  -> Admission sourceError
  -> WriteIntent
  -> IO (Either (WriteError sourceError) ())
publishUsing fileSystem admit intent =
  catch (checkStaleAndWrite fileSystem admit intent) handleError
  where
    handleError :: IOException -> IO (Either (WriteError sourceError) ())
    handleError err = pure (Left (FileIOError (show err)))

checkStaleAndWrite
  :: WriterFileSystem
  -> Admission sourceError
  -> WriteIntent
  -> IO (Either (WriteError sourceError) ())
checkStaleAndWrite fileSystem admit intent = do
  currentBytes <- readTextFile fileSystem (targetFilePath intent)
  if currentBytes /= expectedSourceText (expectedOldBytes intent)
    then pure (Left StaleFile)
    else withAtomicSwap fileSystem admit intent

withAtomicSwap
  :: WriterFileSystem
  -> Admission sourceError
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
  -> Admission sourceError
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
    Right postBytes -> do
      admitted <- admit filePath postBytes
      case admitted of
        Left errs -> do
          restored <- restoreBackup fileSystem backupPath filePath
          pure (Left (PostAdmissionFailed errs restored))
        Right () -> do
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
