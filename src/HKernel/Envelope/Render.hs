-- | Rendering entry points for current Envelope configuration.
--
-- Historical standalone allocation-report rendering was retired with the
-- duplicate Budget-style Envelope facade. Configuration rendering remains a
-- narrow presentation of the canonical current Envelope policy.
module HKernel.Envelope.Render
  ( renderCurrentEnvelopeConfiguration
  , renderCurrentEnvelopeConfigurationErrors
  ) where

import HKernel.Envelope.Config
  ( renderCurrentEnvelopeConfiguration
  , renderCurrentEnvelopeConfigurationErrors
  )
