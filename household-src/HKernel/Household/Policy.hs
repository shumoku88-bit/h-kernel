-- | Stable household policy layered on independently admitted current Envelope,
-- current Expense assignment, and Backing owners.
module HKernel.Household.Policy
  ( HouseholdCyclePolicy
  , incomeAnchorCyclePolicy
  , householdCycleIncomeAccount
  , HouseholdEnvelopeCoordinates
  , defineHouseholdEnvelopeCoordinates
  , householdEnvelopeCoordinateId
  , householdEnvelopeAllocationAccount
  , HouseholdPolicy
  , HouseholdPolicyError(..)
  , mkHouseholdPolicy
  , withHouseholdAccountPolicy
  , householdPolicyAccountPolicy
  , householdPolicyCycle
  , householdEnvelopePolicy
  , householdBackingPolicy
  , householdCurrentExpenseAssignments
  , householdEnvelopeOrder
  , householdAllocationEnvelopes
  , householdUnassignedBudgetAccounts
  , HouseholdPolicyAccountError(..)
  , validateHouseholdPolicyAccounts
  ) where

import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import HKernel.Account
  ( Account
  , AccountRegistry
  , AccountType(..)
  , declaredAccountType
  , lookupAccountDeclaration
  )
import HKernel.Backing.Policy
  ( BackingPolicy
  , BackingPolicyAccountError
  , validateBackingPolicyAccounts
  )
import HKernel.Envelope
  ( CurrentEnvelopePolicy
  , CurrentExpenseAssignments
  , CurrentExpenseAssignmentsReferenceError
  , currentEnvelopePolicyDefinitions
  , envelopeDefinitionId
  , validateCurrentExpenseAssignments
  )
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Household.AccountProfile (HouseholdAccountPolicy)

newtype HouseholdCyclePolicy = IncomeAnchorCyclePolicy
  { householdCycleIncomeAccount :: Account
  } deriving (Eq, Show)

incomeAnchorCyclePolicy :: Account -> HouseholdCyclePolicy
incomeAnchorCyclePolicy = IncomeAnchorCyclePolicy

-- | Current canonical allocation coordinates for one Envelope. Historical
-- @plan-destination-accounts@ syntax is a physical shared-source compatibility
-- coordinate owned at Config admission and is deliberately not Household policy
-- state. Plan-to-Envelope intent belongs to stable PlanId fulfillment routing.
data HouseholdEnvelopeCoordinates = HouseholdEnvelopeCoordinates
  { householdEnvelopeCoordinateId      :: EnvelopeId
  , householdEnvelopeAllocationAccount :: Account
  } deriving (Eq, Show)

defineHouseholdEnvelopeCoordinates
  :: EnvelopeId -> Account -> HouseholdEnvelopeCoordinates
defineHouseholdEnvelopeCoordinates = HouseholdEnvelopeCoordinates

data HouseholdPolicyError
  = DuplicateHouseholdEnvelopeCoordinates EnvelopeId
  | HouseholdCoordinatesReferenceUnknownEnvelope EnvelopeId
  | HouseholdEnvelopeMissingCoordinates EnvelopeId
  | DuplicateAllocationAccount Account EnvelopeId EnvelopeId
  | HouseholdPolicyHasNoUnassignedBudgetAccounts
  | DuplicateUnassignedBudgetAccount Account
  | AllocationAccountAlsoUnassigned Account EnvelopeId
  deriving (Eq, Show)

data HouseholdPolicy = HouseholdPolicy
  { householdPolicyCycle                 :: HouseholdCyclePolicy
  , householdEnvelopePolicy              :: CurrentEnvelopePolicy
  , householdBackingPolicy               :: BackingPolicy
  , householdCurrentExpenseAssignments   :: CurrentExpenseAssignments
  , householdEnvelopeOrder               :: [EnvelopeId]
  , householdAllocationEnvelopes         :: Map Account EnvelopeId
  , householdUnassignedBudgetAccounts    :: Set Account
  , householdPolicyAccountPolicy         :: Maybe HouseholdAccountPolicy
  } deriving (Eq, Show)

withHouseholdAccountPolicy
  :: Maybe HouseholdAccountPolicy -> HouseholdPolicy -> HouseholdPolicy
withHouseholdAccountPolicy accountPolicy policy =
  policy { householdPolicyAccountPolicy = accountPolicy }

mkHouseholdPolicy
  :: HouseholdCyclePolicy
  -> CurrentEnvelopePolicy
  -> BackingPolicy
  -> CurrentExpenseAssignments
  -> [HouseholdEnvelopeCoordinates]
  -> [Account]
  -> Either (NonEmpty HouseholdPolicyError) HouseholdPolicy
