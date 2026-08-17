{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Explicit Issue realization as one coordinated household operation.
--
-- A realization creates a newly identified Actual transaction, records one
-- explicit 'IssueRealizedAs' relation to that exact source-durable identity,
-- and resolves the Issue as separate lifecycle evidence. No relation is inferred
-- from date, memo, amount, Account shape, or other approximate similarity.
module HKernel.Editor.IssueRealize
  ( IssueRealizeIntent(..)
  , IssueRealizeError(..)
  , IssueRealizePreview(..)
  , IssueRelationHouseholdAdmissionError(..)
  , admitIssueRelationSource
  , prepareIssueRealize
  , IssueRealizeWriteIntent(..)
  , IssueRealizeWriteError(..)
  , publishIssueRealize
  , publishIssueRealizeUsing
  ) where

import Control.Exception (IOException, catch, onException)
import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import System.IO.Error (isDoesNotExistError)

import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalIdentifiedTransactions
  , actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntrySource
  )
import qualified HKernel.Editor.ActualAppend as ActualAppend
import HKernel.Editor.IssueAppend
  ( IssueCloseDisposition(..)
  , IssueCloseError
  , IssueCloseIntent(..)
  , closeCandidateCompleteSource
  , closeCandidateRow
  , prepareIssueCloseOn
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Editor.SourcePublication
  ( WriterFileSystem(..)
  , defaultWriterFileSystem
  )
import HKernel.Household.Issue.Relation.TSV
  ( IssueRelationTSVError
  , issueRelationHeader
  , parseIssueRelations
  , renderIssueRelations
  )
import HKernel.Household.Issue.TSV
  ( HouseholdIssueTSVError
  , parseHouseholdIssues
  )
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueId
  , IssueRelation(..)
  , IssueRelationEvent
  , IssueRelationEventError
  , IssueRelationEventId
  , IssueRelationEventIdError
  , IssueRelationReferenceError
  , IssueStatus(..)
  , admitIssueRelationReferences
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  , issueIdText
  , issueRelationEventId
  , issueRelationEventIdText
  , mkIssueRelationEvent
  , mkIssueRelationEventId
  )
import HKernel.Journal
  ( journalMetadataKey
  , journalMetadataValue
  , journalTransactionSourceMetadata
  )
import HKernel.Plan.Journal
  ( PlanJournal
  , identifiedPlanId
  , planJournalTransactions
  )
import HKernel.Plan.Completion
  ( ActualTransactionId
  , ActualTransactionIdError
  , actualTransactionIdText
  , identifiedActualId
  , mkActualTransactionId
  )

-- | One household decision to turn an open Issue into explicit Actual evidence.
--
-- The Actual date belongs to 'realizeActualIntent'. @recordedOn@ is when the
-- relation assertion was recorded, while @closedOn@ remains independent Issue
-- lifecycle evidence. Existing Issue close admission validates the close date
-- against the Issue's own recorded date without coupling it to relation time.
data IssueRealizeIntent = IssueRealizeIntent
  { realizeIssueId      :: IssueId
  , realizeRecordedOn   :: Day
  , realizeClosedOn     :: Day
  , realizeActualIntent :: ActualAppend.ActualEditIntent
  , realizeDecisionMemo :: Text
  } deriving (Eq, Show)

data IssueRealizeError
  = RealizeIssueSourceError (NonEmpty HouseholdIssueTSVError)
  | RealizeRelationSourceError (NonEmpty IssueRelationTSVError)
  | RealizeIssueNotFound IssueId
  | RealizeIssueNotOpen IssueStatus
  | RealizeRelationBeforeIssueRecorded Day Day
  | RealizeActualMetadataOwnsEventId
  | RealizeActualIdentityError ActualTransactionIdError
  | RealizeActualCandidateError ActualAppend.ActualEditError
  | RealizeRelationEventIdError IssueRelationEventIdError
  | RealizeRelationEventError IssueRelationEventError
  | RealizeRelationReferenceError IssueRelationReferenceError
  | RealizeRelationCandidateSourceError (NonEmpty IssueRelationTSVError)
  | RealizeIssueCloseError IssueCloseError
  deriving (Eq, Show)

data IssueRealizePreview = IssueRealizePreview
  { realizedActualId                 :: ActualTransactionId
  , realizedRelationEventId          :: IssueRelationEventId
  , realizedActualBlock              :: Text
  , realizedRelationBlock            :: Text
  , realizedIssueBlock               :: Text
  , realizedActualCandidateSource    :: Text
  , realizedRelationCandidateSource  :: Text
  , realizedIssuesCandidateSource    :: Text
  } deriving (Eq, Show)

-- | Source-level relation admission against one already admitted Household.
-- Only explicit source-durable Actual @event-id@ coordinates are relation
-- targets. Plan-derived runtime identities remain intentionally excluded.
data IssueRelationHouseholdAdmissionError
  = IssueRelationAdmissionSourceError (NonEmpty IssueRelationTSVError)
  | IssueRelationAdmissionReferenceError IssueRelationReferenceError
  deriving (Eq, Show)

