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
  , EnvelopeChangeBaseline(..)
  , ResolvedEnvelopeChangeBaseline
  , EnvelopeChangeBaselineError(..)
  , resolveEnvelopeChangeBaseline
  , resolvedEnvelopeChangeBaseline
  , resolvedEnvelopeChangeBaselineDay
  , HouseholdEnvelopeChangeError(..)
  , HouseholdEnvelopeChange
  , EnvelopeChangeLine
  , observeHouseholdEnvelopeChange
  , householdEnvelopeChangePeriod
  , householdEnvelopeChangeFrom
  , householdEnvelopeChangeThrough
  , householdEnvelopeChangeLines
  , envelopeChangeId
  , envelopeChangeEntitlement
  , envelopeChangeConsumptionCharges
  , envelopeChangeConsumptionRefunds
  , envelopeChangeConsumptionNet
  , envelopeChangeFulfillmentApplied
  , envelopeChangeFulfillmentReversed
  , envelopeChangeFulfillmentNet
  , envelopeChangeRemaining
  , envelopeChangeCommitment
  , envelopeChangeHeadroom
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import Data.Time.Calendar (Day, addDays)
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
import HKernel.Money (Balance, Commodity, subtractBalance)
import HKernel.Period
  ( Period
  , periodContains
  , periodStart
  )
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

-- | Semantic selection of the earlier observation used by one same-Period
-- Envelope Change. Selecting a baseline is a temporal question, not arithmetic.
data EnvelopeChangeBaseline
  = PreviousObservation
  | PreviousDay
  | CycleStart
  | ExplicitDay Day
  deriving (Eq, Show)

-- | One baseline request after its temporal coordinate has been validated.
data ResolvedEnvelopeChangeBaseline = ResolvedEnvelopeChangeBaseline
  { resolvedEnvelopeChangeBaseline    :: EnvelopeChangeBaseline
  , resolvedEnvelopeChangeBaselineDay :: Day
  } deriving (Eq, Show)

-- | Baseline requests fail closed instead of silently changing the meaning of
-- Change. In particular, previous observation is context supplied by the caller
-- and is never inferred from accounting evidence.
data EnvelopeChangeBaselineError
  = EnvelopeChangeThroughOutsidePeriod Day Period
  | EnvelopeChangePreviousObservationUnavailable
  | EnvelopeChangePreviousObservationNotBefore Day Day
  | EnvelopeChangeBaselineDayOutsidePeriod EnvelopeChangeBaseline Day Period
  | EnvelopeChangeBaselineDayAfterObservation EnvelopeChangeBaseline Day Day
  deriving (Eq, Show)

-- | Resolve the earlier day for one same-Period Change without reading sources.
--
-- The optional previous observation day belongs to observation context, such as
-- a TUI session or explicit observation history. 'ExplicitDay' may equal the
-- later day for an intentional zero-length comparison. 'PreviousObservation'
-- must be strictly earlier because "previous" itself carries temporal meaning.
resolveEnvelopeChangeBaseline
  :: Period
  -> Day
  -> Maybe Day
  -> EnvelopeChangeBaseline
  -> Either EnvelopeChangeBaselineError ResolvedEnvelopeChangeBaseline
resolveEnvelopeChangeBaseline period through previousObservation baseline
  | not (periodContains period through) =
      Left (EnvelopeChangeThroughOutsidePeriod through period)
  | otherwise = case baseline of
      PreviousObservation -> case previousObservation of
        Nothing -> Left EnvelopeChangePreviousObservationUnavailable
        Just day -> do
          validateInside PreviousObservation day
          if day < through
            then resolved PreviousObservation day
            else Left (EnvelopeChangePreviousObservationNotBefore day through)
      PreviousDay -> do
        let day = addDays (-1) through
        validateInside PreviousDay day
        resolved PreviousDay day
      CycleStart ->
        resolved CycleStart (periodStart period)
      ExplicitDay day -> do
        validateInside baseline day
        if day <= through
          then resolved baseline day
          else Left (EnvelopeChangeBaselineDayAfterObservation baseline day through)
  where
    validateInside requested day
      | periodContains period day = Right ()
      | otherwise = Left
          (EnvelopeChangeBaselineDayOutsidePeriod requested day period)

    resolved requested day = Right ResolvedEnvelopeChangeBaseline
      { resolvedEnvelopeChangeBaseline = requested
      , resolvedEnvelopeChangeBaselineDay = day
      }

