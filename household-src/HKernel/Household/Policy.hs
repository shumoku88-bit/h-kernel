-- | Stable household policy layered on top of the general Budget policy.
--
-- 'BudgetPolicy' owns spendable envelopes, Expense assignment, pacing, and
-- backing pools. This module adds only household coordinates: the income-anchor
-- cycle, allocation Budget Accounts, publication order, extra Plan
-- destinations, and the unassigned Budget Account scope.
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
  , householdPolicyCycle
  , householdBudgetPolicy
  , householdEnvelopeOrder
  , householdAllocationEnvelopes
  , householdUnassignedBudgetAccounts
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

-- | The household cycle is bounded by observed and planned movements from one
-- explicitly named Income Account.
newtype HouseholdCyclePolicy = IncomeAnchorCyclePolicy
  { householdCycleIncomeAccount :: Account
  } deriving (Eq, Show)

incomeAnchorCyclePolicy :: Account -> HouseholdCyclePolicy
incomeAnchorCyclePolicy = IncomeAnchorCyclePolicy

-- | Household-only coordinates for one envelope already defined by
-- 'BudgetPolicy'. Source order becomes deterministic publication order.
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

-- | Structural conflicts in the household layer. General Budget conflicts are
-- admitted earlier by 'HKernel.Budget.Config'.
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

-- | Canonical household policy. The constructor stays hidden so every lookup
-- map and publication order is derived from one admitted coordinate sequence.
data HouseholdPolicy = HouseholdPolicy
  { householdPolicyCycle                :: HouseholdCyclePolicy
  , householdBudgetPolicy               :: BudgetPolicy
  , householdEnvelopeOrder              :: [EnvelopeId]
  , householdAllocationEnvelopes        :: Map Account EnvelopeId
  , householdPlanDestinationEnvelopes   :: Map Account EnvelopeId
  , householdAdditionalPlanDestinations :: Map Account EnvelopeId
  , householdUnassignedBudgetAccounts   :: Set Account
  } deriving (Eq, Show)

-- | Combine general Budget meaning with household-only coordinates while
-- retaining every independently observable structural conflict.
mkHouseholdPolicy
  :: HouseholdCyclePolicy
  -> BudgetPolicy
  -> [HouseholdEnvelopeCoordinates]
  -> [Account]
  -> Either (NonEmpty HouseholdPolicyError) HouseholdPolicy
mkHouseholdPolicy cyclePolicy budgetPolicy coordinates unassignedAccounts =
  case NonEmpty.nonEmpty errors of
    Just nonEmptyErrors -> Left nonEmptyErrors
    Nothing -> Right HouseholdPolicy
      { householdPolicyCycle = cyclePolicy
      , householdBudgetPolicy = budgetPolicy
      , householdEnvelopeOrder = map householdEnvelopeCoordinateId coordinates
      , householdAllocationEnvelopes = coordinateValues allocationObservation
      , householdPlanDestinationEnvelopes = coordinateValues planObservation
      , householdAdditionalPlanDestinations =
          coordinateValues additionalPlanObservation
      , householdUnassignedBudgetAccounts = Set.fromList unassignedAccounts
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
    expensePlanCoordinates =
      [ (account, envelopeDefinitionId definition)
      | definition <- budgetEnvelopeDefinitions
      , account <- envelopeDefinitionExpenseAccounts definition
      ]
    allocationPlanCoordinates =
      [ ( householdEnvelopeAllocationAccount coordinate
        , householdEnvelopeCoordinateId coordinate
        )
      | coordinate <- canonicalCoordinates
      ]
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
      | (account, envelope) <- Map.toAscList
          (coordinateValues allocationObservation)
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

-- | Narrow writer permission for Plan completion Budget reflection. Only
-- explicit Household Plan destination coordinates participate, so ordinary
-- Actual consumption cannot also authorize the same Budget movement.
householdEnvelopeForExecutionPlanDestination
  :: Account
  -> HouseholdPolicy
  -> Maybe EnvelopeId
householdEnvelopeForExecutionPlanDestination account =
  Map.lookup account . householdAdditionalPlanDestinations

-- | A household policy whose every Account reference has been checked against
-- one canonical AccountRegistry. Expense Accounts with no current management
-- route remain valid and are retained as attention evidence.
data AccountValidatedHouseholdPolicy = AccountValidatedHouseholdPolicy
  { accountValidatedHouseholdPolicy :: HouseholdPolicy
  , accountValidatedHouseholdBudgetPolicy :: AccountValidatedBudgetPolicy
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
  | HouseholdExpenseManagementAmbiguous Account
  deriving (Eq, Show)

-- | Validate every household Account coordinate together, then return typed
-- evidence that later calculations can require instead of raw policy.
--
-- Expense management is asymmetric by design: zero routes is valid attention
-- evidence, one route is valid, and two routes fail closed.
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
        , accountValidatedHouseholdUnassignedExpenseAccounts =
            unassignedExpenseAccounts
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
                  envelope
                  account
                  (declaredAccountType declaration)
              ]

    validateUnassigned account =
      case lookupAccountDeclaration account registry of
        Nothing -> [HouseholdUnassignedAccountUndeclared account]
        Just declaration
          | declaredAccountType declaration == Budget -> []
          | otherwise ->
              [ HouseholdUnassignedAccountNotBudget
                  account
                  (declaredAccountType declaration)
              ]

    validateAdditionalPlanDestination (account, envelope) =
      case lookupAccountDeclaration account registry of
        Nothing -> [HouseholdPlanDestinationUndeclared envelope account]
        Just _ -> []

    consumptionManagedExpenses = Set.fromList
      [ account
      | definition <- budgetPolicyEnvelopeDefinitions (householdBudgetPolicy policy)
      , account <- envelopeDefinitionExpenseAccounts definition
      ]
    executionManagedExpenses = Map.keysSet
      (householdAdditionalPlanDestinations policy)
    declaredExpenses =
      [ declaredAccount declaration
      | declaration <- accountDeclarations registry
      , declaredAccountType declaration == Expense
      ]
    routeCount account = length
      [ ()
      | present <-
          [ Set.member account consumptionManagedExpenses
          , Set.member account executionManagedExpenses
          ]
      , present
      ]
    unassignedExpenseAccounts = Set.fromList
      [ account
      | account <- declaredExpenses
      , routeCount account == 0
      ]
    expenseManagementErrors =
      [ HouseholdExpenseManagementAmbiguous account
      | account <- declaredExpenses
      , routeCount account > 1
      ]

-- | A source-ordered coordinate observation. The first occurrence is canonical
-- and every later occurrence remains visible in encounter order.
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

-- | Observe semantic ownership rather than source duplication. Repeating the
-- same owner is idempotent; only one coordinate assigned to two different
-- owners is a conflict.
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
