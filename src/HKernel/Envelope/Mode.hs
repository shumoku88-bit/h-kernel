module HKernel.Envelope.Mode
  ( EnvelopeMode(..)
  ) where

data EnvelopeMode
  = Daily
  | Flex
  | Reserve
  deriving (Eq, Ord, Show)
