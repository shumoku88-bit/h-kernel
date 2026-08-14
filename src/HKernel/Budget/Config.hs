{-# LANGUAGE OverloadedStrings #-}

-- | TOML admission and canonical rendering for stable household budget policy.
--
-- Syntax is converted immediately into 'BudgetPolicy'. Later calculations never
-- depend on raw TOML values. Rendering publishes one deterministic TOML shape
-- from the already admitted policy instead of preserving incidental formatting.
module HKernel.Budget.Config
  ( parseBudgetPolicy
  , renderBudgetPolicy
  , renderBudgetPolicyErrors
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
import HKernel.Budget
  ( EnvelopeIdError(..)
  , Pacing(..)
  , envelopeIdText
  , mkEnvelopeId
  )
import HKernel.Budget.Policy
import Toml (decode)
import Toml.Schema
  ( FromValue(..)
  , Result(..)
  , parseTableFromValue
  , reqKey
  )

data RawBudgetPolicy = RawBudgetPolicy
  [RawBackingPool]
  [RawEnvelope]

data RawBackingPool = RawBackingPool Text [Text]

data RawEnvelope = RawEnvelope Text Text Text Text [Text]

instance FromValue RawBudgetPolicy where
  fromValue = parseTableFromValue
    (RawBudgetPolicy
      <$> reqKey "backing-pools"
      <*> reqKey "envelopes")

instance FromValue RawBackingPool where
  fromValue = parseTableFromValue
    (RawBackingPool
      <$> reqKey "id"
      <*> reqKey "asset-accounts")

instance FromValue RawEnvelope where
  fromValue = parseTableFromValue
    (RawEnvelope
      <$> reqKey "id"
      <*> reqKey "label"
      <*> reqKey "pacing"
      <*> reqKey "backing-pool"
      <*> reqKey "expense-accounts")

parseBudgetPolicy :: Text -> Either [Text] BudgetPolicy
parseBudgetPolicy input = case (decode input :: Result String RawBudgetPolicy) of
  Failure errors -> Left (map T.pack errors)
  Success warnings raw
    | null warnings -> rawToBudgetPolicy raw
    | otherwise -> Left (map T.pack warnings)

renderBudgetPolicy :: BudgetPolicy -> Text
renderBudgetPolicy policy =
  T.intercalate "\n"
    (map renderBackingPoolDefinition
      (budgetPolicyBackingPoolDefinitions policy)
      ++ map renderEnvelopeDefinition
        (budgetPolicyEnvelopeDefinitions policy))
  <> "\n"

renderBackingPoolDefinition :: BackingPoolDefinition -> Text
renderBackingPoolDefinition definition = T.unlines
  [ "[[backing-pools]]"
  , "id = " <> tomlString
      (backingPoolIdText (backingPoolDefinitionId definition))
  , "asset-accounts = " <> renderAccountArray
      (backingPoolDefinitionAssetAccounts definition)
  ]

renderEnvelopeDefinition :: EnvelopeDefinition -> Text
renderEnvelopeDefinition definition = T.unlines
  [ "[[envelopes]]"
  , "id = " <> tomlString
      (envelopeIdText (envelopeDefinitionId definition))
  , "label = " <> tomlString
      (envelopeLabelText (envelopeDefinitionLabel definition))
  , "pacing = " <> tomlString
      (renderPacing (envelopeDefinitionPacing definition))
  , "backing-pool = " <> tomlString
      (backingPoolIdText (envelopeDefinitionBackingPool definition))
  , "expense-accounts = " <> renderAccountArray
      (envelopeDefinitionExpenseAccounts definition)
  ]

renderPacing :: Pacing -> Text
renderPacing Daily = "daily"
renderPacing Flex = "flex"

renderAccountArray :: [Account] -> Text
renderAccountArray accounts =
  "[" <> T.intercalate ", " (map (tomlString . accountName) accounts) <> "]"

tomlString :: Text -> Text
tomlString value = "\"" <> T.concatMap escape value <> "\""
  where
    escape '\\' = "\\\\"
    escape '"' = "\\\""
    escape character = T.singleton character

renderBudgetPolicyErrors :: [Text] -> Text
renderBudgetPolicyErrors = T.unlines . map ("  " <>)

rawToBudgetPolicy :: RawBudgetPolicy -> Either [Text] BudgetPolicy
rawToBudgetPolicy (RawBudgetPolicy rawPools rawEnvelopes) =
  case syntaxErrors of
    [] -> case mkBudgetPolicy envelopeDefinitions poolDefinitions of
      Right policy -> Right policy
      Left errors -> Left (map renderPolicyError (NonEmpty.toList errors))
    _ -> Left syntaxErrors
  where
    (poolErrorGroups, poolDefinitions) = partitionEithers
      (zipWith parseRawBackingPool [0..] rawPools)
    (envelopeErrorGroups, envelopeDefinitions) = partitionEithers
      (zipWith parseRawEnvelope [0..] rawEnvelopes)
    syntaxErrors = concat poolErrorGroups ++ concat envelopeErrorGroups

parseRawBackingPool
  :: Int
  -> RawBackingPool
  -> Either [Text] BackingPoolDefinition
parseRawBackingPool index (RawBackingPool rawId rawAccounts) =
  case (poolIdResult, errors) of
    (Right poolId, []) -> Right (defineBackingPool poolId accounts)
    _                  -> Left errors
  where
    path = indexedPath "backing-pools" index
    poolIdResult = mkBackingPoolId rawId
    poolIdErrors = either
      (pure . renderBackingPoolIdError (path <> ".id"))
      (const [])
      poolIdResult
    (accountErrors, accounts) = parseAccounts
      (path <> ".asset-accounts")
      rawAccounts
    errors = poolIdErrors ++ accountErrors

parseRawEnvelope
  :: Int
  -> RawEnvelope
  -> Either [Text] EnvelopeDefinition
parseRawEnvelope index (RawEnvelope rawId rawLabel rawPacing rawPool rawAccounts) =
  case (envelopeIdResult, labelResult, pacingResult, poolResult, errors) of
    (Right envelopeId, Right label, Right pacing, Right poolId, []) ->
      Right (defineEnvelope envelopeId label pacing poolId accounts)
    _ -> Left errors
  where
    path = indexedPath "envelopes" index
    envelopeIdResult = mkEnvelopeId rawId
    labelResult = mkEnvelopeLabel rawLabel
    pacingResult = parsePacing (path <> ".pacing") rawPacing
    poolResult = mkBackingPoolId rawPool
    (accountErrors, accounts) = parseAccounts
      (path <> ".expense-accounts")
      rawAccounts
    errors =
      either
        (pure . renderEnvelopeIdError (path <> ".id"))
        (const [])
        envelopeIdResult
        ++ either
          (pure . renderEnvelopeLabelError (path <> ".label"))
          (const [])
          labelResult
        ++ either id (const []) pacingResult
        ++ either
          (pure . renderBackingPoolIdError (path <> ".backing-pool"))
          (const [])
          poolResult
        ++ accountErrors

parsePacing :: Text -> Text -> Either [Text] Pacing
parsePacing _ "daily" = Right Daily
parsePacing _ "flex" = Right Flex
parsePacing path value = Left
  [ path <> ": expected daily or flex; got " <> quoted value ]

parseAccounts :: Text -> [Text] -> ([Text], [Account])
parseAccounts path = finish . foldl' add ([], []) . zip [0..]
  where
    add (errors, accounts) (index, rawAccount) =
      case mkAccount rawAccount of
        Right account -> (errors, account : accounts)
        Left err ->
          ( renderAccountError (indexedValuePath path index) err : errors
          , accounts
          )

    finish (errors, accounts) = (reverse errors, reverse accounts)

indexedPath :: Text -> Int -> Text
indexedPath path index = path <> "[" <> T.pack (show index) <> "]"

indexedValuePath :: Text -> Int -> Text
indexedValuePath = indexedPath

renderBackingPoolIdError :: Text -> BackingPoolIdError -> Text
renderBackingPoolIdError path err = path <> ": " <> case err of
  EmptyBackingPoolId -> "expected a non-empty backing pool identity"
  BackingPoolIdHasSurroundingWhitespace value ->
    "surrounding whitespace is not allowed; got " <> quoted value
  BackingPoolIdContainsControlCharacter value ->
    "control characters are not allowed; got " <> quoted value
  BackingPoolIdContainsWhitespace value ->
    "whitespace is not allowed; got " <> quoted value

renderEnvelopeLabelError :: Text -> EnvelopeLabelError -> Text
renderEnvelopeLabelError path err = path <> ": " <> case err of
  EmptyEnvelopeLabel -> "expected a non-empty human label"
  EnvelopeLabelHasSurroundingWhitespace value ->
    "surrounding whitespace is not allowed; got " <> quoted value
  EnvelopeLabelContainsControlCharacter value ->
    "control characters are not allowed; got " <> quoted value

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

renderAccountError :: Text -> AccountError -> Text
renderAccountError path err = path <> ": " <> case err of
  EmptyAccount -> "expected a non-empty account identity"
  AccountHasSurroundingWhitespace value ->
    "surrounding whitespace is not allowed; got " <> quoted value
  AccountContainsControlCharacter value ->
    "control characters are not allowed; got " <> quoted value

renderPolicyError :: BudgetPolicyError -> Text
renderPolicyError err = case err of
  BudgetPolicyHasNoEnvelopes ->
    "envelopes: expected at least one spendable envelope"
  BudgetPolicyHasNoBackingPools ->
    "backing-pools: expected at least one backing pool"
  DuplicateEnvelopeDefinition envelope ->
    "envelopes: duplicate identity " <> quoted (envelopeIdText envelope)
  DuplicateEnvelopeLabel label firstEnvelope secondEnvelope ->
    "envelopes: duplicate label " <> quoted (envelopeLabelText label)
      <> " for " <> quoted (envelopeIdText firstEnvelope)
      <> " and " <> quoted (envelopeIdText secondEnvelope)
  DuplicateBackingPoolDefinition pool ->
    "backing-pools: duplicate identity " <> quoted (backingPoolIdText pool)
  BackingPoolHasNoAssetAccounts pool ->
    "backing-pool " <> quoted (backingPoolIdText pool)
      <> ": expected at least one Asset account identity"
  EnvelopeReferencesUnknownBackingPool envelope pool ->
    "envelope " <> quoted (envelopeIdText envelope)
      <> ": unknown backing pool " <> quoted (backingPoolIdText pool)
  DuplicateExpenseAccountAssignment account firstEnvelope secondEnvelope ->
    "Expense account " <> quoted (accountName account)
      <> " is assigned to both " <> quoted (envelopeIdText firstEnvelope)
      <> " and " <> quoted (envelopeIdText secondEnvelope)
  DuplicateAssetAccountMembership account firstPool secondPool ->
    "Asset account " <> quoted (accountName account)
      <> " belongs to both " <> quoted (backingPoolIdText firstPool)
      <> " and " <> quoted (backingPoolIdText secondPool)

quoted :: Text -> Text
quoted value = "‘" <> value <> "’"
