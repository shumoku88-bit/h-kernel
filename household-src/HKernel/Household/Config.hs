{-# LANGUAGE OverloadedStrings #-}

-- | TOML admission for household coordinates layered on an admitted
-- 'BudgetPolicy'.
--
-- General envelope, pacing, Expense assignment, and backing-pool syntax belongs
-- to 'HKernel.Budget.Config'. This module parses only household-specific
-- coordinates and combines both values immediately into typed configuration.
module HKernel.Household.Config
  ( HouseholdConfiguration
  , householdConfigurationPolicy
  , householdConfigurationDailyTargetAssets
  , parseHouseholdConfiguration
  , parseHouseholdPolicy
  , renderHouseholdPolicyErrors
  ) where

import Data.Either (partitionEithers)
import Data.List (foldl')
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
  ( Account
  , AccountError(..)
  , accountName
  , mkAccount
  )
import HKernel.Budget
  ( EnvelopeIdError(..)
  , envelopeIdText
  , mkEnvelopeId
  )
import HKernel.Budget.Policy (BudgetPolicy)
import HKernel.Household.DailyTarget
  ( DailyTargetAssetSelection
  , DailyTargetScopeIdError(..)
  , mkDailyTargetScopeId
  , selectDailyTargetAsset
  )
import HKernel.Household.Policy
import Toml (decode)
import Toml.Schema
  ( FromValue(..)
  , Result(..)
  , optKey
  , parseTableFromValue
  , reqKey
  )

data HouseholdConfiguration = HouseholdConfiguration
  { householdConfigurationPolicy            :: HouseholdPolicy
  , householdConfigurationDailyTargetAssets :: [DailyTargetAssetSelection]
  } deriving (Eq, Show)

data RawHouseholdPolicy = RawHouseholdPolicy
  RawCycle
  RawHouseholdBudget
  (Maybe RawDailyTarget)

data RawCycle = RawCycle Text Text

data RawHouseholdBudget = RawHouseholdBudget
  [RawEnvelopeCoordinates]
  [Text]

data RawEnvelopeCoordinates = RawEnvelopeCoordinates
  Text
  Text
  (Maybe [Text])

data RawDailyTarget = RawDailyTarget [RawDailyTargetAsset]

data RawDailyTargetAsset = RawDailyTargetAsset Text Text

instance FromValue RawHouseholdPolicy where
  fromValue = parseTableFromValue
    (RawHouseholdPolicy
      <$> reqKey "cycle"
      <*> reqKey "budget"
      <*> optKey "daily-target")

instance FromValue RawCycle where
  fromValue = parseTableFromValue
    (RawCycle
      <$> reqKey "mode"
      <*> reqKey "income-account")

instance FromValue RawHouseholdBudget where
  fromValue = parseTableFromValue
    (RawHouseholdBudget
      <$> reqKey "envelopes"
      <*> reqKey "unassigned-accounts")

instance FromValue RawEnvelopeCoordinates where
  fromValue = parseTableFromValue
    (RawEnvelopeCoordinates
      <$> reqKey "id"
      <*> reqKey "allocation-account"
      <*> optKey "plan-destination-accounts")

instance FromValue RawDailyTarget where
  fromValue = parseTableFromValue
    (RawDailyTarget <$> reqKey "assets")

instance FromValue RawDailyTargetAsset where
  fromValue = parseTableFromValue
    (RawDailyTargetAsset
      <$> reqKey "id"
      <*> reqKey "account")

-- | Decode @household.toml@ into stable household policy plus source-independent
-- Daily Target Asset selections. Unknown keys are rejected rather than retained
-- as warnings.
parseHouseholdConfiguration
  :: BudgetPolicy
  -> Text
  -> Either [Text] HouseholdConfiguration
parseHouseholdConfiguration budgetPolicy input =
  case (decode input :: Result String RawHouseholdPolicy) of
    Failure errors -> Left (map T.pack errors)
    Success warnings raw
      | null warnings -> rawToHouseholdConfiguration budgetPolicy raw
      | otherwise -> Left (map T.pack warnings)

-- | Compatibility projection for callers that only need household policy.
parseHouseholdPolicy
  :: BudgetPolicy
  -> Text
  -> Either [Text] HouseholdPolicy
parseHouseholdPolicy budgetPolicy =
  fmap householdConfigurationPolicy . parseHouseholdConfiguration budgetPolicy

renderHouseholdPolicyErrors :: [Text] -> Text
renderHouseholdPolicyErrors = T.unlines . map ("  " <>)

rawToHouseholdConfiguration
  :: BudgetPolicy
  -> RawHouseholdPolicy
  -> Either [Text] HouseholdConfiguration
rawToHouseholdConfiguration budgetPolicy
    (RawHouseholdPolicy rawCycle rawHouseholdBudget rawDailyTarget) = do
  policy <- rawToHouseholdPolicy budgetPolicy rawCycle rawHouseholdBudget
  case partitionEithers
      (zipWith parseRawDailyTargetAsset [0 :: Int ..] rawAssets) of
    ([], selections) -> Right HouseholdConfiguration
      { householdConfigurationPolicy = policy
      , householdConfigurationDailyTargetAssets = selections
      }
    (errorGroups, _) -> Left (concat errorGroups)
  where
    rawAssets = case rawDailyTarget of
      Nothing -> []
      Just (RawDailyTarget values) -> values

rawToHouseholdPolicy
  :: BudgetPolicy
  -> RawCycle
  -> RawHouseholdBudget
  -> Either [Text] HouseholdPolicy
rawToHouseholdPolicy budgetPolicy rawCycle rawHouseholdBudget = do
  cyclePolicy <- parseRawCycle rawCycle
  case rawHouseholdBudget of
    RawHouseholdBudget rawEnvelopes rawUnassigned ->
      case syntaxErrors of
        [] -> case mkHouseholdPolicy
            cyclePolicy budgetPolicy envelopeCoordinates unassignedAccounts of
          Right policy -> Right policy
          Left errors -> Left
            (map renderHouseholdPolicyError (NonEmpty.toList errors))
        _ -> Left syntaxErrors
      where
        (envelopeErrorGroups, envelopeCoordinates) = partitionEithers
          (zipWith parseRawEnvelopeCoordinates [0 :: Int ..] rawEnvelopes)
        (unassignedErrors, unassignedAccounts) = parseAccounts
          "budget.unassigned-accounts"
          rawUnassigned
        syntaxErrors = concat envelopeErrorGroups ++ unassignedErrors

parseRawCycle :: RawCycle -> Either [Text] HouseholdCyclePolicy
parseRawCycle (RawCycle rawMode rawAccount)
  | rawMode /= "income-anchor" = Left
      [ "cycle.mode: expected income-anchor; got " <> quoted rawMode ]
  | otherwise = case mkAccount rawAccount of
      Right account -> Right (incomeAnchorCyclePolicy account)
      Left err -> Left [renderAccountError "cycle.income-account" err]

parseRawEnvelopeCoordinates
  :: Int
  -> RawEnvelopeCoordinates
  -> Either [Text] HouseholdEnvelopeCoordinates
parseRawEnvelopeCoordinates index
    (RawEnvelopeCoordinates rawId rawAllocation rawPlanDestinations) =
  case (envelopeIdResult, allocationResult, errors) of
    (Right envelopeId, Right allocationAccount, []) -> Right
      (defineHouseholdEnvelopeCoordinates
        envelopeId allocationAccount planDestinationAccounts)
    _ -> Left errors
  where
    path = indexedPath "budget.envelopes" index
    envelopeIdResult = mkEnvelopeId rawId
    allocationResult = mkAccount rawAllocation
    (planErrors, planDestinationAccounts) = parseAccounts
      (path <> ".plan-destination-accounts")
      (fromMaybe [] rawPlanDestinations)
    errors =
      either
        (pure . renderEnvelopeIdError (path <> ".id"))
        (const [])
        envelopeIdResult
        ++ either
          (pure . renderAccountError (path <> ".allocation-account"))
          (const [])
          allocationResult
        ++ planErrors

parseRawDailyTargetAsset
  :: Int
  -> RawDailyTargetAsset
  -> Either [Text] DailyTargetAssetSelection
parseRawDailyTargetAsset index (RawDailyTargetAsset rawId rawAccount) =
  case (idResult, accountResult, errors) of
    (Right scopeId, Right account, []) ->
      Right (selectDailyTargetAsset scopeId account)
    _ -> Left errors
  where
    path = indexedPath "daily-target.assets" index
    idResult = mkDailyTargetScopeId rawId
    accountResult = mkAccount rawAccount
    errors =
      either
        (pure . renderDailyTargetScopeIdError (path <> ".id"))
        (const [])
        idResult
        ++ either
          (pure . renderAccountError (path <> ".account"))
          (const [])
          accountResult

parseAccounts :: Text -> [Text] -> ([Text], [Account])
parseAccounts path = finish . foldl' add ([], []) . zip [0 :: Int ..]
  where
    add (errors, accounts) (index, rawAccount) =
      case mkAccount rawAccount of
        Right account -> (errors, account : accounts)
        Left err ->
          ( renderAccountError (indexedPath path index) err : errors
          , accounts
          )
    finish (errors, accounts) = (reverse errors, reverse accounts)

indexedPath :: Text -> Int -> Text
indexedPath path index = path <> "[" <> T.pack (show index) <> "]"

renderHouseholdPolicyError :: HouseholdPolicyError -> Text
renderHouseholdPolicyError err = case err of
  DuplicateHouseholdEnvelopeCoordinates envelope ->
    "budget.envelopes: duplicate household coordinates for "
      <> quoted (envelopeIdText envelope)
  HouseholdCoordinatesReferenceUnknownEnvelope envelope ->
    "budget.envelopes: unknown Budget envelope "
      <> quoted (envelopeIdText envelope)
  HouseholdEnvelopeMissingCoordinates envelope ->
    "budget.envelopes: missing household coordinates for "
      <> quoted (envelopeIdText envelope)
  DuplicateAllocationAccount account firstEnvelope repeatedEnvelope ->
    "budget.envelopes: allocation Account " <> quoted (accountName account)
      <> " belongs to both " <> quoted (envelopeIdText firstEnvelope)
      <> " and " <> quoted (envelopeIdText repeatedEnvelope)
  DuplicatePlanDestinationAccount account firstEnvelope repeatedEnvelope ->
    "budget.envelopes: Plan destination Account " <> quoted (accountName account)
      <> " belongs to both " <> quoted (envelopeIdText firstEnvelope)
      <> " and " <> quoted (envelopeIdText repeatedEnvelope)
  HouseholdPolicyHasNoUnassignedBudgetAccounts ->
    "budget.unassigned-accounts: expected at least one Budget Account identity"
  DuplicateUnassignedBudgetAccount account ->
    "budget.unassigned-accounts: duplicate Account "
      <> quoted (accountName account)
  AllocationAccountAlsoUnassigned account envelope ->
    "budget.unassigned-accounts: allocation Account " <> quoted (accountName account)
      <> " for envelope " <> quoted (envelopeIdText envelope)
      <> " cannot also be unassigned"

renderEnvelopeIdError :: Text -> EnvelopeIdError -> Text
renderEnvelopeIdError path err = path <> ": " <> case err of
  EmptyEnvelopeId -> "expected a non-empty envelope identity"
  EnvelopeIdHasSurroundingWhitespace value ->
    "surrounding whitespace is not allowed; got " <> quoted value
  EnvelopeIdContainsControlCharacter value ->
    "control characters are not allowed; got " <> quoted value
  EnvelopeIdContainsWhitespace value ->
    "whitespace is not allowed; got " <> quoted value
  ReservedEnvelopeId value ->
    quoted value <> " is derived and cannot be a spendable envelope identity"

renderDailyTargetScopeIdError :: Text -> DailyTargetScopeIdError -> Text
renderDailyTargetScopeIdError path err = path <> ": " <> case err of
  EmptyDailyTargetScopeId -> "expected a non-empty Daily Target selection identity"

renderAccountError :: Text -> AccountError -> Text
renderAccountError path err = path <> ": " <> case err of
  EmptyAccount -> "expected a non-empty Account identity"
  AccountHasSurroundingWhitespace value ->
    "surrounding whitespace is not allowed; got " <> quoted value
  AccountContainsControlCharacter value ->
    "control characters are not allowed; got " <> quoted value

quoted :: Text -> Text
quoted value = "‘" <> value <> "’"
