-- | Exact entitlement derived from admitted budget-change history.
--
-- This module owns the policy-facing calculation after 'BudgetHistory'
-- admission. It selects changes visible through one explicit budget observation,
-- rejects changes whose envelope is not declared by policy, reduces exact
-- amounts at envelope coordinates, and publishes every policy envelope with
-- canonical zero when it has no changes.
module HKernel.Budget.Entitlement
  ( EnvelopeEntitlement
  , envelopeEntitlementEnvelope
  , envelopeEntitlementBalance
  , BudgetEntitlement
  , budgetEntitlementObservation
  , budgetEntitlementCycle
  , budgetEntitlementObservedThrough
  , budgetEntitlementEnvelopes
  , EntitlementError(..)
  , calculateBudgetEntitlement
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day)
import HKernel.Budget
  ( BudgetChange
  , BudgetCycle
  , BudgetObservation
  , EnvelopeId
  , budgetChangeAmount
  , budgetChangeCycle
  , budgetChangeDate
  , budgetChangeEnvelope
  , budgetObservationCycle
  , budgetObservationObservedThrough
  )
import HKernel.Budget.History
  ( BudgetHistory
  , budgetHistoryChanges
  )
import HKernel.Budget.Policy
  ( BudgetPolicy
  , budgetPolicyEnvelopeDefinition
  , budgetPolicyEnvelopeDefinitions
  , envelopeDefinitionId
  )
import HKernel.Money
  ( Balance
  , addBalance
  , emptyBalance
  , singletonBalance
  )

-- | Exact entitlement at one spendable-envelope coordinate.
data EnvelopeEntitlement = EnvelopeEntitlement
  { envelopeEntitlementEnvelope :: EnvelopeId
  , envelopeEntitlementBalance  :: Balance
  } deriving (Eq, Show)

-- | Entitlement facts for one point-in-time budget observation.
--
-- Every policy envelope is present, including envelopes with canonical zero
-- entitlement. Commodity identity remains inside each exact 'Balance'.
data BudgetEntitlement = BudgetEntitlement
  { budgetEntitlementObservation :: BudgetObservation
  , budgetEntitlementEnvelopes    :: [EnvelopeEntitlement]
  } deriving (Eq, Show)

budgetEntitlementCycle :: BudgetEntitlement -> BudgetCycle
budgetEntitlementCycle =
  budgetObservationCycle . budgetEntitlementObservation

budgetEntitlementObservedThrough :: BudgetEntitlement -> Day
budgetEntitlementObservedThrough =
  budgetObservationObservedThrough . budgetEntitlementObservation

-- | A budget change names an envelope that the selected policy does not own.
data EntitlementError
  = EntitlementUnknownEnvelope EnvelopeId
  deriving (Eq, Show)

-- | Derive exact envelope entitlement through one inclusive observation day.
--
-- The calculation has four semantic stages:
--
-- * select changes belonging to the requested cycle and visible through the
--   observation day,
-- * verify that every selected envelope belongs to policy,
-- * reduce exact contributions at envelope coordinates,
-- * publish every policy envelope, including canonical zero entitlement.
calculateBudgetEntitlement
  :: BudgetObservation
  -> BudgetPolicy
  -> BudgetHistory
  -> Either (NonEmpty EntitlementError) BudgetEntitlement
calculateBudgetEntitlement observation policy history =
  publishBudgetEntitlement observation policy
    <$> policyKnownChangesForObservation observation policy history

policyKnownChangesForObservation
  :: BudgetObservation
  -> BudgetPolicy
  -> BudgetHistory
  -> Either (NonEmpty EntitlementError) [BudgetChange]
policyKnownChangesForObservation observation policy history =
  case NonEmpty.nonEmpty entitlementErrors of
    Just errors -> Left errors
    Nothing     -> Right changes
  where
    cycle = budgetObservationCycle observation
    observedThrough = budgetObservationObservedThrough observation
    changes =
      [ change
      | change <- budgetHistoryChanges history
      , budgetChangeCycle change == cycle
      , budgetChangeDate change <= observedThrough
      ]
    entitlementErrors =
      map EntitlementUnknownEnvelope
        (Map.keys (Map.fromList
          [ (envelope, ())
          | change <- changes
          , let envelope = budgetChangeEnvelope change
          , Nothing <- [budgetPolicyEnvelopeDefinition envelope policy]
          ]))

publishBudgetEntitlement
  :: BudgetObservation
  -> BudgetPolicy
  -> [BudgetChange]
  -> BudgetEntitlement
publishBudgetEntitlement observation policy changes = BudgetEntitlement
  { budgetEntitlementObservation = observation
  , budgetEntitlementEnvelopes =
      [ EnvelopeEntitlement envelope
          (Map.findWithDefault emptyBalance envelope entitlementBalances)
      | definition <- budgetPolicyEnvelopeDefinitions policy
      , let envelope = envelopeDefinitionId definition
      ]
  }
  where
    entitlementBalances = contributionBalances changes

contributionBalances :: [BudgetChange] -> Map EnvelopeId Balance
contributionBalances = Map.fromListWith addBalance
  . map (\change ->
      ( budgetChangeEnvelope change
      , singletonBalance (budgetChangeAmount change)
      ))
