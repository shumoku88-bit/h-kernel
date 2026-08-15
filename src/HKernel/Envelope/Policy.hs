{-# LANGUAGE OverloadedStrings #-}

-- | Current household Envelope policy.
--
-- Stable identity, historical routing, entitlement history, and Backing each
-- have separate owners. This policy contains only current Envelope definition
-- and presentation/selection coordinates.
module HKernel.Envelope.Policy
  ( Pacing(..)
  , EnvelopeLabel
  , EnvelopeLabelError(..)
  , mkEnvelopeLabel
  , envelopeLabelText
  , EnvelopeDefinition
  , defineEnvelope
  , envelopeDefinitionId
  , envelopeDefinitionLabel
  , envelopeDefinitionPacing
  , envelopeDefinitionExpenseAccounts
  , CurrentEnvelopePolicy
  , CurrentEnvelopePolicyError(..)
  , mkCurrentEnvelopePolicy
  , currentEnvelopePolicyDefinitions
  , currentEnvelopePolicyDefinition
  , currentEnvelopePolicyEnvelopeForExpense
  , currentEnvelopePolicyBackingPolicy
  , AccountValidatedCurrentEnvelopePolicy
  , accountValidatedCurrentEnvelopePolicy
  , CurrentEnvelopePolicyAccountError(..)
  , validateCurrentEnvelopePolicyAccounts
  ) where

import Data.Char (isControl)
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
import HKernel.Backing.Policy
  ( BackingPolicy
  , BackingPolicyAccountError
  , validateBackingPolicyAccounts
  )
import HKernel.Envelope.Identity (EnvelopeId)

data Pacing = Daily | Flex
  deriving (Eq, Ord, Show)

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
  , envelopeDefinitionPacing          :: Pacing
  , envelopeDefinitionExpenseAccounts :: [Account]
  } deriving (Eq, Show)

defineEnvelope
  :: EnvelopeId
  -> EnvelopeLabel
  -> Pacing
  -> [Account]
  -> EnvelopeDefinition
defineEnvelope = EnvelopeDefinition

data CurrentEnvelopePolicy = CurrentEnvelopePolicy
  { currentDefinitions        :: Map EnvelopeId EnvelopeDefinition
  , currentExpenseAssignments :: Map Account EnvelopeId
  , currentBackingPolicy      :: BackingPolicy
  } deriving (Eq, Show)

data CurrentEnvelopePolicyError
  = CurrentEnvelopePolicyHasNoEnvelopes
  | DuplicateCurrentEnvelopeDefinition EnvelopeId
  | DuplicateCurrentEnvelopeLabel EnvelopeLabel EnvelopeId EnvelopeId
  | DuplicateCurrentExpenseAccountAssignment Account EnvelopeId EnvelopeId
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
  { coordinateValues = Map.map (snd . NonEmpty.head) grouped
  , coordinateConflicts =
      [ (key, firstValue, repeatedValue)
      | (_, key, firstValue, repeatedValue) <- sortOn position conflicts
      ]
  }
  where
    grouped = Map.fromListWith appendLater
      [ (key, NonEmpty.singleton (index, value))
      | (index, (key, value)) <- zip [(0 :: Int)..] coordinates
      ]
    appendLater later earlier = earlier <> later
    conflicts =
      [ (index, key, firstValue, repeatedValue)
      | (key, occurrences) <- Map.toList grouped
      , let firstValue = snd (NonEmpty.head occurrences)
      , (index, repeatedValue) <- NonEmpty.tail occurrences
      ]
    position (index, _, _, _) = index

mkCurrentEnvelopePolicy
  :: [EnvelopeDefinition]
  -> BackingPolicy
  -> Either (NonEmpty CurrentEnvelopePolicyError) CurrentEnvelopePolicy
