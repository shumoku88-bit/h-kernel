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
  , admitActualJournalRootSource
  , admitActualJournalPath
  , publishActualAppend
  , publishActualAppendFromResolvedJournal
  , publishActualBlock
  , publishActualBlockWithPathAdmission
  , publishActualBlockFromResolvedJournal
  , PlanJournalSourceAdmissionError(..)
  , admitPlanJournalRootSource
  , admitPlanJournalPath
  , publishPlanJournalFromResolvedJournal
  , BudgetJournalSourceAdmissionError(..)
  , admitBudgetJournalPath
  , publishBudgetJournalAppend
  ) where

import Control.Exception (IOException, catch, onException, throwIO)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text.IO as TextIO
import System.Directory (renameFile, removeFile)
import System.IO (Handle, hClose, openTempFile)

import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , admitActualJournalFromResolvedJournal
  , parseActualJournal
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement
  , HouseholdBudgetMovementJournalError
  , admitHouseholdBudgetMovementJournal
  )
import HKernel.Loader (LoadError, loadJournal, loadJournalFromRootSource)
import HKernel.Plan.Journal
  ( PlanJournal
  , PlanJournalError
  , admitPlanJournalFromResolvedJournal
  )

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
-- weakening the ordinary IO entry point. 'stageSiblingTextFile' must allocate
-- a fresh path in the target directory so concurrent writer invocations never
-- share a backup or candidate staging file.
data WriterFileSystem = WriterFileSystem
  { readTextFile          :: FilePath -> IO Text
  , writeTextFile         :: FilePath -> Text -> IO ()
  , stageSiblingTextFile  :: FilePath -> String -> Text -> IO FilePath
  , renameTextFile        :: FilePath -> FilePath -> IO ()
  , removeTextFile        :: FilePath -> IO ()
  }

defaultWriterFileSystem :: WriterFileSystem
defaultWriterFileSystem = WriterFileSystem
  { readTextFile = TextIO.readFile
  , writeTextFile = TextIO.writeFile
  , stageSiblingTextFile = stageSiblingText
  , renameTextFile = renameFile
  , removeTextFile = removeFile
  }

stageSiblingText :: FilePath -> String -> Text -> IO FilePath
stageSiblingText targetPath role source = do
  let (directory, fileName) = splitTargetPath targetPath
      template = fileName <> role
  (tempPath, handle) <- openTempFile directory template
  (TextIO.hPutStr handle source >> hClose handle >> pure tempPath)
    `onException` cleanupOpenTemp tempPath handle

-- | Split only at the last platform path separator. This filesystem adapter
-- intentionally needs no general path algebra: it only needs the parent text
-- and basename required by 'openTempFile'. Both POSIX and Windows separators
-- are accepted so an explicit absolute writer path stays on its own filesystem.
splitTargetPath :: FilePath -> (FilePath, FilePath)
splitTargetPath path =
  case break isPathSeparator (reverse path) of
    (reversedName, []) -> (".", reverse reversedName)
    (reversedName, separator : reversedDirectory) ->
      (reverse reversedDirectory <> [separator], reverse reversedName)
  where
    isPathSeparator character = character == '/' || character == '\\'

cleanupOpenTemp :: FilePath -> Handle -> IO ()
cleanupOpenTemp tempPath handle = do
  _ <- catch (hClose handle) (\(_ :: IOException) -> pure ())
  _ <- catch (removeFile tempPath) (\(_ :: IOException) -> pure ())
  pure ()

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

-- | Admit exact Actual root bytes together with the include graph resolved from
-- the root path. The root text and the accounting graph therefore belong to one
-- observation instead of permitting a second root-file read to drift in time.
admitActualJournalRootSource
  :: FilePath
  -> Text
  -> IO (Either (NonEmpty ActualSourceAdmissionError) ActualJournal)
admitActualJournalRootSource sourceFile source = do
  resolved <- loadJournalFromRootSource sourceFile source
  pure $ case resolved of
    Left loadError -> Left (pure (ActualSourceLoadError loadError))
    Right journal -> case admitActualJournalFromResolvedJournal journal source of
      Left errors -> Left (fmap ActualSourceJournalError errors)
      Right actualJournal -> Right actualJournal

-- | Admit one Actual root using exactly the root bytes read for this observation.
admitActualJournalPath
  :: FilePath
  -> IO (Either (NonEmpty ActualSourceAdmissionError) ActualJournal)
admitActualJournalPath sourceFile = do
  source <- TextIO.readFile sourceFile
  admitActualJournalRootSource sourceFile source

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

