-- | Stable Household policy layered on independently admitted current Envelope
-- and Backing owners. Historical Expense/Fulfillment meaning is admitted from
-- explicit routing history, never reconstructed from current policy.
module HKernel.Household.Policy
  ( HouseholdCyclePolicy
  , incomeAnchorCyclePolicy
  , householdCycleIncomeAccount
  , HouseholdPolicy
  , HouseholdPolicyError(..)
  , mkHouseholdPolicy
  , householdPolicyCycle
  , householdEnvelopePolicy
  , householdBackingPolicy
  , householdEnvelopeOrder
  , HouseholdPolicyAccountError(..)
  , validateHouseholdPolicyAccounts
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
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
  , currentEnvelopePolicyDefinitions
  , envelopeDefinitionId
  )
import HKernel.Envelope.Identity (EnvelopeId)

newtype HouseholdCyclePolicy = IncomeAnchorCyclePolicy
  { householdCycleIncomeAccount :: Account
  } deriving (Eq, Show)

incomeAnchorCyclePolicy :: Account -> HouseholdCyclePolicy
incomeAnchorCyclePolicy = IncomeAnchorCyclePolicy

data HouseholdPolicyError
  = HouseholdPolicyInvalid
  deriving (Eq, Show)

data HouseholdPolicy = HouseholdPolicy
  { householdPolicyCycle    :: HouseholdCyclePolicy
  , householdEnvelopePolicy :: CurrentEnvelopePolicy
  , householdBackingPolicy  :: BackingPolicy
  , householdEnvelopeOrder  :: [EnvelopeId]
  } deriving (Eq, Show)

mkHouseholdPolicy
  :: HouseholdCyclePolicy
  -> CurrentEnvelopePolicy
  -> BackingPolicy
  -> Either (NonEmpty HouseholdPolicyError) HouseholdPolicy
mkHouseholdPolicy cyclePolicy envelopePolicy backingPolicy =
  Right HouseholdPolicy
    { householdPolicyCycle = cyclePolicy
    , householdEnvelopePolicy = envelopePolicy
    , householdBackingPolicy = backingPolicy
    , householdEnvelopeOrder = currentEnvelopeIds
    }
  where
    definitions = currentEnvelopePolicyDefinitions envelopePolicy
    currentEnvelopeIds = map envelopeDefinitionId definitions

data HouseholdPolicyAccountError
  = HouseholdBackingPolicyAccountError BackingPolicyAccountError
  | HouseholdCycleIncomeAccountUndeclared Account
  | HouseholdCycleIncomeAccountNotIncome Account AccountType
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
    backingErrors = case validateBackingPolicyAccounts registry (householdBackingPolicy policy) of
      Left values -> map HouseholdBackingPolicyAccountError (NonEmpty.toList values)
      Right _ -> []
    cycleAccount = householdCycleIncomeAccount (householdPolicyCycle policy)
    validateCycle = case lookupAccountDeclaration cycleAccount registry of
      Nothing -> [HouseholdCycleIncomeAccountUndeclared cycleAccount]
      Just declaration
        | declaredAccountType declaration == Income -> []
        | otherwise -> [HouseholdCycleIncomeAccountNotIncome cycleAccount (declaredAccountType declaration)]
    errors = backingErrors ++ validateCycle
