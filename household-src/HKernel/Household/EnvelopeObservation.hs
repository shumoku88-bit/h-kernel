-- | Native Household Envelope observation from admitted entitlement, Actual,
-- Plan, and historical routing evidence.
module HKernel.Household.EnvelopeObservation
  ( HouseholdEnvelopeObservation
  , householdEnvelopeObservationPeriod
  , householdEnvelopeObservationObservedThrough
  , householdEnvelopeObservationStockOrigins
  , householdEnvelopeConsumption
  , householdEnvelopeEntitlement
  , householdEnvelopeFulfillment
  , householdEnvelopeRemaining
  , householdEnvelopeCommitment
  , householdEnvelopeHeadroom
  , HouseholdEnvelopeError(..)
  , deriveHouseholdEnvelopeObservation
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import Data.Time.Calendar (Day)
import HKernel.Actual.Journal (ActualJournal)
import HKernel.Envelope.Commitment
  ( EnvelopeCommitment
  , EnvelopeCommitmentError
  , observeEnvelopeCommitment
  )
import HKernel.Envelope.Consumption
  ( EnvelopeConsumption
  , EnvelopeConsumptionError
  , observeEnvelopeStockConsumption
  )
import HKernel.Envelope.Entitlement
  ( EnvelopeEntitlement
  , EnvelopeEntitlementError
  , observeEnvelopeEntitlement
  )
import HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , envelopeEntitlementHistoryOrigins
  )
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoutingHistory
  , expenseRoutingResolver
  )
import HKernel.Envelope.Fulfillment
  ( EnvelopeFulfillment
  , EnvelopeFulfillmentError
  , observeEnvelopeStockFulfillment
  )
import HKernel.Envelope.FulfillmentRouting (FulfillmentRoutingHistory)
import HKernel.Envelope.Headroom
  ( EnvelopeHeadroom
  , EnvelopeHeadroomError
  , calculateEnvelopeHeadroom
  )
import HKernel.Envelope.Remaining
  ( EnvelopeRemaining
  , EnvelopeRemainingError
  , calculateEnvelopeRemaining
  )
import HKernel.Envelope.StockOrigin (StockOrigin)
import HKernel.Money (Commodity)
import HKernel.Period (Period)
import HKernel.Plan.Journal (PlanJournal)

data HouseholdEnvelopeObservation = HouseholdEnvelopeObservation
  { householdEnvelopeObservationPeriod          :: Period
  , householdEnvelopeObservationObservedThrough :: Day
  , householdEnvelopeObservationStockOrigins    :: Map Commodity StockOrigin
  , householdEnvelopeConsumption                :: EnvelopeConsumption
  , householdEnvelopeEntitlement                :: EnvelopeEntitlement
  , householdEnvelopeFulfillment                :: EnvelopeFulfillment
  , householdEnvelopeRemaining                  :: EnvelopeRemaining
  , householdEnvelopeCommitment                 :: EnvelopeCommitment
  , householdEnvelopeHeadroom                   :: EnvelopeHeadroom
  } deriving (Eq, Show)

data HouseholdEnvelopeError
  = HouseholdEnvelopeConsumptionError EnvelopeConsumptionError
  | HouseholdEnvelopeEntitlementObservationError EnvelopeEntitlementError
  | HouseholdEnvelopeFulfillmentError EnvelopeFulfillmentError
  | HouseholdEnvelopeRemainingError EnvelopeRemainingError
  | HouseholdEnvelopeCommitmentError EnvelopeCommitmentError
  | HouseholdEnvelopeHeadroomError EnvelopeHeadroomError
  deriving (Eq, Show)

deriveHouseholdEnvelopeObservation
  :: Day
  -> Period
  -> ActualJournal
  -> PlanJournal
  -> ExpenseRoutingHistory
  -> FulfillmentRoutingHistory
  -> EnvelopeEntitlementHistory
  -> Either (NonEmpty HouseholdEnvelopeError) HouseholdEnvelopeObservation
deriveHouseholdEnvelopeObservation observedThrough period actual plans expenseRouting fulfillmentRouting history = do
  entitlement <- singleLeft HouseholdEnvelopeEntitlementObservationError
    (observeEnvelopeEntitlement period observedThrough history)
  consumption <- singleLeft HouseholdEnvelopeConsumptionError
    (observeEnvelopeStockConsumption
      history period observedThrough actual (expenseRoutingResolver expenseRouting))
  fulfillment <- mapLeft (fmap HouseholdEnvelopeFulfillmentError)
    (observeEnvelopeStockFulfillment
      history period observedThrough plans actual fulfillmentRouting)
  remaining <- valueLeft HouseholdEnvelopeRemainingError
    (calculateEnvelopeRemaining entitlement consumption fulfillment)
  commitment <- mapLeft (fmap HouseholdEnvelopeCommitmentError)
    (observeEnvelopeCommitment
      period observedThrough plans actual expenseRouting fulfillmentRouting)
  headroom <- valueLeft HouseholdEnvelopeHeadroomError
    (calculateEnvelopeHeadroom remaining commitment)
  Right HouseholdEnvelopeObservation
    { householdEnvelopeObservationPeriod = period
    , householdEnvelopeObservationObservedThrough = observedThrough
    , householdEnvelopeObservationStockOrigins = envelopeEntitlementHistoryOrigins history
    , householdEnvelopeConsumption = consumption
    , householdEnvelopeEntitlement = entitlement
    , householdEnvelopeFulfillment = fulfillment
    , householdEnvelopeRemaining = remaining
    , householdEnvelopeCommitment = commitment
    , householdEnvelopeHeadroom = headroom
    }

singleLeft
  :: (error -> HouseholdEnvelopeError)
  -> Either error value
  -> Either (NonEmpty HouseholdEnvelopeError) value
singleLeft wrap = mapLeft (NonEmpty.singleton . wrap)

valueLeft
  :: (error -> HouseholdEnvelopeError)
  -> Either error value
  -> Either (NonEmpty HouseholdEnvelopeError) value
valueLeft = singleLeft

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value
