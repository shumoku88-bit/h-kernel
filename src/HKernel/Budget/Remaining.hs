-- | Exact remaining envelope capacity derived by coordinatewise subtraction.
--
-- This compatibility module still publishes the legacy 'BudgetRemaining'
-- surface, but production Household composition can now subtract native
-- 'EnvelopeConsumption' directly. The legacy 'BudgetConsumption' entry point is
-- retained only for callers that have not migrated yet.
module HKernel.Budget.Remaining
  ( EnvelopeRemaining
  , envelopeRemainingEnvelope
  , envelopeRemainingBalance
  , BudgetRemaining
  , budgetRemainingObservation
  , budgetRemainingCycle
  , budgetRemainingObservedThrough
  , budgetRemainingEnvelopes
  , RemainingError(..)
  , calculateBudgetRemaining
  , calculateBudgetRemainingFromEnvelopeConsumption
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day)
import HKernel.Budget
  ( BudgetCycle
  , BudgetObservation
  , EnvelopeId
  , budgetCycleEndExclusive
  , budgetCycleStart
  , budgetObservationCycle
  , budgetObservationObservedThrough
  )
import HKernel.Budget.Consumption
  ( BudgetConsumption
  , budgetConsumptionCycle
  , budgetConsumptionEnvelopes
  , budgetConsumptionObservedThrough
  , envelopeConsumptionBalance
  , envelopeConsumptionEnvelope
  )
import HKernel.Budget.Entitlement
  ( BudgetEntitlement
  , budgetEntitlementCycle
  , budgetEntitlementEnvelopes
  , budgetEntitlementObservation
  , budgetEntitlementObservedThrough
  , envelopeEntitlementBalance
  , envelopeEntitlementEnvelope
  )
import qualified HKernel.Envelope.Consumption as Native
import HKernel.Money
  ( Balance
  , subtractBalance
  )
import HKernel.Period
  ( Period
  , periodEndExclusive
  , periodStart
  )

-- | Exact remaining capacity at one spendable-envelope coordinate.
data EnvelopeRemaining = EnvelopeRemaining
  { envelopeRemainingEnvelope :: EnvelopeId
  , envelopeRemainingBalance  :: Balance
  } deriving (Eq, Show)

-- | Remaining facts for one point-in-time budget observation.
--
-- Envelope order is canonical by identity. A negative balance means exact
-- consumption exceeded exact entitlement for that commodity.
data BudgetRemaining = BudgetRemaining
  { budgetRemainingObservation :: BudgetObservation
  , budgetRemainingEnvelopes    :: [EnvelopeRemaining]
  } deriving (Eq, Show)

budgetRemainingCycle :: BudgetRemaining -> BudgetCycle
budgetRemainingCycle =
  budgetObservationCycle . budgetRemainingObservation

budgetRemainingObservedThrough :: BudgetRemaining -> Day
budgetRemainingObservedThrough =
  budgetObservationObservedThrough . budgetRemainingObservation

-- | Entitlement and consumption cannot be subtracted until their semantic axes
-- agree.
data RemainingError
  = RemainingCycleMismatch BudgetCycle BudgetCycle
  | RemainingPeriodMismatch BudgetCycle Period
  | RemainingObservedThroughMismatch Day Day
  | RemainingEnvelopeMissingFromEntitlement EnvelopeId
  | RemainingEnvelopeMissingFromConsumption EnvelopeId
  deriving (Eq, Show)

-- | Legacy compatibility entry point for callers still producing
-- 'BudgetConsumption'.
calculateBudgetRemaining
  :: BudgetEntitlement
  -> BudgetConsumption
  -> Either (NonEmpty RemainingError) BudgetRemaining
calculateBudgetRemaining entitlement consumption =
  publishBudgetRemaining (budgetEntitlementObservation entitlement)
    <$> alignedRemainingBalances entitlement consumption

-- | Subtract native Envelope consumption from legacy-compatible entitlement.
--
-- Native consumption has total zero lookup for untouched Envelopes, so an
-- absent consumption coordinate means canonical zero rather than an alignment
-- failure. Managed consumption that names an Envelope absent from entitlement
-- still fails closed. Unrouted and explicit unmanaged Expense evidence are not
-- Envelope coordinates and therefore do not participate in remaining arithmetic.
calculateBudgetRemainingFromEnvelopeConsumption
  :: BudgetEntitlement
  -> Native.EnvelopeConsumption
  -> Either (NonEmpty RemainingError) BudgetRemaining
