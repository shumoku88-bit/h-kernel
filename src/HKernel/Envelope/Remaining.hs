module HKernel.Envelope.Remaining
  ( EnvelopeRemaining
  , EnvelopeRemainingError(..)
  , calculateEnvelopeRemaining
  , envelopeRemainingPeriod
  , envelopeRemainingObservedThrough
  , envelopeRemainingFor
  , envelopeRemainingEntries
  ) where

import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Time.Calendar (Day)
import HKernel.Envelope.Consumption
  ( EnvelopeConsumption
  , consumptionNet
  , envelopeConsumptionEntries
  , envelopeConsumptionFor
  , envelopeConsumptionObservedThrough
  , envelopeConsumptionPeriod
  )
import HKernel.Envelope.Entitlement
  ( EnvelopeEntitlement
  , envelopeEntitlementBalance
  , envelopeEntitlementEntries
  , envelopeEntitlementObservedThrough
  , envelopeEntitlementPeriod
  )
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Money
  ( Balance
  , emptyBalance
  , isZeroBalance
  , subtractBalance
  )
import HKernel.Period (Period)

-- | Exact spendable remainder after Actual consumption.
--
-- This is a projection only. Negative values are valid overspending evidence;
-- current policy, presentation order, unmanaged activity, and unrouted attention
-- remain outside this arithmetic owner.
data EnvelopeRemaining = EnvelopeRemaining
  { envelopeRemainingPeriod          :: Period
  , envelopeRemainingObservedThrough :: Day
  , remainingBalances                :: Map.Map EnvelopeId Balance
  } deriving (Eq, Show)

data EnvelopeRemainingError
  = EnvelopeRemainingPeriodMismatch Period Period
  | EnvelopeRemainingObservationMismatch Day Day
  deriving (Eq, Show)

-- | Align two already-derived observations and subtract exact Actual
-- consumption from exact entitlement at every Envelope coordinate mentioned by
-- either side. Total lookups make policy-driven zero filling unnecessary.
calculateEnvelopeRemaining
  :: EnvelopeEntitlement
  -> EnvelopeConsumption
  -> Either EnvelopeRemainingError EnvelopeRemaining
calculateEnvelopeRemaining entitlement consumption
  | entitlementPeriod /= consumptionPeriod =
      Left (EnvelopeRemainingPeriodMismatch entitlementPeriod consumptionPeriod)
  | entitlementDay /= consumptionDay =
      Left (EnvelopeRemainingObservationMismatch entitlementDay consumptionDay)
  | otherwise = Right EnvelopeRemaining
      { envelopeRemainingPeriod = entitlementPeriod
      , envelopeRemainingObservedThrough = entitlementDay
      , remainingBalances = Map.fromList
          [ (envelope, remainingFor envelope)
          | envelope <- Set.toAscList coordinates
          , not (isZeroBalance (remainingFor envelope))
          ]
      }
  where
    entitlementPeriod = envelopeEntitlementPeriod entitlement
    consumptionPeriod = envelopeConsumptionPeriod consumption
    entitlementDay = envelopeEntitlementObservedThrough entitlement
    consumptionDay = envelopeConsumptionObservedThrough consumption
    coordinates :: Set EnvelopeId
    coordinates = Set.fromList
      ( map fst (envelopeEntitlementEntries entitlement)
          ++ map fst (envelopeConsumptionEntries consumption)
      )
    remainingFor envelope =
      envelopeEntitlementBalance envelope entitlement
        `subtractBalance`
          consumptionNet (envelopeConsumptionFor envelope consumption)

envelopeRemainingFor :: EnvelopeId -> EnvelopeRemaining -> Balance
envelopeRemainingFor envelope =
  Map.findWithDefault emptyBalance envelope . remainingBalances

envelopeRemainingEntries :: EnvelopeRemaining -> [(EnvelopeId, Balance)]
envelopeRemainingEntries = Map.toAscList . remainingBalances
