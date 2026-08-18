-- | Aligned comparison between two Household Envelope cycle observations.
--
-- Same-Period temporal transition belongs to 'HouseholdEnvelopeChange'. This
-- observer answers a different question: how does one cycle look beside an
-- earlier cycle at the same elapsed day count?
--
-- Activity and position stay distinct. Consumption/Fulfillment activity is
-- bounded by each compared Period, while Entitlement/Remaining/Commitment/
-- Headroom are point-in-time positions at the aligned observation days.
module HKernel.Household.EnvelopeCycleComparison
  ( EnvelopeCycleComparisonSide(..)
  , HouseholdEnvelopeCycleComparisonError(..)
  , HouseholdEnvelopeCycleComparison
  , EnvelopeCycleComparisonLine
  , observeAlignedHouseholdEnvelopeCycleComparison
  , householdEnvelopeCycleComparisonCurrentPeriod
  , householdEnvelopeCycleComparisonBaselinePeriod
  , householdEnvelopeCycleComparisonCurrentThrough
  , householdEnvelopeCycleComparisonBaselineThrough
  , householdEnvelopeCycleComparisonLines
  , envelopeCycleComparisonId
  , envelopeCycleCurrentConsumption
  , envelopeCycleBaselineConsumption
  , envelopeCycleCurrentFulfillment
  , envelopeCycleBaselineFulfillment
  , envelopeCycleCurrentEntitlement
  , envelopeCycleBaselineEntitlement
  , envelopeCycleCurrentRemaining
  , envelopeCycleBaselineRemaining
  , envelopeCycleCurrentCommitment
  , envelopeCycleBaselineCommitment
  , envelopeCycleCurrentHeadroom
  , envelopeCycleBaselineHeadroom
  , envelopeCycleConsumptionNetDifference
  , envelopeCycleFulfillmentNetDifference
  , envelopeCycleEntitlementDifference
  , envelopeCycleRemainingDifference
  , envelopeCycleCommitmentDifference
  , envelopeCycleHeadroomDifference
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Time.Calendar (Day, addDays, diffDays)
import HKernel.Actual.Journal (ActualJournal)
import HKernel.Envelope.Commitment (envelopeCommitmentFor)
import HKernel.Envelope.Consumption
  ( ConsumptionAmounts
  , EnvelopeConsumption
  , EnvelopeConsumptionError
  , consumptionNet
  , envelopeConsumptionFor
  , observeEnvelopeConsumption
  )
import HKernel.Envelope.Entitlement (envelopeEntitlementBalance)
import HKernel.Envelope.EntitlementHistory (EnvelopeEntitlementHistory)
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoutingHistory
  , expenseRoutingResolver
  )
import HKernel.Envelope.Fulfillment
  ( EnvelopeFulfillment
  , EnvelopeFulfillmentError
  , FulfillmentAmounts
  , envelopeFulfillmentFor
  , fulfillmentNet
  , observeEnvelopeFulfillment
  )
import HKernel.Envelope.FulfillmentRouting (FulfillmentRoutingHistory)
import HKernel.Envelope.Headroom (envelopeHeadroomFor)
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Envelope.Remaining (envelopeRemainingFor)
import HKernel.Household.EnvelopeObservation
  ( HouseholdEnvelopeError
  , HouseholdEnvelopeObservation
  , deriveHouseholdEnvelopeObservation
  , householdEnvelopeCommitment
  , householdEnvelopeEntitlement
  , householdEnvelopeHeadroom
  , householdEnvelopeRemaining
  )
import HKernel.Money (Balance, subtractBalance)
import HKernel.Period
  ( Period
  , periodContains
  , periodStart
  )
import HKernel.Plan.Journal (PlanJournal)

data EnvelopeCycleComparisonSide
  = CurrentEnvelopeCycle
  | BaselineEnvelopeCycle
  deriving (Eq, Show)

data HouseholdEnvelopeCycleComparisonError
  = EnvelopeCycleComparisonPeriodOrderInvalid Period Period
  | EnvelopeCycleComparisonCurrentObservationOutsidePeriod Day Period
  | EnvelopeCycleComparisonAlignedBaselineOutsidePeriod Day Period
  | EnvelopeCycleComparisonStockObservationError
      EnvelopeCycleComparisonSide
      HouseholdEnvelopeError
  | EnvelopeCycleComparisonConsumptionError
      EnvelopeCycleComparisonSide
      EnvelopeConsumptionError
  | EnvelopeCycleComparisonFulfillmentError
      EnvelopeCycleComparisonSide
      EnvelopeFulfillmentError
  deriving (Eq, Show)