data PlanJournalSourceAdmissionError
  = PlanJournalSourceLoadError LoadError
  | PlanJournalSourceAdmissionError PlanJournalError
  deriving (Show)

-- | Admit exact Plan root bytes together with the include graph resolved from
-- the root path. This can validate an in-memory candidate before publication
-- without replacing the current root file.
admitPlanJournalRootSource
  :: FilePath
  -> Text
  -> IO (Either (NonEmpty PlanJournalSourceAdmissionError) PlanJournal)
admitPlanJournalRootSource sourceFile source = do
  resolved <- loadJournalFromRootSource sourceFile source
  pure $ case resolved of
    Left loadError -> Left (pure (PlanJournalSourceLoadError loadError))
    Right journal -> case admitPlanJournalFromResolvedJournal journal source of
      Left errors -> Left (fmap PlanJournalSourceAdmissionError errors)
      Right planJournal -> Right planJournal

-- | Admit one Plan root using exactly the root bytes read for this observation.
admitPlanJournalPath
  :: FilePath
  -> IO (Either (NonEmpty PlanJournalSourceAdmissionError) PlanJournal)
admitPlanJournalPath sourceFile = do
  source <- TextIO.readFile sourceFile
  admitPlanJournalRootSource sourceFile source

-- | Publish a Plan root and re-admit the complete include-resolved Plan graph.
publishPlanJournalFromResolvedJournal
  :: WriteIntent
  -> IO (Either (WriteError PlanJournalSourceAdmissionError) ())
publishPlanJournalFromResolvedJournal =
  publishWithPathAdmission admitPlanJournalPath

data BudgetJournalSourceAdmissionError
  = BudgetJournalSourceLoadError LoadError
  | BudgetJournalSourceAdmitError (NonEmpty HouseholdBudgetMovementJournalError)
  deriving (Show)

-- | Admit a Budget journal root through its filesystem-resolved Journal graph.
admitBudgetJournalPath
  :: FilePath
  -> IO (Either (NonEmpty BudgetJournalSourceAdmissionError) [HouseholdBudgetMovement])
admitBudgetJournalPath filePath = do
  resolved <- loadJournal filePath
  pure $ case resolved of
    Left loadError -> Left (pure (BudgetJournalSourceLoadError loadError))
    Right journal -> case admitHouseholdBudgetMovementJournal journal of
      Left errors -> Left (pure (BudgetJournalSourceAdmitError errors))
      Right movements -> Right movements

publishBudgetJournalAppend
  :: WriteIntent
  -> IO (Either (WriteError BudgetJournalSourceAdmissionError) ())
publishBudgetJournalAppend =
  publishWithPathAdmission admitBudgetJournalPath

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
    (actualBlockWriteIntent filePath expectedSource block)

-- | Place an already validated Actual block while letting the application
-- choose the complete post-publication admission boundary.
--
-- The source-placement and filesystem law stay here. A canonical Household
-- adapter can therefore require whole-Household admission without duplicating
-- append placement, stale checks, staging, publication, or checked rollback.
publishActualBlockWithPathAdmission
  :: (FilePath -> IO (Either (NonEmpty sourceError) admitted))
  -> FilePath
  -> Text
  -> Text
  -> IO (Either (WriteError sourceError) ())
publishActualBlockWithPathAdmission admit filePath expectedSource block =
  publishWithPathAdmission admit
    (actualBlockWriteIntent filePath expectedSource block)

-- | Publish an already validated block through resolved Actual admission.
publishActualBlockFromResolvedJournal
  :: FilePath
  -> Text
  -> Text
  -> IO (Either (WriteError ActualSourceAdmissionError) ())
publishActualBlockFromResolvedJournal filePath expectedSource block =
  publishActualAppendFromResolvedJournal
    (actualBlockWriteIntent filePath expectedSource block)

actualBlockWriteIntent :: FilePath -> Text -> Text -> WriteIntent
actualBlockWriteIntent filePath expectedSource block = WriteIntent
  { targetFilePath = filePath
  , expectedOldBytes = ExpectedSource expectedSource
  , candidateNewBytes = CandidateSource
      (appendSourceBlock expectedSource (SourceBlock block))
  }

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

-- | Stage both old and new bytes at unique sibling paths, then fence publication
-- with a second stale check immediately before rename. No lock is introduced:
-- the project remains single-operator, but two processes cannot silently share
-- staging filenames or overwrite a change that landed during candidate staging.
withAtomicSwap
  :: WriterFileSystem
  -> Admission sourceError
  -> WriteIntent
  -> IO (Either (WriteError sourceError) ())
