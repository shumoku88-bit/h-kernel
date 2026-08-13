-- | Stable household policy layered on top of the general Budget policy.
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
  , mkHouseholdPolicyWithExpenseManagement
  , householdPolicyCycle
  , householdBudgetPolicy
  , householdEnvelopeOrder
  , householdAllocationEnvelopes
  , householdUnassignedBudgetAccounts
  , householdUnmanagedExpenseAccounts
  , householdEnvelopeForPlanDestination
  , householdEnvelopeForExecutionPlanDestination
  , AccountValidatedHouseholdPolicy
  , accountValidatedHouseholdPolicy
  , accountValidatedHouseholdBudgetPolicy
  , accountValidatedHouseholdUnassignedExpenseAccounts
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
  , accountDeclarations
  , declaredAccount
  , declaredAccountType
  , lookupAccountDeclaration
  )
import HKernel.Budget (EnvelopeId)
import HKernel.Budget.Policy
  ( AccountValidatedBudgetPolicy
  , BudgetPolicy
  , BudgetPolicyAccountError
  , budgetPolicyEnvelopeDefinitions
  , envelopeDefinitionExpenseAccounts
  , envelopeDefinitionId
  , validateBudgetPolicyAccounts
  )

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
  :: EnvelopeId
  -> Account
  -> [Account]
  -> HouseholdEnvelopeCoordinates
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
  , householdBudgetPolicy               :: BudgetPolicy
  , householdEnvelopeOrder              :: [EnvelopeId]
  , householdAllocationEnvelopes        :: Map Account EnvelopeId
  , householdPlanDestinationEnvelopes   :: Map Account EnvelopeId
  , householdAdditionalPlanDestinations :: Map Account EnvelopeId
  , householdUnassignedBudgetAccounts   :: Set Account
  , householdUnmanagedExpenseAccounts   :: Set Account
  } deriving (Eq, Show)

-- | Existing callers have no explicitly unmanaged Expense Accounts.
-- Unassigned Expense Accounts remain valid and become attention evidence only
-- when the policy meets an AccountRegistry.
mkHouseholdPolicy
  :: HouseholdCyclePolicy
  -> BudgetPolicy
  -> [HouseholdEnvelopeCoordinates]
  -> [Account]
  -> Either (NonEmpty HouseholdPolicyError) HouseholdPolicy
mkHouseholdPolicy cyclePolicy budgetPolicy coordinates unassignedAccounts =
  mkHouseholdPolicyWithExpenseManagement
    cyclePolicy budgetPolicy coordinates unassignedAccounts []

-- | Add an explicit negative decision for Expense Accounts intentionally left
-- outside envelope management. Syntax/admission for this list is owned by a
-- later configuration migration; this constructor is the domain boundary.
mkHouseholdPolicyWithExpenseManagement
  :: HouseholdCyclePolicy
  -> BudgetPolicy
  -> [HouseholdEnvelopeCoordinates]
  -> [Account]
  -> [Account]
  -> Either (NonEmpty HouseholdPolicyError) HouseholdPolicy
