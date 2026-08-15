{-# LANGUAGE OverloadedStrings #-}

module HKernel.Envelope.Config
  ( parseCurrentEnvelopeConfiguration
  , renderCurrentEnvelopeConfiguration
  , renderCurrentEnvelopeConfigurationErrors
  ) where

import Data.Either (partitionEithers)
import Data.List (foldl')
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account (Account, AccountError(..), accountName, mkAccount)
import HKernel.Backing.Identity
  ( BackingPoolIdError(..), backingPoolIdText, mkBackingPoolId )
import HKernel.Backing.Policy
  ( BackingPolicy, BackingPolicyError(..), BackingPoolDefinition, EnvelopeBackingAssignment
  , assignEnvelopeBackingPool, backingPolicyPoolDefinitions
  , backingPolicyPoolForEnvelope, backingPoolDefinitionAssetAccounts
  , backingPoolDefinitionId, defineBackingPool, mkBackingPolicy )
import HKernel.Envelope.Identity
  ( EnvelopeId, EnvelopeIdError(..), envelopeIdText, mkEnvelopeId )
import HKernel.Envelope.Policy
import Toml (decode)
import Toml.Schema (FromValue(..), Result(..), parseTableFromValue, reqKey)

data RawConfiguration = RawConfiguration [RawBackingPool] [RawEnvelope]
data RawBackingPool = RawBackingPool Text [Text]
data RawEnvelope = RawEnvelope Text Text Text Text [Text]

instance FromValue RawConfiguration where
  fromValue = parseTableFromValue
    (RawConfiguration <$> reqKey "backing-pools" <*> reqKey "envelopes")
instance FromValue RawBackingPool where
  fromValue = parseTableFromValue
    (RawBackingPool <$> reqKey "id" <*> reqKey "asset-accounts")
instance FromValue RawEnvelope where
  fromValue = parseTableFromValue
    (RawEnvelope <$> reqKey "id" <*> reqKey "label" <*> reqKey "pacing"
      <*> reqKey "backing-pool" <*> reqKey "expense-accounts")

-- | Admit three independent semantic/source owners from one retained physical
-- source. The tuple is only the parser boundary; none of the owners contains
-- either of the others.
--
-- Current Expense assignments remain source compatibility/current operational
-- policy. Historical Expense routing is admitted independently and never
-- reconstructed from this source.
parseCurrentEnvelopeConfiguration
  :: Text
  -> Either [Text] (CurrentEnvelopePolicy, BackingPolicy, CurrentExpenseAssignments)
parseCurrentEnvelopeConfiguration input =
  case decode input :: Result String RawConfiguration of
    Failure errors -> Left (map T.pack errors)
    Success warnings raw
      | null warnings -> rawToPolicies raw
      | otherwise -> Left (map T.pack warnings)

rawToPolicies
  :: RawConfiguration
  -> Either [Text] (CurrentEnvelopePolicy, BackingPolicy, CurrentExpenseAssignments)
rawToPolicies (RawConfiguration rawPools rawEnvelopes) =
  case syntaxErrors of
    _ : _ -> Left syntaxErrors
    [] -> case mkBackingPolicy poolDefinitions backingAssignments of
      Left errors -> Left (map renderBackingError (NonEmpty.toList errors))
      Right backing -> case mkCurrentEnvelopePolicy envelopeDefinitions of
        Left errors -> Left (map renderPolicyError (NonEmpty.toList errors))
        Right policy -> case mkCurrentExpenseAssignments expenseAssignments of
          Left errors -> Left (map renderCurrentExpenseAssignmentsError (NonEmpty.toList errors))
          Right currentExpenses -> Right (policy, backing, currentExpenses)
  where
    (poolErrorGroups, poolDefinitions) = partitionEithers
      (zipWith parseRawBackingPool [0 :: Int ..] rawPools)
    (envelopeErrorGroups, parsedEnvelopes) = partitionEithers
      (zipWith parseRawEnvelope [0 :: Int ..] rawEnvelopes)
    envelopeDefinitions = [definition | (definition, _, _) <- parsedEnvelopes]
    backingAssignments = [assignment | (_, assignment, _) <- parsedEnvelopes]
    expenseAssignments = concat [assignments | (_, _, assignments) <- parsedEnvelopes]
    syntaxErrors = concat poolErrorGroups ++ concat envelopeErrorGroups

parseRawBackingPool :: Int -> RawBackingPool -> Either [Text] BackingPoolDefinition
parseRawBackingPool index (RawBackingPool rawId rawAccounts) =
  case (poolResult, errors) of
    (Right pool, []) -> Right (defineBackingPool pool accounts)
    _ -> Left errors
  where
    path = indexed "backing-pools" index
    poolResult = mkBackingPoolId rawId
    (accountErrors, accounts) = parseAccounts (path <> ".asset-accounts") rawAccounts
    errors = either (pure . renderPoolIdError (path <> ".id")) (const []) poolResult ++ accountErrors

parseRawEnvelope
  :: Int
  -> RawEnvelope
  -> Either [Text] (EnvelopeDefinition, EnvelopeBackingAssignment, [(Account, EnvelopeId)])
parseRawEnvelope index (RawEnvelope rawId rawLabel rawPacing rawPool rawAccounts) =
  case (idResult, labelResult, pacingResult, poolResult, errors) of
    (Right envelope, Right label, Right pacing, Right pool, []) -> Right
      ( defineEnvelope envelope label pacing
      , assignEnvelopeBackingPool envelope pool
      , [(account, envelope) | account <- accounts]
      )
    _ -> Left errors
  where
    path = indexed "envelopes" index
    idResult = mkEnvelopeId rawId
    labelResult = mkEnvelopeLabel rawLabel
    pacingResult = parsePacing (path <> ".pacing") rawPacing
    poolResult = mkBackingPoolId rawPool
    (accountErrors, accounts) = parseAccounts (path <> ".expense-accounts") rawAccounts
    errors = either (pure . renderEnvelopeIdError (path <> ".id")) (const []) idResult
      ++ either (pure . renderLabelError (path <> ".label")) (const []) labelResult
      ++ either id (const []) pacingResult
      ++ either (pure . renderPoolIdError (path <> ".backing-pool")) (const []) poolResult
      ++ accountErrors

parsePacing :: Text -> Text -> Either [Text] Pacing
parsePacing _ "daily" = Right Daily
parsePacing _ "flex" = Right Flex
parsePacing path value = Left [path <> ": expected daily or flex; got " <> quoted value]

renderCurrentEnvelopeConfiguration
  :: CurrentEnvelopePolicy
  -> BackingPolicy
  -> CurrentExpenseAssignments
  -> Text
renderCurrentEnvelopeConfiguration policy backing currentExpenses =
  T.intercalate "\n"
    (map renderPool (backingPolicyPoolDefinitions backing)
      ++ map renderEnvelope (currentEnvelopePolicyDefinitions policy)) <> "\n"
  where
    renderPool definition = T.unlines
      [ "[[backing-pools]]"
      , "id = " <> tomlString (backingPoolIdText (backingPoolDefinitionId definition))
      , "asset-accounts = " <> renderAccountArray (backingPoolDefinitionAssetAccounts definition) ]
    renderEnvelope definition = T.unlines
      [ "[[envelopes]]"
      , "id = " <> tomlString (envelopeIdText envelope)
      , "label = " <> tomlString (envelopeLabelText (envelopeDefinitionLabel definition))
      , "pacing = " <> tomlString (renderPacing (envelopeDefinitionPacing definition))
      , "backing-pool = " <> maybe "\"\"" (tomlString . backingPoolIdText)
          (backingPolicyPoolForEnvelope envelope backing)
      , "expense-accounts = " <> renderAccountArray
          (currentExpenseAccountsForEnvelope envelope currentExpenses) ]
      where envelope = envelopeDefinitionId definition

renderPacing :: Pacing -> Text
renderPacing Daily = "daily"
renderPacing Flex = "flex"
renderCurrentEnvelopeConfigurationErrors :: [Text] -> Text
renderCurrentEnvelopeConfigurationErrors = T.unlines . map ("  " <>)

parseAccounts :: Text -> [Text] -> ([Text], [Account])
parseAccounts path = finish . foldl' add ([], []) . zip [0 :: Int ..]
  where
    add (errors, accounts) (index, raw) = case mkAccount raw of
      Right account -> (errors, account : accounts)
      Left err -> (renderAccountError (indexed path index) err : errors, accounts)
    finish (errors, accounts) = (reverse errors, reverse accounts)

renderAccountArray :: [Account] -> Text
renderAccountArray accounts = "[" <> T.intercalate ", " (map (tomlString . accountName) accounts) <> "]"
tomlString :: Text -> Text
tomlString value = "\"" <> T.concatMap escape value <> "\""
  where
    escape '\\' = "\\\\"
    escape '"' = "\\\""
    escape character = T.singleton character
indexed :: Text -> Int -> Text
indexed path index = path <> "[" <> T.pack (show index) <> "]"
quoted :: Text -> Text
quoted value = "‘" <> value <> "’"

renderAccountError :: Text -> AccountError -> Text
renderAccountError path err = path <> ": " <> case err of
  EmptyAccount -> "expected a non-empty account identity"
  AccountHasSurroundingWhitespace value -> "surrounding whitespace is not allowed; got " <> quoted value
  AccountContainsControlCharacter value -> "control characters are not allowed; got " <> quoted value
renderPoolIdError :: Text -> BackingPoolIdError -> Text
renderPoolIdError path err = path <> ": " <> case err of
  EmptyBackingPoolId -> "expected a non-empty backing pool identity"
  BackingPoolIdHasSurroundingWhitespace value -> "surrounding whitespace is not allowed; got " <> quoted value
  BackingPoolIdContainsControlCharacter value -> "control characters are not allowed; got " <> quoted value
  BackingPoolIdContainsWhitespace value -> "whitespace is not allowed; got " <> quoted value
renderEnvelopeIdError :: Text -> EnvelopeIdError -> Text
renderEnvelopeIdError path err = path <> ": " <> case err of
  EmptyEnvelopeId -> "expected a non-empty envelope identity"
  EnvelopeIdHasSurroundingWhitespace value -> "surrounding whitespace is not allowed; got " <> quoted value
  EnvelopeIdContainsControlCharacter value -> "control characters are not allowed; got " <> quoted value
  EnvelopeIdContainsWhitespace value -> "whitespace is not allowed; got " <> quoted value
  ReservedEnvelopeId value -> quoted value <> " is derived and cannot be a spendable envelope identity"
renderLabelError :: Text -> EnvelopeLabelError -> Text
renderLabelError path err = path <> ": " <> case err of
  EmptyEnvelopeLabel -> "expected a non-empty human label"
  EnvelopeLabelHasSurroundingWhitespace value -> "surrounding whitespace is not allowed; got " <> quoted value
  EnvelopeLabelContainsControlCharacter value -> "control characters are not allowed; got " <> quoted value
renderPolicyError :: CurrentEnvelopePolicyError -> Text
renderPolicyError err = case err of
  CurrentEnvelopePolicyHasNoEnvelopes -> "envelopes: expected at least one spendable envelope"
  DuplicateCurrentEnvelopeDefinition envelope -> "envelopes: duplicate identity " <> quoted (envelopeIdText envelope)
  DuplicateCurrentEnvelopeLabel label firstEnvelope secondEnvelope ->
    "envelopes: duplicate label " <> quoted (envelopeLabelText label)
      <> " for " <> quoted (envelopeIdText firstEnvelope) <> " and " <> quoted (envelopeIdText secondEnvelope)
renderCurrentExpenseAssignmentsError :: CurrentExpenseAssignmentsError -> Text
renderCurrentExpenseAssignmentsError err = case err of
  DuplicateCurrentExpenseAccountAssignment account firstEnvelope secondEnvelope ->
    "Expense account " <> quoted (accountName account) <> " is assigned to both "
      <> quoted (envelopeIdText firstEnvelope) <> " and " <> quoted (envelopeIdText secondEnvelope)
renderBackingError :: BackingPolicyError -> Text
renderBackingError err = case err of
  DuplicateBackingPoolDefinition pool -> "backing-pools: duplicate identity " <> quoted (backingPoolIdText pool)
  BackingPoolHasNoAssetAccounts pool -> "backing-pool " <> quoted (backingPoolIdText pool) <> ": expected at least one Asset account identity"
  DuplicateAssetAccountMembership account firstPool secondPool -> "Asset account " <> quoted (accountName account) <> " belongs to both " <> quoted (backingPoolIdText firstPool) <> " and " <> quoted (backingPoolIdText secondPool)
  DuplicateEnvelopeBackingAssignment envelope firstPool secondPool -> "Envelope " <> quoted (envelopeIdText envelope) <> " is assigned to both " <> quoted (backingPoolIdText firstPool) <> " and " <> quoted (backingPoolIdText secondPool)
  EnvelopeReferencesUnknownBackingPool envelope pool -> "envelope " <> quoted (envelopeIdText envelope) <> ": unknown backing pool " <> quoted (backingPoolIdText pool)
