-- | Exact remaining envelope capacity derived by coordinatewise subtraction.
--
-- This module combines one canonical entitlement result with one canonical
-- consumption result. It refuses to subtract different cycles, observation
-- horizons, or envelope coordinate sets, then preserves commodity identity
-- through exact 'Balance' subtraction. Negative remaining balances are valid
-- overspending evidence and are never clamped to zero.
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
import HKernel.Money
  ( Balance
  , subtractBalance
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
  | RemainingObservedThroughMismatch Day Day
  | RemainingEnvelopeMissingFromEntitlement EnvelopeId
  | RemainingEnvelopeMissingFromConsumption EnvelopeId
  deriving (Eq, Show)

-- | Subtract exact consumption from exact entitlement coordinate by coordinate.
--
-- The calculation has three semantic stages:
--
-- * verify that both results describe the same cycle and inclusive observation
--   horizon,
-- * verify that both results expose the same envelope coordinate set,
-- * subtract balances at each aligned envelope identity.
--
-- Unassigned Expense evidence remains owned by 'BudgetConsumption'; this
-- envelope-only subtraction neither transforms nor discards the input value.
calculateBudgetRemaining
  :: BudgetEntitlement
  -> BudgetConsumption
  -> Either (NonEmpty RemainingError) BudgetRemaining
calculateBudgetRemaining entitlement consumption =
  publishBudgetRemaining (budgetEntitlementObservation entitlement)
    <$> alignedRemainingBalances entitlement consumption

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