mkCurrentEnvelopePolicy definitions backing =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right CurrentEnvelopePolicy
      { currentDefinitions = definitionMap
      , currentExpenseAssignments = expenseAssignments
      , currentBackingPolicy = backing
      }
  where
    definitionObservation = observeCoordinates
      [ (envelopeDefinitionId definition, definition)
      | definition <- definitions
      ]
    definitionMap = coordinateValues definitionObservation
    duplicateDefinitionErrors =
      [ DuplicateCurrentEnvelopeDefinition envelope
      | (envelope, _, _) <- coordinateConflicts definitionObservation
      ]
    labelObservation = observeCoordinates
      [ (envelopeDefinitionLabel definition, envelopeDefinitionId definition)
      | definition <- definitions
      ]
    duplicateLabelErrors =
      [ DuplicateCurrentEnvelopeLabel label firstEnvelope repeatedEnvelope
      | (label, firstEnvelope, repeatedEnvelope) <- coordinateConflicts labelObservation
      ]
    expenseObservation = observeCoordinates
      [ (account, envelopeDefinitionId definition)
      | definition <- definitions
      , account <- envelopeDefinitionExpenseAccounts definition
      ]
    expenseAssignments = coordinateValues expenseObservation
    duplicateExpenseErrors =
      [ DuplicateCurrentExpenseAccountAssignment account firstEnvelope repeatedEnvelope
      | (account, firstEnvelope, repeatedEnvelope) <- coordinateConflicts expenseObservation
      ]
    errors =
      [CurrentEnvelopePolicyHasNoEnvelopes | null definitions]
        ++ duplicateDefinitionErrors
        ++ duplicateLabelErrors
        ++ duplicateExpenseErrors

currentEnvelopePolicyDefinitions :: CurrentEnvelopePolicy -> [EnvelopeDefinition]
currentEnvelopePolicyDefinitions = Map.elems . currentDefinitions

currentEnvelopePolicyDefinition :: EnvelopeId -> CurrentEnvelopePolicy -> Maybe EnvelopeDefinition
currentEnvelopePolicyDefinition envelope = Map.lookup envelope . currentDefinitions

currentEnvelopePolicyEnvelopeForExpense :: Account -> CurrentEnvelopePolicy -> Maybe EnvelopeId
currentEnvelopePolicyEnvelopeForExpense account = Map.lookup account . currentExpenseAssignments

currentEnvelopePolicyBackingPolicy :: CurrentEnvelopePolicy -> BackingPolicy
currentEnvelopePolicyBackingPolicy = currentBackingPolicy

newtype AccountValidatedCurrentEnvelopePolicy = AccountValidatedCurrentEnvelopePolicy
  { accountValidatedCurrentEnvelopePolicy :: CurrentEnvelopePolicy
  } deriving (Eq, Show)

data CurrentEnvelopePolicyAccountError
  = CurrentEnvelopePolicyExpenseAccountUndeclared EnvelopeId Account
  | CurrentEnvelopePolicyExpenseAccountNotExpense EnvelopeId Account AccountType
  | CurrentEnvelopePolicyBackingAccountError BackingPolicyAccountError
  deriving (Eq, Show)

validateCurrentEnvelopePolicyAccounts
  :: AccountRegistry
  -> CurrentEnvelopePolicy
  -> Either (NonEmpty CurrentEnvelopePolicyAccountError) AccountValidatedCurrentEnvelopePolicy
validateCurrentEnvelopePolicyAccounts registry policy =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right (AccountValidatedCurrentEnvelopePolicy policy)
  where
    expenseErrors = concatMap validateDefinition (currentEnvelopePolicyDefinitions policy)
    backingErrors = case validateBackingPolicyAccounts registry (currentEnvelopePolicyBackingPolicy policy) of
      Right _ -> []
      Left found -> map CurrentEnvelopePolicyBackingAccountError (NonEmpty.toList found)
    errors = expenseErrors ++ backingErrors
    validateDefinition definition = concatMap
      (validateExpense (envelopeDefinitionId definition))
      (envelopeDefinitionExpenseAccounts definition)
    validateExpense envelope account =
      case lookupAccountDeclaration account registry of
        Nothing -> [CurrentEnvelopePolicyExpenseAccountUndeclared envelope account]
        Just declaration
          | declaredAccountType declaration == Expense -> []
          | otherwise ->
              [ CurrentEnvelopePolicyExpenseAccountNotExpense
                  envelope account (declaredAccountType declaration)
              ]
