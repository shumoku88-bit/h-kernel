-- | Pure temporal composition over one already-admitted Household state.
--
-- Canonical admission remains owned by 'HKernel.Household.Application'. This
-- module only selects the time coordinates needed by Envelope Change or aligned
-- cycle comparison and delegates all domain arithmetic to the named observers.
module HKernel.Household.Temporal
  ( HouseholdEnvelopeChangeViewError(..)
  , HouseholdEnvelopeCycleComparisonViewError(..)
  , householdEnvelopeChangeFromBaseline
  , householdEnvelopeAlignedPreviousCycle
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import Data.Time.Calendar (Day)

import HKernel.Household.Application (HouseholdState(..))
import HKernel.Household.Cycle
  ( HouseholdCycleError
  , householdCycleCurrentPeriod
  , householdCyclePreviousPeriod
  , observeHouseholdCycle
  )
import HKernel.Household.EnvelopeHistory
  ( householdExpenseRoutingHistory
  , householdFulfillmentRoutingHistory
  )
import HKernel.Household.EnvelopeObservation
  ( EnvelopeChangeBaseline
  , EnvelopeChangeBaselineError
  , HouseholdEnvelopeChange
  , HouseholdEnvelopeChangeError
  , HouseholdEnvelopeCycleComparison
  , HouseholdEnvelopeCycleComparisonError
  , HouseholdEnvelopeError
  , deriveHouseholdEnvelopeObservation
  , explainHouseholdEnvelope
  , observeAlignedHouseholdEnvelopeCycleComparison
  , observeHouseholdEnvelopeChange
  , resolveEnvelopeChangeBaseline
  , resolvedEnvelopeChangeBaselineDay
  )
import HKernel.Household.Policy
  ( householdEnvelopeOrder
  , householdPolicyCycle
  )

data HouseholdEnvelopeChangeViewError
  = HouseholdEnvelopeChangeCycleUnavailable (NonEmpty HouseholdCycleError)
  | HouseholdEnvelopeChangeBaselineUnavailable EnvelopeChangeBaselineError
  | HouseholdEnvelopeChangeEarlierObservationUnavailable (NonEmpty HouseholdEnvelopeError)
  | HouseholdEnvelopeChangeCurrentObservationUnavailable (NonEmpty HouseholdEnvelopeError)
  | HouseholdEnvelopeChangeRejected HouseholdEnvelopeChangeError
  deriving (Eq, Show)

data HouseholdEnvelopeCycleComparisonViewError
  = HouseholdEnvelopeCycleComparisonCycleUnavailable (NonEmpty HouseholdCycleError)
  | HouseholdEnvelopeCycleComparisonUnavailable
      (NonEmpty HouseholdEnvelopeCycleComparisonError)
  deriving (Eq, Show)

-- | Observe same-Period Envelope Change using one explicit baseline meaning.
--
-- Previous-observation context is supplied separately and is never reconstructed
-- from accounting evidence. Other baseline meanings ignore this optional value.
householdEnvelopeChangeFromBaseline
  :: Day
  -> Maybe Day
  -> EnvelopeChangeBaseline
  -> HouseholdState
  -> Either HouseholdEnvelopeChangeViewError HouseholdEnvelopeChange
householdEnvelopeChangeFromBaseline observation previousObservation baseline state = do
  cycleObservation <- first HouseholdEnvelopeChangeCycleUnavailable
    (observeHouseholdCycle
      observation
      (householdStateActualJournal state)
      (householdStatePlanJournal state)
      (householdPolicyCycle policy))
  let period = householdCycleCurrentPeriod cycleObservation
  resolvedBaseline <- first HouseholdEnvelopeChangeBaselineUnavailable
    (resolveEnvelopeChangeBaseline period observation previousObservation baseline)
  earlierObservation <- first HouseholdEnvelopeChangeEarlierObservationUnavailable
    (deriveHouseholdEnvelopeObservation
      (resolvedEnvelopeChangeBaselineDay resolvedBaseline)
      period
      actual
      plans
      expenseRouting
      fulfillmentRouting
      entitlementHistory)
  currentObservation <- first HouseholdEnvelopeChangeCurrentObservationUnavailable
    (deriveHouseholdEnvelopeObservation
      observation
      period
      actual
      plans
      expenseRouting
      fulfillmentRouting
      entitlementHistory)
  first HouseholdEnvelopeChangeRejected
    (observeHouseholdEnvelopeChange
      (explainHouseholdEnvelope envelopeOrder earlierObservation)
      (explainHouseholdEnvelope envelopeOrder currentObservation))
  where
    actual = householdStateActualJournal state
    plans = householdStatePlanJournal state
    entitlementHistory = householdStateEntitlementHistory state
    history = householdStateEnvelopeHistory state
    expenseRouting = householdExpenseRoutingHistory history
    fulfillmentRouting = householdFulfillmentRoutingHistory history
    policy = householdStatePolicy state
    envelopeOrder = householdEnvelopeOrder policy

-- | Compare the current Envelope cycle with the previous cycle at equal elapsed
-- day count. This is deliberately not implemented as a cross-Period Change.
householdEnvelopeAlignedPreviousCycle
  :: Day
  -> HouseholdState
  -> Either
       HouseholdEnvelopeCycleComparisonViewError
       HouseholdEnvelopeCycleComparison
householdEnvelopeAlignedPreviousCycle observation state = do
  cycleObservation <- first HouseholdEnvelopeCycleComparisonCycleUnavailable
    (observeHouseholdCycle
      observation
      actual
      plans
      (householdPolicyCycle policy))
  first HouseholdEnvelopeCycleComparisonUnavailable
    (observeAlignedHouseholdEnvelopeCycleComparison
      observation
      (householdCycleCurrentPeriod cycleObservation)
      (householdCyclePreviousPeriod cycleObservation)
      (householdEnvelopeOrder policy)
      actual
      plans
      (householdExpenseRoutingHistory history)
      (householdFulfillmentRoutingHistory history)
      (householdStateEntitlementHistory state))
  where
    actual = householdStateActualJournal state
    plans = householdStatePlanJournal state
    history = householdStateEnvelopeHistory state
    policy = householdStatePolicy state
