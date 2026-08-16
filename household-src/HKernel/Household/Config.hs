{-# LANGUAGE OverloadedStrings #-}

-- | TOML admission for Household coordinates layered on independently admitted
-- current Envelope and Backing policy. Expense and Fulfillment meaning belongs
-- to explicit history in this same physical source, not to current policy.
module HKernel.Household.Config
  ( HouseholdConfiguration
  , householdConfigurationPolicy
  , householdConfigurationPrimaryCommodity
  , householdConfigurationDailyTargetAssets
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
import HKernel.Envelope (CurrentEnvelopePolicy)
import HKernel.Envelope.Identity
  ( EnvelopeIdError(..)
  , envelopeIdText
  , mkEnvelopeId
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
  } deriving (Eq, Show)

data RawHouseholdPolicy = RawHouseholdPolicy
  RawCycle
  RawHouseholdEnvelopeCoordinates
  (Maybe RawMoney)
  (Maybe RawDailyTarget)
  (Maybe Value)

data RawCycle = RawCycle Text Text

data RawHouseholdEnvelopeCoordinates = RawHouseholdEnvelopeCoordinates
  [RawEnvelopeCoordinates]
  [Text]
  [Text]

data RawMoney = RawMoney Text

data RawEnvelopeCoordinates = RawEnvelopeCoordinates Text Text

data RawDailyTarget = RawDailyTarget [RawDailyTargetAsset]

data RawDailyTargetAsset = RawDailyTargetAsset Text Text

instance FromValue RawHouseholdPolicy where
  fromValue = parseTableFromValue
    (RawHouseholdPolicy
      <$> reqKey "cycle"
      <*> reqKey "budget"
      <*> optKey "money"
      <*> optKey "daily-target"
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
      <*> reqKey "opening-accounts"
      <*> reqKey "unassigned-accounts")

instance FromValue RawMoney where
  fromValue = parseTableFromValue
    (RawMoney <$> reqKey "primary-commodity")

instance FromValue RawEnvelopeCoordinates where
  fromValue = parseTableFromValue
    (RawEnvelopeCoordinates
      <$> reqKey "id"
      <*> reqKey "allocation-account")

instance FromValue RawDailyTarget where
  fromValue = parseTableFromValue
    (RawDailyTarget <$> reqKey "assets")

instance FromValue RawDailyTargetAsset where
  fromValue = parseTableFromValue
    (RawDailyTargetAsset
      <$> reqKey "id"
      <*> reqKey "account")

parseHouseholdConfiguration
  :: CurrentEnvelopePolicy
  -> BackingPolicy
  -> Text
  -> Either [Text] HouseholdConfiguration
parseHouseholdConfiguration envelopePolicy backingPolicy input =
  case (decode input :: Result String RawHouseholdPolicy) of
    Failure errors -> Left (map T.pack errors)
    Success warnings raw
      | null warnings -> rawToHouseholdConfiguration envelopePolicy backingPolicy raw
      | otherwise -> Left (map T.pack warnings)

parseHouseholdPolicy
  :: CurrentEnvelopePolicy
  -> BackingPolicy
  -> Text
  -> Either [Text] HouseholdPolicy
parseHouseholdPolicy envelopePolicy backingPolicy =
  fmap householdConfigurationPolicy
    . parseHouseholdConfiguration envelopePolicy backingPolicy

renderHouseholdPolicyErrors :: [Text] -> Text
renderHouseholdPolicyErrors = T.unlines . map ("  " <>)

rawToHouseholdConfiguration
  :: CurrentEnvelopePolicy
  -> BackingPolicy
  -> RawHouseholdPolicy
  -> Either [Text] HouseholdConfiguration
rawToHouseholdConfiguration envelopePolicy backingPolicy
    (RawHouseholdPolicy rawCycle rawCoordinates rawMoney rawDailyTarget _rawEnvelopeHistory) = do
  policy <- rawToHouseholdPolicy envelopePolicy backingPolicy rawCycle rawCoordinates
  primaryCommodity <- traverse parseRawMoney rawMoney
  dailyTargetAssets <- parseRawDailyTarget rawDailyTarget
  Right HouseholdConfiguration
    { householdConfigurationPolicy = policy
    , householdConfigurationPrimaryCommodity = primaryCommodity
    , householdConfigurationDailyTargetAssets = dailyTargetAssets
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
  -> RawCycle
  -> RawHouseholdEnvelopeCoordinates
  -> Either [Text] HouseholdPolicy
rawToHouseholdPolicy envelopePolicy backingPolicy rawCycle rawCoordinates = do
  cyclePolicy <- parseRawCycle rawCycle
  case rawCoordinates of
    RawHouseholdEnvelopeCoordinates rawEnvelopes rawOpening rawUnassigned ->
      case syntaxErrors of
        [] -> case mkHouseholdPolicy
            cyclePolicy envelopePolicy backingPolicy envelopeCoordinates
            openingAccounts unassignedAccounts of
          Right policy -> Right policy
          Left errors -> Left
            (map renderHouseholdPolicyError (NonEmpty.toList errors))
        _ -> Left syntaxErrors
      where
        (envelopeErrorGroups, envelopeCoordinates) = partitionEithers
          (zipWith parseRawEnvelopeCoordinates [0 :: Int ..] rawEnvelopes)
        (openingErrors, openingAccounts) = parseAccounts
          "budget.opening-accounts"
          rawOpening
        (unassignedErrors, unassignedAccounts) = parseAccounts
          "budget.unassigned-accounts"
          rawUnassigned
        syntaxErrors = concat envelopeErrorGroups ++ openingErrors ++ unassignedErrors

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
    (RawEnvelopeCoordinates rawId rawAllocation) =
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
  HouseholdEnvelopeMissingCoordinates envelope ->
    "budget.envelopes: missing household coordinates for "
      <> quoted (envelopeIdText envelope)
  DuplicateAllocationAccount account firstEnvelope repeatedEnvelope ->
    "budget.envelopes: allocation Account " <> quoted (accountName account)
      <> " belongs to both " <> quoted (envelopeIdText firstEnvelope)
      <> " and " <> quoted (envelopeIdText repeatedEnvelope)
  HouseholdPolicyHasNoOpeningBudgetAccounts ->
    "budget.opening-accounts: expected at least one source Account identity"
  DuplicateOpeningBudgetAccount account ->
    "budget.opening-accounts: duplicate Account " <> quoted (accountName account)
  HouseholdPolicyHasNoUnassignedBudgetAccounts ->
    "budget.unassigned-accounts: expected at least one unallocated Account identity"
  DuplicateUnassignedBudgetAccount account ->
    "budget.unassigned-accounts: duplicate Account " <> quoted (accountName account)
  AllocationAccountAlsoOpening account envelope ->
    "budget.opening-accounts: allocation Account " <> quoted (accountName account)
      <> " for envelope " <> quoted (envelopeIdText envelope)
      <> " cannot also be an opening Account"
  AllocationAccountAlsoUnassigned account envelope ->
    "budget.unassigned-accounts: allocation Account " <> quoted (accountName account)
      <> " for envelope " <> quoted (envelopeIdText envelope)
      <> " cannot also be unassigned"
  OpeningAccountAlsoUnassigned account ->
    "budget: Account " <> quoted (accountName account)
      <> " cannot be both opening and unassigned"

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
