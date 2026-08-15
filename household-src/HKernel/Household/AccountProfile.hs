-- | Household Account classification policy admitted from current
-- @household.toml@. The historical @accounts.tsv@ classifier and projection
-- lived here during migration, but current application admission no longer
-- depends on that source.
module HKernel.Household.AccountProfile
  ( RetainedAssetClass(..)
  , RetainedBudgetAccountKind(..)
  , RetainedEnvelopeRole(..)
  , RetainedBudgetGroup(..)
  , RetainedSpendClass(..)
  , HouseholdAccountPolicy
  , householdAssetClassByAccount
  , householdBudgetKindByAccount
  , householdEnvelopeRoleByAccount
  , householdBudgetGroupByAccount
  , householdSpendClassByAccount
  , HouseholdAccountPolicyError(..)
  , mkHouseholdAccountPolicy
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import HKernel.Account (Account)

data RetainedAssetClass
  = RetainedLiquidAsset
  | RetainedSavingsAsset
  | RetainedInvestmentAsset
  deriving (Eq, Ord, Show)

data RetainedBudgetAccountKind
  = RetainedOpeningBudgetAccount
  | RetainedUnassignedBudgetAccount
  | RetainedSpentBudgetAccount
  | RetainedEnvelopeBudgetAccount
  deriving (Eq, Ord, Show)

data RetainedEnvelopeRole
  = RetainedUnassignedEnvelopeRole
  | RetainedDynamicEnvelopeRole
  | RetainedExecutionEnvelopeRole
  deriving (Eq, Ord, Show)

-- | Household group evidence for existing Budget Accounts. @reserve@ remains
-- distinct from current Envelope pacing.
data RetainedBudgetGroup
  = RetainedDailyBudgetGroup
  | RetainedFlexBudgetGroup
  | RetainedReserveBudgetGroup
  deriving (Eq, Ord, Show)

data RetainedSpendClass
  = RetainedFixedSpend
  | RetainedVariableSpend
  deriving (Eq, Ord, Show)

data HouseholdAccountPolicy = HouseholdAccountPolicy
  { householdAssetClassByAccount    :: Map Account RetainedAssetClass
  , householdBudgetKindByAccount    :: Map Account RetainedBudgetAccountKind
  , householdEnvelopeRoleByAccount  :: Map Account RetainedEnvelopeRole
  , householdBudgetGroupByAccount   :: Map Account RetainedBudgetGroup
  , householdSpendClassByAccount    :: Map Account RetainedSpendClass
  } deriving (Eq, Show)

data HouseholdAccountPolicyError
  = DuplicateHouseholdAssetClassCoordinate
  | DuplicateHouseholdBudgetKindCoordinate
  | DuplicateHouseholdEnvelopeRoleCoordinate
  | DuplicateHouseholdBudgetGroupCoordinate
  | DuplicateHouseholdSpendClassCoordinate
  deriving (Eq, Show)

mkHouseholdAccountPolicy
  :: [(Account, RetainedAssetClass)]
  -> [(Account, RetainedBudgetAccountKind)]
  -> [(Account, RetainedEnvelopeRole)]
  -> [(Account, RetainedBudgetGroup)]
  -> [(Account, RetainedSpendClass)]
  -> Either (NonEmpty HouseholdAccountPolicyError) HouseholdAccountPolicy
mkHouseholdAccountPolicy assetClasses budgetKinds envelopeRoles budgetGroups spendClasses =
  case NonEmpty.nonEmpty errors of
    Just values -> Left values
    Nothing -> Right HouseholdAccountPolicy
      { householdAssetClassByAccount = Map.fromList assetClasses
      , householdBudgetKindByAccount = Map.fromList budgetKinds
      , householdEnvelopeRoleByAccount = Map.fromList envelopeRoles
      , householdBudgetGroupByAccount = Map.fromList budgetGroups
      , householdSpendClassByAccount = Map.fromList spendClasses
      }
  where
    errors = concat
      [ duplicateError DuplicateHouseholdAssetClassCoordinate assetClasses
      , duplicateError DuplicateHouseholdBudgetKindCoordinate budgetKinds
      , duplicateError DuplicateHouseholdEnvelopeRoleCoordinate envelopeRoles
      , duplicateError DuplicateHouseholdBudgetGroupCoordinate budgetGroups
      , duplicateError DuplicateHouseholdSpendClassCoordinate spendClasses
      ]

duplicateError
  :: HouseholdAccountPolicyError
  -> [(Account, value)]
  -> [HouseholdAccountPolicyError]
duplicateError err values =
  [ err
  | hasDuplicateAccounts values
  ]

hasDuplicateAccounts :: [(Account, value)] -> Bool
hasDuplicateAccounts values =
  length values /= Map.size (Map.fromList [(account, ()) | (account, _) <- values])