mkHouseholdPolicy cyclePolicy envelopePolicy backingPolicy currentExpenses coordinates unassignedAccounts =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right HouseholdPolicy
      { householdPolicyCycle = cyclePolicy
      , householdEnvelopePolicy = envelopePolicy
      , householdBackingPolicy = backingPolicy
      , householdCurrentExpenseAssignments = currentExpenses
      , householdEnvelopeOrder = map householdEnvelopeCoordinateId coordinates
      , householdAllocationEnvelopes = coordinateValues allocationObservation
      , householdUnassignedBudgetAccounts = Set.fromList unassignedAccounts
      , householdPolicyAccountPolicy = Nothing
      }
  where
    definitions = currentEnvelopePolicyDefinitions envelopePolicy
    knownEnvelopes = Set.fromList (map envelopeDefinitionId definitions)
    envelopeCoordinateObservation = observeCoordinates
      [ (householdEnvelopeCoordinateId coordinate, coordinate) | coordinate <- coordinates ]
    canonicalCoordinates = Map.elems (coordinateValues envelopeCoordinateObservation)
    coordinateEnvelopes = Map.keysSet (coordinateValues envelopeCoordinateObservation)
    duplicateCoordinateErrors =
      [ DuplicateHouseholdEnvelopeCoordinates envelope
      | (envelope, _, _) <- coordinateConflicts envelopeCoordinateObservation ]
    unknownCoordinateErrors = map HouseholdCoordinatesReferenceUnknownEnvelope
      (Set.toAscList (Set.difference coordinateEnvelopes knownEnvelopes))
    missingCoordinateErrors = map HouseholdEnvelopeMissingCoordinates
      (Set.toAscList (Set.difference knownEnvelopes coordinateEnvelopes))
    allocationObservation = observeCoordinates
      [ (householdEnvelopeAllocationAccount coordinate, householdEnvelopeCoordinateId coordinate)
      | coordinate <- canonicalCoordinates ]
    allocationErrors =
      [ DuplicateAllocationAccount account firstEnvelope repeatedEnvelope
      | (account, firstEnvelope, repeatedEnvelope) <- coordinateConflicts allocationObservation ]
    unassignedObservation = observeCoordinates [(account, ()) | account <- unassignedAccounts]
    unassignedErrors =
      [ DuplicateUnassignedBudgetAccount account
      | (account, _, _) <- coordinateConflicts unassignedObservation ]
    presenceErrors = [HouseholdPolicyHasNoUnassignedBudgetAccounts | null unassignedAccounts]
    overlapErrors =
      [ AllocationAccountAlsoUnassigned account envelope
      | (account, envelope) <- Map.toAscList (coordinateValues allocationObservation)
      , Set.member account (Set.fromList unassignedAccounts) ]
    errors = duplicateCoordinateErrors ++ unknownCoordinateErrors ++ missingCoordinateErrors
      ++ allocationErrors ++ presenceErrors ++ unassignedErrors ++ overlapErrors

data HouseholdPolicyAccountError
  = HouseholdCurrentExpenseAssignmentsReferenceError CurrentExpenseAssignmentsReferenceError
  | HouseholdBackingPolicyAccountError BackingPolicyAccountError
  | HouseholdCycleIncomeAccountUndeclared Account
  | HouseholdCycleIncomeAccountNotIncome Account AccountType
  | HouseholdAllocationAccountUndeclared EnvelopeId Account
  | HouseholdAllocationAccountNotBudget EnvelopeId Account AccountType
  | HouseholdUnassignedAccountUndeclared Account
  | HouseholdUnassignedAccountNotBudget Account AccountType
  deriving (Eq, Show)

-- | Validate all Account references owned by Household policy. Success is a
-- gate, not a second semantic value: consumers continue to use the admitted
-- 'HouseholdPolicy' that was checked here.
validateHouseholdPolicyAccounts
  :: AccountRegistry
  -> HouseholdPolicy
  -> Either (NonEmpty HouseholdPolicyAccountError) ()
validateHouseholdPolicyAccounts registry policy =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right ()
  where
    currentExpenseErrors = case validateCurrentExpenseAssignments
        registry
        (householdEnvelopePolicy policy)
        (householdCurrentExpenseAssignments policy) of
      Left values ->
        map HouseholdCurrentExpenseAssignmentsReferenceError (NonEmpty.toList values)
      Right _ -> []
    backingErrors = case validateBackingPolicyAccounts registry (householdBackingPolicy policy) of
      Left values -> map HouseholdBackingPolicyAccountError (NonEmpty.toList values)
      Right _ -> []
    cycleAccount = householdCycleIncomeAccount (householdPolicyCycle policy)
    validateCycle = case lookupAccountDeclaration cycleAccount registry of
      Nothing -> [HouseholdCycleIncomeAccountUndeclared cycleAccount]
      Just declaration
        | declaredAccountType declaration == Income -> []
        | otherwise -> [HouseholdCycleIncomeAccountNotIncome cycleAccount (declaredAccountType declaration)]
    validateAllocation (account, envelope) = case lookupAccountDeclaration account registry of
      Nothing -> [HouseholdAllocationAccountUndeclared envelope account]
      Just declaration
        | declaredAccountType declaration == Budget -> []
        | otherwise -> [HouseholdAllocationAccountNotBudget envelope account (declaredAccountType declaration)]
    validateUnassigned account = case lookupAccountDeclaration account registry of
      Nothing -> [HouseholdUnassignedAccountUndeclared account]
      Just declaration
        | declaredAccountType declaration == Budget -> []
        | otherwise -> [HouseholdUnassignedAccountNotBudget account (declaredAccountType declaration)]
    errors = currentExpenseErrors ++ backingErrors ++ validateCycle
      ++ concatMap validateAllocation (Map.toAscList (householdAllocationEnvelopes policy))
      ++ concatMap validateUnassigned (Set.toAscList (householdUnassignedBudgetAccounts policy))

data CoordinateObservation key value = CoordinateObservation
  { coordinateValues :: Map key value
  , coordinateConflicts :: [(key, value, value)]
  }

observeCoordinates :: Ord key => [(key, value)] -> CoordinateObservation key value
observeCoordinates = foldl' observe (CoordinateObservation Map.empty [])
  where
    observe observation (key, value) = case Map.lookup key (coordinateValues observation) of
      Nothing -> observation { coordinateValues = Map.insert key value (coordinateValues observation) }
      Just firstValue -> observation
        { coordinateConflicts = coordinateConflicts observation ++ [(key, firstValue, value)] }
