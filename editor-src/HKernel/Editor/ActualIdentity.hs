{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HKernel.Editor.ActualIdentity
  ( ActualIdentityGenerationFailure(..)
  , ActualIdentityCandidateSource(..)
  , actualIdentityAttemptLimit
  , defaultCandidateSource
  , generateActualTransactionId
  , generateActualTransactionIdUsing
  , actualIdentityGenerationFailureText
  , actualEventIdentityMetadata
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDv4

import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalIdentifiedTransactions
  )
import HKernel.Plan.Completion
  ( ActualTransactionId
  , actualTransactionIdText
  , identifiedActualId
  , mkActualTransactionId
  )

-- | Explicit taxonomy of identity generation failures.
--
-- This structure contains no raw exception messages, candidate strings,
-- source text, path, or private data.
data ActualIdentityGenerationFailure
  = ActualIdentityGenerationUnavailable
  | ActualIdentityCandidateInvalid
  | ActualIdentityCollisionLimitReached
  deriving (Eq, Show)

-- | Abstraction for identity candidate acquisition.
--
-- Production code uses 'defaultCandidateSource' with UUID v4. Focused tests
-- supply deterministic test doubles.
newtype ActualIdentityCandidateSource = ActualIdentityCandidateSource
  { requestActualIdentityCandidate
      :: IO (Either ActualIdentityGenerationFailure Text)
  }

-- | Maximum number of candidate generation retries when colliding with
-- existing effective Actual identities.
actualIdentityAttemptLimit :: Int
actualIdentityAttemptLimit = 8

-- | Production candidate generator using UUID v4 formatted as lowercase
-- hyphenated text with an "evt-" prefix.
defaultCandidateSource :: ActualIdentityCandidateSource
defaultCandidateSource = ActualIdentityCandidateSource $ do
  result <- try UUIDv4.nextRandom
  case result of
    Left (_ :: IOException) ->
      pure (Left ActualIdentityGenerationUnavailable)
    Right uuid ->
      pure (Right ("evt-" <> UUID.toText uuid))

-- | Generate an admitted unique 'ActualTransactionId' for the given journal snapshot
-- using the production UUID v4 candidate source.
generateActualTransactionId
  :: ActualJournal
  -> IO (Either ActualIdentityGenerationFailure ActualTransactionId)
generateActualTransactionId =
  generateActualTransactionIdUsing defaultCandidateSource

-- | Generate an admitted unique 'ActualTransactionId' for the given journal snapshot
-- using a supplied candidate source.
--
-- Checks against all effective Actual identities in the snapshot (both explicit
-- event identities and plan-derived runtime identities) up to 'actualIdentityAttemptLimit'.
generateActualTransactionIdUsing
  :: ActualIdentityCandidateSource
  -> ActualJournal
  -> IO (Either ActualIdentityGenerationFailure ActualTransactionId)
generateActualTransactionIdUsing candidateSource journal = go 1
  where
    existingIds = map identifiedActualId (actualJournalIdentifiedTransactions journal)
    go attempt
      | attempt > actualIdentityAttemptLimit =
          pure (Left ActualIdentityCollisionLimitReached)
      | otherwise = do
          candidateResult <- requestActualIdentityCandidate candidateSource
          case candidateResult of
            Left err -> pure (Left err)
            Right candidateText ->
              case mkActualTransactionId candidateText of
                Left _ -> pure (Left ActualIdentityCandidateInvalid)
                Right actualId ->
                  if actualId `elem` existingIds
                    then go (attempt + 1)
                    else pure (Right actualId)

-- | User-facing sanitized failure description suitable for presentation.
actualIdentityGenerationFailureText
  :: ActualIdentityGenerationFailure
  -> Text
actualIdentityGenerationFailureText ActualIdentityGenerationUnavailable =
  "A durable Actual identity candidate could not be generated."
actualIdentityGenerationFailureText ActualIdentityCandidateInvalid =
  "The generated identity candidate was rejected by domain admission."
actualIdentityGenerationFailureText ActualIdentityCollisionLimitReached =
  "The identity generator reached the collision retry limit."

-- | Canonical event identity metadata key-value pair for Journal serialization.
actualEventIdentityMetadata :: ActualTransactionId -> (Text, Text)
actualEventIdentityMetadata actualId =
  ("event-id", actualTransactionIdText actualId)
