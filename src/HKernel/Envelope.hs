-- | Canonical Envelope domain surfaces.
--
-- Current definition/admission lives in 'HKernel.Envelope.Policy' and
-- 'HKernel.Envelope.Config'. Entitlement, consumption, routing, fulfillment,
-- remaining, and backing each keep their own semantic owners.
module HKernel.Envelope
  ( module HKernel.Envelope.Policy
  , module HKernel.Envelope.Config
  ) where

import HKernel.Envelope.Config
import HKernel.Envelope.Policy
