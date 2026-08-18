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
  , HouseholdEnvelopeExplanation
  , EnvelopeExplanationLine
  , explainHouseholdEnvelope
  , householdEnvelopeExplanationPeriod
  , householdEnvelopeExplanationObservedThrough
  , householdEnvelopeExplanationLines
  , envelopeExplanationId
  , envelopeExplanationEntitlement
  , envelopeExplanationConsumptionCharges
  , envelopeExplanationConsumptionRefunds
  , envelopeExplanationConsumptionNet
  , envelopeExplanationFulfillmentApplied
  , envelopeExplanationFulfillmentReversed
  , envelopeExplanationFulfillmentNet
  , envelopeExplanationRemaining
  , envelopeExplanationCommitment
  , envelopeExplanationHeadroom
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import Data.Time.Calendar (Day)
import HKernel.Actual.Journal (ActualJournal)
import HKernel.Envelope.Commitment
  ( EnvelopeCommitment
  , EnvelopeCommitmentError
  , envelopeCommitmentFor
  , observeEnvelopeCommitment
  )
import HKernel.Envelope.Consumption
  ( EnvelopeConsumption
  , EnvelopeConsumptionError
  , consumptionCharges
  , consumptionNet
  , consumptionRefunds
  , envelopeConsumptionFor
  , observeEnvelopeStockConsumption
  )
import HKernel.Envelope.Entitlement
  ( EnvelopeEntitlement
  , EnvelopeEntitlementError
  , envelopeEntitlementBalance
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
  , envelopeFulfillmentFor
  , fulfillmentApplied
  , fulfillmentNet
  , fulfillmentReversed
  , observeEnvelopeStockFulfillment
  )
import HKernel.Envelope.FulfillmentRouting (FulfillmentRoutingHistory)
import HKernel.Envelope.Headroom
  ( EnvelopeHeadroom
  , EnvelopeHeadroomError
  , calculateEnvelopeHeadroom
  , envelopeHeadroomFor
  )
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Envelope.Remaining
  ( EnvelopeRemaining
  , EnvelopeRemainingError
  , calculateEnvelopeRemaining
  , envelopeRemainingFor
  )
import HKernel.Envelope.StockOrigin (StockOrigin)
import HKernel.Money (Balance, Commodity)
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

-- | Complete arithmetic witness for one Envelope in one admitted Household
-- observation. Gross evidence remains beside its net projection so activity does
-- not disappear merely because opposite movements cancel.
data EnvelopeExplanationLine = EnvelopeExplanationLine
  { envelopeExplanationId                  :: EnvelopeId
  , envelopeExplanationEntitlement         :: Balance
  , envelopeExplanationConsumptionCharges  :: Balance
  , envelopeExplanationConsumptionRefunds  :: Balance
  , envelopeExplanationConsumptionNet      :: Balance
  , envelopeExplanationFulfillmentApplied  :: Balance
  , envelopeExplanationFulfillmentReversed :: Balance
  , envelopeExplanationFulfillmentNet      :: Balance
  , envelopeExplanationRemaining           :: Balance
  , envelopeExplanationCommitment          :: Balance
  , envelopeExplanationHeadroom            :: Balance
  } deriving (Eq, Show)

-- | Question-specific explanation of why current Envelope Remaining and
-- Headroom have their observed values. The caller supplies current presentation
-- membership and order; historical evidence does not decide current membership.
data HouseholdEnvelopeExplanation = HouseholdEnvelopeExplanation
  { householdEnvelopeExplanationPeriod          :: Period
  , householdEnvelopeExplanationObservedThrough :: Day
  , householdEnvelopeExplanationLines           :: [EnvelopeExplanationLine]
  } deriving (Eq, Show)

-- | Preserve the typed arithmetic evidence already present in one observation.
-- This projection performs no source reads and creates no new authority.
explainHouseholdEnvelope
  :: [EnvelopeId]
  -> HouseholdEnvelopeObservation
  -> HouseholdEnvelopeExplanation
explainHouseholdEnvelope envelopes observation =
  HouseholdEnvelopeExplanation
    { householdEnvelopeExplanationPeriod =
        householdEnvelopeObservationPeriod observation
    , householdEnvelopeExplanationObservedThrough =
        householdEnvelopeObservationObservedThrough observation
    , householdEnvelopeExplanationLines = map explain envelopes
    }
  where
    entitlement = householdEnvelopeEntitlement observation
    consumption = householdEnvelopeConsumption observation
    fulfillment = householdEnvelopeFulfillment observation
    remaining = householdEnvelopeRemaining observation
    commitment = householdEnvelopeCommitment observation
    headroom = householdEnvelopeHeadroom observation

    explain envelope =
      let consumptionAmounts = envelopeConsumptionFor envelope consumption
          fulfillmentAmounts = envelopeFulfillmentFor envelope fulfillment
      in EnvelopeExplanationLine
        { envelopeExplanationId = envelope
        , envelopeExplanationEntitlement =
            envelopeEntitlementBalance envelope entitlement
        , envelopeExplanationConsumptionCharges =
            consumptionCharges consumptionAmounts
        , envelopeExplanationConsumptionRefunds =
            consumptionRefunds consumptionAmounts
        , envelopeExplanationConsumptionNet =
            consumptionNet consumptionAmounts
        , envelopeExplanationFulfillmentApplied =
            fulfillmentApplied fulfillmentAmounts
        , envelopeExplanationFulfillmentReversed =
            fulfillmentReversed fulfillmentAmounts
        , envelopeExplanationFulfillmentNet =
            fulfillmentNet fulfillmentAmounts
        , envelopeExplanationRemaining =
            envelopeRemainingFor envelope remaining
        , envelopeExplanationCommitment =
            envelopeCommitmentFor envelope commitment
        , envelopeExplanationHeadroom =
            envelopeHeadroomFor envelope headroom
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
