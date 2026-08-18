-- | Question-specific arithmetic witness for one admitted Household Envelope
-- observation.
--
-- This module does not read canonical sources or invent provenance edges. It
-- preserves the already typed evidence needed to answer two concrete questions:
-- why is Remaining this value, and why is Headroom this value?
module HKernel.Household.EnvelopeExplanation
  ( HouseholdEnvelopeExplanation
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

import Data.Time.Calendar (Day)
import HKernel.Envelope.Commitment
  ( envelopeCommitmentFor )
import HKernel.Envelope.Consumption
  ( consumptionCharges
  , consumptionNet
  , consumptionRefunds
  , envelopeConsumptionFor
  )
import HKernel.Envelope.Entitlement
  ( envelopeEntitlementBalance )
import HKernel.Envelope.Fulfillment
  ( envelopeFulfillmentFor
  , fulfillmentApplied
  , fulfillmentNet
  , fulfillmentReversed
  )
import HKernel.Envelope.Headroom (envelopeHeadroomFor)
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Envelope.Remaining (envelopeRemainingFor)
import HKernel.Household.EnvelopeObservation
  ( HouseholdEnvelopeObservation
  , householdEnvelopeCommitment
  , householdEnvelopeConsumption
  , householdEnvelopeEntitlement
  , householdEnvelopeFulfillment
  , householdEnvelopeHeadroom
  , householdEnvelopeObservationObservedThrough
  , householdEnvelopeObservationPeriod
  , householdEnvelopeRemaining
  )
import HKernel.Money (Balance)
import HKernel.Period (Period)

-- | Complete arithmetic witness for one Envelope in one Household observation.
-- Gross evidence remains alongside net coordinates so zero-net activity does not
-- disappear from the explanation.
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
  , envelopeExplanationHeadroom             :: Balance
  } deriving (Eq, Show)

-- | Explanation for the current presentation Envelope order at one observation.
-- The order is supplied by the Household policy owner; explanation does not
-- decide current membership from historical evidence.
data HouseholdEnvelopeExplanation = HouseholdEnvelopeExplanation
  { householdEnvelopeExplanationPeriod          :: Period
  , householdEnvelopeExplanationObservedThrough :: Day
  , householdEnvelopeExplanationLines           :: [EnvelopeExplanationLine]
  } deriving (Eq, Show)

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
