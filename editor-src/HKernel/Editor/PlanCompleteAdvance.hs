{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | One household operation for closing a Plan with an Actual transaction and,
-- when requested, appending its next occurrence.
--
-- The nominal Plan date and the Actual date deliberately remain separate. A
-- payment brought forward for a weekend must not make a monthly series drift.
module HKernel.Editor.PlanCompleteAdvance
  ( PlanRecurrence(..)
  , PlanAdvanceProposal(..)
  , PlanCompleteAdvanceIntent(..)
  , PlanCompleteAdvancePreview(..)
  , PlanCompleteAdvanceError(..)
  , proposePlanAdvance
  , preparePlanCompleteAdvance
  , PlanCompleteAdvanceWriteIntent(..)
  , PlanCompleteAdvanceWriteError(..)
  , publishPlanCompleteAdvance
  , publishPlanCompleteAdvanceUsing
  ) where

import Control.Exception (IOException, catch, onException)
import Data.Bifunctor (first)
import Data.Char (isAsciiLower, isAsciiUpper, isSpace, toLower)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, addGregorianMonthsClip)

import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalCompletionDeclarations
  , actualJournalValue
  )
import HKernel.Editor.ActualAppend
  ( ActualAppendPreview(..)
  , ActualEditError
  , ActualEditIntent(..)
  , prepareActualAppendFromResolvedJournal
  )
import HKernel.Editor.ActualWriter
  ( WriterFileSystem(..)
  , defaultWriterFileSystem
  )
