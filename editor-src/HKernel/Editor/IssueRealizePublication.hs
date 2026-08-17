{-# LANGUAGE ScopedTypeVariables #-}

-- | Safe three-source publication for one prepared Issue realization.
--
-- Candidate construction belongs to 'HKernel.Editor.IssueRealize'. This module
-- owns only the coordinated temporal write: Actual, explicit relation history,
-- and Issue lifecycle move together or guarded recovery restores the exact
-- sources observed before publication. An unrelated later writer is never
-- overwritten by rollback.
module HKernel.Editor.IssueRealizePublication
  ( IssueRealizeWriteIntent(..)
  , IssueRealizeWriteError(..)
  , publishIssueRealize
  , publishIssueRealizeUsing
  ) where

import Control.Exception (IOException, catch, onException)
import Data.Text (Text)
import System.IO.Error (isDoesNotExistError)

import HKernel.Editor.SourcePublication
  ( WriterFileSystem(..)
  , defaultWriterFileSystem
  )

data IssueRealizeWriteIntent = IssueRealizeWriteIntent
  { writeRealizeActualPath             :: FilePath
  , writeRealizeExpectedActual         :: Text
  , writeRealizeCandidateActual        :: Text
  , writeRealizeRelationPath           :: FilePath
  , writeRealizeExpectedRelationExists :: Bool
  , writeRealizeExpectedRelation       :: Text
  , writeRealizeCandidateRelation      :: Text
  , writeRealizeIssuesPath             :: FilePath
  , writeRealizeExpectedIssues         :: Text
  , writeRealizeCandidateIssues        :: Text
  } deriving (Eq, Show)

data IssueRealizeWriteError admissionError
  = IssueRealizeActualStale
  | IssueRealizeRelationStale
  | IssueRealizeIssuesStale
  | IssueRealizePostAdmissionFailed admissionError Bool Bool Bool
  | IssueRealizeFileIOError String Bool Bool Bool
  deriving (Eq, Show)

-- | Publish a prepared realization using the ordinary filesystem adapter.
publishIssueRealize
  :: IO (Either admissionError admitted)
  -> IssueRealizeWriteIntent
  -> IO (Either (IssueRealizeWriteError admissionError) ())
publishIssueRealize = publishIssueRealizeUsing defaultWriterFileSystem

publishIssueRealizeUsing
  :: WriterFileSystem
  -> IO (Either admissionError admitted)
  -> IssueRealizeWriteIntent
  -> IO (Either (IssueRealizeWriteError admissionError) ())
publishIssueRealizeUsing fileSystem postAdmission intent = do
  initial <- readCurrentSources fileSystem intent
  case initial of
    Left ioMessage ->
      pure (Left (IssueRealizeFileIOError ioMessage False False False))
    Right current -> case staleCoordinate intent current of
      Just stale -> pure (Left stale)
      Nothing -> stageAndPublish fileSystem postAdmission intent current

data CurrentSources = CurrentSources
  { currentActual         :: Text
  , currentRelationExists :: Bool
  , currentRelation       :: Text
  , currentIssues         :: Text
  }

readCurrentSources
  :: WriterFileSystem
  -> IssueRealizeWriteIntent
  -> IO (Either String CurrentSources)
readCurrentSources fileSystem intent = do
  actualResult <- readRequired fileSystem (writeRealizeActualPath intent)
  relationResult <- readOptional fileSystem (writeRealizeRelationPath intent)
  issuesResult <- readRequired fileSystem (writeRealizeIssuesPath intent)
  pure $ do
    actual <- actualResult
    (relationExists, relation) <- relationResult
    issues <- issuesResult
    pure CurrentSources
      { currentActual = actual
      , currentRelationExists = relationExists
      , currentRelation = relation
      , currentIssues = issues
      }

readRequired :: WriterFileSystem -> FilePath -> IO (Either String Text)
readRequired fileSystem path = catch
  (Right <$> readTextFile fileSystem path)
  (\(errorValue :: IOException) -> pure (Left (show errorValue)))

readOptional
  :: WriterFileSystem
  -> FilePath
  -> IO (Either String (Bool, Text))
readOptional fileSystem path = catch
  (do
    content <- readTextFile fileSystem path
    pure (Right (True, content)))
  (\(errorValue :: IOException) ->
    if isDoesNotExistError errorValue
      then pure (Right (False, ""))
      else pure (Left (show errorValue)))

staleCoordinate
  :: IssueRealizeWriteIntent
  -> CurrentSources
  -> Maybe (IssueRealizeWriteError admissionError)
staleCoordinate intent current
  | currentActual current /= writeRealizeExpectedActual intent =
      Just IssueRealizeActualStale
  | currentRelationExists current /= writeRealizeExpectedRelationExists intent
      || currentRelation current /= writeRealizeExpectedRelation intent =
      Just IssueRealizeRelationStale
  | currentIssues current /= writeRealizeExpectedIssues intent =
      Just IssueRealizeIssuesStale
  | otherwise = Nothing

data StagedIssueRealize = StagedIssueRealize
  { stagedRealizeActualBackup   :: FilePath
  , stagedRealizeActualNew      :: FilePath
  , stagedRealizeRelationBackup :: Maybe FilePath
  , stagedRealizeRelationNew    :: FilePath
  , stagedRealizeIssuesBackup   :: FilePath
  , stagedRealizeIssuesNew      :: FilePath
  }

stageAndPublish
  :: WriterFileSystem
  -> IO (Either admissionError admitted)
  -> IssueRealizeWriteIntent
  -> CurrentSources
  -> IO (Either (IssueRealizeWriteError admissionError) ())
stageAndPublish fileSystem postAdmission intent initial = do
  stagedResult <- catch
    (Right <$> stageSources fileSystem intent initial)
    (\(errorValue :: IOException) -> pure (Left (show errorValue)))
  case stagedResult of
    Left ioMessage ->
      pure (Left (IssueRealizeFileIOError ioMessage False False False))
    Right staged -> do
      prePublish <- readCurrentSources fileSystem intent
      case prePublish of
        Left ioMessage -> do
          cleanupStaged fileSystem staged
          pure (Left (IssueRealizeFileIOError ioMessage False False False))
        Right current -> case staleCoordinate intent current of
          Just stale -> do
            cleanupStaged fileSystem staged
            pure (Left stale)
          Nothing -> installAndAdmit fileSystem postAdmission intent staged

stageSources
  :: WriterFileSystem
  -> IssueRealizeWriteIntent
  -> CurrentSources
  -> IO StagedIssueRealize
stageSources fileSystem intent initial = do
  actualBackup <- stageSiblingTextFile fileSystem
    (writeRealizeActualPath intent)
    ".issue-realize.backup.tmp"
    (writeRealizeExpectedActual intent)
  relationBackup <-
    if currentRelationExists initial
      then Just <$> stageSiblingTextFile fileSystem
        (writeRealizeRelationPath intent)
        ".issue-realize.backup.tmp"
        (writeRealizeExpectedRelation intent)
        `onException` removeQuietly fileSystem actualBackup
      else pure Nothing
  issuesBackup <- stageSiblingTextFile fileSystem
    (writeRealizeIssuesPath intent)
    ".issue-realize.backup.tmp"
    (writeRealizeExpectedIssues intent)
    `onException` cleanupPaths fileSystem
      (actualBackup : maybe [] pure relationBackup)
  actualNew <- stageSiblingTextFile fileSystem
    (writeRealizeActualPath intent)
    ".issue-realize.new.tmp"
    (writeRealizeCandidateActual intent)
    `onException` cleanupPaths fileSystem
      (issuesBackup : actualBackup : maybe [] pure relationBackup)
  relationNew <- stageSiblingTextFile fileSystem
    (writeRealizeRelationPath intent)
    ".issue-realize.new.tmp"
    (writeRealizeCandidateRelation intent)
    `onException` cleanupPaths fileSystem
      (actualNew : issuesBackup : actualBackup : maybe [] pure relationBackup)
  issuesNew <- stageSiblingTextFile fileSystem
    (writeRealizeIssuesPath intent)
    ".issue-realize.new.tmp"
    (writeRealizeCandidateIssues intent)
    `onException` cleanupPaths fileSystem
      (relationNew : actualNew : issuesBackup : actualBackup : maybe [] pure relationBackup)
  pure StagedIssueRealize
    { stagedRealizeActualBackup = actualBackup
    , stagedRealizeActualNew = actualNew
    , stagedRealizeRelationBackup = relationBackup
    , stagedRealizeRelationNew = relationNew
    , stagedRealizeIssuesBackup = issuesBackup
    , stagedRealizeIssuesNew = issuesNew
    }

installAndAdmit
  :: WriterFileSystem
  -> IO (Either admissionError admitted)
  -> IssueRealizeWriteIntent
  -> StagedIssueRealize
  -> IO (Either (IssueRealizeWriteError admissionError) ())
installAndAdmit fileSystem postAdmission intent staged =
  catch run handleIO
  where
    run = do
      renameTextFile fileSystem
        (stagedRealizeActualNew staged)
        (writeRealizeActualPath intent)
      relationBefore <- readOptional fileSystem (writeRealizeRelationPath intent)
      case relationBefore of
        Left ioMessage -> recoverIO ioMessage
        Right (exists, current)
          | exists /= writeRealizeExpectedRelationExists intent
              || current /= writeRealizeExpectedRelation intent -> recoverStale IssueRealizeRelationStale
          | otherwise -> do
              renameTextFile fileSystem
                (stagedRealizeRelationNew staged)
                (writeRealizeRelationPath intent)
              issuesBefore <- readRequired fileSystem (writeRealizeIssuesPath intent)
              case issuesBefore of
                Left ioMessage -> recoverIO ioMessage
                Right currentIssuesSource
                  | currentIssuesSource /= writeRealizeExpectedIssues intent ->
                      recoverStale IssueRealizeIssuesStale
                  | otherwise -> do
                      renameTextFile fileSystem
                        (stagedRealizeIssuesNew staged)
                        (writeRealizeIssuesPath intent)
                      verifyInstalled

    verifyInstalled = do
      currentResult <- readCurrentSources fileSystem intent
      case currentResult of
        Left ioMessage -> recoverIO ioMessage
        Right current
          | currentActual current /= writeRealizeCandidateActual intent ->
              recoverStale IssueRealizeActualStale
          | not (currentRelationExists current)
              || currentRelation current /= writeRealizeCandidateRelation intent ->
              recoverStale IssueRealizeRelationStale
          | currentIssues current /= writeRealizeCandidateIssues intent ->
              recoverStale IssueRealizeIssuesStale
          | otherwise -> admitInstalled

    admitInstalled = do
      admitted <- postAdmission
      case admitted of
        Left admissionError -> do
          (actualSafe, relationSafe, issuesSafe) <-
            recoverExpectedSources fileSystem intent staged
          cleanupCandidatePaths fileSystem staged
          pure (Left (IssueRealizePostAdmissionFailed
            admissionError actualSafe relationSafe issuesSafe))
        Right _ -> verifyAfterAdmission

    verifyAfterAdmission = do
      currentResult <- readCurrentSources fileSystem intent
      case currentResult of
        Left ioMessage -> recoverIO ioMessage
        Right current
          | currentActual current /= writeRealizeCandidateActual intent ->
              recoverStale IssueRealizeActualStale
          | not (currentRelationExists current)
              || currentRelation current /= writeRealizeCandidateRelation intent ->
              recoverStale IssueRealizeRelationStale
          | currentIssues current /= writeRealizeCandidateIssues intent ->
              recoverStale IssueRealizeIssuesStale
          | otherwise -> do
              removeQuietly fileSystem (stagedRealizeActualBackup staged)
              maybe (pure ()) (removeQuietly fileSystem)
                (stagedRealizeRelationBackup staged)
              removeQuietly fileSystem (stagedRealizeIssuesBackup staged)
              cleanupCandidatePaths fileSystem staged
              pure (Right ())

    recoverStale stale = do
      safe <- recoverExpectedSources fileSystem intent staged
      cleanupCandidatePaths fileSystem staged
      if allSafe safe
        then pure (Left stale)
        else pure (Left (recoveryFailure stale safe))

    recoverIO ioMessage = do
      safe@(actualSafe, relationSafe, issuesSafe) <-
        recoverExpectedSources fileSystem intent staged
      cleanupCandidatePaths fileSystem staged
      pure (Left (IssueRealizeFileIOError
        ioMessage actualSafe relationSafe issuesSafe))

    handleIO (errorValue :: IOException) = recoverIO (show errorValue)

allSafe :: (Bool, Bool, Bool) -> Bool
allSafe (actualSafe, relationSafe, issuesSafe) =
  actualSafe && relationSafe && issuesSafe

recoveryFailure
  :: IssueRealizeWriteError admissionError
  -> (Bool, Bool, Bool)
  -> IssueRealizeWriteError admissionError
recoveryFailure stale (actualSafe, relationSafe, issuesSafe) =
  IssueRealizeFileIOError
    ("coordinated realization became stale and guarded recovery was incomplete: "
      <> showStale stale)
    actualSafe relationSafe issuesSafe

showStale :: IssueRealizeWriteError admissionError -> String
showStale stale = case stale of
  IssueRealizeActualStale -> "actual"
  IssueRealizeRelationStale -> "relation"
  IssueRealizeIssuesStale -> "issues"
  IssueRealizePostAdmissionFailed _ _ _ _ -> "post-admission"
  IssueRealizeFileIOError _ _ _ _ -> "io"

recoverExpectedSources
  :: WriterFileSystem
  -> IssueRealizeWriteIntent
  -> StagedIssueRealize
  -> IO (Bool, Bool, Bool)
recoverExpectedSources fileSystem intent staged = do
  actualSafe <- recoverRequiredExpectedSource
    fileSystem
    (stagedRealizeActualBackup staged)
    (writeRealizeActualPath intent)
    (writeRealizeExpectedActual intent)
    (writeRealizeCandidateActual intent)
  relationSafe <- recoverRelationExpectedSource
    fileSystem intent staged
  issuesSafe <- recoverRequiredExpectedSource
    fileSystem
    (stagedRealizeIssuesBackup staged)
    (writeRealizeIssuesPath intent)
    (writeRealizeExpectedIssues intent)
    (writeRealizeCandidateIssues intent)
  pure (actualSafe, relationSafe, issuesSafe)

recoverRequiredExpectedSource
  :: WriterFileSystem
  -> FilePath
  -> FilePath
  -> Text
  -> Text
  -> IO Bool
recoverRequiredExpectedSource fileSystem backupPath targetPath expected candidate = do
  current <- catch
    (Just <$> readTextFile fileSystem targetPath)
    (\(_ :: IOException) -> pure Nothing)
  case current of
    Nothing -> pure False
    Just bytes
      | bytes == expected -> do
          removeQuietly fileSystem backupPath
          pure True
      | bytes == candidate -> catch
          (renameTextFile fileSystem backupPath targetPath >> pure True)
          (\(_ :: IOException) -> pure False)
      | otherwise -> do
          removeQuietly fileSystem backupPath
          pure False

recoverRelationExpectedSource
  :: WriterFileSystem
  -> IssueRealizeWriteIntent
  -> StagedIssueRealize
  -> IO Bool
recoverRelationExpectedSource fileSystem intent staged = do
  currentResult <- readOptional fileSystem (writeRealizeRelationPath intent)
  case currentResult of
    Left _ -> pure False
    Right (exists, bytes)
      | writeRealizeExpectedRelationExists intent ->
          case stagedRealizeRelationBackup staged of
            Nothing -> pure False
            Just backupPath
              | exists && bytes == writeRealizeExpectedRelation intent -> do
                  removeQuietly fileSystem backupPath
                  pure True
              | exists && bytes == writeRealizeCandidateRelation intent -> catch
                  (renameTextFile fileSystem backupPath (writeRealizeRelationPath intent) >> pure True)
                  (\(_ :: IOException) -> pure False)
              | otherwise -> do
                  removeQuietly fileSystem backupPath
                  pure False
      | not exists -> pure True
      | bytes == writeRealizeCandidateRelation intent -> catch
          (removeTextFile fileSystem (writeRealizeRelationPath intent) >> pure True)
          (\(_ :: IOException) -> pure False)
      | otherwise -> pure False

cleanupStaged :: WriterFileSystem -> StagedIssueRealize -> IO ()
cleanupStaged fileSystem staged = cleanupPaths fileSystem
  ( [ stagedRealizeActualNew staged
    , stagedRealizeRelationNew staged
    , stagedRealizeIssuesNew staged
    , stagedRealizeActualBackup staged
    , stagedRealizeIssuesBackup staged
    ]
    ++ maybe [] pure (stagedRealizeRelationBackup staged)
  )

cleanupCandidatePaths :: WriterFileSystem -> StagedIssueRealize -> IO ()
cleanupCandidatePaths fileSystem staged = cleanupPaths fileSystem
  [ stagedRealizeActualNew staged
  , stagedRealizeRelationNew staged
  , stagedRealizeIssuesNew staged
  ]

cleanupPaths :: WriterFileSystem -> [FilePath] -> IO ()
cleanupPaths fileSystem = mapM_ (removeQuietly fileSystem)

removeQuietly :: WriterFileSystem -> FilePath -> IO ()
removeQuietly fileSystem path = catch
  (removeTextFile fileSystem path)
  (\(_ :: IOException) -> pure ())
