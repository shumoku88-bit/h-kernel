-- | Temporary adapter from admitted household Budget movements into one aligned
-- domain observation.
--
-- Stable Household policy is admitted by 'HKernel.Household.Config' and checked
-- against the canonical AccountRegistry before it reaches this module. This
-- adapter owns only the interpretation of ordered movements as named
-- Consumption, Entitlement, and Remaining calculations.
module HKernel.Spike.HouseholdConsumption
  ( HouseholdBudgetObservation
  , householdBudgetObservationPolicy
  , householdBudgetConsumption
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
import HKernel.Budget
  ( BudgetChange
  , BudgetChangeError
  , BudgetCycle
  , BudgetCycleError
  , BudgetObservation
  , BudgetObservationError
  , EnvelopeId
  , budgetCycleContains
  , mkBudgetChange
  , mkBudgetCycle
  , mkBudgetObservation
  )
import HKernel.Budget.Consumption
  ( BudgetConsumption
  , ConsumptionError
  , calculateBudgetConsumption
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
import HKernel.Budget.Remaining
  ( BudgetRemaining
  , RemainingError
  , calculateBudgetRemaining
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
import HKernel.Journal (Journal)
import HKernel.Money (negateAmount)
import HKernel.Period (Period, periodEndExclusive, periodStart)

-- | Aligned household budget results and the exact validated policy that
-- produced them.
data HouseholdBudgetObservation = HouseholdBudgetObservation
  { householdBudgetObservationPolicy :: HouseholdPolicy
  , householdBudgetConsumption       :: BudgetConsumption
  , householdBudgetEntitlement       :: BudgetEntitlement
  , householdBudgetRemaining         :: BudgetRemaining
  } deriving (Eq, Show)

data HouseholdBudgetError
  = HouseholdBudgetCycleError BudgetCycleError
  | HouseholdBudgetObservationError BudgetObservationError
  | HouseholdBudgetConsumptionError ConsumptionError
  | HouseholdBudgetChangeError Day BudgetChangeError
  | HouseholdBudgetHistoryError BudgetHistoryError
  | HouseholdBudgetEntitlementError EntitlementError
  | HouseholdBudgetRemainingError RemainingError
  deriving (Eq, Show)

-- | Admitted evidence required by the aligned domain calculations.
data HouseholdBudgetEvidence = HouseholdBudgetEvidence
  { householdBudgetEvidenceObservation :: BudgetObservation
  , householdBudgetEvidencePolicy      :: AccountValidatedHouseholdPolicy
  , householdBudgetEvidenceHistory     :: BudgetHistory
  }

-- | Derive one aligned point-in-time household budget observation from ordered
-- movement facts and one already validated Household policy.
deriveHouseholdBudgetObservation
  :: Day
  -> Period
  -> Journal
  -> AccountValidatedHouseholdPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetObservation
deriveHouseholdBudgetObservation observedThrough period journal policy movements = do
  evidence <- admitHouseholdBudgetEvidence
    observedThrough period policy movements
  calculateHouseholdBudgetObservation journal evidence

admitHouseholdBudgetEvidence
  :: Day
  -> Period
  -> AccountValidatedHouseholdPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetEvidence
admitHouseholdBudgetEvidence observedThrough period validatedPolicy movements = do
  cycle <- singleLeft HouseholdBudgetCycleError
    (mkBudgetCycle (periodStart period) (periodEndExclusive period))
  observation <- singleLeft HouseholdBudgetObservationError
    (mkBudgetObservation cycle observedThrough)
  changes <- fmap concat
    (traverse
      (budgetChangesForMovement cycle
        (householdAllocationEnvelopes policy))
      movements)
  history <- mapLeft (fmap HouseholdBudgetHistoryError)
    (mkBudgetHistory changes)
  Right HouseholdBudgetEvidence
    { householdBudgetEvidenceObservation = observation
    , householdBudgetEvidencePolicy = validatedPolicy
    , householdBudgetEvidenceHistory = history
    }
  where
    policy = accountValidatedHouseholdPolicy validatedPolicy

calculateHouseholdBudgetObservation
  :: Journal
  -> HouseholdBudgetEvidence
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetObservation
calculateHouseholdBudgetObservation journal evidence = do
  consumption <- singleLeft HouseholdBudgetConsumptionError
    (calculateBudgetConsumption observation validatedBudgetPolicy journal)
  entitlement <- mapLeft (fmap HouseholdBudgetEntitlementError)
    (calculateBudgetEntitlement observation budgetPolicy history)
  remaining <- mapLeft (fmap HouseholdBudgetRemainingError)
    (calculateBudgetRemaining entitlement consumption)
  Right HouseholdBudgetObservation
    { householdBudgetObservationPolicy = policy
    , householdBudgetConsumption = consumption
    , householdBudgetEntitlement = entitlement
    , householdBudgetRemaining = remaining
    }
  where
    observation = householdBudgetEvidenceObservation evidence
    validatedPolicy = householdBudgetEvidencePolicy evidence
    policy = accountValidatedHouseholdPolicy validatedPolicy
    budgetPolicy = householdBudgetPolicy policy
    validatedBudgetPolicy =
      accountValidatedHouseholdBudgetPolicy validatedPolicy
    history = householdBudgetEvidenceHistory evidence

budgetChangesForMovement
  :: BudgetCycle
  -> Map.Map Account EnvelopeId
  -> HouseholdBudgetMovement
  -> Either (NonEmpty HouseholdBudgetError) [BudgetChange]
budgetChangesForMovement cycle envelopeByAccount movement
  | not (budgetCycleContains cycle day) = Right []
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
        (mkBudgetChange day cycle envelope (signedAmount account) note)
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
