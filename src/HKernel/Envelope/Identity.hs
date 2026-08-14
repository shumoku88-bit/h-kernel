{-# LANGUAGE OverloadedStrings #-}

-- | Stable machine identity and admitted identity universe for spendable
-- Envelopes.
--
-- Identity belongs to the Envelope domain rather than accounting Accounts or
-- the retiring Budget compatibility layer. Human-facing labels and current
-- policy remain separate coordinates.
module HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeIdError(..)
  , mkEnvelopeId
  , envelopeIdText
  , EnvelopeRegistry
  , EnvelopeRegistryError(..)
  , mkEnvelopeRegistry
  , envelopeRegistryIds
  , envelopeRegistryContains
  ) where

import Data.Char (isControl, isSpace)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

newtype EnvelopeId = EnvelopeId { envelopeIdText :: Text }
  deriving (Eq, Ord, Show)

data EnvelopeIdError
  = EmptyEnvelopeId
  | EnvelopeIdHasSurroundingWhitespace Text
  | EnvelopeIdContainsControlCharacter Text
  | EnvelopeIdContainsWhitespace Text
  | ReservedEnvelopeId Text
  deriving (Eq, Show)

mkEnvelopeId :: Text -> Either EnvelopeIdError EnvelopeId
mkEnvelopeId value
  | T.null value = Left EmptyEnvelopeId
  | T.strip value /= value = Left (EnvelopeIdHasSurroundingWhitespace value)
  | T.any isControl value = Left (EnvelopeIdContainsControlCharacter value)
  | T.any isSpace value = Left (EnvelopeIdContainsWhitespace value)
  | T.toCaseFold value == "unallocated" = Left (ReservedEnvelopeId value)
  | otherwise = Right (EnvelopeId value)

-- | The admitted universe of stable spendable Envelope identities.
--
-- This owner deliberately contains no label, mode, BackingPool, Expense route,
-- allocation amount, or active/retired state. Those coordinates have different
-- lifetimes. In particular, removing an Envelope from current policy must not
-- make its historical identity cease to exist.
--
-- A source adapter may eventually build this registry from an append-only
-- declaration history. The physical source shape is not part of this owner.
data EnvelopeRegistry = EnvelopeRegistry
  { envelopeRegistryIds :: [EnvelopeId]
  , envelopeRegistrySet :: Set.Set EnvelopeId
  } deriving (Eq, Show)

data EnvelopeRegistryError
  = DuplicateEnvelopeRegistryIdentity EnvelopeId
  deriving (Eq, Show)

-- | Admit stable identities without silently collapsing duplicate declarations.
--
-- Source order is retained for deterministic publication and diagnostics.
-- Empty is permitted at this domain boundary; a higher-level household policy
-- may independently require at least one currently configured Envelope.
mkEnvelopeRegistry
  :: [EnvelopeId]
  -> Either (NonEmpty EnvelopeRegistryError) EnvelopeRegistry
mkEnvelopeRegistry identities =
  case NonEmpty.nonEmpty duplicateErrors of
    Just errors -> Left errors
    Nothing -> Right EnvelopeRegistry
      { envelopeRegistryIds = identities
      , envelopeRegistrySet = Set.fromList identities
      }
  where
    (_, reversedDuplicateErrors) =
      foldl' observe (Set.empty, []) identities
    duplicateErrors = reverse reversedDuplicateErrors

    observe (seen, errors) envelope
      | envelope `Set.member` seen =
          (seen, DuplicateEnvelopeRegistryIdentity envelope : errors)
      | otherwise = (Set.insert envelope seen, errors)

envelopeRegistryContains :: EnvelopeId -> EnvelopeRegistry -> Bool
envelopeRegistryContains envelope =
  Set.member envelope . envelopeRegistrySet
