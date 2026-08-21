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
  , entitlementCandidateCompleteSource
  , EntitlementTransferPublicationError(..)
  , prepareEntitlementTransferAppend
  , prepareCurrentEntitlementTransferAppend
  , publishCurrentEntitlementTransferFromPreview
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)

import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteError
  , WriteIntent(..)
  , publishWithPathAdmission
  )
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

-- | A validated preview retains the observed source and typed operation, not a
-- pre-authorized replacement source. Delivery surfaces may render the block,
-- while publication reconstructs and re-admits the complete candidate inside
-- this domain owner.
data EntitlementTransferAppendPreview = EntitlementTransferAppendPreview
  { entitlementCandidateBlock   :: Text
  , entitlementObservedSource   :: Text
  , entitlementPreparedTransfer :: EnvelopeEntitlementTransfer
  } deriving (Eq, Show)

-- | Derive the complete append candidate from the observed source and the
-- domain-rendered block. Kept for compatibility with delivery adapters that
-- have not yet moved to operation-owned publication.
entitlementCandidateCompleteSource :: EntitlementTransferAppendPreview -> Text
entitlementCandidateCompleteSource preview =
  appendSourceBlock
    (entitlementObservedSource preview)
    (SourceBlock (entitlementCandidateBlock preview))

data EntitlementTransferPublicationError sourceError
  = EntitlementTransferPublicationPreparationFailed
      (NonEmpty EntitlementTransferAppendError)
  | EntitlementTransferPublicationWriteFailed (WriteError sourceError)
  deriving (Eq, Show)

-- | Prepare a candidate append against the stable 'EnvelopeRegistry'.
prepareEntitlementTransferAppend
  :: EnvelopeRegistry
  -> Text
  -> EnvelopeEntitlementTransfer
  -> Either (NonEmpty EntitlementTransferAppendError) EntitlementTransferAppendPreview
prepareEntitlementTransferAppend registry existingSource transfer = do
  let block = renderEntitlementTransfer transfer
      preview = EntitlementTransferAppendPreview
        { entitlementCandidateBlock = block
        , entitlementObservedSource = existingSource
        , entitlementPreparedTransfer = transfer
        }
      completeSource = entitlementCandidateCompleteSource preview
  case admitEntitlementJournal registry completeSource of
    Left errors ->
      Left (fmap EntitlementTransferCandidateAdmitError errors)
    Right _ -> Right preview

-- | Prepare a candidate append enforcing that any spendable Envelope endpoint
-- belongs to current writable policy.
prepareCurrentEntitlementTransferAppend
  :: CurrentEnvelopePolicy
  -> EnvelopeRegistry
  -> Text
  -> EnvelopeEntitlementTransfer
  -> Either (NonEmpty EntitlementTransferAppendError) EntitlementTransferAppendPreview
prepareCurrentEntitlementTransferAppend policy registry existingSource transfer = do
  validateCurrentTransfer policy transfer
  prepareEntitlementTransferAppend registry existingSource transfer

-- | Publish one previously previewed typed transfer.
--
-- The preview does not grant authority to install arbitrary complete source
-- bytes. Publication re-runs current-policy validation and candidate admission
-- from the exact observed source plus the typed transfer, then delegates only
-- filesystem safety and post-admission to 'SourcePublication'.
publishCurrentEntitlementTransferFromPreview
  :: (FilePath -> IO (Either (NonEmpty sourceError) admitted))
  -> FilePath
  -> CurrentEnvelopePolicy
  -> EnvelopeRegistry
  -> EntitlementTransferAppendPreview
  -> IO (Either (EntitlementTransferPublicationError sourceError) ())
publishCurrentEntitlementTransferFromPreview admit filePath policy registry preview =
  case prepareCurrentEntitlementTransferAppend
      policy
      registry
      (entitlementObservedSource preview)
      (entitlementPreparedTransfer preview) of
    Left errors ->
      pure (Left (EntitlementTransferPublicationPreparationFailed errors))
    Right prepared ->
      fmap (first EntitlementTransferPublicationWriteFailed) $
        publishWithPathAdmission admit WriteIntent
          { targetFilePath = filePath
          , expectedOldBytes = ExpectedSource (entitlementObservedSource prepared)
          , candidateNewBytes = CandidateSource
              (entitlementCandidateCompleteSource prepared)
          }

validateCurrentTransfer
  :: CurrentEnvelopePolicy
  -> EnvelopeEntitlementTransfer
  -> Either (NonEmpty EntitlementTransferAppendError) ()
validateCurrentTransfer policy transfer =
  let currentEnvelopes = map envelopeDefinitionId (currentEnvelopePolicyDefinitions policy)
      retiredErrors =
        [ EntitlementTransferAppendRetiredEnvelope envId
        | Spendable envId <- [entitlementTransferFrom transfer, entitlementTransferTo transfer]
        , envId `notElem` currentEnvelopes
        ]
  in case NonEmpty.nonEmpty retiredErrors of
    Just errors -> Left errors
    Nothing -> Right ()