mkHouseholdPolicyWithExpenseManagement cyclePolicy budgetPolicy coordinates unassignedAccounts unmanagedExpenseAccounts =
  case NonEmpty.nonEmpty errors of
    Just nonEmptyErrors -> Left nonEmptyErrors
    Nothing -> Right HouseholdPolicy
      { householdPolicyCycle = cyclePolicy
      , householdBudgetPolicy = budgetPolicy
      , householdEnvelopeOrder = map householdEnvelopeCoordinateId coordinates
      , householdAllocationEnvelopes = coordinateValues allocationObservation
      , householdPlanDestinationEnvelopes = coordinateValues planObservation
      , householdAdditionalPlanDestinations = additionalPlanAssignments
      , householdUnassignedBudgetAccounts = Set.fromList unassignedAccounts
      , householdUnmanagedExpenseAccounts = Set.fromList unmanagedExpenseAccounts
      }
  where
    budgetEnvelopeDefinitions = budgetPolicyEnvelopeDefinitions budgetPolicy
    knownEnvelopes = Set.fromList
      (map envelopeDefinitionId budgetEnvelopeDefinitions)

    envelopeCoordinateObservation = observeCoordinates
      [ (householdEnvelopeCoordinateId coordinate, coordinate)
      | coordinate <- coordinates
      ]
    canonicalCoordinates = Map.elems
      (coordinateValues envelopeCoordinateObservation)
    coordinateEnvelopes = Map.keysSet
      (coordinateValues envelopeCoordinateObservation)
    duplicateCoordinateErrors =
      [ DuplicateHouseholdEnvelopeCoordinates envelope
      | (envelope, _, _) <- coordinateConflicts envelopeCoordinateObservation
      ]
    unknownCoordinateErrors = map
      HouseholdCoordinatesReferenceUnknownEnvelope
      (Set.toAscList (Set.difference coordinateEnvelopes knownEnvelopes))
    missingCoordinateErrors = map
      HouseholdEnvelopeMissingCoordinates
      (Set.toAscList (Set.difference knownEnvelopes coordinateEnvelopes))

    allocationObservation = observeCoordinates
      [ ( householdEnvelopeAllocationAccount coordinate
        , householdEnvelopeCoordinateId coordinate
        )
      | coordinate <- canonicalCoordinates
      ]
    allocationAssignments = coordinateValues allocationObservation
    allocationErrors =
      [ DuplicateAllocationAccount account firstEnvelope repeatedEnvelope
      | (account, firstEnvelope, repeatedEnvelope) <-
          coordinateConflicts allocationObservation
      ]

    additionalPlanCoordinates =
      [ (account, householdEnvelopeCoordinateId coordinate)
      | coordinate <- canonicalCoordinates
      , account <- householdEnvelopePlanDestinationAccounts coordinate
      ]
    additionalPlanObservation = observeAssignments additionalPlanCoordinates
    additionalPlanAssignments = coordinateValues additionalPlanObservation
    expensePlanCoordinates =
      [ (account, envelopeDefinitionId definition)
      | definition <- budgetEnvelopeDefinitions
      , account <- envelopeDefinitionExpenseAccounts definition
      ]
    allocationPlanCoordinates = Map.toAscList allocationAssignments
    planObservation = observeAssignments
      ( expensePlanCoordinates
          ++ allocationPlanCoordinates
          ++ additionalPlanCoordinates
      )
    planErrors =
      [ DuplicatePlanDestinationAccount account firstEnvelope repeatedEnvelope
      | (account, firstEnvelope, repeatedEnvelope) <-
          coordinateConflicts planObservation
      ]

    unassignedObservation = observeCoordinates
      [ (account, ())
      | account <- unassignedAccounts
      ]
    unassignedErrors =
      [ DuplicateUnassignedBudgetAccount account
      | (account, _, _) <- coordinateConflicts unassignedObservation
      ]
    presenceErrors =
      [ HouseholdPolicyHasNoUnassignedBudgetAccounts
      | null unassignedAccounts
      ]
    overlapErrors =
      [ AllocationAccountAlsoUnassigned account envelope
      | (account, envelope) <- Map.toAscList allocationAssignments
      , Set.member account (Set.fromList unassignedAccounts)
      ]

    errors =
      duplicateCoordinateErrors
        ++ unknownCoordinateErrors
        ++ missingCoordinateErrors
        ++ allocationErrors
        ++ planErrors
        ++ presenceErrors
        ++ unassignedErrors
        ++ overlapErrors

-- | Broad read relation. Normal Expense routing participates so a future Plan
-- to an ordinarily consumed Expense reserves the same Envelope.
householdEnvelopeForPlanDestination
  :: Account
  -> HouseholdPolicy
  -> Maybe EnvelopeId
householdEnvelopeForPlanDestination account =
  Map.lookup account . householdPlanDestinationEnvelopes