admitIssueRelationSource
  :: ActualJournal
  -> PlanJournal
  -> [HouseholdIssue]
  -> Text
  -> Either (NonEmpty IssueRelationHouseholdAdmissionError) [IssueRelationEvent]
admitIssueRelationSource actualJournal planJournal issues source = do
  relations <- first (pure . IssueRelationAdmissionSourceError)
    (parseIssueRelations source)
  first (fmap IssueRelationAdmissionReferenceError)
    (admitIssueRelationReferences
      (map householdIssueId issues)
      (map identifiedPlanId (planJournalTransactions planJournal))
      (sourceDurableActualIds actualJournal)
      relations)

-- | Prepare the three complete sources for one explicit Issue realization.
--
-- The supplied Actual and Plan journals must come from the same admitted
-- Household observation as the supplied root source texts. Existing relation
-- references are rechecked together with the new relation, and the new Actual
-- identity participates only because this operation writes an explicit
-- @event-id@ into the candidate Actual block.
prepareIssueRealize
  :: ActualJournal
  -> PlanJournal
  -> Text
  -> Text
  -> Text
  -> IssueRealizeIntent
  -> Either (NonEmpty IssueRealizeError) IssueRealizePreview
prepareIssueRealize actualJournal planJournal actualSource relationSource issuesSource intent = do
  issues <- first (pure . RealizeIssueSourceError)
    (parseHouseholdIssues issuesSource)
  relations <- first (pure . RealizeRelationSourceError)
    (parseIssueRelations relationSource)
  target <- maybe
    (Left (pure (RealizeIssueNotFound (realizeIssueId intent))))
    Right
    (findIssue (realizeIssueId intent) issues)
  case householdIssueStatus target of
    Open -> Right ()
    status -> Left (pure (RealizeIssueNotOpen status))
  if realizeRecordedOn intent < householdIssueRecordedOn target
    then Left (pure (RealizeRelationBeforeIssueRecorded
      (householdIssueRecordedOn target) (realizeRecordedOn intent)))
    else Right ()
  if any ((== "event-id") . T.toCaseFold . fst)
      (ActualAppend.intentMetadata (realizeActualIntent intent))
    then Left (pure RealizeActualMetadataOwnsEventId)
    else Right ()

  actualId <- first (pure . RealizeActualIdentityError)
    (generateActualId
      (realizeIssueId intent)
      (map identifiedActualId (actualJournalIdentifiedTransactions actualJournal)))
  let actualIntent = (realizeActualIntent intent)
        { ActualAppend.intentMetadata =
            ("event-id", actualTransactionIdText actualId)
              : ActualAppend.intentMetadata (realizeActualIntent intent)
        }
  actualPreview <- first (fmap RealizeActualCandidateError)
    (ActualAppend.prepareActualAppendFromResolvedJournal
      (actualJournalValue actualJournal)
      actualSource
      actualIntent)

  relationEventId <- first (pure . RealizeRelationEventIdError)
    (generateRelationEventId actualId relations)
  relation <- first (pure . RealizeRelationEventError)
    (mkIssueRelationEvent
      relationEventId
      (realizeRecordedOn intent)
      (realizeIssueId intent)
      (IssueRealizedAs actualId)
      (realizeDecisionMemo intent))
  let relationBlock = renderedRelationRow relation
      relationCandidate = appendRelation relationSource relationBlock
      candidateRelations = relations ++ [relation]
      knownIssues = map householdIssueId issues
      knownPlans = map identifiedPlanId (planJournalTransactions planJournal)
      knownDurableActuals = sourceDurableActualIds actualJournal ++ [actualId]
  _ <- first (fmap RealizeRelationReferenceError)
    (admitIssueRelationReferences
      knownIssues knownPlans knownDurableActuals candidateRelations)
  parsedCandidateRelations <- first (pure . RealizeRelationCandidateSourceError)
    (parseIssueRelations relationCandidate)
  _ <- first (fmap RealizeRelationReferenceError)
    (admitIssueRelationReferences
      knownIssues knownPlans knownDurableActuals parsedCandidateRelations)

  closePreview <- first (fmap RealizeIssueCloseError)
    (prepareIssueCloseOn
      issuesSource
      (realizeClosedOn intent)
      IssueCloseIntent
        { closeIssueId = realizeIssueId intent
        , closeDisposition = ResolveIssue
        , closeDecisionMemo = realizeDecisionMemo intent
        })

  pure IssueRealizePreview
    { realizedActualId = actualId
    , realizedRelationEventId = relationEventId
    , realizedActualBlock = ActualAppend.candidateBlock actualPreview
    , realizedRelationBlock = relationBlock
    , realizedIssueBlock = closeCandidateRow closePreview
    , realizedActualCandidateSource = ActualAppend.candidateCompleteSource actualPreview
    , realizedRelationCandidateSource = relationCandidate
    , realizedIssuesCandidateSource = closeCandidateCompleteSource closePreview
    }

