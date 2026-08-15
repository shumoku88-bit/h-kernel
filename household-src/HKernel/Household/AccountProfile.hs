{-# LANGUAGE OverloadedStrings #-}

-- | Source-independent semantic contract for household Account classifications
-- and the retained @accounts.tsv@ evidence from which they are being migrated.
--
-- Physical @accounts.tsv@ admission belongs to
-- 'HKernel.Household.AccountProfile.TSV'. This module owns the value boundary
-- produced after admission and the native policy value that can be carried by
-- @household.toml@ without preserving TSV row shape.
module HKernel.Household.AccountProfile
  ( RetainedAssetClass(..)
  , RetainedBudgetAccountKind(..)
  , RetainedEnvelopeRole(..)
  , RetainedBudgetGroup(..)
  , RetainedSpendClass(..)
  , AccountEnvelopePolicyEvidence(..)
  , AccountHouseholdPolicyEvidence(..)
  , RetainedAccountProfile(..)
  , AccountProfileError(..)
  , classifyRetainedAccountProfile
  , HouseholdAccountPolicy
  , householdAssetClassByAccount
  , householdBudgetKindByAccount
  , householdEnvelopeRoleByAccount
  , householdBudgetGroupByAccount
  , householdSpendClassByAccount
  , HouseholdAccountPolicyError(..)
  , mkHouseholdAccountPolicy
  , projectRetainedHouseholdAccountPolicy
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
  ( Account
  , AccountDeclaration
  , AccountType(..)
  , declaredAccountType
  )
import HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeIdError
  , mkEnvelopeId
  )

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

-- | Retained household group evidence for existing Budget Accounts.
-- @reserve@ is deliberately distinct from current Envelope pacing.
data RetainedBudgetGroup
  = RetainedDailyBudgetGroup
  | RetainedFlexBudgetGroup
  | RetainedReserveBudgetGroup
  deriving (Eq, Ord, Show)

data RetainedSpendClass
  = RetainedFixedSpend
  | RetainedVariableSpend
  deriving (Eq, Ord, Show)

-- | Retained Expense Account to Envelope assignment evidence.
data AccountEnvelopePolicyEvidence = AccountEnvelopePolicyEvidence
  { accountExpenseEnvelopeEvidence :: Maybe EnvelopeId
  } deriving (Eq, Show)

data AccountHouseholdPolicyEvidence = AccountHouseholdPolicyEvidence
  { accountAssetClassEvidence              :: Maybe RetainedAssetClass
  , accountPlanDestinationEnvelopeEvidence :: Maybe EnvelopeId
  , accountBudgetAccountKindEvidence       :: Maybe RetainedBudgetAccountKind
  , accountAllocationEnvelopeEvidence      :: Maybe EnvelopeId
  , accountEnvelopeRoleEvidence            :: Maybe RetainedEnvelopeRole
  , accountBudgetGroupEvidence             :: Maybe RetainedBudgetGroup
  , accountFixedExpenseEvidence            :: Maybe Bool
  , accountSpendClassEvidence              :: Maybe RetainedSpendClass
  } deriving (Eq, Show)

data RetainedAccountProfile = RetainedAccountProfile
  { retainedAccountDeclaration          :: AccountDeclaration
  , retainedAccountEnvelopeEvidence     :: AccountEnvelopePolicyEvidence
  , retainedAccountHouseholdEvidence    :: AccountHouseholdPolicyEvidence
  , retainedAccountUnclassifiedMetadata :: Map Text Text
  } deriving (Eq, Show)

data AccountProfileError
  = UnsupportedRetainedAssetClass Text
  | UnsupportedRetainedBudgetAccountKind Text
  | UnsupportedRetainedEnvelopeRole Text
  | UnsupportedRetainedBudgetGroup Text
  | UnsupportedRetainedFixedMarker Text
  | UnsupportedRetainedSpendClass Text
  | InvalidRetainedEnvelopeReference Text EnvelopeIdError
  deriving (Eq, Show)

classifyRetainedAccountProfile
  :: AccountDeclaration
  -> Map Text Text
  -> Either (NonEmpty AccountProfileError) RetainedAccountProfile
classifyRetainedAccountProfile declaration metadata =
  case NonEmpty.nonEmpty errors of
    Just values -> Left values
    Nothing -> Right RetainedAccountProfile
      { retainedAccountDeclaration = declaration
      , retainedAccountEnvelopeEvidence = AccountEnvelopePolicyEvidence
          { accountExpenseEnvelopeEvidence = case accountType of
              Expense -> valueOf envelopeReferenceResult
              _       -> Nothing
          }
      , retainedAccountHouseholdEvidence = AccountHouseholdPolicyEvidence
          { accountAssetClassEvidence = valueOf assetClassResult
          , accountPlanDestinationEnvelopeEvidence = case accountType of
              Asset -> valueOf envelopeReferenceResult
              _     -> Nothing
          , accountBudgetAccountKindEvidence = valueOf budgetKindResult
          , accountAllocationEnvelopeEvidence = case accountType of
              Budget -> valueOf envelopeReferenceResult
              _      -> Nothing
          , accountEnvelopeRoleEvidence = valueOf envelopeRoleResult
          , accountBudgetGroupEvidence = valueOf budgetGroupResult
          , accountFixedExpenseEvidence = valueOf fixedResult
          , accountSpendClassEvidence = valueOf spendClassResult
          }
      , retainedAccountUnclassifiedMetadata =
          foldr Map.delete metadata consumedKeys
      }
  where
    accountType = declaredAccountType declaration
    assetClassResult = parseWhen (accountType == Asset)
      "type" parseAssetClass metadata
    budgetKindResult = parseWhen (accountType == Budget)
      "kind" parseBudgetAccountKind metadata
    envelopeRoleResult = parseWhen (accountType == Budget)
      "envelope_role" parseEnvelopeRole metadata
    budgetGroupResult = parseWhen (accountType == Budget)
      "budget_group" parseBudgetGroup metadata
    fixedResult = parseWhen (accountType == Expense)
      "fixed" parseFixedMarker metadata
    spendClassResult = parseWhen (accountType == Expense)
      "spend_class" parseSpendClass metadata
    envelopeReferenceResult
      | accountType `elem` [Asset, Expense, Budget] =
          parseOptional metadata "budget" parseEnvelopeReference
      | otherwise = Right Nothing
    errors = concat
      [ errorsOf assetClassResult
      , errorsOf budgetKindResult
      , errorsOf envelopeRoleResult
      , errorsOf budgetGroupResult
      , errorsOf fixedResult
      , errorsOf spendClassResult
      , errorsOf envelopeReferenceResult
      ]
    consumedKeys = case accountType of
      Asset   -> ["type", "budget"]
      Expense -> ["budget", "fixed", "spend_class"]
      Budget  -> ["kind", "budget", "envelope_role", "budget_group"]
      _       -> []

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
  | RetainedFixedMarkerHasNoSpendClass
  | RetainedFixedMarkerConflictsWithSpendClass
  | RetainedAccountMetadataRemainsUnclassified
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

projectRetainedHouseholdAccountPolicy
  :: Map Account RetainedAccountProfile
  -> Either (NonEmpty HouseholdAccountPolicyError) HouseholdAccountPolicy
projectRetainedHouseholdAccountPolicy profiles =
  case NonEmpty.nonEmpty migrationErrors of
    Just errors -> Left errors
    Nothing -> mkHouseholdAccountPolicy
      assetClasses budgetKinds envelopeRoles budgetGroups spendClasses
  where
    entries = Map.toAscList profiles
    assetClasses = mapMaybeEvidence
      (accountAssetClassEvidence . retainedAccountHouseholdEvidence)
      entries
    budgetKinds = mapMaybeEvidence
      (accountBudgetAccountKindEvidence . retainedAccountHouseholdEvidence)
      entries
    envelopeRoles = mapMaybeEvidence
      (accountEnvelopeRoleEvidence . retainedAccountHouseholdEvidence)
      entries
    budgetGroups = mapMaybeEvidence
      (accountBudgetGroupEvidence . retainedAccountHouseholdEvidence)
      entries
    spendClasses = mapMaybeEvidence
      (accountSpendClassEvidence . retainedAccountHouseholdEvidence)
      entries
    migrationErrors = concatMap profileMigrationErrors entries

profileMigrationErrors
  :: (Account, RetainedAccountProfile)
  -> [HouseholdAccountPolicyError]
profileMigrationErrors (_, profile) = unclassifiedError ++ fixedErrors
  where
    evidence = retainedAccountHouseholdEvidence profile
    unclassifiedError =
      [ RetainedAccountMetadataRemainsUnclassified
      | not (Map.null (retainedAccountUnclassifiedMetadata profile))
      ]
    fixedErrors = case
        ( accountFixedExpenseEvidence evidence
        , accountSpendClassEvidence evidence
        ) of
      (Nothing, _) -> []
      (Just _, Nothing) -> [RetainedFixedMarkerHasNoSpendClass]
      (Just True, Just RetainedFixedSpend) -> []
      (Just False, Just RetainedVariableSpend) -> []
      (Just _, Just _) -> [RetainedFixedMarkerConflictsWithSpendClass]

mapMaybeEvidence
  :: (RetainedAccountProfile -> Maybe value)
  -> [(Account, RetainedAccountProfile)]
  -> [(Account, value)]
mapMaybeEvidence field = foldr add []
  where
    add (account, profile) values = case field profile of
      Nothing -> values
      Just value -> (account, value) : values

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

parseWhen
  :: Bool
  -> Text
  -> (Text -> Either error value)
  -> Map Text Text
  -> Either error (Maybe value)
parseWhen applicable key parser metadata
  | applicable = parseOptional metadata key parser
  | otherwise  = Right Nothing

parseOptional
  :: Map Text Text
  -> Text
  -> (Text -> Either error value)
  -> Either error (Maybe value)
parseOptional metadata key parser =
  case Map.lookup key metadata of
    Nothing    -> Right Nothing
    Just value -> Just <$> parser value

parseAssetClass :: Text -> Either AccountProfileError RetainedAssetClass
parseAssetClass value = case T.toCaseFold value of
  "liquid"  -> Right RetainedLiquidAsset
  "savings" -> Right RetainedSavingsAsset
  "invest"  -> Right RetainedInvestmentAsset
  _         -> Left (UnsupportedRetainedAssetClass value)

parseBudgetAccountKind
  :: Text
  -> Either AccountProfileError RetainedBudgetAccountKind
parseBudgetAccountKind value = case T.toCaseFold value of
  "opening"    -> Right RetainedOpeningBudgetAccount
  "unassigned" -> Right RetainedUnassignedBudgetAccount
  "spent"      -> Right RetainedSpentBudgetAccount
  "envelope"   -> Right RetainedEnvelopeBudgetAccount
  _            -> Left (UnsupportedRetainedBudgetAccountKind value)

parseEnvelopeRole :: Text -> Either AccountProfileError RetainedEnvelopeRole
parseEnvelopeRole value = case T.toCaseFold value of
  "unassigned" -> Right RetainedUnassignedEnvelopeRole
  "dynamic"    -> Right RetainedDynamicEnvelopeRole
  "execution"  -> Right RetainedExecutionEnvelopeRole
  _            -> Left (UnsupportedRetainedEnvelopeRole value)

parseBudgetGroup :: Text -> Either AccountProfileError RetainedBudgetGroup
parseBudgetGroup value = case T.toCaseFold value of
  "daily"   -> Right RetainedDailyBudgetGroup
  "flex"    -> Right RetainedFlexBudgetGroup
  "reserve" -> Right RetainedReserveBudgetGroup
  _         -> Left (UnsupportedRetainedBudgetGroup value)

parseFixedMarker :: Text -> Either AccountProfileError Bool
parseFixedMarker value = case T.toCaseFold value of
  "1" -> Right True
  "0" -> Right False
  _   -> Left (UnsupportedRetainedFixedMarker value)

parseSpendClass :: Text -> Either AccountProfileError RetainedSpendClass
parseSpendClass value = case T.toCaseFold value of
  "fixed"    -> Right RetainedFixedSpend
  "variable" -> Right RetainedVariableSpend
  _          -> Left (UnsupportedRetainedSpendClass value)

parseEnvelopeReference :: Text -> Either AccountProfileError EnvelopeId
parseEnvelopeReference value =
  mapLeft (InvalidRetainedEnvelopeReference value) (mkEnvelopeId value)

errorsOf :: Either error value -> [error]
errorsOf result = case result of
  Left err -> [err]
  Right _  -> []

valueOf :: Either error (Maybe value) -> Maybe value
valueOf result = case result of
  Left _      -> Nothing
  Right value -> value

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err    -> Left (f err)
  Right value -> Right value