-- | Narrow writer relation. Only explicit household plan destinations may
-- authorize Plan-completion Budget reflection.
householdEnvelopeForExecutionPlanDestination
  :: Account
  -> HouseholdPolicy
  -> Maybe EnvelopeId
householdEnvelopeForExecutionPlanDestination account =
  Map.lookup account . householdAdditionalPlanDestinations

-- | A structurally valid Household policy qualified against one AccountRegistry.
-- Expense Accounts with no current management decision remain visible as an
-- attention projection rather than making the Household invalid.
data AccountValidatedHouseholdPolicy = AccountValidatedHouseholdPolicy
  { accountValidatedHouseholdPolicy                  :: HouseholdPolicy
  , accountValidatedHouseholdBudgetPolicy            :: AccountValidatedBudgetPolicy
  , accountValidatedHouseholdUnassignedExpenseAccounts :: Set Account
  } deriving (Eq, Show)

data HouseholdPolicyAccountError
  = HouseholdBudgetPolicyAccountError BudgetPolicyAccountError
  | HouseholdCycleIncomeAccountUndeclared Account
  | HouseholdCycleIncomeAccountNotIncome Account AccountType
  | HouseholdAllocationAccountUndeclared EnvelopeId Account
  | HouseholdAllocationAccountNotBudget EnvelopeId Account AccountType
  | HouseholdUnassignedAccountUndeclared Account
  | HouseholdUnassignedAccountNotBudget Account AccountType
  | HouseholdPlanDestinationUndeclared EnvelopeId Account
  | HouseholdUnmanagedExpenseUndeclared Account
  | HouseholdUnmanagedAccountNotExpense Account AccountType
  | HouseholdExpenseManagementAmbiguous Account
  deriving (Eq, Show)

-- | Qualify every Account coordinate against one AccountRegistry.
--
-- Expense management is intentionally asymmetric:
--
-- * zero decisions is valid and retained as unassigned attention evidence,
-- * one decision is valid,
-- * two or more decisions are ambiguous and fail closed.
validateHouseholdPolicyAccounts
  :: AccountRegistry
  -> HouseholdPolicy
  -> Either (NonEmpty HouseholdPolicyAccountError) AccountValidatedHouseholdPolicy
