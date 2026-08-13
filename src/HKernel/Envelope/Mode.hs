-- | Presentation and pacing policy for one spendable Envelope.
--
-- This is not accounting metadata. It controls how an Envelope participates in
-- household pacing and grouping without changing the Envelope's identity or
-- historical allocation facts.
module HKernel.Envelope.Mode
  ( EnvelopeMode(..)
  ) where

-- | Current household treatment of one spendable Envelope.
--
-- Daily participates in per-day pacing, Flex retains only cycle-level capacity,
-- and Reserve remains outside ordinary pacing while staying visible as a
-- protected Envelope group.
data EnvelopeMode
  = Daily
  | Flex
  | Reserve
  deriving (Eq, Ord, Show)
