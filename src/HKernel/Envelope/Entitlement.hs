module HKernel.Envelope.Entitlement
  ( EnvelopeEntitlement
  , EnvelopeEntitlementError(..)
  , observeEnvelopeEntitlement
  , envelopeEntitlementPeriod
  , envelopeEntitlementObservedThrough
  , envelopeEntitlementBalance
  , envelopeEntitlementEntries
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day)
import HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , envelopeEntitlementHistoryTransfers
  )
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransfer
  , entitlementTransferAmount
  , entitlementTransferDate
  , entitlementTransferFrom
  , entitlementTransferTo
  )
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Money
  ( Balance
  , addBalance
  , emptyBalance
  , isZeroBalance
  , negateAmount
  , singletonBalance
  )
import HKernel.Period (Period, periodContains)

-- | Exact spendable entitlement at one resolved period/day observation.
--
-- This is a projection, not another source of truth. Current policy is absent on
-- purpose: historical transfer admission and arithmetic do not depend on the
-- latest TOML definition set or presentation order.
data EnvelopeEntitlement = EnvelopeEntitlement
  { envelopeEntitlementPeriod          :: Period
  , envelopeEntitlementObservedThrough :: Day
  , entitlementBalances                :: Map EnvelopeId Balance
  } deriving (Eq, Show)

data EnvelopeEntitlementError
  = EnvelopeEntitlementObservationOutsidePeriod Day Period
  deriving (Eq, Show)

-- | Project admitted entitlement history through one inclusive observation day.
--
-- All admitted transfers whose effective day is on or before the observation day
-- contribute to the observed balance. Period start does not truncate historical
-- facts, allowing pre-period grants, reallocations, and releases to carry forward.
-- History admission has already proven that effective-date entitlement never
-- becomes negative.
observeEnvelopeEntitlement
  :: Period
  -> Day
  -> EnvelopeEntitlementHistory
  -> Either EnvelopeEntitlementError EnvelopeEntitlement
observeEnvelopeEntitlement period observedThrough history
  | not (periodContains period observedThrough) =
      Left (EnvelopeEntitlementObservationOutsidePeriod observedThrough period)
  | otherwise = Right EnvelopeEntitlement
      { envelopeEntitlementPeriod = period
      , envelopeEntitlementObservedThrough = observedThrough
      , entitlementBalances = Map.filter (not . isZeroBalance)
          (Map.fromListWith addBalance
            (concatMap transferContributions visibleTransfers))
      }
  where
    visibleTransfers =
      [ transfer
      | transfer <- envelopeEntitlementHistoryTransfers history
      , entitlementTransferDate transfer <= observedThrough
      ]

-- | Total lookup. An untouched or fully released Envelope has canonical zero.
envelopeEntitlementBalance :: EnvelopeId -> EnvelopeEntitlement -> Balance
envelopeEntitlementBalance envelope =
  Map.findWithDefault emptyBalance envelope . entitlementBalances

-- | Non-zero entitlement coordinates in stable EnvelopeId order.
envelopeEntitlementEntries :: EnvelopeEntitlement -> [(EnvelopeId, Balance)]
envelopeEntitlementEntries = Map.toAscList . entitlementBalances

transferContributions
  :: EnvelopeEntitlementTransfer
  -> [(EnvelopeId, Balance)]
transferContributions transfer = fromContribution ++ toContribution
  where
    amount = entitlementTransferAmount transfer
    fromContribution = case entitlementTransferFrom transfer of
      Unallocated -> []
      Spendable envelope ->
        [(envelope, singletonBalance (negateAmount amount))]
    toContribution = case entitlementTransferTo transfer of
      Unallocated -> []
      Spendable envelope -> [(envelope, singletonBalance amount)]
