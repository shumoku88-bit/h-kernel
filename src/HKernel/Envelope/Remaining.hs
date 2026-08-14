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
import HKernel.Envelope.Fulfillment
  ( EnvelopeFulfillment
  , envelopeFulfillmentEntries
  , envelopeFulfillmentFor
  , envelopeFulfillmentObservedThrough
  , envelopeFulfillmentPeriod
  , fulfillmentNet
  )
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Money
  ( Balance
  , emptyBalance
  , isZeroBalance
  , subtractBalance
  )
import HKernel.Period (Period)

-- | Exact spendable remainder after posted Actual use.
--
-- Expense Consumption and explicit non-Expense target Fulfillment are separate
-- evidence owners, then meet only in this arithmetic projection. Negative values
-- remain valid overspending evidence; current policy, presentation order, and
-- routing attention stay outside this owner.
data EnvelopeRemaining = EnvelopeRemaining
  { envelopeRemainingPeriod          :: Period
  , envelopeRemainingObservedThrough :: Day
  , remainingBalances                :: Map.Map EnvelopeId Balance
  } deriving (Eq, Show)

data EnvelopeRemainingError
  = EnvelopeRemainingPeriodMismatch Period Period
  | EnvelopeRemainingObservationMismatch Day Day
  | EnvelopeRemainingFulfillmentPeriodMismatch Period Period
  | EnvelopeRemainingFulfillmentObservationMismatch Day Day
  deriving (Eq, Show)

calculateEnvelopeRemaining
  :: EnvelopeEntitlement
  -> EnvelopeConsumption
  -> EnvelopeFulfillment
  -> Either EnvelopeRemainingError EnvelopeRemaining
calculateEnvelopeRemaining entitlement consumption fulfillment
  | entitlementPeriod /= consumptionPeriod =
      Left (EnvelopeRemainingPeriodMismatch entitlementPeriod consumptionPeriod)
  | entitlementDay /= consumptionDay =
      Left (EnvelopeRemainingObservationMismatch entitlementDay consumptionDay)
  | entitlementPeriod /= fulfillmentPeriod =
      Left (EnvelopeRemainingFulfillmentPeriodMismatch entitlementPeriod fulfillmentPeriod)
  | entitlementDay /= fulfillmentDay =
      Left (EnvelopeRemainingFulfillmentObservationMismatch entitlementDay fulfillmentDay)
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
    fulfillmentPeriod = envelopeFulfillmentPeriod fulfillment
    entitlementDay = envelopeEntitlementObservedThrough entitlement
    consumptionDay = envelopeConsumptionObservedThrough consumption
    fulfillmentDay = envelopeFulfillmentObservedThrough fulfillment
    coordinates :: Set EnvelopeId
    coordinates = Set.fromList
      ( map fst (envelopeEntitlementEntries entitlement)
          ++ map fst (envelopeConsumptionEntries consumption)
          ++ map fst (envelopeFulfillmentEntries fulfillment)
      )
    remainingFor envelope =
      envelopeEntitlementBalance envelope entitlement
        `subtractBalance`
          consumptionNet (envelopeConsumptionFor envelope consumption)
        `subtractBalance`
          fulfillmentNet (envelopeFulfillmentFor envelope fulfillment)

envelopeRemainingFor :: EnvelopeId -> EnvelopeRemaining -> Balance
envelopeRemainingFor envelope =
  Map.findWithDefault emptyBalance envelope . remainingBalances

envelopeRemainingEntries :: EnvelopeRemaining -> [(EnvelopeId, Balance)]
envelopeRemainingEntries = Map.toAscList . remainingBalances