findIssue :: IssueId -> [HouseholdIssue] -> Maybe HouseholdIssue
findIssue target = go
  where
    go [] = Nothing
    go (issue : rest)
      | householdIssueId issue == target = Just issue
      | otherwise = go rest

generateActualId
  :: IssueId
  -> [ActualTransactionId]
  -> Either ActualTransactionIdError ActualTransactionId
generateActualId issueId existing = go (1 :: Int)
  where
    occupied = Set.fromList (map actualTransactionIdText existing)
    base = issueIdText issueId <> "-actual"
    go index = do
      let candidateText
            | index == 1 = base
            | otherwise = base <> "-" <> T.pack (show index)
      candidate <- mkActualTransactionId candidateText
      if candidateText `Set.member` occupied
        then go (index + 1)
        else Right candidate

generateRelationEventId
  :: ActualTransactionId
  -> [IssueRelationEvent]
  -> Either IssueRelationEventIdError IssueRelationEventId
generateRelationEventId actualId existing = go (1 :: Int)
  where
    occupied = Set.fromList
      (map (issueRelationEventIdText . issueRelationEventId) existing)
    base = actualTransactionIdText actualId <> "-realized"
    go index = do
      let candidateText
            | index == 1 = base
            | otherwise = base <> "-" <> T.pack (show index)
      candidate <- mkIssueRelationEventId candidateText
      if candidateText `Set.member` occupied
        then go (index + 1)
        else Right candidate

sourceDurableActualIds :: ActualJournal -> [ActualTransactionId]
sourceDurableActualIds =
  mapMaybe durableId . actualJournalTransactionEntries
  where
    durableId entry = case
        [ journalMetadataValue metadata
        | metadata <- journalTransactionSourceMetadata
            (actualTransactionEntrySource entry)
        , T.toCaseFold (journalMetadataKey metadata) == "event-id"
        ] of
      [value] -> either (const Nothing) Just (mkActualTransactionId value)
      _ -> Nothing

renderedRelationRow :: IssueRelationEvent -> Text
renderedRelationRow relation =
  case T.lines (renderIssueRelations [relation]) of
    _header : row : _ -> row
    _ -> error "renderIssueRelations did not render one relation row"

appendRelation :: Text -> Text -> Text
appendRelation existing row =
  appendSourceBlock existing (SourceBlock block)
  where
    hasHeader = case meaningfulLines existing of
      (_, firstLine) : _ -> firstLine == issueRelationHeader
      [] -> False
    block
      | hasHeader = row
      | otherwise = issueRelationHeader <> "\n" <> row <> "\n"

meaningfulLines :: Text -> [(Int, Text)]
meaningfulLines =
  filter (not . ignored . snd) . zip [1..] . T.lines
  where
    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped

-- Coordinated publication -----------------------------------------------------

-- | Three physical sources whose exact observed bytes and exact candidates form
-- one coordinated household mutation. The relation source may be absent before
-- the first realization; absence is an explicit temporal coordinate.
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

publishIssueRealize
  :: IO (Either admissionError admitted)
  -> IssueRealizeWriteIntent
  -> IO (Either (IssueRealizeWriteError admissionError) ())
publishIssueRealize = publishIssueRealizeUsing defaultWriterFileSystem

-- | Publish Actual, explicit relation history, and Issue closure as one guarded
-- operation. All expected sources are fenced before staging and again before the
-- first install. Relation and Issues are re-fenced after each preceding install.
-- Rollback replaces only this operation's exact candidate, so an unrelated
-- writer is never overwritten.
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
      (actualBackup : maybe [] (:[]) relationBackup)
  actualNew <- stageSiblingTextFile fileSystem
    (writeRealizeActualPath intent)
    ".issue-realize.new.tmp"
    (writeRealizeCandidateActual intent)
    `onException` cleanupPaths fileSystem
      (issuesBackup : actualBackup : maybe [] (:[]) relationBackup)
  relationNew <- stageSiblingTextFile fileSystem
    (writeRealizeRelationPath intent)
    ".issue-realize.new.tmp"
    (writeRealizeCandidateRelation intent)
    `onException` cleanupPaths fileSystem
      (actualNew : issuesBackup : actualBackup : maybe [] (:[]) relationBackup)
  issuesNew <- stageSiblingTextFile fileSystem
    (writeRealizeIssuesPath intent)
    ".issue-realize.new.tmp"
    (writeRealizeCandidateIssues intent)
    `onException` cleanupPaths fileSystem
      (relationNew : actualNew : issuesBackup : actualBackup : maybe [] (:[]) relationBackup)
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
              || current /= writeRealizeExpectedRelation intent ->
              recoverStale IssueRealizeRelationStale
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
      (actualSafe, relationSafe, issuesSafe) <-
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
  relationSafe <- recoverRelationExpectedSource fileSystem intent staged
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
                  (renameTextFile fileSystem backupPath
                    (writeRealizeRelationPath intent) >> pure True)
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
    ++ maybe [] (:[]) (stagedRealizeRelationBackup staged)
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
