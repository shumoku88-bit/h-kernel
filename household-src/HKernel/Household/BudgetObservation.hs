-- | Stable composition of admitted household Budget movements into one aligned
-- domain observation.
--
-- Stable Household policy is admitted by 'HKernel.Household.Config' and checked
-- against the canonical AccountRegistry before it reaches this module. This
-- adapter owns only the interpretation of ordered movements as native Expense
-- Consumption plus compatibility Entitlement and Remaining calculations.
module HKernel.Household.BudgetObservation
  ( HouseholdBudgetObservation
  , householdBudgetObservationPolicy
  , householdEnvelopeConsumption
  , householdBudgetEntitlement
  , householdBudgetRemaining
  , HouseholdBudgetError(..)
  , deriveHouseholdBudgetObservation
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day)
import HKernel.Account (Account)
import HKernel.Actual.Journal (ActualJournal)
import HKernel.Budget
  ( BudgetChange
  , BudgetChangeError
  , BudgetCycle
  , BudgetCycleError
  , BudgetObservation
  , BudgetObservationError
  , EnvelopeId
  , budgetCycleContains
  , budgetObservationObservedThrough
  , mkBudgetChange
  , mkBudgetCycle
  , mkBudgetObservation
  )
import HKernel.Budget.Entitlement
  ( BudgetEntitlement
  , EntitlementError
  , calculateBudgetEntitlement
  )
import HKernel.Budget.History
  ( BudgetHistory
  , BudgetHistoryError
  , mkBudgetHistory
  )
import HKernel.Budget.Policy
  ( AccountValidatedBudgetPolicy
  , accountValidatedBudgetPolicy
  , budgetPolicyEnvelopeForExpense
  )
import HKernel.Budget.Remaining
  ( BudgetRemaining
  , RemainingError
  , calculateBudgetRemainingFromEnvelopeConsumption
  )
import HKernel.Envelope.Consumption
  ( EnvelopeConsumption
  , EnvelopeConsumptionError
  , observeEnvelopeConsumption
  )
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , ExpenseRouteResolver(..)
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Policy
  ( AccountValidatedHouseholdPolicy
  , HouseholdPolicy
  , accountValidatedHouseholdBudgetPolicy
  , accountValidatedHouseholdPolicy
  , householdAllocationEnvelopes
  , householdBudgetPolicy
  )
import HKernel.Money (negateAmount)
import HKernel.Period (Period, periodEndExclusive, periodStart)

-- | Aligned household budget results and the exact validated policy that
-- produced them.
--
-- Legacy 'BudgetConsumption' is deliberately absent: Actual Expense ownership
-- has migrated to 'EnvelopeConsumption'. Entitlement and Remaining are retained
-- as compatibility surfaces until their Envelope-native owners are connected to
-- production Household sources.
data HouseholdBudgetObservation = HouseholdBudgetObservation
  { householdBudgetObservationPolicy :: HouseholdPolicy
  , householdEnvelopeConsumption     :: EnvelopeConsumption
  , householdBudgetEntitlement       :: BudgetEntitlement
  , householdBudgetRemaining         :: BudgetRemaining
  } deriving (Eq, Show)

data HouseholdBudgetError
  = HouseholdBudgetCycleError BudgetCycleError
  | HouseholdBudgetObservationError BudgetObservationError
  | HouseholdEnvelopeConsumptionError EnvelopeConsumptionError
  | HouseholdBudgetChangeError Day BudgetChangeError
  | HouseholdBudgetHistoryError BudgetHistoryError
  | HouseholdBudgetEntitlementError EntitlementError
  | HouseholdBudgetRemainingError RemainingError
  deriving (Eq, Show)

-- | Admitted evidence required by the aligned domain calculations.
data HouseholdBudgetEvidence = HouseholdBudgetEvidence
  { householdBudgetEvidenceObservation :: BudgetObservation
  , householdBudgetEvidencePeriod      :: Period
  , householdBudgetEvidencePolicy      :: AccountValidatedHouseholdPolicy
  , householdBudgetEvidenceHistory     :: BudgetHistory
  }

-- | Derive one aligned point-in-time household budget observation from ordered
-- movement facts and one already validated Household policy.
deriveHouseholdBudgetObservation
  :: Day
  -> Period
  -> ActualJournal
  -> AccountValidatedHouseholdPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetObservation
deriveHouseholdBudgetObservation observedThrough period actualJournal policy movements = do
  evidence <- admitHouseholdBudgetEvidence
    observedThrough period policy movements
  calculateHouseholdBudgetObservation actualJournal evidence

admitHouseholdBudgetEvidence
  :: Day
  -> Period
  -> AccountValidatedHouseholdPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetEvidence
