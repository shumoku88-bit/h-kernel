-- | Pool-local Backing arithmetic kept separate from source admission.
--
-- A BackingPool is the scope within which configured Asset funding is mutually
-- usable. Gross values describe recorded facts; available values additionally
-- apply still-open commitments. This module does not decide which Plans or
-- Accounts belong to a pool.
module HKernel.Household.Backing.Pool
  ( BackingPoolBacking(..)
  , backingPoolAvailableFunding
  , backingPoolGrossSurplus
  , backingPoolAvailableSurplus
  ) where

import HKernel.Budget.Policy (BackingPoolId)
import HKernel.Money (Balance, subtractBalance)

-- | One validated BackingPool coordinate at one Household observation.
data BackingPoolBacking = BackingPoolBacking
  { backingPoolBackingId                 :: BackingPoolId
  , backingPoolFundingBalance            :: Balance
  , backingPoolOpenPlanCommitment        :: Balance
  , backingPoolGrossEnvelopeRequired     :: Balance
  , backingPoolAvailableEnvelopeRequired :: Balance
  } deriving (Eq, Show)

-- | Asset funding still available after open Plans sourced from this pool.
backingPoolAvailableFunding :: BackingPoolBacking -> Balance
backingPoolAvailableFunding pool =
  backingPoolFundingBalance pool
    `subtractBalance` backingPoolOpenPlanCommitment pool

-- | Gross funding headroom before open Plan commitments are applied.
backingPoolGrossSurplus :: BackingPoolBacking -> Balance
backingPoolGrossSurplus pool =
  backingPoolFundingBalance pool
    `subtractBalance` backingPoolGrossEnvelopeRequired pool

-- | Funding headroom after pool and envelope commitments are both applied.
-- A normal envelope payment reduces both sides; an envelope-external fixed
-- payment reduces only available funding and can therefore reveal a shortage.
backingPoolAvailableSurplus :: BackingPoolBacking -> Balance
backingPoolAvailableSurplus pool =
  backingPoolAvailableFunding pool
    `subtractBalance` backingPoolAvailableEnvelopeRequired pool