import HKernel.Editor.PlanLifecycle
  ( PositivePlanFinishAmount
  , positivePlanFinishAmountQuantity
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Editor.TransactionBlock
  ( IntentPosting(..)
  , PreparedTransactionBlock(..)
  , TransactionBlockError
  , TransactionBlockIntent(..)
  , prepareTransactionBlock
  )
import HKernel.Journal
  ( appendJournalTransaction
  , journalAccountRegistry
  )
import HKernel.Ledger
  ( Posting
  , Transaction
  , mkPosting
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( amountCommodity
  , amountQuantity
  , mkAmount
  , negateQuantity
  , quantityToRational
  )
import HKernel.Plan
  ( PlanId
  , PlanIdError
  , mkPlanId
  , planIdText
  )
import HKernel.Plan.Completion (declaredCompletionPlanId)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanJournal
  , PlanJournalError
  , admitPlanJournalFromResolvedJournal
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalTransactions
  , planJournalValue
  )

data PlanRecurrence
  = PlanRecursOnce
  | PlanRecursMonthly
  | PlanRecursByHouseholdCycle
  | PlanRecurrenceUnspecified
  deriving (Eq, Show)

data PlanAdvanceProposal = PlanAdvanceProposal
  { proposalPlanId              :: PlanId
  , proposalNominalDate         :: Day
  , proposalRecurrence          :: PlanRecurrence
  , proposalSuggestedNextDate   :: Maybe Day
  , proposalDescription         :: Text
  , proposalOriginalTransaction :: Transaction
  } deriving (Eq, Show)

data PlanCompleteAdvanceIntent = PlanCompleteAdvanceIntent
  { completeAdvancePlanId          :: PlanId
  , completeAdvanceActualDate      :: Day
  , completeAdvanceActualAmount    :: Maybe PositivePlanFinishAmount
  , completeAdvanceSuccessorDate   :: Maybe Day
  , completeAdvanceSuccessorAmount :: Maybe PositivePlanFinishAmount
  } deriving (Eq, Show)

data PlanCompleteAdvancePreview = PlanCompleteAdvancePreview
  { completeAdvanceActualBlock        :: Text
  , completeAdvanceActualSource       :: Text
  , completeAdvanceSuccessorBlock     :: Maybe Text
  , completeAdvancePlanSource         :: Text
  , completeAdvanceSuccessorPlanId    :: Maybe PlanId
  , completeAdvanceRecurrence         :: PlanRecurrence
  } deriving (Eq, Show)

data PlanCompleteAdvanceError
  = CompleteAdvancePlanNotFound PlanId
  | CompleteAdvancePlanAlreadyClosed PlanId
  | CompleteAdvanceMetadataMissing PlanId
  | CompleteAdvanceDuplicateMetadata Text
  | CompleteAdvanceInvalidRecurrence Text
  | CompleteAdvanceSuccessorForbiddenForOnce
  | CompleteAdvanceSuccessorAmountWithoutDate
  | CompleteAdvanceAmountOverrideRequiresBinaryPlan
  | CompleteAdvanceActualError (NonEmpty ActualEditError)
  | CompleteAdvanceSuccessorBlockError (NonEmpty TransactionBlockError)
  | CompleteAdvanceSuccessorCandidateError (NonEmpty PlanJournalError)
  | CompleteAdvanceGeneratedPlanIdError PlanIdError
  deriving (Eq, Show)

proposePlanAdvance
  :: PlanJournal
  -> Text
  -> PlanId
  -> Either (NonEmpty PlanCompleteAdvanceError) PlanAdvanceProposal
proposePlanAdvance planJournal planSource targetId = do
  identified <- findPlan planJournal targetId
  metadata <- sourceMetadataFor targetId planSource
  recurrence <- admitRecurrence metadata
  let transaction = identifiedPlanTransaction identified
      nominalDate = transactionDate transaction
      suggested = case recurrence of
        PlanRecursMonthly -> Just (addGregorianMonthsClip 1 nominalDate)
        PlanRecursOnce -> Nothing
        PlanRecursByHouseholdCycle -> Nothing
        PlanRecurrenceUnspecified -> Nothing
  pure PlanAdvanceProposal
    { proposalPlanId = targetId
    , proposalNominalDate = nominalDate
    , proposalRecurrence = recurrence
    , proposalSuggestedNextDate = suggested
    , proposalDescription = transactionDescription transaction
    , proposalOriginalTransaction = transaction
    }

preparePlanCompleteAdvance
  :: PlanJournal
  -> ActualJournal
  -> Text
  -> Text
  -> PlanCompleteAdvanceIntent
  -> Either (NonEmpty PlanCompleteAdvanceError) PlanCompleteAdvancePreview
preparePlanCompleteAdvance planJournal actualJournal planSource actualSource intent = do
  identified <- findPlan planJournal targetId
  let transaction = identifiedPlanTransaction identified
  ensureOpen actualJournal targetId
  metadata <- sourceMetadataFor targetId planSource
  recurrence <- admitRecurrence metadata
  validateSuccessorChoice recurrence intent
  actualPostings <- replaceBinaryMagnitude
    CompleteAdvanceAmountOverrideRequiresBinaryPlan
    (completeAdvanceActualAmount intent)
    (transactionPostings transaction)
  actualPreview <- first (pure . CompleteAdvanceActualError)
    (prepareActualAppendFromResolvedJournal
      (actualJournalValue actualJournal)
      actualSource
      ActualEditIntent
        { intentDate = completeAdvanceActualDate intent
        , intentDescription = transactionDescription transaction
        , intentPostings = fmap postingIntent actualPostings
        , intentMetadata = [("plan-id", planIdText targetId)]
        })
  case completeAdvanceSuccessorDate intent of
    Nothing -> pure PlanCompleteAdvancePreview
      { completeAdvanceActualBlock = candidateBlock actualPreview
      , completeAdvanceActualSource = candidateCompleteSource actualPreview
      , completeAdvanceSuccessorBlock = Nothing
      , completeAdvancePlanSource = planSource
      , completeAdvanceSuccessorPlanId = Nothing
      , completeAdvanceRecurrence = recurrence
      }
    Just successorDate -> do
      successorPostings <- replaceBinaryMagnitude
        CompleteAdvanceAmountOverrideRequiresBinaryPlan
        (completeAdvanceSuccessorAmount intent)
        (transactionPostings transaction)
      successorId <- first (pure . CompleteAdvanceGeneratedPlanIdError)
        (generateSuccessorPlanId
          successorDate
          (transactionDescription transaction)
          (metadataValue "series" metadata)
          (map identifiedPlanId (planJournalTransactions planJournal)
            ++ map declaredCompletionPlanId
              (actualJournalCompletionDeclarations actualJournal)))
      let successorMetadata =
            [("plan-id", planIdText successorId)]
              ++ successorDailyTargetMetadata successorId metadata
              ++ metadataForSuccessor metadata
          blockIntent = TransactionBlockIntent
            { blockDate = successorDate
            , blockDescription = transactionDescription transaction
            , blockPostings = fmap postingIntent successorPostings
            , blockMetadata = successorMetadata
            }
      prepared <- first (pure . CompleteAdvanceSuccessorBlockError)
        (prepareTransactionBlock
          (journalAccountRegistry (planJournalValue planJournal))
          blockIntent)
      let successorBlock = preparedTransactionBlock prepared
          candidatePlanSource = appendSourceBlock planSource (SourceBlock successorBlock)
          candidateResolvedPlan = appendJournalTransaction
            (preparedTransaction prepared)
            (planJournalValue planJournal)
      _ <- first (pure . CompleteAdvanceSuccessorCandidateError)
        (admitPlanJournalFromResolvedJournal candidateResolvedPlan candidatePlanSource)
      pure PlanCompleteAdvancePreview
        { completeAdvanceActualBlock = candidateBlock actualPreview
        , completeAdvanceActualSource = candidateCompleteSource actualPreview
        , completeAdvanceSuccessorBlock = Just successorBlock
        , completeAdvancePlanSource = candidatePlanSource
        , completeAdvanceSuccessorPlanId = Just successorId
        , completeAdvanceRecurrence = recurrence
        }
  where
    targetId = completeAdvancePlanId intent

postingIntent :: Posting -> IntentPosting
postingIntent posting = IntentPosting
  (postingAccount posting)
  (amountQuantity (postingAmount posting))
  (Just (amountCommodity (postingAmount posting)))

replaceBinaryMagnitude
  :: PlanCompleteAdvanceError
  -> Maybe PositivePlanFinishAmount
  -> NonEmpty Posting
  -> Either (NonEmpty PlanCompleteAdvanceError) (NonEmpty Posting)
replaceBinaryMagnitude _ Nothing postings = Right postings
replaceBinaryMagnitude errorValue (Just replacement) postings
  | NonEmpty.length postings /= 2 = Left (pure errorValue)
  | otherwise = Right (fmap replace postings)
  where
    magnitude = positivePlanFinishAmountQuantity replacement
    replace posting =
      let oldAmount = postingAmount posting
          oldQuantity = amountQuantity oldAmount
          newQuantity
            | quantityToRational oldQuantity < 0 = negateQuantity magnitude
            | otherwise = magnitude
      in mkPosting
          (postingAccount posting)
          (mkAmount (amountCommodity oldAmount) newQuantity)

findPlan :: PlanJournal -> PlanId -> Either (NonEmpty PlanCompleteAdvanceError) IdentifiedPlanTransaction
findPlan planJournal targetId =
  case filter ((== targetId) . identifiedPlanId) (planJournalTransactions planJournal) of
    identified : _ -> Right identified
    [] -> Left (pure (CompleteAdvancePlanNotFound targetId))

ensureOpen :: ActualJournal -> PlanId -> Either (NonEmpty PlanCompleteAdvanceError) ()
ensureOpen actualJournal targetId
  | targetId `elem` map declaredCompletionPlanId
      (actualJournalCompletionDeclarations actualJournal) =
      Left (pure (CompleteAdvancePlanAlreadyClosed targetId))
  | otherwise = Right ()

validateSuccessorChoice :: PlanRecurrence -> PlanCompleteAdvanceIntent -> Either (NonEmpty PlanCompleteAdvanceError) ()
validateSuccessorChoice recurrence intent
  | completeAdvanceSuccessorDate intent == Nothing
      && completeAdvanceSuccessorAmount intent /= Nothing =
      Left (pure CompleteAdvanceSuccessorAmountWithoutDate)
  | recurrence == PlanRecursOnce
      && completeAdvanceSuccessorDate intent /= Nothing =
      Left (pure CompleteAdvanceSuccessorForbiddenForOnce)
  | otherwise = Right ()

type Metadata = [(Text, Text)]

sourceMetadataFor :: PlanId -> Text -> Either (NonEmpty PlanCompleteAdvanceError) Metadata
sourceMetadataFor targetId source =
  case filter (blockOwns targetId) (sourceBlocks source) of
    [] -> Left (pure (CompleteAdvanceMetadataMissing targetId))
    block : _ ->
      let metadata = mapMaybe metadataLine (drop 1 block)
          duplicateKeys = duplicates (map fst metadata)
      in case duplicateKeys of
          key : _ -> Left (pure (CompleteAdvanceDuplicateMetadata key))
          [] -> Right metadata

blockOwns :: PlanId -> [Text] -> Bool
blockOwns targetId block =
  metadataValue "plan-id" (mapMaybe metadataLine (drop 1 block)) == Just (planIdText targetId)

sourceBlocks :: Text -> [[Text]]
sourceBlocks = map reverse . reverse . foldl' addLine [] . T.lines
  where
    addLine blocks line
      | startsBlock line = [line] : blocks
      | otherwise = case blocks of
          [] -> []
          block : rest -> (line : block) : rest

startsBlock :: Text -> Bool
startsBlock line =
  not (T.null (T.strip line)) && not (isIndented line) && not (isComment line)

isIndented :: Text -> Bool
isIndented line = case T.uncons line of
  Just (character, _) -> isSpace character
  Nothing -> False

isComment :: Text -> Bool
isComment = T.isPrefixOf ";" . T.stripStart

metadataLine :: Text -> Maybe (Text, Text)
metadataLine line
  | not (isIndented line && isComment line) = Nothing
  | T.null remainder = Nothing
  | otherwise = Just (T.toCaseFold (T.strip key), T.strip (T.drop 1 remainder))
  where
    clean = T.dropWhile (\character -> character == ';' || isSpace character) (T.strip line)
    (key, remainder) = T.breakOn ":" clean

metadataValue :: Text -> Metadata -> Maybe Text
metadataValue key metadata = lookup (T.toCaseFold key) metadata

admitRecurrence :: Metadata -> Either (NonEmpty PlanCompleteAdvanceError) PlanRecurrence
admitRecurrence metadata = case fmap T.toCaseFold (metadataValue "recur" metadata) of
  Nothing -> Right PlanRecurrenceUnspecified
  Just "once" -> Right PlanRecursOnce
  Just "monthly" -> Right PlanRecursMonthly
  Just "cycle" -> Right PlanRecursByHouseholdCycle
  Just value -> Left (pure (CompleteAdvanceInvalidRecurrence value))

metadataForSuccessor :: Metadata -> Metadata
metadataForSuccessor = filter (not . excluded . fst)
  where
    excluded key = T.toCaseFold key `elem`
      [ "plan-id", "daily-target-id", "reservation-id", "reservation-amount", "reservation-commodity" ]

successorDailyTargetMetadata :: PlanId -> Metadata -> Metadata
successorDailyTargetMetadata successorId metadata =
  case metadataValue "daily-target-id" metadata of
    Nothing -> []
    Just _ -> [("daily-target-id", planIdText successorId <> "-daily-target")]

duplicates :: Eq value => [value] -> [value]
duplicates = go []
  where
    go _ [] = []
    go seen (value : values)
      | value `elem` seen = value : go seen values
      | otherwise = go (value : seen) values

slugify :: Text -> Text
slugify textValue = T.intercalate "-" (filter (not . T.null) (T.splitOn "-" mapped))
  where
    mapped = T.map mapCharacter textValue
    mapCharacter character
      | isAsciiUpper character = toLower character
      | isAsciiLower character = character
      | character >= '0' && character <= '9' = character
      | otherwise = '-'

generateSuccessorPlanId :: Day -> Text -> Maybe Text -> [PlanId] -> Either PlanIdError PlanId
generateSuccessorPlanId date description maybeSeries existing = go 1
  where
    dateText = T.pack (show date)
    suffix = case maybeSeries of
      Just series | not (T.null (T.strip series)) -> T.strip series
      _ -> let slug = slugify description in if T.null slug then "plan" else slug
    base = "plan-" <> dateText <> "-" <> suffix
    candidate n
      | n == 1 = base
      | n < 10 = base <> "-0" <> T.pack (show n)
      | otherwise = base <> "-" <> T.pack (show n)
    go n = do
      planId <- mkPlanId (candidate n)
      if planId `elem` existing then go (n + 1) else Right planId

data PlanCompleteAdvanceWriteIntent = PlanCompleteAdvanceWriteIntent
  { writeActualPath      :: FilePath
  , writeExpectedActual  :: Text
  , writeCandidateActual :: Text
  , writePlanPath        :: FilePath
  , writeExpectedPlan    :: Text
  , writeCandidatePlan   :: Text
  } deriving (Eq, Show)

data PlanCompleteAdvanceWriteError admissionError
  = PlanCompleteAdvanceActualStale
  | PlanCompleteAdvancePlanStale
  | PlanCompleteAdvancePostAdmissionFailed admissionError Bool Bool
  | PlanCompleteAdvanceFileIOError String Bool Bool
  deriving (Eq, Show)

-- | Publish the coordinated Plan completion using the same narrow filesystem
-- primitives as the single-source writer. Both expected roots are observed
-- before staging and again immediately before the first rename. Plan is fenced
-- once more after Actual installation and immediately before its own rename.
-- Both exact candidates are fenced immediately before and after whole-Household
-- admission. Staging paths are unique siblings, and recovery only replaces a
-- target that still contains this writer's exact candidate. The Bool recovery
-- coordinates mean that the expected original is safely present after recovery,
-- either because it was untouched or because guarded restore worked.
publishPlanCompleteAdvance
  :: IO (Either admissionError admitted)
  -> PlanCompleteAdvanceWriteIntent
  -> IO (Either (PlanCompleteAdvanceWriteError admissionError) ())
publishPlanCompleteAdvance = publishPlanCompleteAdvanceUsing defaultWriterFileSystem

publishPlanCompleteAdvanceUsing
  :: WriterFileSystem
  -> IO (Either admissionError admitted)
  -> PlanCompleteAdvanceWriteIntent
  -> IO (Either (PlanCompleteAdvanceWriteError admissionError) ())
publishPlanCompleteAdvanceUsing fileSystem postAdmission intent = do
  initial <- readCurrentSources fileSystem intent
  case initial of
    Left ioMessage ->
      pure (Left (PlanCompleteAdvanceFileIOError ioMessage False False))
    Right (currentActual, currentPlan)
      | currentActual /= writeExpectedActual intent ->
          pure (Left PlanCompleteAdvanceActualStale)
      | currentPlan /= writeExpectedPlan intent ->
          pure (Left PlanCompleteAdvancePlanStale)
      | otherwise -> stageAndPublish fileSystem postAdmission intent

readCurrentSources
  :: WriterFileSystem
  -> PlanCompleteAdvanceWriteIntent
  -> IO (Either String (Text, Text))
readCurrentSources fileSystem intent = catch
  (do
    actual <- readTextFile fileSystem (writeActualPath intent)
    plan <- readTextFile fileSystem (writePlanPath intent)
    pure (Right (actual, plan)))
  (\(errorValue :: IOException) -> pure (Left (show errorValue)))

readSource :: WriterFileSystem -> FilePath -> IO (Either String Text)
readSource fileSystem path = catch
  (Right <$> readTextFile fileSystem path)
  (\(errorValue :: IOException) -> pure (Left (show errorValue)))

data StagedCompleteAdvance = StagedCompleteAdvance
  { stagedActualBackup :: FilePath
  , stagedActualNew    :: FilePath
  , stagedPlanBackup   :: FilePath
  , stagedPlanNew      :: FilePath
  }

stageAndPublish
  :: WriterFileSystem
  -> IO (Either admissionError admitted)
  -> PlanCompleteAdvanceWriteIntent
  -> IO (Either (PlanCompleteAdvanceWriteError admissionError) ())
stageAndPublish fileSystem postAdmission intent = do
  stagedResult <- catch
    (Right <$> stageCompleteAdvance fileSystem intent)
    (\(errorValue :: IOException) -> pure (Left (show errorValue)))
  case stagedResult of
    Left ioMessage ->
      pure (Left (PlanCompleteAdvanceFileIOError ioMessage False False))
    Right staged -> do
      prePublish <- readCurrentSources fileSystem intent
      case prePublish of
        Left ioMessage -> do
          cleanupStaged fileSystem staged
          pure (Left (PlanCompleteAdvanceFileIOError ioMessage False False))
        Right (currentActual, currentPlan)
          | currentActual /= writeExpectedActual intent -> do
              cleanupStaged fileSystem staged
              pure (Left PlanCompleteAdvanceActualStale)
          | currentPlan /= writeExpectedPlan intent -> do
              cleanupStaged fileSystem staged
              pure (Left PlanCompleteAdvancePlanStale)
          | otherwise ->
              installAndAdmit fileSystem postAdmission intent staged

stageCompleteAdvance
  :: WriterFileSystem
  -> PlanCompleteAdvanceWriteIntent
  -> IO StagedCompleteAdvance
stageCompleteAdvance fileSystem intent = do
  actualBackup <- stageSiblingTextFile fileSystem
    (writeActualPath intent)
    ".complete-advance.backup.tmp"
    (writeExpectedActual intent)
  planBackup <- stageSiblingTextFile fileSystem
    (writePlanPath intent)
    ".complete-advance.backup.tmp"
    (writeExpectedPlan intent)
    `onException` removeQuietly fileSystem actualBackup
  actualNew <- stageSiblingTextFile fileSystem
    (writeActualPath intent)
    ".complete-advance.new.tmp"
    (writeCandidateActual intent)
    `onException` cleanupPaths fileSystem [planBackup, actualBackup]
  planNew <- stageSiblingTextFile fileSystem
    (writePlanPath intent)
    ".complete-advance.new.tmp"
    (writeCandidatePlan intent)
    `onException` cleanupPaths fileSystem [actualNew, planBackup, actualBackup]
  pure StagedCompleteAdvance
    { stagedActualBackup = actualBackup
    , stagedActualNew = actualNew
    , stagedPlanBackup = planBackup
    , stagedPlanNew = planNew
    }

installAndAdmit
  :: WriterFileSystem
  -> IO (Either admissionError admitted)
  -> PlanCompleteAdvanceWriteIntent
  -> StagedCompleteAdvance
  -> IO (Either (PlanCompleteAdvanceWriteError admissionError) ())
installAndAdmit fileSystem postAdmission intent staged =
  catch run handleIO
  where
    run = do
      renameTextFile fileSystem
        (stagedActualNew staged)
        (writeActualPath intent)
      planBeforeInstall <- readSource fileSystem (writePlanPath intent)
      case planBeforeInstall of
        Left ioMessage -> recoverInstallWindowFailure ioMessage
        Right currentPlan
          | currentPlan /= writeExpectedPlan intent -> recoverPlanStale
          | otherwise -> do
              renameTextFile fileSystem
                (stagedPlanNew staged)
                (writePlanPath intent)
              verifyInstalled <- readCurrentSources fileSystem intent
              case verifyInstalled of
                Left ioMessage -> recoverInstallWindowFailure ioMessage
                Right (currentActual, currentPlanAfterInstall)
                  | currentActual /= writeCandidateActual intent ->
                      recoverActualStale
                  | currentPlanAfterInstall /= writeCandidatePlan intent ->
                      recoverPlanStale
                  | otherwise -> admitInstalledCandidates

    admitInstalledCandidates = do
      admitted <- postAdmission
      case admitted of
        Left admissionError -> do
          (actualSafe, planSafe) <- recoverExpectedSources fileSystem intent staged
          cleanupCandidatePaths fileSystem staged
          pure (Left
            (PlanCompleteAdvancePostAdmissionFailed
              admissionError
              actualSafe
              planSafe))
        Right _ -> verifyAfterAdmission

    verifyAfterAdmission = do
      finalSources <- readCurrentSources fileSystem intent
      case finalSources of
        Left ioMessage -> recoverInstallWindowFailure ioMessage
        Right (currentActual, currentPlan)
          | currentActual /= writeCandidateActual intent -> recoverActualStale
          | currentPlan /= writeCandidatePlan intent -> recoverPlanStale
          | otherwise -> do
              removeQuietly fileSystem (stagedActualBackup staged)
              removeQuietly fileSystem (stagedPlanBackup staged)
              cleanupCandidatePaths fileSystem staged
              pure (Right ())

    recoverActualStale = do
      _ <- recoverExpectedSource
        fileSystem
        (stagedActualBackup staged)
        (writeActualPath intent)
        (writeExpectedActual intent)
        (writeCandidateActual intent)
      planSafe <- recoverExpectedSource
        fileSystem
        (stagedPlanBackup staged)
        (writePlanPath intent)
        (writeExpectedPlan intent)
        (writeCandidatePlan intent)
      cleanupCandidatePaths fileSystem staged
      if planSafe
        then pure (Left PlanCompleteAdvanceActualStale)
        else pure (Left
          (PlanCompleteAdvanceFileIOError
            "Actual changed during coordinated installation and Plan recovery did not complete"
            False
            False))

    recoverPlanStale = do
      actualSafe <- recoverExpectedSource
        fileSystem
        (stagedActualBackup staged)
        (writeActualPath intent)
        (writeExpectedActual intent)
        (writeCandidateActual intent)
      _ <- recoverExpectedSource
        fileSystem
        (stagedPlanBackup staged)
        (writePlanPath intent)
        (writeExpectedPlan intent)
        (writeCandidatePlan intent)
      cleanupCandidatePaths fileSystem staged
      if actualSafe
        then pure (Left PlanCompleteAdvancePlanStale)
        else pure (Left
          (PlanCompleteAdvanceFileIOError
            "Plan changed during coordinated installation and Actual recovery did not complete"
            False
            False))

    recoverInstallWindowFailure ioMessage = do
      (actualSafe, planSafe) <- recoverExpectedSources fileSystem intent staged
      cleanupCandidatePaths fileSystem staged
      pure (Left
        (PlanCompleteAdvanceFileIOError
          ioMessage
          actualSafe
          planSafe))

    handleIO (errorValue :: IOException) = do
      (actualSafe, planSafe) <- recoverExpectedSources fileSystem intent staged
      cleanupCandidatePaths fileSystem staged
      pure (Left
        (PlanCompleteAdvanceFileIOError
          (show errorValue)
          actualSafe
          planSafe))

recoverExpectedSources
  :: WriterFileSystem
  -> PlanCompleteAdvanceWriteIntent
  -> StagedCompleteAdvance
  -> IO (Bool, Bool)
recoverExpectedSources fileSystem intent staged = do
  actualSafe <- recoverExpectedSource
    fileSystem
    (stagedActualBackup staged)
    (writeActualPath intent)
    (writeExpectedActual intent)
    (writeCandidateActual intent)
  planSafe <- recoverExpectedSource
    fileSystem
    (stagedPlanBackup staged)
    (writePlanPath intent)
    (writeExpectedPlan intent)
    (writeCandidatePlan intent)
  pure (actualSafe, planSafe)

-- | Recover only while the source is still either untouched expected bytes or
-- this operation's exact candidate. A later unrelated writer wins and is never
-- replaced by rollback. When the target cannot be read, keep the backup for
-- explicit recovery rather than guessing.
recoverExpectedSource
  :: WriterFileSystem
  -> FilePath
  -> FilePath
  -> Text
  -> Text
  -> IO Bool
recoverExpectedSource fileSystem backupPath targetPath expected candidate = do
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

cleanupStaged :: WriterFileSystem -> StagedCompleteAdvance -> IO ()
cleanupStaged fileSystem staged = cleanupPaths fileSystem
  [ stagedActualNew staged
  , stagedPlanNew staged
  , stagedActualBackup staged
  , stagedPlanBackup staged
  ]

cleanupCandidatePaths :: WriterFileSystem -> StagedCompleteAdvance -> IO ()
cleanupCandidatePaths fileSystem staged = cleanupPaths fileSystem
  [ stagedActualNew staged
  , stagedPlanNew staged
  ]

cleanupPaths :: WriterFileSystem -> [FilePath] -> IO ()
cleanupPaths fileSystem = mapM_ (removeQuietly fileSystem)

removeQuietly :: WriterFileSystem -> FilePath -> IO ()
removeQuietly fileSystem path = catch
  (removeTextFile fileSystem path)
  (\(_ :: IOException) -> pure ())
