{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HKernel.Editor.ActualWriter
  ( WriteIntent(..)
  , WriteError(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithAdmission
  , publishWithAdmissionUsing
  , publishActualAppend
  , publishActualBlock
  , CandidateOrigin(..)
  , ActualComparisonError(..)
  , ActualSemanticDifference(..)
  , compareActualCandidateSemantics
  , renderActualComparisonErrorCode
  , renderActualSemanticDifferenceCode
  ) where

import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory (renameFile, removeFile)

import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalIdentifiedTransactions
  , actualJournalReversalDeclarations
  , actualJournalValue
  , parseActualJournal
  , reversedTransactionId
  , reversalTransactionId
  )
import HKernel.Editor.SourceAppend (appendSourceBlock)
import HKernel.Journal (journalAccountRegistry, journalTransactions)
import HKernel.Ledger (Transaction)
import HKernel.Plan.Completion
  ( ActualTransactionId
  , identifiedActualId
  , identifiedActualTransaction
  )

data WriteIntent = WriteIntent
  { targetFilePath    :: FilePath
  , expectedOldBytes  :: Text
  , candidateNewBytes :: Text
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

-- | Which editor produced one candidate complete source.
--
-- The comparison boundary does not invoke either editor. Callers must label
-- independently produced candidates explicitly before comparison.
data CandidateOrigin
  = BqnCandidate
  | HaskellCandidate
  deriving (Eq, Show)

-- | Sanitised failure classes for the cross-editor comparison harness.
--
-- These constructors retain only structural counts and origin labels. They do
-- not retain source text, Account names, dates, descriptions, quantities,
-- identities, file paths, or parser diagnostics.
data ActualComparisonError
  = ExistingSourceRejected Int
  | CandidateSourceRejected CandidateOrigin Int
  | CandidatePrefixChanged CandidateOrigin
  | CandidateTrailingNewlineMissing CandidateOrigin
  | CandidateTransactionCountMismatch CandidateOrigin Int Int
  | CandidatePriorTransactionsChanged CandidateOrigin
  | CandidateAccountRegistryChanged CandidateOrigin
  | CandidateIdentityProjectionCountInvalid CandidateOrigin Int
  | CandidateIdentityDoesNotNameAddedTransaction CandidateOrigin
  | CandidateReversalProjectionCountInvalid CandidateOrigin Int
  | CandidateReversalIdentityMismatch CandidateOrigin
  deriving (Eq, Show)

-- | Parser-observable semantic differences between two valid candidates.
--
-- No private value is retained in these result constructors.
data ActualSemanticDifference
  = ActualTransactionDiffers
  | ActualIdentityDiffers
  | ActualReversalTargetDiffers
  deriving (Eq, Show)

data ActualCandidateObservation = ActualCandidateObservation
  { observedTransaction    :: Transaction
  , observedIdentity       :: Maybe ActualTransactionId
  , observedReversalTarget :: Maybe ActualTransactionId
  } deriving (Eq)

-- | Compare one BQN-produced candidate and one Haskell-produced candidate
-- against the exact same existing Actual Journal source.
--
-- Each candidate must preserve the existing source as an exact prefix, keep the
-- Account registry and prior transactions unchanged, append exactly one
-- transaction, and remain strictly admissible. Text rendering may differ. The
-- comparison observes the admitted transaction, durable identity, and explicit
-- reversal target.
compareActualCandidateSemantics
  :: Text
  -> Text
  -> Text
  -> Either (NonEmpty ActualComparisonError) [ActualSemanticDifference]
compareActualCandidateSemantics existingSource bqnSource haskellSource =
  case parseActualJournal existingSource of
    Left errors ->
      Left (pure (ExistingSourceRejected (NonEmpty.length errors)))
    Right existingJournal ->
      case
        ( observeActualCandidate
            BqnCandidate
            existingSource
            existingJournal
            bqnSource
        , observeActualCandidate
            HaskellCandidate
            existingSource
            existingJournal
            haskellSource
        ) of
          (Left bqnErrors, Left haskellErrors) ->
            Left (bqnErrors <> haskellErrors)
          (Left bqnErrors, Right _) -> Left bqnErrors
          (Right _, Left haskellErrors) -> Left haskellErrors
          (Right bqnObservation, Right haskellObservation) ->
            Right (semanticDifferences bqnObservation haskellObservation)

observeActualCandidate
  :: CandidateOrigin
  -> Text
  -> ActualJournal
  -> Text
  -> Either (NonEmpty ActualComparisonError) ActualCandidateObservation
observeActualCandidate origin existingSource existingJournal candidateSource =
  case parseActualJournal candidateSource of
    Left errors ->
      Left (pure
        (CandidateSourceRejected origin (NonEmpty.length errors)))
    Right candidateJournal ->
      case NonEmpty.nonEmpty structuralErrors of
        Just errors -> Left errors
        Nothing -> do
          identity <- observeAddedIdentity
            origin
            existingJournal
            candidateJournal
            candidateTransaction
          reversalTarget <- observeAddedReversal
            origin
            existingJournal
            candidateJournal
            identity
          Right ActualCandidateObservation
            { observedTransaction = candidateTransaction
            , observedIdentity = identity
            , observedReversalTarget = reversalTarget
            }
      where
        existingValue = actualJournalValue existingJournal
        candidateValue = actualJournalValue candidateJournal
        existingTransactions = journalTransactions existingValue
        candidateTransactions = journalTransactions candidateValue
        existingCount = length existingTransactions
        candidateCount = length candidateTransactions
        expectedCount = existingCount + 1
        candidateTransaction = candidateTransactions !! existingCount

        structuralErrors =
          [ CandidatePrefixChanged origin
          | not (existingSource `Text.isPrefixOf` candidateSource)
          ]
          ++
          [ CandidateTrailingNewlineMissing origin
          | not ("\n" `Text.isSuffixOf` candidateSource)
          ]
          ++
          [ CandidateTransactionCountMismatch
              origin
              expectedCount
              candidateCount
          | candidateCount /= expectedCount
          ]
          ++
          [ CandidatePriorTransactionsChanged origin
          | candidateCount == expectedCount
          , take existingCount candidateTransactions /= existingTransactions
          ]
          ++
          [ CandidateAccountRegistryChanged origin
          | journalAccountRegistry candidateValue
              /= journalAccountRegistry existingValue
          ]

observeAddedIdentity
  :: CandidateOrigin
  -> ActualJournal
  -> ActualJournal
  -> Transaction
  -> Either (NonEmpty ActualComparisonError) (Maybe ActualTransactionId)
observeAddedIdentity origin existingJournal candidateJournal candidateTransaction =
  case delta of
    0 -> Right Nothing
    1 ->
      let identified = last candidateIdentified
      in if identifiedActualTransaction identified == candidateTransaction
          then Right (Just (identifiedActualId identified))
          else Left (pure
            (CandidateIdentityDoesNotNameAddedTransaction origin))
    _ -> Left (pure
      (CandidateIdentityProjectionCountInvalid origin delta))
  where
    existingIdentified =
      actualJournalIdentifiedTransactions existingJournal
    candidateIdentified =
      actualJournalIdentifiedTransactions candidateJournal
    delta = length candidateIdentified - length existingIdentified

observeAddedReversal
  :: CandidateOrigin
  -> ActualJournal
  -> ActualJournal
  -> Maybe ActualTransactionId
  -> Either (NonEmpty ActualComparisonError) (Maybe ActualTransactionId)
observeAddedReversal origin existingJournal candidateJournal candidateIdentity =
  case delta of
    0 -> Right Nothing
    1 ->
      let declaration = last candidateReversals
      in if Just (reversalTransactionId declaration) == candidateIdentity
          then Right (Just (reversedTransactionId declaration))
          else Left (pure (CandidateReversalIdentityMismatch origin))
    _ -> Left (pure
      (CandidateReversalProjectionCountInvalid origin delta))
  where
    existingReversals =
      actualJournalReversalDeclarations existingJournal
    candidateReversals =
      actualJournalReversalDeclarations candidateJournal
    delta = length candidateReversals - length existingReversals

semanticDifferences
  :: ActualCandidateObservation
  -> ActualCandidateObservation
  -> [ActualSemanticDifference]
semanticDifferences bqnObservation haskellObservation =
  [ ActualTransactionDiffers
  | observedTransaction bqnObservation
      /= observedTransaction haskellObservation
  ]
  ++
  [ ActualIdentityDiffers
  | observedIdentity bqnObservation
      /= observedIdentity haskellObservation
  ]
  ++
  [ ActualReversalTargetDiffers
  | observedReversalTarget bqnObservation
      /= observedReversalTarget haskellObservation
  ]

renderActualComparisonErrorCode :: ActualComparisonError -> Text
renderActualComparisonErrorCode comparisonError = case comparisonError of
  ExistingSourceRejected _ -> "existing_source_rejected"
  CandidateSourceRejected origin _ ->
    originCode origin <> "_source_rejected"
  CandidatePrefixChanged origin ->
    originCode origin <> "_prefix_changed"
  CandidateTrailingNewlineMissing origin ->
    originCode origin <> "_trailing_newline_missing"
  CandidateTransactionCountMismatch origin _ _ ->
    originCode origin <> "_transaction_count_mismatch"
  CandidatePriorTransactionsChanged origin ->
    originCode origin <> "_prior_transactions_changed"
  CandidateAccountRegistryChanged origin ->
    originCode origin <> "_account_registry_changed"
  CandidateIdentityProjectionCountInvalid origin _ ->
    originCode origin <> "_identity_projection_count_invalid"
  CandidateIdentityDoesNotNameAddedTransaction origin ->
    originCode origin <> "_identity_not_added_transaction"
  CandidateReversalProjectionCountInvalid origin _ ->
    originCode origin <> "_reversal_projection_count_invalid"
  CandidateReversalIdentityMismatch origin ->
    originCode origin <> "_reversal_identity_mismatch"

renderActualSemanticDifferenceCode :: ActualSemanticDifference -> Text
renderActualSemanticDifferenceCode difference = case difference of
  ActualTransactionDiffers -> "actual_transaction_differs"
  ActualIdentityDiffers -> "actual_identity_differs"
  ActualReversalTargetDiffers -> "actual_reversal_target_differs"

originCode :: CandidateOrigin -> Text
originCode origin = case origin of
  BqnCandidate -> "bqn_candidate"
  HaskellCandidate -> "haskell_candidate"

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
      , expectedOldBytes = expectedSource
      , candidateNewBytes = appendSourceBlock expectedSource block
      })

checkStaleAndWrite
  :: WriterFileSystem
  -> (Text -> Either (NonEmpty sourceError) admitted)
  -> WriteIntent
  -> IO (Either (WriteError sourceError) ())
checkStaleAndWrite fileSystem admit intent = do
  currentBytes <- readTextFile fileSystem (targetFilePath intent)
  if currentBytes /= expectedOldBytes intent
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

  writeTextFile fileSystem backupPath (expectedOldBytes intent)
  writeTextFile fileSystem newPath (candidateNewBytes intent)
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
