{-# LANGUAGE OverloadedStrings #-}

-- | A synthetic semantic contract for the retained @accounts.tsv@ metadata.
--
-- The physical TSV admission still belongs to the Household Report Spike. This
-- module fixes the value boundary that admission can target later: canonical
-- Account declaration, general Budget-policy evidence, household-only policy
-- evidence, and metadata whose meaning is not yet classified.
--
-- A key is consumed only when its meaning is valid for the declared
-- 'AccountType'. The same textual key on another Account type remains visible
-- in 'retainedAccountUnclassifiedMetadata' instead of being forced into the
-- wrong policy owner.
module HKernel.Household.AccountProfile
  ( RetainedAssetClass(..)
  , RetainedBudgetAccountKind(..)
  , RetainedEnvelopeRole(..)
  , RetainedBudgetGroup(..)
  , RetainedSpendClass(..)
  , AccountBudgetPolicyEvidence(..)
  , AccountHouseholdPolicyEvidence(..)
  , RetainedAccountProfile(..)
  , AccountProfileError(..)
  , classifyRetainedAccountProfile
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
  ( AccountDeclaration
  , AccountType(..)
  , declaredAccountType
  )
import HKernel.Budget
  ( EnvelopeId
  , EnvelopeIdError
  , mkEnvelopeId
  )

-- | Retained household classification for an Asset Account.
data RetainedAssetClass
  = RetainedLiquidAsset
  | RetainedSavingsAsset
  | RetainedInvestmentAsset
  deriving (Eq, Show)

-- | Retained structural role for a Budget Account.
data RetainedBudgetAccountKind
  = RetainedOpeningBudgetAccount
  | RetainedUnassignedBudgetAccount
  | RetainedSpentBudgetAccount
  | RetainedEnvelopeBudgetAccount
  deriving (Eq, Show)

-- | Retained household execution role for an Envelope allocation Account.
data RetainedEnvelopeRole
  = RetainedUnassignedEnvelopeRole
  | RetainedDynamicEnvelopeRole
  | RetainedExecutionEnvelopeRole
  deriving (Eq, Show)

-- | Retained household group evidence.
--
-- This is deliberately not 'HKernel.Budget.Pacing': @reserve@ is a separate
-- legacy coordinate, so collapsing both values would lose evidence.
data RetainedBudgetGroup
  = RetainedDailyBudgetGroup
  | RetainedFlexBudgetGroup
  | RetainedReserveBudgetGroup
  deriving (Eq, Show)

-- | Retained expense classification evidence.
data RetainedSpendClass
  = RetainedFixedSpend
  | RetainedVariableSpend
  deriving (Eq, Show)

-- | Evidence whose stable semantic owner is the general 'BudgetPolicy'.
--
-- Currently this is the Expense Account to Envelope assignment. Backing pools,
-- pacing, and Envelope definitions remain owned by @budget.toml@.
data AccountBudgetPolicyEvidence = AccountBudgetPolicyEvidence
  { accountExpenseEnvelopeEvidence :: Maybe EnvelopeId
  } deriving (Eq, Show)

-- | Evidence whose stable semantic owner is household policy or a future named
-- household overlay.
--
-- These coordinates are retained separately from 'AccountDeclaration'. They do
-- not change Account identity, accounting type, or default Commodity.
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

-- | One retained Account profile after semantic separation.
data RetainedAccountProfile = RetainedAccountProfile
  { retainedAccountDeclaration        :: AccountDeclaration
  , retainedAccountBudgetEvidence     :: AccountBudgetPolicyEvidence
  , retainedAccountHouseholdEvidence  :: AccountHouseholdPolicyEvidence
  , retainedAccountUnclassifiedMetadata :: Map Text Text
  } deriving (Eq, Show)

-- | Invalid values in coordinates whose owner is already classified.
data AccountProfileError
  = UnsupportedRetainedAssetClass Text
  | UnsupportedRetainedBudgetAccountKind Text
  | UnsupportedRetainedEnvelopeRole Text
  | UnsupportedRetainedBudgetGroup Text
  | UnsupportedRetainedFixedMarker Text
  | UnsupportedRetainedSpendClass Text
  | InvalidRetainedEnvelopeReference Text EnvelopeIdError
  deriving (Eq, Show)

-- | Separate retained metadata according to the already declared Account type.
--
-- The input map begins after physical syntax admission and after @role@ and
-- @currency@ have produced the supplied 'AccountDeclaration'. Unknown keys and
-- known keys used on a non-applicable Account type remain visible as
-- unclassified metadata.
classifyRetainedAccountProfile
  :: AccountDeclaration
  -> Map Text Text
  -> Either (NonEmpty AccountProfileError) RetainedAccountProfile
classifyRetainedAccountProfile declaration metadata =
  case NonEmpty.nonEmpty errors of
    Just values -> Left values
    Nothing -> Right RetainedAccountProfile
      { retainedAccountDeclaration = declaration
      , retainedAccountBudgetEvidence = AccountBudgetPolicyEvidence
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