admitHouseholdBudgetEvidence observedThrough period validatedPolicy movements = do
  budgetCycle <- singleLeft HouseholdBudgetCycleError
    (mkBudgetCycle (periodStart period) (periodEndExclusive period))
  observation <- singleLeft HouseholdBudgetObservationError
    (mkBudgetObservation budgetCycle observedThrough)
  changes <- fmap concat
    (traverse
      (budgetChangesForMovement budgetCycle
        (householdAllocationEnvelopes policy))
      movements)
  history <- mapLeft (fmap HouseholdBudgetHistoryError)
    (mkBudgetHistory changes)
  Right HouseholdBudgetEvidence
    { householdBudgetEvidenceObservation = observation
    , householdBudgetEvidencePeriod = period
    , householdBudgetEvidencePolicy = validatedPolicy
    , householdBudgetEvidenceHistory = history
    }
  where
    policy = accountValidatedHouseholdPolicy validatedPolicy

calculateHouseholdBudgetObservation
  :: ActualJournal
  -> HouseholdBudgetEvidence
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetObservation
calculateHouseholdBudgetObservation actualJournal evidence = do
  envelopeConsumption <- singleLeft HouseholdEnvelopeConsumptionError
    (observeEnvelopeConsumption period observedThrough actualJournal
      (legacyStaticExpenseRouteResolver validatedBudgetPolicy))
  entitlement <- mapLeft (fmap HouseholdBudgetEntitlementError)
    (calculateBudgetEntitlement observation budgetPolicy history)
  remaining <- mapLeft (fmap HouseholdBudgetRemainingError)
    (calculateBudgetRemainingFromEnvelopeConsumption
      entitlement envelopeConsumption)
  Right HouseholdBudgetObservation
    { householdBudgetObservationPolicy = policy
    , householdEnvelopeConsumption = envelopeConsumption
    , householdBudgetEntitlement = entitlement
    , householdBudgetRemaining = remaining
    }
  where
    observation = householdBudgetEvidenceObservation evidence
    period = householdBudgetEvidencePeriod evidence
    observedThrough = budgetObservationObservedThrough observation
    validatedPolicy = householdBudgetEvidencePolicy evidence
    policy = accountValidatedHouseholdPolicy validatedPolicy
    budgetPolicy = householdBudgetPolicy policy
    validatedBudgetPolicy =
      accountValidatedHouseholdBudgetPolicy validatedPolicy
    history = householdBudgetEvidenceHistory evidence

-- | Adapt the current static 'BudgetPolicy' into the native Expense route
-- resolver while production @expense_routing.tsv@ is not connected yet.
--
-- Static compatibility semantics ignore transaction dates and route exclusively
-- through Account-to-Envelope policy membership. 'NotEnvelopeManaged' is never
-- invented; unmapped Expense Accounts remain 'Nothing' (unrouted).
legacyStaticExpenseRouteResolver
  :: AccountValidatedBudgetPolicy
  -> ExpenseRouteResolver
legacyStaticExpenseRouteResolver validatedPolicy =
  ExpenseRouteResolver (\_day account ->
    case budgetPolicyEnvelopeForExpense account policy of
      Just envelope -> Just (ManagedByEnvelope envelope)
      Nothing       -> Nothing)
  where
    policy = accountValidatedBudgetPolicy validatedPolicy

budgetChangesForMovement
  :: BudgetCycle
  -> Map.Map Account EnvelopeId
  -> HouseholdBudgetMovement
  -> Either (NonEmpty HouseholdBudgetError) [BudgetChange]
budgetChangesForMovement budgetCycle envelopeByAccount movement
  | not (budgetCycleContains budgetCycle day) = Right []
  | otherwise = traverse changeFor touchedEnvelopes
  where
    day = householdBudgetMovementDate movement
    fromAccount = householdBudgetMovementFrom movement
    toAccount = householdBudgetMovementTo movement
    amount = householdBudgetMovementAmount movement
    note = householdBudgetMovementMemo movement
    touchedEnvelopes =
      [ (account, envelope)
      | (account, envelope) <- Map.toAscList envelopeByAccount
      , fromAccount == account || toAccount == account
      ]
    changeFor (account, envelope) =
      singleLeft (HouseholdBudgetChangeError day)
        (mkBudgetChange day budgetCycle envelope (signedAmount account) note)
    signedAmount account
      | toAccount == account = amount
      | otherwise = negateAmount amount

singleLeft
  :: (error -> HouseholdBudgetError)
  -> Either error value
  -> Either (NonEmpty HouseholdBudgetError) value
singleLeft wrap = mapLeft (NonEmpty.singleton . wrap)

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value
