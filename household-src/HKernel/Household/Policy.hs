-- | Stable household policy layered on native Envelope and Backing policy.
module HKernel.Household.Policy
  ( HouseholdCyclePolicy
  , incomeAnchorCyclePolicy
  , householdCycleIncomeAccount
  , HouseholdEnvelopeCoordinates
  , defineHouseholdEnvelopeCoordinates
  , householdEnvelopeCoordinateId
  , householdEnvelopeAllocationAccount
  , householdEnvelopePlanDestinationAccounts
  , HouseholdPolicy
  , HouseholdPolicyError(..)
  , mkHouseholdPolicy
  , withHouseholdAccountPolicy
  , householdPolicyAccountPolicy
  , householdPolicyCycle
  , householdEnvelopePolicy
  , householdBackingPolicy
  , householdEnvelopeOrder
  , householdAllocationEnvelopes
  , householdUnassignedBudgetAccounts
  , householdEnvelopeForPlanDestination
  , AccountValidatedHouseholdPolicy
  , accountValidatedHouseholdPolicy
  , accountValidatedHouseholdEnvelopePolicy
  , accountValidatedHouseholdBackingPolicy
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
  ( AccountValidatedCurrentEnvelopePolicy
  , CurrentEnvelopePolicy
  , CurrentEnvelopePolicyAccountError
  , currentEnvelopePolicyDefinitions
  , envelopeDefinitionExpenseAccounts
  , envelopeDefinitionId
  , validateCurrentEnvelopePolicyAccounts
  )
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Household.AccountProfile (HouseholdAccountPolicy)

newtype HouseholdCyclePolicy = IncomeAnchorCyclePolicy
  { householdCycleIncomeAccount :: Account
  } deriving (Eq, Show)

incomeAnchorCyclePolicy :: Account -> HouseholdCyclePolicy
incomeAnchorCyclePolicy = IncomeAnchorCyclePolicy

data HouseholdEnvelopeCoordinates = HouseholdEnvelopeCoordinates
  { householdEnvelopeCoordinateId            :: EnvelopeId
  , householdEnvelopeAllocationAccount       :: Account
  , householdEnvelopePlanDestinationAccounts :: [Account]
  } deriving (Eq, Show)

defineHouseholdEnvelopeCoordinates
  :: EnvelopeId -> Account -> [Account] -> HouseholdEnvelopeCoordinates
defineHouseholdEnvelopeCoordinates = HouseholdEnvelopeCoordinates

data HouseholdPolicyError
  = DuplicateHouseholdEnvelopeCoordinates EnvelopeId
  | HouseholdCoordinatesReferenceUnknownEnvelope EnvelopeId
  | HouseholdEnvelopeMissingCoordinates EnvelopeId
  | DuplicateAllocationAccount Account EnvelopeId EnvelopeId
  | DuplicatePlanDestinationAccount Account EnvelopeId EnvelopeId
  | HouseholdPolicyHasNoUnassignedBudgetAccounts
  | DuplicateUnassignedBudgetAccount Account
  | AllocationAccountAlsoUnassigned Account EnvelopeId
  deriving (Eq, Show)

data HouseholdPolicy = HouseholdPolicy
  { householdPolicyCycle                :: HouseholdCyclePolicy
  , householdEnvelopePolicy             :: CurrentEnvelopePolicy
  , householdBackingPolicy              :: BackingPolicy
  , householdEnvelopeOrder              :: [EnvelopeId]
  , householdAllocationEnvelopes        :: Map Account EnvelopeId
  , householdPlanDestinationEnvelopes   :: Map Account EnvelopeId
  , householdAdditionalPlanDestinations :: Map Account EnvelopeId
  , householdUnassignedBudgetAccounts   :: Set Account
  , householdPolicyAccountPolicy        :: Maybe HouseholdAccountPolicy
  } deriving (Eq, Show)

withHouseholdAccountPolicy
  :: Maybe HouseholdAccountPolicy -> HouseholdPolicy -> HouseholdPolicy
withHouseholdAccountPolicy accountPolicy policy =
  policy { householdPolicyAccountPolicy = accountPolicy }

mkHouseholdPolicy
  :: HouseholdCyclePolicy
  -> CurrentEnvelopePolicy
  -> BackingPolicy
  -> [HouseholdEnvelopeCoordinates]
  -> [Account]
  -> Either (NonEmpty HouseholdPolicyError) HouseholdPolicy
mkHouseholdPolicy cyclePolicy envelopePolicy backingPolicy coordinates unassignedAccounts =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right HouseholdPolicy
      { householdPolicyCycle = cyclePolicy
      , householdEnvelopePolicy = envelopePolicy
      , householdBackingPolicy = backingPolicy
      , householdEnvelopeOrder = map householdEnvelopeCoordinateId coordinates
      , householdAllocationEnvelopes = coordinateValues allocationObservation
      , householdPlanDestinationEnvelopes = coordinateValues planObservation
      , householdAdditionalPlanDestinations = coordinateValues additionalPlanObservation
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
    additionalPlanCoordinates =
      [ (account, householdEnvelopeCoordinateId coordinate)
      | coordinate <- canonicalCoordinates
      , account <- householdEnvelopePlanDestinationAccounts coordinate ]
    additionalPlanObservation = observeAssignments additionalPlanCoordinates
    expensePlanCoordinates =
      [ (account, envelopeDefinitionId definition)
      | definition <- definitions
      , account <- envelopeDefinitionExpenseAccounts definition ]
    allocationPlanCoordinates =
      [ (householdEnvelopeAllocationAccount coordinate, householdEnvelopeCoordinateId coordinate)
      | coordinate <- canonicalCoordinates ]
    planObservation = observeAssignments
      (expensePlanCoordinates ++ allocationPlanCoordinates ++ additionalPlanCoordinates)
    planErrors =
      [ DuplicatePlanDestinationAccount account firstEnvelope repeatedEnvelope
      | (account, firstEnvelope, repeatedEnvelope) <- coordinateConflicts planObservation ]
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
      ++ allocationErrors ++ planErrors ++ presenceErrors ++ unassignedErrors ++ overlapErrors

householdEnvelopeForPlanDestination :: Account -> HouseholdPolicy -> Maybe EnvelopeId
householdEnvelopeForPlanDestination account = Map.lookup account . householdPlanDestinationEnvelopes

data AccountValidatedHouseholdPolicy = AccountValidatedHouseholdPolicy
  { accountValidatedHouseholdPolicy         :: HouseholdPolicy
  , accountValidatedHouseholdEnvelopePolicy :: AccountValidatedCurrentEnvelopePolicy
  } deriving (Eq, Show)

accountValidatedHouseholdBackingPolicy :: AccountValidatedHouseholdPolicy -> BackingPolicy
accountValidatedHouseholdBackingPolicy = householdBackingPolicy . accountValidatedHouseholdPolicy

data HouseholdPolicyAccountError
  = HouseholdEnvelopePolicyAccountError CurrentEnvelopePolicyAccountError
  | HouseholdBackingPolicyAccountError BackingPolicyAccountError
  | HouseholdCycleIncomeAccountUndeclared Account
  | HouseholdCycleIncomeAccountNotIncome Account AccountType
  | HouseholdAllocationAccountUndeclared EnvelopeId Account
  | HouseholdAllocationAccountNotBudget EnvelopeId Account AccountType
  | HouseholdUnassignedAccountUndeclared Account
  | HouseholdUnassignedAccountNotBudget Account AccountType
  | HouseholdPlanDestinationUndeclared EnvelopeId Account
  deriving (Eq, Show)

validateHouseholdPolicyAccounts
  :: AccountRegistry
  -> HouseholdPolicy
  -> Either (NonEmpty HouseholdPolicyAccountError) AccountValidatedHouseholdPolicy
validateHouseholdPolicyAccounts registry policy =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> case envelopeValidation of
      Right validated -> Right AccountValidatedHouseholdPolicy
        { accountValidatedHouseholdPolicy = policy
        , accountValidatedHouseholdEnvelopePolicy = validated
        }
      Left impossible -> Left (fmap HouseholdEnvelopePolicyAccountError impossible)
  where
    envelopeValidation = validateCurrentEnvelopePolicyAccounts registry (householdEnvelopePolicy policy)
    envelopeErrors = case envelopeValidation of
      Left values -> map HouseholdEnvelopePolicyAccountError (NonEmpty.toList values)
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
    validateAdditionalPlanDestination (account, envelope) =
      case lookupAccountDeclaration account registry of
        Nothing -> [HouseholdPlanDestinationUndeclared envelope account]
        Just _ -> []
    errors = envelopeErrors ++ backingErrors ++ validateCycle
      ++ concatMap validateAllocation (Map.toAscList (householdAllocationEnvelopes policy))
      ++ concatMap validateUnassigned (Set.toAscList (householdUnassignedBudgetAccounts policy))
      ++ concatMap validateAdditionalPlanDestination
        (Map.toAscList (householdAdditionalPlanDestinations policy))

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

observeAssignments :: (Ord key, Eq value) => [(key, value)] -> CoordinateObservation key value
observeAssignments = foldl' observe (CoordinateObservation Map.empty [])
  where
    observe observation (key, value) = case Map.lookup key (coordinateValues observation) of
      Nothing -> observation { coordinateValues = Map.insert key value (coordinateValues observation) }
      Just firstValue
        | firstValue == value -> observation
        | otherwise -> observation
            { coordinateConflicts = coordinateConflicts observation ++ [(key, firstValue, value)] }
