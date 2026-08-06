{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HKernel.Editor.ActualIdentity
  ( ActualEventIdentityAdmissionFailure(..)
  , admitActualEventIdentityText
  , actualIdentityIsAlreadyUsed
  , ActualIdentityGenerationFailure(..)
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

-- | Admission failure for canonical new Actual event identities.
data ActualEventIdentityAdmissionFailure
  = ActualEventIdentityFormatInvalid
  deriving (Eq, Show)

-- | Explicit taxonomy of identity generation failures.
--
-- This structure contains no raw exception messages, candidate strings,
-- source text, path, or private data.
data ActualIdentityGenerationFailure
  = ActualIdentityGenerationUnavailable
  | ActualIdentityCandidateInvalid
  | ActualIdentityCollisionLimitReached
  deriving (Eq, Show)

-- | Pure admission boundary for new canonical Actual event identities.
--
-- Enforces:
-- 1. Exact lowercase "evt-" prefix
-- 2. Valid UUID text parseable by Data.UUID.fromText
-- 3. Canonical lowercase hyphenated text matching Data.UUID.toText
-- 4. UUID version nibble '4'
-- 5. UUID RFC variant nibble in ['8', '9', 'a', 'b']
-- 6. Admitted by domain 'mkActualTransactionId'
admitActualEventIdentityText
  :: Text
  -> Either ActualEventIdentityAdmissionFailure ActualTransactionId
admitActualEventIdentityText value = do
  body <- requirePrefix value
  uuid <- requireUuid body
  requireCanonicalRoundTrip body uuid
  requireVersion4AndRfcVariant body uuid
  mapDomainFailure (mkActualTransactionId value)
  where
    requirePrefix text = case T.stripPrefix "evt-" text of
      Just b -> Right b
      Nothing -> Left ActualEventIdentityFormatInvalid

    requireUuid b = case UUID.fromText b of
      Just u -> Right u
      Nothing -> Left ActualEventIdentityFormatInvalid

    requireCanonicalRoundTrip b u =
      if UUID.toText u == b
        then Right ()
        else Left ActualEventIdentityFormatInvalid

    requireVersion4AndRfcVariant b u =
      case T.splitOn "-" b of
        [g1, g2, g3, g4, g5]
          | UUID.toText u == b
          , T.take 1 g3 == "4"
          , T.take 1 g4 `elem` ["8", "9", "a", "b"]
            -> Right ()
        _ -> Left ActualEventIdentityFormatInvalid

    mapDomainFailure res = case res of
      Right actualId -> Right actualId
      Left _ -> Left ActualEventIdentityFormatInvalid

-- | Pure predicate checking whether an admitted 'ActualTransactionId' is already in use
-- by any effective identity in the given journal snapshot (explicit event identity or
-- plan-derived runtime identity).
actualIdentityIsAlreadyUsed
  :: ActualJournal
  -> ActualTransactionId
  -> Bool
actualIdentityIsAlreadyUsed journal actualId =
  actualId `elem` map identifiedActualId (actualJournalIdentifiedTransactions journal)

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
-- Candidates must pass 'admitActualEventIdentityText' and are checked against all
-- effective Actual identities in the snapshot (both explicit event identities and
-- plan-derived runtime identities) up to 'actualIdentityAttemptLimit'.
generateActualTransactionIdUsing
  :: ActualIdentityCandidateSource
  -> ActualJournal
  -> IO (Either ActualIdentityGenerationFailure ActualTransactionId)
generateActualTransactionIdUsing candidateSource journal = go 1
  where
    go attempt
      | attempt > actualIdentityAttemptLimit =
          pure (Left ActualIdentityCollisionLimitReached)
      | otherwise = do
          candidateResult <- requestActualIdentityCandidate candidateSource
          case candidateResult of
            Left err -> pure (Left err)
            Right candidateText ->
              case admitActualEventIdentityText candidateText of
                Left _ -> pure (Left ActualIdentityCandidateInvalid)
                Right actualId ->
                  if actualIdentityIsAlreadyUsed journal actualId
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