-- | Reasons two typed Envelope explanations do not denote one comparable
-- change coordinate. Change never silently crosses a period boundary, reverses
-- time, or treats a different current Envelope set as zero-valued evidence.
data HouseholdEnvelopeChangeError
  = HouseholdEnvelopeChangePeriodMismatch Period Period
  | HouseholdEnvelopeChangeObservationOrderInvalid Day Day
  | HouseholdEnvelopeChangeEnvelopeOrderMismatch [EnvelopeId] [EnvelopeId]
  deriving (Eq, Show)

-- | Fieldwise change for one Envelope. Every coordinate is @later - earlier@.
-- Gross evidence changes remain first-class beside net and final-value changes.
data EnvelopeChangeLine = EnvelopeChangeLine
  { envelopeChangeId                  :: EnvelopeId
  , envelopeChangeEntitlement         :: Balance
  , envelopeChangeConsumptionCharges  :: Balance
  , envelopeChangeConsumptionRefunds  :: Balance
  , envelopeChangeConsumptionNet      :: Balance
  , envelopeChangeFulfillmentApplied  :: Balance
  , envelopeChangeFulfillmentReversed :: Balance
  , envelopeChangeFulfillmentNet      :: Balance
  , envelopeChangeRemaining           :: Balance
  , envelopeChangeCommitment          :: Balance
  , envelopeChangeHeadroom            :: Balance
  } deriving (Eq, Show)

-- | First-class change between two comparable typed observations.
data HouseholdEnvelopeChange = HouseholdEnvelopeChange
  { householdEnvelopeChangePeriod  :: Period
  , householdEnvelopeChangeFrom    :: Day
  , householdEnvelopeChangeThrough :: Day
  , householdEnvelopeChangeLines   :: [EnvelopeChangeLine]
  } deriving (Eq, Show)

-- | Compare two explanations without rereading source evidence.
--
-- This deliberately requires the same period and current Envelope order. A
-- policy or period change is itself a different question and must not be hidden
-- by treating a missing coordinate as zero.
observeHouseholdEnvelopeChange
  :: HouseholdEnvelopeExplanation
  -> HouseholdEnvelopeExplanation
  -> Either HouseholdEnvelopeChangeError HouseholdEnvelopeChange
observeHouseholdEnvelopeChange earlier later
  | earlierPeriod /= laterPeriod =
      Left (HouseholdEnvelopeChangePeriodMismatch earlierPeriod laterPeriod)
  | earlierDay > laterDay =
      Left (HouseholdEnvelopeChangeObservationOrderInvalid earlierDay laterDay)
  | earlierIds /= laterIds =
      Left (HouseholdEnvelopeChangeEnvelopeOrderMismatch earlierIds laterIds)
  | otherwise = Right HouseholdEnvelopeChange
      { householdEnvelopeChangePeriod = earlierPeriod
      , householdEnvelopeChangeFrom = earlierDay
      , householdEnvelopeChangeThrough = laterDay
      , householdEnvelopeChangeLines =
          zipWith changeLine earlierLines laterLines
      }
  where
    earlierPeriod = householdEnvelopeExplanationPeriod earlier
    laterPeriod = householdEnvelopeExplanationPeriod later
    earlierDay = householdEnvelopeExplanationObservedThrough earlier
    laterDay = householdEnvelopeExplanationObservedThrough later
    earlierLines = householdEnvelopeExplanationLines earlier
    laterLines = householdEnvelopeExplanationLines later
    earlierIds = map envelopeExplanationId earlierLines
    laterIds = map envelopeExplanationId laterLines

    changeLine before after = EnvelopeChangeLine
      { envelopeChangeId = envelopeExplanationId after
      , envelopeChangeEntitlement = delta
          envelopeExplanationEntitlement before after
      , envelopeChangeConsumptionCharges = delta
          envelopeExplanationConsumptionCharges before after
      , envelopeChangeConsumptionRefunds = delta
          envelopeExplanationConsumptionRefunds before after
      , envelopeChangeConsumptionNet = delta
          envelopeExplanationConsumptionNet before after
      , envelopeChangeFulfillmentApplied = delta
          envelopeExplanationFulfillmentApplied before after
      , envelopeChangeFulfillmentReversed = delta
          envelopeExplanationFulfillmentReversed before after
      , envelopeChangeFulfillmentNet = delta
          envelopeExplanationFulfillmentNet before after
      , envelopeChangeRemaining = delta
          envelopeExplanationRemaining before after
      , envelopeChangeCommitment = delta
          envelopeExplanationCommitment before after
      , envelopeChangeHeadroom = delta
          envelopeExplanationHeadroom before after
      }

    delta accessor before after =
      accessor after `subtractBalance` accessor before

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