calculateBudgetRemainingFromEnvelopeConsumption entitlement consumption =
  publishBudgetRemaining (budgetEntitlementObservation entitlement)
    <$> alignedRemainingBalancesFromEnvelopeConsumption entitlement consumption

alignedRemainingBalances
  :: BudgetEntitlement
  -> BudgetConsumption
  -> Either (NonEmpty RemainingError) (Map EnvelopeId Balance)
alignedRemainingBalances entitlement consumption =
  case NonEmpty.nonEmpty alignmentErrors of
    Just errors -> Left errors
    Nothing -> Right
      (Map.intersectionWith subtractBalance
        entitlementBalances
        consumptionBalances)
  where
    entitlementCycle = budgetEntitlementCycle entitlement
    consumptionCycle = budgetConsumptionCycle consumption
    entitlementObservedThrough = budgetEntitlementObservedThrough entitlement
    consumptionObservedThrough = budgetConsumptionObservedThrough consumption
    entitlementBalances = Map.fromList
      [ ( envelopeEntitlementEnvelope entry
        , envelopeEntitlementBalance entry
        )
      | entry <- budgetEntitlementEnvelopes entitlement
      ]
    consumptionBalances = Map.fromList
      [ ( envelopeConsumptionEnvelope entry
        , envelopeConsumptionBalance entry
        )
      | entry <- budgetConsumptionEnvelopes consumption
      ]
    alignmentErrors =
      [ RemainingCycleMismatch entitlementCycle consumptionCycle
      | entitlementCycle /= consumptionCycle
      ]
        ++ [ RemainingObservedThroughMismatch
              entitlementObservedThrough
              consumptionObservedThrough
           | entitlementObservedThrough /= consumptionObservedThrough
           ]
        ++ map RemainingEnvelopeMissingFromEntitlement
          (Map.keys (Map.difference consumptionBalances entitlementBalances))
        ++ map RemainingEnvelopeMissingFromConsumption
          (Map.keys (Map.difference entitlementBalances consumptionBalances))

alignedRemainingBalancesFromEnvelopeConsumption
  :: BudgetEntitlement
  -> Native.EnvelopeConsumption
  -> Either (NonEmpty RemainingError) (Map EnvelopeId Balance)
alignedRemainingBalancesFromEnvelopeConsumption entitlement consumption =
  case NonEmpty.nonEmpty alignmentErrors of
    Just errors -> Left errors
    Nothing -> Right
      (Map.mapWithKey remainingFor entitlementBalances)
  where
    entitlementCycle = budgetEntitlementCycle entitlement
    consumptionPeriod = Native.envelopeConsumptionPeriod consumption
    entitlementObservedThrough = budgetEntitlementObservedThrough entitlement
    consumptionObservedThrough = Native.envelopeConsumptionObservedThrough consumption
    entitlementBalances = Map.fromList
      [ ( envelopeEntitlementEnvelope entry
        , envelopeEntitlementBalance entry
        )
      | entry <- budgetEntitlementEnvelopes entitlement
      ]
    consumptionCoordinates = Map.fromList
      [ (envelope, ())
      | (envelope, _) <- Native.envelopeConsumptionEntries consumption
      ]
    periodMatches =
      budgetCycleStart entitlementCycle == periodStart consumptionPeriod
        && budgetCycleEndExclusive entitlementCycle
          == periodEndExclusive consumptionPeriod
    alignmentErrors =
      [ RemainingPeriodMismatch entitlementCycle consumptionPeriod
      | not periodMatches
      ]
        ++ [ RemainingObservedThroughMismatch
              entitlementObservedThrough
              consumptionObservedThrough
           | entitlementObservedThrough /= consumptionObservedThrough
           ]
        ++ map RemainingEnvelopeMissingFromEntitlement
          (Map.keys (Map.difference consumptionCoordinates entitlementBalances))
    remainingFor envelope entitlementBalance =
      entitlementBalance
        `subtractBalance`
          Native.consumptionNet
            (Native.envelopeConsumptionFor envelope consumption)

publishBudgetRemaining
  :: BudgetObservation
  -> Map EnvelopeId Balance
  -> BudgetRemaining
publishBudgetRemaining observation remainingBalances = BudgetRemaining
  { budgetRemainingObservation = observation
  , budgetRemainingEnvelopes =
      [ EnvelopeRemaining envelope balance
      | (envelope, balance) <- Map.toAscList remainingBalances
      ]
  }