validateHouseholdPolicyAccounts registry policy =
  case NonEmpty.nonEmpty errors of
    Just nonEmptyErrors -> Left nonEmptyErrors
    Nothing -> case budgetValidation of
      Right validated -> Right AccountValidatedHouseholdPolicy
        { accountValidatedHouseholdPolicy = policy
        , accountValidatedHouseholdBudgetPolicy = validated
        , accountValidatedHouseholdUnassignedExpenseAccounts = unassignedExpenseAccounts
        }
      Left impossible -> Left (fmap HouseholdBudgetPolicyAccountError impossible)
  where
    budgetValidation = validateBudgetPolicyAccounts registry
      (householdBudgetPolicy policy)
    budgetErrors = case budgetValidation of
      Left values -> map HouseholdBudgetPolicyAccountError (NonEmpty.toList values)
      Right _ -> []
    errors =
      budgetErrors
        ++ validateCycle
        ++ concatMap validateAllocation
          (Map.toAscList (householdAllocationEnvelopes policy))
        ++ concatMap validateUnassigned
          (Set.toAscList (householdUnassignedBudgetAccounts policy))
        ++ concatMap validateAdditionalPlanDestination
          (Map.toAscList (householdAdditionalPlanDestinations policy))
        ++ concatMap validateUnmanagedExpense
          (Set.toAscList (householdUnmanagedExpenseAccounts policy))
        ++ expenseManagementErrors

    cycleAccount = householdCycleIncomeAccount (householdPolicyCycle policy)
    validateCycle = case lookupAccountDeclaration cycleAccount registry of
      Nothing -> [HouseholdCycleIncomeAccountUndeclared cycleAccount]
      Just declaration
        | declaredAccountType declaration == Income -> []
        | otherwise ->
            [ HouseholdCycleIncomeAccountNotIncome
                cycleAccount
                (declaredAccountType declaration)
            ]

    validateAllocation (account, envelope) =
      case lookupAccountDeclaration account registry of
        Nothing -> [HouseholdAllocationAccountUndeclared envelope account]
        Just declaration
          | declaredAccountType declaration == Budget -> []
          | otherwise ->
              [ HouseholdAllocationAccountNotBudget
                  envelope account (declaredAccountType declaration)
              ]

    validateUnassigned account =
      case lookupAccountDeclaration account registry of
        Nothing -> [HouseholdUnassignedAccountUndeclared account]
        Just declaration
          | declaredAccountType declaration == Budget -> []
          | otherwise ->
              [ HouseholdUnassignedAccountNotBudget
                  account (declaredAccountType declaration)
              ]

    validateAdditionalPlanDestination (account, envelope) =
      case lookupAccountDeclaration account registry of
        Nothing -> [HouseholdPlanDestinationUndeclared envelope account]
        Just _ -> []

    validateUnmanagedExpense account =
      case lookupAccountDeclaration account registry of
        Nothing -> [HouseholdUnmanagedExpenseUndeclared account]
        Just declaration
          | declaredAccountType declaration == Expense -> []
          | otherwise ->
              [ HouseholdUnmanagedAccountNotExpense
                  account (declaredAccountType declaration)
              ]

    consumptionManagedExpenses = Set.fromList
      [ account
      | definition <- budgetPolicyEnvelopeDefinitions (householdBudgetPolicy policy)
      , account <- envelopeDefinitionExpenseAccounts definition
      ]
    executionManagedExpenses = Map.keysSet
      (householdAdditionalPlanDestinations policy)
    explicitlyUnmanagedExpenses = householdUnmanagedExpenseAccounts policy
    declaredExpenses =
      [ declaredAccount declaration
      | declaration <- accountDeclarations registry
      , declaredAccountType declaration == Expense
      ]
    decisionCount account = length
      [ ()
      | present <-
          [ Set.member account consumptionManagedExpenses
          , Set.member account executionManagedExpenses
          , Set.member account explicitlyUnmanagedExpenses
          ]
      , present
      ]
    unassignedExpenseAccounts = Set.fromList
      [ account
      | account <- declaredExpenses
      , decisionCount account == 0
      ]
    expenseManagementErrors =
      [ HouseholdExpenseManagementAmbiguous account
      | account <- declaredExpenses
      , decisionCount account > 1
      ]

data CoordinateObservation key value = CoordinateObservation
  { coordinateValues    :: Map key value
  , coordinateConflicts :: [(key, value, value)]
  }

observeCoordinates
  :: Ord key
  => [(key, value)]
  -> CoordinateObservation key value
observeCoordinates = foldl' observe emptyObservation
  where
    emptyObservation = CoordinateObservation Map.empty []
    observe observation (key, value) =
      case Map.lookup key (coordinateValues observation) of
        Nothing -> observation
          { coordinateValues = Map.insert key value
              (coordinateValues observation)
          }
        Just firstValue -> observation
          { coordinateConflicts = coordinateConflicts observation
              ++ [(key, firstValue, value)]
          }

observeAssignments
  :: (Ord key, Eq value)
  => [(key, value)]
  -> CoordinateObservation key value
observeAssignments = foldl' observe emptyObservation
  where
    emptyObservation = CoordinateObservation Map.empty []
    observe observation (key, value) =
      case Map.lookup key (coordinateValues observation) of
        Nothing -> observation
          { coordinateValues = Map.insert key value
              (coordinateValues observation)
          }
        Just firstValue
          | firstValue == value -> observation
          | otherwise -> observation
              { coordinateConflicts = coordinateConflicts observation
                  ++ [(key, firstValue, value)]
              }