-- | One Envelope axis under aligned cycle comparison.
--
-- Bounded activity is stored as the original typed gross evidence. Position
-- values are snapshots. Differences are derived accessors so current/baseline
-- remain the sole stored authority.
data EnvelopeCycleComparisonLine = EnvelopeCycleComparisonLine
  { envelopeCycleComparisonId          :: EnvelopeId
  , envelopeCycleCurrentConsumption    :: ConsumptionAmounts
  , envelopeCycleBaselineConsumption   :: ConsumptionAmounts
  , envelopeCycleCurrentFulfillment    :: FulfillmentAmounts
  , envelopeCycleBaselineFulfillment   :: FulfillmentAmounts
  , envelopeCycleCurrentEntitlement    :: Balance
  , envelopeCycleBaselineEntitlement   :: Balance
  , envelopeCycleCurrentRemaining      :: Balance
  , envelopeCycleBaselineRemaining     :: Balance
  , envelopeCycleCurrentCommitment     :: Balance
  , envelopeCycleBaselineCommitment    :: Balance
  , envelopeCycleCurrentHeadroom       :: Balance
  , envelopeCycleBaselineHeadroom      :: Balance
  } deriving (Eq, Show)

-- | Two explicit Period observations aligned by elapsed day count.
data HouseholdEnvelopeCycleComparison = HouseholdEnvelopeCycleComparison
  { householdEnvelopeCycleComparisonCurrentPeriod    :: Period
  , householdEnvelopeCycleComparisonBaselinePeriod   :: Period
  , householdEnvelopeCycleComparisonCurrentThrough   :: Day
  , householdEnvelopeCycleComparisonBaselineThrough  :: Day
  , householdEnvelopeCycleComparisonLines            :: [EnvelopeCycleComparisonLine]
  } deriving (Eq, Show)

-- | Compare the current cycle against an earlier cycle at the same elapsed day.
--
-- The caller supplies the Envelope axis. Current policy may therefore select a
-- presentation axis without becoming historical routing authority. Historical
-- activity meaning still comes from the admitted routing histories at each
-- evidence date.
observeAlignedHouseholdEnvelopeCycleComparison
  :: Day
  -> Period
  -> Period
  -> [EnvelopeId]
  -> ActualJournal
  -> PlanJournal
  -> ExpenseRoutingHistory
  -> FulfillmentRoutingHistory
  -> EnvelopeEntitlementHistory
  -> Either (NonEmpty HouseholdEnvelopeCycleComparisonError) HouseholdEnvelopeCycleComparison
observeAlignedHouseholdEnvelopeCycleComparison currentThrough currentPeriod baselinePeriod envelopes actual plans expenseRouting fulfillmentRouting entitlementHistory
  | periodStart baselinePeriod >= periodStart currentPeriod =
      Left (EnvelopeCycleComparisonPeriodOrderInvalid baselinePeriod currentPeriod NonEmpty.:| [])
  | not (periodContains currentPeriod currentThrough) =
      Left (EnvelopeCycleComparisonCurrentObservationOutsidePeriod currentThrough currentPeriod NonEmpty.:| [])
  | not (periodContains baselinePeriod baselineThrough) =
      Left (EnvelopeCycleComparisonAlignedBaselineOutsidePeriod baselineThrough baselinePeriod NonEmpty.:| [])
  | otherwise = do
      currentStock <- mapLeft
        (fmap (EnvelopeCycleComparisonStockObservationError CurrentEnvelopeCycle))
        (deriveHouseholdEnvelopeObservation
          currentThrough currentPeriod actual plans expenseRouting fulfillmentRouting entitlementHistory)
      baselineStock <- mapLeft
        (fmap (EnvelopeCycleComparisonStockObservationError BaselineEnvelopeCycle))
        (deriveHouseholdEnvelopeObservation
          baselineThrough baselinePeriod actual plans expenseRouting fulfillmentRouting entitlementHistory)
      currentConsumption <- mapLeft
        (NonEmpty.singleton . EnvelopeCycleComparisonConsumptionError CurrentEnvelopeCycle)
        (observeEnvelopeConsumption
          currentPeriod currentThrough actual (expenseRoutingResolver expenseRouting))
      baselineConsumption <- mapLeft
        (NonEmpty.singleton . EnvelopeCycleComparisonConsumptionError BaselineEnvelopeCycle)
        (observeEnvelopeConsumption
          baselinePeriod baselineThrough actual (expenseRoutingResolver expenseRouting))
      currentFulfillment <- mapLeft
        (fmap (EnvelopeCycleComparisonFulfillmentError CurrentEnvelopeCycle))
        (observeEnvelopeFulfillment
          currentPeriod currentThrough plans actual fulfillmentRouting)
      baselineFulfillment <- mapLeft
        (fmap (EnvelopeCycleComparisonFulfillmentError BaselineEnvelopeCycle))
        (observeEnvelopeFulfillment
          baselinePeriod baselineThrough plans actual fulfillmentRouting)
      pure HouseholdEnvelopeCycleComparison
        { householdEnvelopeCycleComparisonCurrentPeriod = currentPeriod
        , householdEnvelopeCycleComparisonBaselinePeriod = baselinePeriod
        , householdEnvelopeCycleComparisonCurrentThrough = currentThrough
        , householdEnvelopeCycleComparisonBaselineThrough = baselineThrough
        , householdEnvelopeCycleComparisonLines = map (lineFor
            currentStock baselineStock
            currentConsumption baselineConsumption
            currentFulfillment baselineFulfillment) envelopes
        }
  where
    elapsedDays = diffDays currentThrough (periodStart currentPeriod)
    baselineThrough = addDays elapsedDays (periodStart baselinePeriod)

