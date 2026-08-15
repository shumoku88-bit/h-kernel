{-# LANGUAGE OverloadedStrings #-}

-- | Current household Envelope policy and current Expense-assignment policy.
--
-- Stable identity, historical routing, entitlement history, and Backing each
-- have separate owners. 'CurrentEnvelopePolicy' contains only current Envelope
-- definition and presentation/selection coordinates. Current Expense Account
-- assignments remain a separate retained source owner and are not historical
-- routing evidence.
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
  , CurrentExpenseAssignments
  , CurrentExpenseAssignmentsError(..)
  , mkCurrentExpenseAssignments
  , currentExpenseAssignmentPairs
  , currentExpenseAssignmentFor
  , currentExpenseAccountsForEnvelope
  , AccountValidatedCurrentExpenseAssignments
  , accountValidatedCurrentExpenseAssignments
  , CurrentExpenseAssignmentsReferenceError(..)
  , validateCurrentExpenseAssignments
  , CurrentEnvelopePolicy
  , CurrentEnvelopePolicyError(..)
  , mkCurrentEnvelopePolicy
  , currentEnvelopePolicyDefinitions
  , currentEnvelopePolicyDefinition
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
  { envelopeDefinitionId     :: EnvelopeId
  , envelopeDefinitionLabel  :: EnvelopeLabel
  , envelopeDefinitionPacing :: Pacing
  } deriving (Eq, Show)

defineEnvelope
  :: EnvelopeId
  -> EnvelopeLabel
  -> Pacing
  -> EnvelopeDefinition
defineEnvelope = EnvelopeDefinition

-- | Retained current Expense Account assignments from the physical Envelope
-- configuration source.
--
-- This is current operational/source compatibility policy only. It must never
-- be interpreted as historical routing when deriving Actual consumption.
newtype CurrentExpenseAssignments = CurrentExpenseAssignments
  { currentExpenseAssignmentsByAccount :: Map Account EnvelopeId
  } deriving (Eq, Show)

data CurrentExpenseAssignmentsError
  = DuplicateCurrentExpenseAccountAssignment Account EnvelopeId EnvelopeId
  deriving (Eq, Show)

mkCurrentExpenseAssignments
  :: [(Account, EnvelopeId)]
  -> Either (NonEmpty CurrentExpenseAssignmentsError) CurrentExpenseAssignments
mkCurrentExpenseAssignments assignments =
  case NonEmpty.nonEmpty duplicateErrors of
    Just found -> Left found
    Nothing -> Right
      (CurrentExpenseAssignments (coordinateValues observation))
  where
    observation = observeCoordinates assignments
    duplicateErrors =
      [ DuplicateCurrentExpenseAccountAssignment account firstEnvelope repeatedEnvelope
      | (account, firstEnvelope, repeatedEnvelope) <- coordinateConflicts observation
      ]

currentExpenseAssignmentPairs
  :: CurrentExpenseAssignments
  -> [(Account, EnvelopeId)]
currentExpenseAssignmentPairs = Map.toAscList . currentExpenseAssignmentsByAccount

currentExpenseAssignmentFor
  :: Account
  -> CurrentExpenseAssignments
  -> Maybe EnvelopeId
currentExpenseAssignmentFor account =
  Map.lookup account . currentExpenseAssignmentsByAccount

currentExpenseAccountsForEnvelope
  :: EnvelopeId
  -> CurrentExpenseAssignments
  -> [Account]
currentExpenseAccountsForEnvelope envelope assignments =
  [ account
  | (account, assignedEnvelope) <- currentExpenseAssignmentPairs assignments
  , assignedEnvelope == envelope
  ]

newtype AccountValidatedCurrentExpenseAssignments =
  AccountValidatedCurrentExpenseAssignments
    { accountValidatedCurrentExpenseAssignments :: CurrentExpenseAssignments
    }
  deriving (Eq, Show)

data CurrentExpenseAssignmentsReferenceError
  = CurrentExpenseAssignmentAccountUndeclared Account
  | CurrentExpenseAssignmentAccountNotExpense Account AccountType
  | CurrentExpenseAssignmentReferencesUnknownEnvelope Account EnvelopeId
  deriving (Eq, Show)

validateCurrentExpenseAssignments
  :: AccountRegistry
  -> CurrentEnvelopePolicy
  -> CurrentExpenseAssignments
  -> Either
      (NonEmpty CurrentExpenseAssignmentsReferenceError)
      AccountValidatedCurrentExpenseAssignments
validateCurrentExpenseAssignments registry envelopePolicy assignments =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right (AccountValidatedCurrentExpenseAssignments assignments)
  where
    errors = concatMap validateAssignment (currentExpenseAssignmentPairs assignments)
    validateAssignment (account, envelope) =
      accountErrors account ++ envelopeErrors account envelope
    accountErrors account = case lookupAccountDeclaration account registry of
      Nothing -> [CurrentExpenseAssignmentAccountUndeclared account]
      Just declaration
        | declaredAccountType declaration == Expense -> []
        | otherwise ->
            [ CurrentExpenseAssignmentAccountNotExpense
                account (declaredAccountType declaration)
            ]
    envelopeErrors account envelope =
      [ CurrentExpenseAssignmentReferencesUnknownEnvelope account envelope
      | currentEnvelopePolicyDefinition envelope envelopePolicy == Nothing
      ]

data CurrentEnvelopePolicy = CurrentEnvelopePolicy
  { currentDefinitions :: Map EnvelopeId EnvelopeDefinition
  } deriving (Eq, Show)

data CurrentEnvelopePolicyError
  = CurrentEnvelopePolicyHasNoEnvelopes
  | DuplicateCurrentEnvelopeDefinition EnvelopeId
  | DuplicateCurrentEnvelopeLabel EnvelopeLabel EnvelopeId EnvelopeId
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
  -> Either (NonEmpty CurrentEnvelopePolicyError) CurrentEnvelopePolicy
mkCurrentEnvelopePolicy definitions =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right CurrentEnvelopePolicy
      { currentDefinitions = definitionMap
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
    errors =
      [CurrentEnvelopePolicyHasNoEnvelopes | null definitions]
        ++ duplicateDefinitionErrors
        ++ duplicateLabelErrors

currentEnvelopePolicyDefinitions :: CurrentEnvelopePolicy -> [EnvelopeDefinition]
currentEnvelopePolicyDefinitions = Map.elems . currentDefinitions

currentEnvelopePolicyDefinition :: EnvelopeId -> CurrentEnvelopePolicy -> Maybe EnvelopeDefinition
currentEnvelopePolicyDefinition envelope = Map.lookup envelope . currentDefinitions
