{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, catch, throwIO)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import System.Directory (removeFile)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalIdentifiedTransactions
  , actualJournalReversalDeclarations
  , actualJournalValue
  , parseActualJournal
  , reversedTransactionId
  , reversalTransactionId
  )
import HKernel.Editor.ActualWriter
import HKernel.Journal (journalAccountRegistry, journalTransactions)
import HKernel.Ledger (Transaction)
import HKernel.Plan.Completion
  ( ActualTransactionId
  , identifiedActualId
  , identifiedActualTransaction
  )
import HKernel.Plan.Journal (parsePlanJournal)

main :: IO ()
main = do
  let results =
        [ ("testStaleReject", testStaleReject)
        , ("testActualWrite", testActualWrite)
        , ("testPlanWrite", testPlanWrite)
        , ("testPostAdmissionFailure", testPostAdmissionFailure)
        , ("testPostPublishReadFailureRestores", testPostPublishReadFailureRestores)
        , ("testActualBlockWrite", testActualBlockWrite)
        , ("testActualBlockStaleReject", testActualBlockStaleReject)
        , ( "testActualBlockPostAdmissionFailureRestores"
          , testActualBlockPostAdmissionFailureRestores
          )
        , ("testActualSemanticAddParity", testActualSemanticAddParity)
        , ("testActualSemanticReverseGap", testActualSemanticReverseGap)
        , ("testActualSemanticPrefixReject", testActualSemanticPrefixReject)
        , ("testActualSemanticSanitizedCode", testActualSemanticSanitizedCode)
        ]
  rs <- sequence [action | (_, action) <- results]
  let namedResults = zip (map fst results) rs
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

withFixture :: FilePath -> Text -> (FilePath -> IO Bool) -> IO Bool
withFixture path initial action = do
  cleanupFixture path
  TIO.writeFile path initial
  result <- action path `catch` (\(_ :: IOException) -> pure False)
  cleanupFixture path
  pure result

cleanupFixture :: FilePath -> IO ()
cleanupFixture path = do
  removeIfPresent path
  removeIfPresent (path <> ".backup.tmp")
  removeIfPresent (path <> ".new.tmp")

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  catch (removeFile path) (\(_ :: IOException) -> pure ())

expectPublished
  :: Show sourceError
  => FilePath
  -> (Text -> Either (NonEmpty sourceError) admitted)
  -> Text
  -> Text
  -> IO Bool
expectPublished path admit oldBytes newBytes =
  withFixture path oldBytes $ \fixturePath -> do
    result <- publishWithAdmission admit
      (WriteIntent
        fixturePath
        (ExpectedSource oldBytes)
        (CandidateSource newBytes))
    case result of
      Right () -> (== newBytes) <$> TIO.readFile fixturePath
      Left err -> print err >> pure False

testStaleReject :: IO Bool
testStaleReject =
  withFixture "tests/fixtures/test_writer_stale.journal" "original" $ \path -> do
    let intent = WriteIntent
          { targetFilePath = path
          , expectedOldBytes = ExpectedSource "different"
          , candidateNewBytes = CandidateSource "new"
          }
    result <- publishActualAppend intent
    pure $ case result of
      Left StaleFile -> show result == "Left StaleFile"
      _ -> False

testActualWrite :: IO Bool
testActualWrite =
  expectPublished
    "tests/fixtures/test_writer_actual.journal"
    parseActualJournal
    actualOld
    actualNew

testPlanWrite :: IO Bool
testPlanWrite =
  expectPublished
    "tests/fixtures/test_writer_plan.journal"
    parsePlanJournal
    planOld
    planNew

testPostAdmissionFailure :: IO Bool
testPostAdmissionFailure =
  withFixture "tests/fixtures/test_writer_reject.journal" actualOld $ \path -> do
    let invalidBytes = actualOld
          <> "\n2026-08-05 invalid\n"
          <> "  assets:unknown  100 JPY\n"
        intent = WriteIntent
          path
          (ExpectedSource actualOld)
          (CandidateSource invalidBytes)
    result <- publishWithAdmission parseActualJournal intent
    case result of
      Left (PostAdmissionFailed _ True) ->
        (== actualOld) <$> TIO.readFile path
      _ -> pure False

testPostPublishReadFailureRestores :: IO Bool
testPostPublishReadFailureRestores =
  withFixture "tests/fixtures/test_writer_read_failure.journal" actualOld $ \path -> do
    readCount <- newIORef (0 :: Int)
    let normalFileSystem = defaultWriterFileSystem
        failSecondRead filePath = do
          previous <- atomicModifyIORef' readCount (\count -> (count + 1, count))
          if previous == 0
            then readTextFile normalFileSystem filePath
            else throwIO (userError "simulated post-publish read failure")
        faultingFileSystem = normalFileSystem
          { readTextFile = failSecondRead }
        intent = WriteIntent
          path
          (ExpectedSource actualOld)
          (CandidateSource actualNew)
    result <- publishWithAdmissionUsing
      faultingFileSystem
      parseActualJournal
      intent
    case result of
      Left (PostPublishReadFailed _ True) ->
        (== actualOld) <$> TIO.readFile path
      _ -> pure False

testActualBlockWrite :: IO Bool
testActualBlockWrite =
  withFixture
    "tests/fixtures/test_writer_actual_block.journal"
    actualOld
    (\path -> do
      result <- publishActualBlock path actualOld actualBlock
      case result of
        Right () -> (== actualNew) <$> TIO.readFile path
        Left err -> print err >> pure False)

