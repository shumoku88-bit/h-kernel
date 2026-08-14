{-# LANGUAGE OverloadedStrings #-}

-- | Stable household budget policy independent from TOML syntax and Journal
-- validation.
--
-- Policy connects spendable envelopes to backing pools, Expense account
-- identities to envelopes, and Asset account identities to backing pools. It
-- does not calculate entitlement, consumption, backing, or presentation.
module HKernel.Budget.Policy
  ( BackingPoolId
  , BackingPoolIdError(..)
  , mkBackingPoolId
  , backingPoolIdText
  , EnvelopeLabel
  , EnvelopeLabelError(..)
  , mkEnvelopeLabel
  , envelopeLabelText
  , EnvelopeDefinition
  , defineEnvelope
  , defineEnvelopeWithMode
  , envelopeDefinitionId
  , envelopeDefinitionLabel
  , envelopeDefinitionMode
  , envelopeDefinitionBackingPool
  , envelopeDefinitionExpenseAccounts
  , BackingPoolDefinition
  , defineBackingPool
  , backingPoolDefinitionId
  , backingPoolDefinitionAssetAccounts
  , BudgetPolicy
  , BudgetPolicyError(..)
  , mkBudgetPolicy
  , AccountValidatedBudgetPolicy
  , accountValidatedBudgetPolicy
  , BudgetPolicyAccountError(..)
  , validateBudgetPolicyAccounts
  , budgetPolicyEnvelopeDefinitions
  , budgetPolicyBackingPoolDefinitions
  , budgetPolicyEnvelopeDefinition
  , budgetPolicyBackingPoolDefinition
  , budgetPolicyEnvelopeForExpense
  , budgetPolicyBackingPoolForAsset
  ) where

import Data.Char (isControl, isSpace)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
  ( Account
  , AccountRegistry
  , AccountType(..)
  , declaredAccountType
  , lookupAccountDeclaration
  )
import HKernel.Budget (EnvelopeId, Pacing(..))
import HKernel.Envelope.Mode (EnvelopeMode)
import qualified HKernel.Envelope.Mode as EnvelopeMode

newtype BackingPoolId = BackingPoolId { backingPoolIdText :: Text }
  deriving (Eq, Ord, Show)

data BackingPoolIdError
  = EmptyBackingPoolId
  | BackingPoolIdHasSurroundingWhitespace Text
  | BackingPoolIdContainsControlCharacter Text
  | BackingPoolIdContainsWhitespace Text
  deriving (Eq, Show)

mkBackingPoolId :: Text -> Either BackingPoolIdError BackingPoolId
mkBackingPoolId value
  | T.null value = Left EmptyBackingPoolId
  | T.strip value /= value = Left (BackingPoolIdHasSurroundingWhitespace value)
  | T.any isControl value = Left (BackingPoolIdContainsControlCharacter value)
  | T.any isSpace value = Left (BackingPoolIdContainsWhitespace value)
  | otherwise = Right (BackingPoolId value)

newtype EnvelopeLabel = EnvelopeLabel { envelopeLabelText :: Text }
  deriving (Eq, Ord, Show)

data EnvelopeLabelError
  = EmptyEnvelopeLabel
  | EnvelopeLabelHasSurroundingWhitespace Text
  | EnvelopeLabelContainsControlCharacter Text
  deriving (Eq, Show)

mkEnvelopeLabel :: Text -> Either EnvelopeLabelError EnvelopeLabel
mkEnvelopeLabel value
  | T.null value = Left EmptyEnvelopeLabel
  | T.strip value /= value = Left (EnvelopeLabelHasSurroundingWhitespace value)
  | T.any isControl value = Left (EnvelopeLabelContainsControlCharacter value)
  | otherwise = Right (EnvelopeLabel value)

data EnvelopeDefinition = EnvelopeDefinition
  { envelopeDefinitionId              :: EnvelopeId
  , envelopeDefinitionLabel           :: EnvelopeLabel
  , envelopeDefinitionMode            :: EnvelopeMode
  , envelopeDefinitionBackingPool     :: BackingPoolId
  , envelopeDefinitionExpenseAccounts :: [Account]
  } deriving (Eq, Show)

defineEnvelope
  :: EnvelopeId
  -> EnvelopeLabel
  -> Pacing
  -> BackingPoolId
  -> [Account]
  -> EnvelopeDefinition
defineEnvelope envelope label pacing pool accounts =
  defineEnvelopeWithMode envelope label (pacingToMode pacing) pool accounts

defineEnvelopeWithMode
  :: EnvelopeId
  -> EnvelopeLabel
  -> EnvelopeMode
  -> BackingPoolId
  -> [Account]
  -> EnvelopeDefinition
defineEnvelopeWithMode = EnvelopeDefinition

pacingToMode :: Pacing -> EnvelopeMode
pacingToMode Daily = EnvelopeMode.Daily
pacingToMode Flex = EnvelopeMode.Flex

data BackingPoolDefinition = BackingPoolDefinition
  { backingPoolDefinitionId            :: BackingPoolId
  , backingPoolDefinitionAssetAccounts :: [Account]
  } deriving (Eq, Show)

defineBackingPool :: BackingPoolId -> [Account] -> BackingPoolDefinition
defineBackingPool = BackingPoolDefinition

data BudgetPolicy = BudgetPolicy
  { policyEnvelopes          :: Map EnvelopeId EnvelopeDefinition
  , policyBackingPools       :: Map BackingPoolId BackingPoolDefinition
  , policyExpenseAssignments :: Map Account EnvelopeId
  , policyAssetMemberships   :: Map Account BackingPoolId
  } deriving (Eq, Show)

data BudgetPolicyError
  = BudgetPolicyHasNoEnvelopes
  | BudgetPolicyHasNoBackingPools
  | DuplicateEnvelopeDefinition EnvelopeId
  | DuplicateEnvelopeLabel EnvelopeLabel EnvelopeId EnvelopeId
  | DuplicateBackingPoolDefinition BackingPoolId
  | BackingPoolHasNoAssetAccounts BackingPoolId
  | EnvelopeReferencesUnknownBackingPool EnvelopeId BackingPoolId
  | DuplicateExpenseAccountAssignment Account EnvelopeId EnvelopeId
  | DuplicateAssetAccountMembership Account BackingPoolId BackingPoolId
  deriving (Eq, Show)

data CoordinateObservation key value = CoordinateObservation
  { coordinateValues    :: Map key value
  , coordinateConflicts :: [(key, value, value)]
  }

observeCoordinates
  :: Ord key
  => [(key, value)]
  -> CoordinateObservation key value
observeCoordinates coordinates = CoordinateObservation
  { coordinateValues = Map.map (snd . NonEmpty.head) groupedCoordinates
  , coordinateConflicts =
      [ (key, firstValue, repeatedValue)
      | (_, key, firstValue, repeatedValue) <- sortOn conflictPosition conflictsByPosition
      ]
  }
  where
    groupedCoordinates = Map.fromListWith appendLaterOccurrence
      [ (key, NonEmpty.singleton (position, value))
      | (position, (key, value)) <- zip [(0 :: Int)..] coordinates
      ]
    appendLaterOccurrence laterOccurrences earlierOccurrences = earlierOccurrences <> laterOccurrences
    conflictsByPosition =
      [ (position, key, firstValue, repeatedValue)
      | (key, occurrences) <- Map.toList groupedCoordinates
      , let firstValue = snd (NonEmpty.head occurrences)
      , (position, repeatedValue) <- NonEmpty.tail occurrences
      ]
    conflictPosition (position, _, _, _) = position

mkBudgetPolicy
  :: [EnvelopeDefinition]
  -> [BackingPoolDefinition]
  -> Either (NonEmpty BudgetPolicyError) BudgetPolicy
mkBudgetPolicy envelopeDefinitions backingPoolDefinitions =
  case NonEmpty.nonEmpty errors of
    Just nonEmptyErrors -> Left nonEmptyErrors
    Nothing -> Right BudgetPolicy
      { policyEnvelopes = envelopeMap
      , policyBackingPools = backingPoolMap
      , policyExpenseAssignments = expenseAssignments
      , policyAssetMemberships = assetMemberships
      }
  where
    envelopeCoordinates =
      [ (envelopeDefinitionId definition, definition)
      | definition <- envelopeDefinitions
      ]
    envelopeObservation = observeCoordinates envelopeCoordinates
    envelopeMap = coordinateValues envelopeObservation
    duplicateEnvelopeErrors =
      [ DuplicateEnvelopeDefinition envelope
      | (envelope, _, _) <- coordinateConflicts envelopeObservation
      ]
    labelCoordinates =
      [ (envelopeDefinitionLabel definition, envelopeDefinitionId definition)
      | definition <- envelopeDefinitions
      ]
    labelObservation = observeCoordinates labelCoordinates
    duplicateLabelErrors =
      [ DuplicateEnvelopeLabel label firstEnvelope repeatedEnvelope
      | (label, firstEnvelope, repeatedEnvelope) <- coordinateConflicts labelObservation
      ]
    backingPoolCoordinates =
      [ (backingPoolDefinitionId definition, definition)
      | definition <- backingPoolDefinitions
      ]
    backingPoolObservation = observeCoordinates backingPoolCoordinates
    backingPoolMap = coordinateValues backingPoolObservation
    duplicatePoolErrors =
      [ DuplicateBackingPoolDefinition pool
      | (pool, _, _) <- coordinateConflicts backingPoolObservation
      ]
    expenseCoordinates =
      [ (account, envelopeDefinitionId definition)
      | definition <- envelopeDefinitions
      , account <- envelopeDefinitionExpenseAccounts definition
      ]
    expenseObservation = observeCoordinates expenseCoordinates
    expenseAssignments = coordinateValues expenseObservation
    duplicateExpenseErrors =
      [ DuplicateExpenseAccountAssignment account firstEnvelope repeatedEnvelope
      | (account, firstEnvelope, repeatedEnvelope) <- coordinateConflicts expenseObservation
      ]
    assetCoordinates =
      [ (account, backingPoolDefinitionId definition)
      | definition <- backingPoolDefinitions
      , account <- backingPoolDefinitionAssetAccounts definition
      ]
    assetObservation = observeCoordinates assetCoordinates
    assetMemberships = coordinateValues assetObservation
    duplicateAssetErrors =
      [ DuplicateAssetAccountMembership account firstPool repeatedPool
      | (account, firstPool, repeatedPool) <- coordinateConflicts assetObservation
      ]
    emptyPoolErrors =
      [ BackingPoolHasNoAssetAccounts (backingPoolDefinitionId definition)
      | definition <- backingPoolDefinitions
      , null (backingPoolDefinitionAssetAccounts definition)
      ]
    unknownPoolErrors =
      [ EnvelopeReferencesUnknownBackingPool
          (envelopeDefinitionId definition)
          (envelopeDefinitionBackingPool definition)
      | definition <- envelopeDefinitions
      , Map.notMember (envelopeDefinitionBackingPool definition) backingPoolMap
      ]
    presenceErrors =
      [ BudgetPolicyHasNoEnvelopes | null envelopeDefinitions ]
        ++ [ BudgetPolicyHasNoBackingPools | null backingPoolDefinitions ]
    errors = presenceErrors
      ++ duplicateEnvelopeErrors
      ++ duplicateLabelErrors
      ++ duplicatePoolErrors
      ++ emptyPoolErrors
      ++ unknownPoolErrors
      ++ duplicateExpenseErrors
      ++ duplicateAssetErrors

newtype AccountValidatedBudgetPolicy = AccountValidatedBudgetPolicy
  { accountValidatedBudgetPolicy :: BudgetPolicy
  } deriving (Eq, Show)

data BudgetPolicyAccountError
  = BudgetPolicyExpenseAccountUndeclared EnvelopeId Account
  | BudgetPolicyExpenseAccountNotExpense EnvelopeId Account AccountType
  | BudgetPolicyAssetAccountUndeclared BackingPoolId Account
  | BudgetPolicyAssetAccountNotAsset BackingPoolId Account AccountType
  deriving (Eq, Show)

validateBudgetPolicyAccounts
  :: AccountRegistry
  -> BudgetPolicy
  -> Either (NonEmpty BudgetPolicyAccountError) AccountValidatedBudgetPolicy
validateBudgetPolicyAccounts registry policy =
  case NonEmpty.nonEmpty errors of
    Just nonEmptyErrors -> Left nonEmptyErrors
    Nothing -> Right (AccountValidatedBudgetPolicy policy)
  where
    errors =
      concatMap validateEnvelope (budgetPolicyEnvelopeDefinitions policy)
        ++ concatMap validateBackingPool (budgetPolicyBackingPoolDefinitions policy)
    validateEnvelope definition =
      concatMap
        (validateExpenseAccount (envelopeDefinitionId definition))
        (envelopeDefinitionExpenseAccounts definition)
    validateExpenseAccount envelope account =
      case lookupAccountDeclaration account registry of
        Nothing -> [BudgetPolicyExpenseAccountUndeclared envelope account]
        Just declaration
          | declaredAccountType declaration == Expense -> []
          | otherwise ->
              [ BudgetPolicyExpenseAccountNotExpense envelope account
                  (declaredAccountType declaration)
              ]
    validateBackingPool definition =
      concatMap
        (validateAssetAccount (backingPoolDefinitionId definition))
        (backingPoolDefinitionAssetAccounts definition)
    validateAssetAccount pool account =
      case lookupAccountDeclaration account registry of
        Nothing -> [BudgetPolicyAssetAccountUndeclared pool account]
        Just declaration
          | declaredAccountType declaration == Asset -> []
          | otherwise ->
              [ BudgetPolicyAssetAccountNotAsset pool account
                  (declaredAccountType declaration)
              ]

budgetPolicyEnvelopeDefinitions :: BudgetPolicy -> [EnvelopeDefinition]
budgetPolicyEnvelopeDefinitions = Map.elems . policyEnvelopes

budgetPolicyBackingPoolDefinitions :: BudgetPolicy -> [BackingPoolDefinition]
budgetPolicyBackingPoolDefinitions = Map.elems . policyBackingPools

budgetPolicyEnvelopeDefinition
  :: EnvelopeId
  -> BudgetPolicy
  -> Maybe EnvelopeDefinition
budgetPolicyEnvelopeDefinition envelope = Map.lookup envelope . policyEnvelopes

budgetPolicyBackingPoolDefinition
  :: BackingPoolId
  -> BudgetPolicy
  -> Maybe BackingPoolDefinition
budgetPolicyBackingPoolDefinition pool = Map.lookup pool . policyBackingPools

budgetPolicyEnvelopeForExpense :: Account -> BudgetPolicy -> Maybe EnvelopeId
budgetPolicyEnvelopeForExpense account = Map.lookup account . policyExpenseAssignments

budgetPolicyBackingPoolForAsset :: Account -> BudgetPolicy -> Maybe BackingPoolId
budgetPolicyBackingPoolForAsset account = Map.lookup account . policyAssetMemberships
