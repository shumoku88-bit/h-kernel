{-# LANGUAGE OverloadedStrings #-}

module ActualComparisonSupport
  ( CandidateOrigin(..)
  , ActualComparisonError(..)
  , ActualSemanticDifference(..)
  , compareActualCandidateSemantics
  , renderActualComparisonErrorCode
  , renderActualSemanticDifferenceCode
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text

import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalIdentifiedTransactions
  , actualJournalReversalDeclarations
  , actualJournalValue
  , parseActualJournal
  , reversedTransactionId
  , reversalTransactionId
  )
import HKernel.Journal (journalAccountRegistry, journalTransactions)
import HKernel.Ledger (Transaction)
import HKernel.Plan.Completion
  ( ActualTransactionId
  , identifiedActualId
  , identifiedActualTransaction
  )

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