testActualBlockStaleReject :: IO Bool
testActualBlockStaleReject =
  withFixture
    "tests/fixtures/test_writer_actual_block_stale.journal"
    actualOld
    (\path -> do
      result <- publishActualBlock path (actualOld <> "\n") actualBlock
      currentSource <- TIO.readFile path
      pure $ case result of
        Left StaleFile -> currentSource == actualOld
        _ -> False)

testActualBlockPostAdmissionFailureRestores :: IO Bool
testActualBlockPostAdmissionFailureRestores =
  withFixture
    "tests/fixtures/test_writer_actual_block_reject.journal"
    actualOld
    (\path -> do
      result <- publishActualBlock path actualOld invalidActualBlock
      currentSource <- TIO.readFile path
      pure $ case result of
        Left (PostAdmissionFailed _ True) -> currentSource == actualOld
        _ -> False)

testActualSemanticAddParity :: IO Bool
testActualSemanticAddParity =
  pure $
    compareActualCandidateSemantics
      comparisonExisting
      bqnAddCandidate
      haskellAddCandidate
    == Right []

testActualSemanticReverseGap :: IO Bool
testActualSemanticReverseGap =
  pure $
    compareActualCandidateSemantics
      comparisonExisting
      bqnReverseCandidate
      haskellReverseCandidate
    == Right
      [ ActualIdentityDiffers
      , ActualReversalTargetDiffers
      ]

testActualSemanticPrefixReject :: IO Bool
testActualSemanticPrefixReject =
  pure $ case compareActualCandidateSemantics
      comparisonExisting
      changedPrefixCandidate
      haskellAddCandidate of
    Left errors ->
      CandidatePrefixChanged BqnCandidate
        `elem` NonEmpty.toList errors
    Right _ -> False

testActualSemanticSanitizedCode :: IO Bool
testActualSemanticSanitizedCode =
  pure $ case compareActualCandidateSemantics
      comparisonExisting
      invalidCandidate
      haskellAddCandidate of
    Left errors ->
      map renderActualComparisonErrorCode (NonEmpty.toList errors)
        == ["bqn_candidate_source_rejected"]
    Right _ -> False

actualOld :: Text
actualOld =
  "account assets:bank\n"
  <> "  type: Asset\n"
  <> "  commodity: JPY\n"

actualBlock :: Text
actualBlock =
  "2026-08-05 actual write\n"
  <> "  assets:bank  100 JPY\n"
  <> "  assets:bank  -100 JPY\n"

invalidActualBlock :: Text
invalidActualBlock =
  "2026-08-05 invalid actual write\n"
  <> "  assets:unknown  100 JPY\n"
  <> "  assets:bank  -100 JPY\n"

actualNew :: Text
actualNew = actualOld <> "\n" <> actualBlock

planOld :: Text
planOld =
  "account assets:bank\n"
  <> "  type: Asset\n"
  <> "  commodity: JPY\n"
  <> "account expenses:food\n"
  <> "  type: Expense\n"
  <> "  commodity: JPY\n"

planNew :: Text
planNew = planOld
  <> "\n2026-08-06 planned meal\n"
  <> "    ; plan-id: PLAN-1\n"
  <> "  assets:bank  -500 JPY\n"
  <> "  expenses:food  500 JPY\n"

comparisonExisting :: Text
comparisonExisting = Text.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2026-08-04 * Original purchase"
  , "    ; event-id: event-123"
  , "    assets:cash    -100 JPY"
  , "    expenses:food    100 JPY"
  ]

bqnAddCandidate :: Text
bqnAddCandidate = comparisonExisting <> Text.unlines
  [ ""
  , "2026-08-05 * Coffee"
  , "    assets:cash    -25 JPY"
  , "    expenses:food    25 JPY"
  ]

haskellAddCandidate :: Text
haskellAddCandidate = comparisonExisting <> Text.unlines
  [ ""
  , "2026-08-05 Coffee"
  , "  assets:cash  -25 JPY"
  , "  expenses:food  25 JPY"
  ]

bqnReverseCandidate :: Text
bqnReverseCandidate = comparisonExisting <> Text.unlines
  [ ""
  , "2026-08-06 * [reverse]Original purchase"
  , "    assets:cash    100 JPY"
  , "    expenses:food    -100 JPY"
  ]

haskellReverseCandidate :: Text
haskellReverseCandidate = comparisonExisting <> Text.unlines
  [ ""
  , "2026-08-06 [reverse]Original purchase"
  , "  ; event-id: event-123-reversal-1"
  , "  ; reverses: event-123"
  , "  assets:cash  100 JPY"
  , "  expenses:food  -100 JPY"
  ]

changedPrefixCandidate :: Text
changedPrefixCandidate =
  Text.replace "Original purchase" "Changed purchase" comparisonExisting
  <> Text.unlines
    [ ""
    , "2026-08-05 Coffee"
    , "  assets:cash  -25 JPY"
    , "  expenses:food  25 JPY"
    ]

invalidCandidate :: Text
invalidCandidate =
  comparisonExisting
  <> "\n2026-08-05 invalid\n"
  <> "  assets:unknown  25 JPY\n"
  <> "  expenses:food  -25 JPY\n"

data CandidateOrigin
  = BqnCandidate
  | HaskellCandidate
  deriving (Eq, Show)

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
