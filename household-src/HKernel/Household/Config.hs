{-# LANGUAGE OverloadedStrings #-}

-- | TOML admission for household coordinates layered on admitted current
-- Envelope, current Expense assignment, and Backing policy. Physical @budget@
-- section names remain source compatibility; no Budget domain value is
-- constructed here.
module HKernel.Household.Config
  ( HouseholdConfiguration
  , householdConfigurationPolicy
  , householdConfigurationPrimaryCommodity
  , householdConfigurationDailyTargetAssets
  , householdConfigurationAccountPolicy
  , parseHouseholdConfiguration
  , parseHouseholdPolicy
  , renderHouseholdPolicyErrors
  ) where

import Data.Either (partitionEithers)
import Data.List (foldl')
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
  ( Account
  , AccountError(..)
  , accountName
  , mkAccount
  )
import HKernel.Backing.Policy (BackingPolicy)
import HKernel.Envelope
  ( CurrentEnvelopePolicy
  , CurrentExpenseAssignments
  )
import HKernel.Envelope.Identity
  ( EnvelopeIdError(..)
  , envelopeIdText
  , mkEnvelopeId
  )
import HKernel.Household.AccountProfile
  ( HouseholdAccountPolicy
  , HouseholdAccountPolicyError(..)
  , RetainedAssetClass(..)
  , RetainedBudgetAccountKind(..)
  , RetainedBudgetGroup(..)
  , RetainedSpendClass(..)
  , mkHouseholdAccountPolicy
  )
import HKernel.Household.DailyTarget
  ( DailyTargetAssetSelection
  , DailyTargetScopeIdError(..)
  , mkDailyTargetScopeId
  , selectDailyTargetAsset
  )
import HKernel.Household.Policy
import HKernel.Money
  ( Commodity
  , CommodityError(..)
  , mkCommodity
  )
import Toml (Value, decode)
import Toml.Schema
  ( FromValue(..)
  , Result(..)
  , optKey
  , parseTableFromValue
  , reqKey
  )

data HouseholdConfiguration = HouseholdConfiguration
  { householdConfigurationPolicy            :: HouseholdPolicy
  , householdConfigurationPrimaryCommodity  :: Maybe Commodity
  , householdConfigurationDailyTargetAssets :: [DailyTargetAssetSelection]
  , householdConfigurationAccountPolicy     :: Maybe HouseholdAccountPolicy
  } deriving (Eq, Show)

data RawHouseholdPolicy = RawHouseholdPolicy
  RawCycle
  RawHouseholdEnvelopeCoordinates
  (Maybe RawMoney)
  (Maybe RawDailyTarget)
  (Maybe RawAccountPolicy)
  (Maybe Value)

data RawCycle = RawCycle Text Text

data RawHouseholdEnvelopeCoordinates = RawHouseholdEnvelopeCoordinates
  [RawEnvelopeCoordinates]
  [Text]

data RawMoney = RawMoney Text

data RawEnvelopeCoordinates = RawEnvelopeCoordinates
  Text
  Text
  (Maybe Value)

data RawDailyTarget = RawDailyTarget [RawDailyTargetAsset]

data RawDailyTargetAsset = RawDailyTargetAsset Text Text

data RawAccountPolicy = RawAccountPolicy
  RawAssetPolicy
  RawBudgetAccountPolicy
  RawExpensePolicy

data RawAssetPolicy = RawAssetPolicy [Text] [Text] [Text]

data RawBudgetAccountPolicy = RawBudgetAccountPolicy
  RawBudgetKindPolicy
  (Maybe Value)
  RawBudgetGroupPolicy

data RawBudgetKindPolicy = RawBudgetKindPolicy [Text] [Text] [Text] [Text]

data RawBudgetGroupPolicy = RawBudgetGroupPolicy [Text] [Text] [Text]

data RawExpensePolicy = RawExpensePolicy [Text] [Text]

instance FromValue RawHouseholdPolicy where
  fromValue = parseTableFromValue
    (RawHouseholdPolicy
      <$> reqKey "cycle"
      <*> reqKey "budget"
      <*> optKey "money"
      <*> optKey "daily-target"
      <*> optKey "account-policy"
      <*> optKey "envelope-history")

instance FromValue RawCycle where
  fromValue = parseTableFromValue
    (RawCycle
      <$> reqKey "mode"
      <*> reqKey "income-account")

instance FromValue RawHouseholdEnvelopeCoordinates where
  fromValue = parseTableFromValue
    (RawHouseholdEnvelopeCoordinates
      <$> reqKey "envelopes"
      <*> reqKey "unassigned-accounts")

instance FromValue RawMoney where
  fromValue = parseTableFromValue
    (RawMoney <$> reqKey "primary-commodity")

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

instance FromValue RawAccountPolicy where
  fromValue = parseTableFromValue
    (RawAccountPolicy
      <$> reqKey "assets"
      <*> reqKey "budget"
      <*> reqKey "expenses")

instance FromValue RawAssetPolicy where
  fromValue = parseTableFromValue
    (RawAssetPolicy
      <$> reqKey "liquid"
      <*> reqKey "savings"
      <*> reqKey "investment")

instance FromValue RawBudgetAccountPolicy where
  fromValue = parseTableFromValue
    (RawBudgetAccountPolicy
      <$> reqKey "kind"
      <*> optKey "envelope-role"
      <*> reqKey "group")

instance FromValue RawBudgetKindPolicy where
  fromValue = parseTableFromValue
    (RawBudgetKindPolicy
      <$> reqKey "opening"
      <*> reqKey "unassigned"
      <*> reqKey "spent"
      <*> reqKey "envelope")

instance FromValue RawBudgetGroupPolicy where
  fromValue = parseTableFromValue
    (RawBudgetGroupPolicy
      <$> reqKey "daily"
      <*> reqKey "flex"
      <*> reqKey "reserve")

instance FromValue RawExpensePolicy where
  fromValue = parseTableFromValue
    (RawExpensePolicy
      <$> reqKey "fixed"
      <*> reqKey "variable")

parseHouseholdConfiguration
  :: CurrentEnvelopePolicy
  -> BackingPolicy
  -> CurrentExpenseAssignments
  -> Text
  -> Either [Text] HouseholdConfiguration
parseHouseholdConfiguration envelopePolicy backingPolicy currentExpenses input =
  case (decode input :: Result String RawHouseholdPolicy) of
    Failure errors -> Left (map T.pack errors)
    Success warnings raw
      | null warnings ->
          rawToHouseholdConfiguration envelopePolicy backingPolicy currentExpenses raw
      | otherwise -> Left (map T.pack warnings)

parseHouseholdPolicy
  :: CurrentEnvelopePolicy
  -> BackingPolicy
  -> CurrentExpenseAssignments
  -> Text
  -> Either [Text] HouseholdPolicy
parseHouseholdPolicy envelopePolicy backingPolicy currentExpenses =
  fmap householdConfigurationPolicy
    . parseHouseholdConfiguration envelopePolicy backingPolicy currentExpenses

renderHouseholdPolicyErrors :: [Text] -> Text
renderHouseholdPolicyErrors = T.unlines . map ("  " <>)

rawToHouseholdConfiguration
  :: CurrentEnvelopePolicy
  -> BackingPolicy
  -> CurrentExpenseAssignments
  -> RawHouseholdPolicy
  -> Either [Text] HouseholdConfiguration
rawToHouseholdConfiguration envelopePolicy backingPolicy currentExpenses
    (RawHouseholdPolicy rawCycle rawCoordinates rawMoney rawDailyTarget rawAccountPolicy _rawEnvelopeHistory) = do
  policy <- rawToHouseholdPolicy
    envelopePolicy backingPolicy currentExpenses rawCycle rawCoordinates
  primaryCommodity <- traverse parseRawMoney rawMoney
  dailyTargetAssets <- parseRawDailyTarget rawDailyTarget
  accountPolicy <- traverse parseRawAccountPolicy rawAccountPolicy
  let admittedPolicy = withHouseholdAccountPolicy accountPolicy policy
  Right HouseholdConfiguration
    { householdConfigurationPolicy = admittedPolicy
    , householdConfigurationPrimaryCommodity = primaryCommodity
    , householdConfigurationDailyTargetAssets = dailyTargetAssets
    , householdConfigurationAccountPolicy = accountPolicy
    }

parseRawMoney :: RawMoney -> Either [Text] Commodity
parseRawMoney (RawMoney rawCommodity) = case mkCommodity rawCommodity of
  Right commodity -> Right commodity
  Left err -> Left [renderCommodityError "money.primary-commodity" err]

parseRawDailyTarget
  :: Maybe RawDailyTarget
  -> Either [Text] [DailyTargetAssetSelection]
parseRawDailyTarget rawDailyTarget =
  case partitionEithers
      (zipWith parseRawDailyTargetAsset [0 :: Int ..] rawAssets) of
    ([], selections) -> Right selections
    (errorGroups, _) -> Left (concat errorGroups)
  where
    rawAssets = case rawDailyTarget of
      Nothing -> []
      Just (RawDailyTarget values) -> values

rawToHouseholdPolicy
  :: CurrentEnvelopePolicy
  -> BackingPolicy
  -> CurrentExpenseAssignments
  -> RawCycle
  -> RawHouseholdEnvelopeCoordinates
  -> Either [Text] HouseholdPolicy
rawToHouseholdPolicy envelopePolicy backingPolicy currentExpenses rawCycle rawCoordinates = do
  cyclePolicy <- parseRawCycle rawCycle
  case rawCoordinates of
    RawHouseholdEnvelopeCoordinates rawEnvelopes rawUnassigned ->
      case syntaxErrors of
        [] -> case mkHouseholdPolicy
            cyclePolicy envelopePolicy backingPolicy currentExpenses
            envelopeCoordinates unassignedAccounts of
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

parseRawAccountPolicy
  :: RawAccountPolicy
  -> Either [Text] HouseholdAccountPolicy
parseRawAccountPolicy
    (RawAccountPolicy rawAssets rawBudget rawExpenses) =
  case syntaxErrors of
    _ : _ -> Left syntaxErrors
    [] -> case mkHouseholdAccountPolicy
        assetClasses budgetKinds [] budgetGroups spendClasses of
      Left errors -> Left
        (map renderHouseholdAccountPolicyError (NonEmpty.toList errors))
      Right policy -> Right policy
  where
    RawAssetPolicy liquid savings investment = rawAssets
    RawBudgetAccountPolicy rawKinds _rawEnvelopeRole rawGroups = rawBudget
    RawBudgetKindPolicy opening unassigned spent envelope = rawKinds
    RawBudgetGroupPolicy daily flex reserve = rawGroups
    RawExpensePolicy fixed variable = rawExpenses

    (liquidErrors, liquidAccounts) = axisAccounts
      "account-policy.assets.liquid" liquid
    (savingsErrors, savingsAccounts) = axisAccounts
      "account-policy.assets.savings" savings
    (investmentErrors, investmentAccounts) = axisAccounts
      "account-policy.assets.investment" investment
    assetClasses =
      map (, RetainedLiquidAsset) liquidAccounts
        ++ map (, RetainedSavingsAsset) savingsAccounts
        ++ map (, RetainedInvestmentAsset) investmentAccounts

    (openingErrors, openingAccounts) = axisAccounts
      "account-policy.budget.kind.opening" opening
    (unassignedErrors, unassignedAccounts) = axisAccounts
      "account-policy.budget.kind.unassigned" unassigned
    (spentErrors, spentAccounts) = axisAccounts
      "account-policy.budget.kind.spent" spent
    (envelopeErrors, envelopeAccounts) = axisAccounts
      "account-policy.budget.kind.envelope" envelope
    budgetKinds =
      map (, RetainedOpeningBudgetAccount) openingAccounts
        ++ map (, RetainedUnassignedBudgetAccount) unassignedAccounts
        ++ map (, RetainedSpentBudgetAccount) spentAccounts
        ++ map (, RetainedEnvelopeBudgetAccount) envelopeAccounts

    (dailyErrors, dailyAccounts) = axisAccounts
      "account-policy.budget.group.daily" daily
    (flexErrors, flexAccounts) = axisAccounts
      "account-policy.budget.group.flex" flex
    (reserveErrors, reserveAccounts) = axisAccounts
      "account-policy.budget.group.reserve" reserve
    budgetGroups =
      map (, RetainedDailyBudgetGroup) dailyAccounts
        ++ map (, RetainedFlexBudgetGroup) flexAccounts
        ++ map (, RetainedReserveBudgetGroup) reserveAccounts

    (fixedErrors, fixedAccounts) = axisAccounts
      "account-policy.expenses.fixed" fixed
    (variableErrors, variableAccounts) = axisAccounts
      "account-policy.expenses.variable" variable
    spendClasses =
      map (, RetainedFixedSpend) fixedAccounts
        ++ map (, RetainedVariableSpend) variableAccounts

    syntaxErrors = concat
      [ liquidErrors, savingsErrors, investmentErrors
      , openingErrors, unassignedErrors, spentErrors, envelopeErrors
      , dailyErrors, flexErrors, reserveErrors
      , fixedErrors, variableErrors
      ]

axisAccounts :: Text -> [Text] -> ([Text], [Account])
axisAccounts = parseAccounts

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
    (RawEnvelopeCoordinates rawId rawAllocation _rawPlanDestinations) =
  case (envelopeIdResult, allocationResult, errors) of
    (Right envelopeId, Right allocationAccount, []) -> Right
      (defineHouseholdEnvelopeCoordinates envelopeId allocationAccount)
    _ -> Left errors
  where
    path = indexedPath "budget.envelopes" index
    envelopeIdResult = mkEnvelopeId rawId
    allocationResult = mkAccount rawAllocation
    errors =
      either
        (pure . renderEnvelopeIdError (path <> ".id"))
        (const [])
        envelopeIdResult
        ++ either
          (pure . renderAccountError (path <> ".allocation-account"))
          (const [])
          allocationResult

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
    "budget.envelopes: unknown Envelope "
      <> quoted (envelopeIdText envelope)
  HouseholdEnvelopeMissingCoordinates envelope ->
    "budget.envelopes: missing household coordinates for "
      <> quoted (envelopeIdText envelope)
  DuplicateAllocationAccount account firstEnvelope repeatedEnvelope ->
    "budget.envelopes: allocation Account " <> quoted (accountName account)
      <> " belongs to both " <> quoted (envelopeIdText firstEnvelope)
      <> " and " <> quoted (envelopeIdText repeatedEnvelope)
  HouseholdPolicyHasNoUnassignedBudgetAccounts ->
    "budget.unassigned-accounts: expected at least one retained allocation Account identity"
  DuplicateUnassignedBudgetAccount account ->
    "budget.unassigned-accounts: duplicate Account "
      <> quoted (accountName account)
  AllocationAccountAlsoUnassigned account envelope ->
    "budget.unassigned-accounts: allocation Account " <> quoted (accountName account)
      <> " for envelope " <> quoted (envelopeIdText envelope)
      <> " cannot also be unassigned"

renderHouseholdAccountPolicyError :: HouseholdAccountPolicyError -> Text
renderHouseholdAccountPolicyError err = case err of
  DuplicateHouseholdAssetClassCoordinate ->
    "account-policy.assets: one Account occurs in more than one Asset class"
  DuplicateHouseholdBudgetKindCoordinate ->
    "account-policy.budget.kind: one Account occurs in more than one structural kind"
  DuplicateHouseholdEnvelopeRoleCoordinate ->
    "account-policy.budget.envelope-role: one Account occurs in more than one role"
  DuplicateHouseholdBudgetGroupCoordinate ->
    "account-policy.budget.group: one Account occurs in more than one household group"
  DuplicateHouseholdSpendClassCoordinate ->
    "account-policy.expenses: one Account occurs in more than one spend class"

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

renderCommodityError :: Text -> CommodityError -> Text
renderCommodityError path err = path <> ": " <> case err of
  EmptyCommodity -> "expected a non-empty Commodity identity"
  CommodityContainsWhitespace value ->
    "whitespace is not allowed; got " <> quoted value

renderAccountError :: Text -> AccountError -> Text
renderAccountError path err = path <> ": " <> case err of
  EmptyAccount -> "expected a non-empty Account identity"
  AccountHasSurroundingWhitespace value ->
    "surrounding whitespace is not allowed; got " <> quoted value
  AccountContainsControlCharacter value ->
    "control characters are not allowed; got " <> quoted value

quoted :: Text -> Text
quoted value = "‘" <> value <> "’"