withAtomicSwap fileSystem admit intent = do
  let filePath = targetFilePath intent
      expectedSource = expectedSourceText (expectedOldBytes intent)
      candidateSource = candidateSourceText (candidateNewBytes intent)

  backupPath <- stageSiblingTextFile fileSystem filePath ".backup.tmp" expectedSource
  newPath <- stageSiblingTextFile fileSystem filePath ".new.tmp" candidateSource
    `onException` removeQuietly fileSystem backupPath

  preRename <- catch
    (Right <$> readTextFile fileSystem filePath)
    (pure . Left)
  case preRename of
    Left (readError :: IOException) -> do
      cleanupStaged fileSystem [newPath, backupPath]
      throwIO readError
    Right latestBytes
      | latestBytes /= expectedSource -> do
          cleanupStaged fileSystem [newPath, backupPath]
          pure (Left StaleFile)
      | otherwise -> do
          renameTextFile fileSystem newPath filePath
            `onException` cleanupStaged fileSystem [newPath, backupPath]
          verifyOrRollback
            fileSystem
            admit
            filePath
            backupPath
            candidateSource

verifyOrRollback
  :: WriterFileSystem
  -> Admission sourceError
  -> FilePath
  -> FilePath
  -> Text
  -> IO (Either (WriteError sourceError) ())
verifyOrRollback fileSystem admit filePath backupPath candidateSource = do
  postRead <- tryRead fileSystem filePath
  case postRead of
    Left readError -> do
      restored <- restoreBackupIfCandidate
        fileSystem backupPath filePath candidateSource
      pure (Left (PostPublishReadFailed (show readError) restored))
    Right postBytes
      | postBytes /= candidateSource -> do
          removeQuietly fileSystem backupPath
          pure (Left StaleFile)
      | otherwise -> do
          admitted <- admit filePath postBytes
          case admitted of
            Left errs -> do
              restored <- restoreBackupIfCandidate
                fileSystem backupPath filePath candidateSource
              pure (Left (PostAdmissionFailed errs restored))
            Right () -> verifyPublishedCandidate
              fileSystem filePath backupPath candidateSource

-- | Admission may perform filesystem IO and therefore opens another temporal
-- window. Re-read once after admission so success is never reported for a file
-- that has already ceased to be this writer's candidate.
verifyPublishedCandidate
  :: WriterFileSystem
  -> FilePath
  -> FilePath
  -> Text
  -> IO (Either (WriteError sourceError) ())
verifyPublishedCandidate fileSystem filePath backupPath candidateSource = do
  finalRead <- tryRead fileSystem filePath
  case finalRead of
    Left readError -> do
      restored <- restoreBackupIfCandidate
        fileSystem backupPath filePath candidateSource
      pure (Left (PostPublishReadFailed (show readError) restored))
    Right finalBytes
      | finalBytes /= candidateSource -> do
          removeQuietly fileSystem backupPath
          pure (Left StaleFile)
      | otherwise -> do
          removeQuietly fileSystem backupPath
          pure (Right ())

-- | Restore only while the target still contains exactly the bytes published by
-- this writer. If another writer has changed the target, never overwrite it.
-- A verified mismatch makes the old backup obsolete; an unreadable target keeps
-- the backup available for explicit recovery rather than guessing.
restoreBackupIfCandidate
  :: WriterFileSystem
  -> FilePath
  -> FilePath
  -> Text
  -> IO Bool
restoreBackupIfCandidate fileSystem backupPath filePath candidateSource = do
  current <- tryRead fileSystem filePath
  case current of
    Left _ -> pure False
    Right currentBytes
      | currentBytes /= candidateSource -> do
          removeQuietly fileSystem backupPath
          pure False
      | otherwise -> catch
          (renameTextFile fileSystem backupPath filePath >> pure True)
          (\(_ :: IOException) -> pure False)

tryRead :: WriterFileSystem -> FilePath -> IO (Either IOException Text)
tryRead fileSystem filePath =
  catch
    (Right <$> readTextFile fileSystem filePath)
    (pure . Left)

cleanupStaged :: WriterFileSystem -> [FilePath] -> IO ()
cleanupStaged fileSystem = mapM_ (removeQuietly fileSystem)

removeQuietly :: WriterFileSystem -> FilePath -> IO ()
removeQuietly fileSystem filePath = do
  _ <- catch
    (removeTextFile fileSystem filePath)
    (\(_ :: IOException) -> pure ())
  pure ()

expectedSourceText :: ExpectedSource -> Text
expectedSourceText (ExpectedSource source) = source

candidateSourceText :: CandidateSource -> Text
candidateSourceText (CandidateSource source) = source
