{-# LANGUAGE OverloadedStrings #-}

-- | Admitted append mutation for canonical @entitlement.journal@.
--
-- This module implements candidate generation, admission checking, and
-- source preparation for Entitlement transfers.
-- Current writers can only create transfers involving current/writable Envelopes
-- ('CurrentEnvelopePolicy').
module HKernel.Editor.EntitlementTransferAppend
  ( EntitlementTransferAppendError(..)
  , EntitlementTransferAppendPreview(..)
  , prepareEntitlementTransferAppend
  , prepareCurrentEntitlementTransferAppend
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)

import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Envelope
  ( CurrentEnvelopePolicy
  , currentEnvelopePolicyDefinitions
  , envelopeDefinitionId
  )
import HKernel.Envelope.Entitlement.Journal
  ( EntitlementJournalError
  , admitEntitlementJournal
  , renderEntitlementTransfer
  )
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransfer(..)
  )
import HKernel.Envelope.Identity (EnvelopeId, EnvelopeRegistry)

data EntitlementTransferAppendError
  = EntitlementTransferAppendRetiredEnvelope EnvelopeId
  | EntitlementTransferCandidateAdmitError EntitlementJournalError
  deriving (Eq, Show)

data EntitlementTransferAppendPreview = EntitlementTransferAppendPreview
  { entitlementCandidateBlock          :: Text
  , entitlementCandidateCompleteSource :: Text
  } deriving (Eq, Show)

-- | Prepare a candidate append against the stable 'EnvelopeRegistry'.
prepareEntitlementTransferAppend
  :: EnvelopeRegistry
  -> Text
  -> EnvelopeEntitlementTransfer
  -> Either (NonEmpty EntitlementTransferAppendError) EntitlementTransferAppendPreview
prepareEntitlementTransferAppend registry existingSource transfer = do
  let block = renderEntitlementTransfer transfer
      completeSource = appendSourceBlock existingSource (SourceBlock block)
  case admitEntitlementJournal registry completeSource of
    Left errors ->
      Left (fmap EntitlementTransferCandidateAdmitError errors)
    Right _ -> Right EntitlementTransferAppendPreview
      { entitlementCandidateBlock = block
      , entitlementCandidateCompleteSource = completeSource
      }

-- | Prepare a candidate append enforcing that any spendable Envelope endpoint
-- belongs to current writable policy.
prepareCurrentEntitlementTransferAppend
  :: CurrentEnvelopePolicy
  -> EnvelopeRegistry
  -> Text
  -> EnvelopeEntitlementTransfer
  -> Either (NonEmpty EntitlementTransferAppendError) EntitlementTransferAppendPreview
prepareCurrentEntitlementTransferAppend policy registry existingSource transfer = do
  let currentEnvelopes = map envelopeDefinitionId (currentEnvelopePolicyDefinitions policy)
      retiredErrors =
        [ EntitlementTransferAppendRetiredEnvelope envId
        | Spendable envId <- [entitlementTransferFrom transfer, entitlementTransferTo transfer]
        , envId `notElem` currentEnvelopes
        ]
  case NonEmpty.nonEmpty retiredErrors of
    Just errors -> Left errors
    Nothing -> prepareEntitlementTransferAppend registry existingSource transfer