lineFor
  :: HouseholdEnvelopeObservation
  -> HouseholdEnvelopeObservation
  -> EnvelopeConsumption
  -> EnvelopeConsumption
  -> EnvelopeFulfillment
  -> EnvelopeFulfillment
  -> EnvelopeId
  -> EnvelopeCycleComparisonLine
lineFor currentStock baselineStock currentConsumption baselineConsumption currentFulfillment baselineFulfillment envelope =
  EnvelopeCycleComparisonLine
    { envelopeCycleComparisonId = envelope
    , envelopeCycleCurrentConsumption =
        envelopeConsumptionFor envelope currentConsumption
    , envelopeCycleBaselineConsumption =
        envelopeConsumptionFor envelope baselineConsumption
    , envelopeCycleCurrentFulfillment =
        envelopeFulfillmentFor envelope currentFulfillment
    , envelopeCycleBaselineFulfillment =
        envelopeFulfillmentFor envelope baselineFulfillment
    , envelopeCycleCurrentEntitlement =
        envelopeEntitlementBalance envelope (householdEnvelopeEntitlement currentStock)
    , envelopeCycleBaselineEntitlement =
        envelopeEntitlementBalance envelope (householdEnvelopeEntitlement baselineStock)
    , envelopeCycleCurrentRemaining =
        envelopeRemainingFor envelope (householdEnvelopeRemaining currentStock)
    , envelopeCycleBaselineRemaining =
        envelopeRemainingFor envelope (householdEnvelopeRemaining baselineStock)
    , envelopeCycleCurrentCommitment =
        envelopeCommitmentFor envelope (householdEnvelopeCommitment currentStock)
    , envelopeCycleBaselineCommitment =
        envelopeCommitmentFor envelope (householdEnvelopeCommitment baselineStock)
    , envelopeCycleCurrentHeadroom =
        envelopeHeadroomFor envelope (householdEnvelopeHeadroom currentStock)
    , envelopeCycleBaselineHeadroom =
        envelopeHeadroomFor envelope (householdEnvelopeHeadroom baselineStock)
    }

envelopeCycleConsumptionNetDifference :: EnvelopeCycleComparisonLine -> Balance
envelopeCycleConsumptionNetDifference line =
  consumptionNet (envelopeCycleCurrentConsumption line)
    `subtractBalance` consumptionNet (envelopeCycleBaselineConsumption line)

envelopeCycleFulfillmentNetDifference :: EnvelopeCycleComparisonLine -> Balance
envelopeCycleFulfillmentNetDifference line =
  fulfillmentNet (envelopeCycleCurrentFulfillment line)
    `subtractBalance` fulfillmentNet (envelopeCycleBaselineFulfillment line)

envelopeCycleEntitlementDifference :: EnvelopeCycleComparisonLine -> Balance
envelopeCycleEntitlementDifference line =
  envelopeCycleCurrentEntitlement line
    `subtractBalance` envelopeCycleBaselineEntitlement line

envelopeCycleRemainingDifference :: EnvelopeCycleComparisonLine -> Balance
envelopeCycleRemainingDifference line =
  envelopeCycleCurrentRemaining line
    `subtractBalance` envelopeCycleBaselineRemaining line

envelopeCycleCommitmentDifference :: EnvelopeCycleComparisonLine -> Balance
envelopeCycleCommitmentDifference line =
  envelopeCycleCurrentCommitment line
    `subtractBalance` envelopeCycleBaselineCommitment line

envelopeCycleHeadroomDifference :: EnvelopeCycleComparisonLine -> Balance
envelopeCycleHeadroomDifference line =
  envelopeCycleCurrentHeadroom line
    `subtractBalance` envelopeCycleBaselineHeadroom line

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value
