{-# LANGUAGE OverloadedStrings #-}

-- | Stable machine identity for one spendable Envelope.
--
-- Identity belongs to the Envelope domain rather than to accounting Accounts or
-- the retiring Budget compatibility layer. Human-facing labels and current
-- display policy are separate coordinates.
module HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeIdError(..)
  , mkEnvelopeId
  , envelopeIdText
  ) where

import Data.Char (isControl, isSpace)
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
  | T.strip value /= value =
      Left (EnvelopeIdHasSurroundingWhitespace value)
  | T.any isControl value =
      Left (EnvelopeIdContainsControlCharacter value)
  | T.any isSpace value = Left (EnvelopeIdContainsWhitespace value)
  | T.toCaseFold value == "unallocated" = Left (ReservedEnvelopeId value)
  | otherwise = Right (EnvelopeId value)
