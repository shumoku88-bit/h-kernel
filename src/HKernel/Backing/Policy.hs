module HKernel.Backing.Policy
  ( BackingPoolDefinition
  , defineBackingPool
  , backingPoolDefinitionId
  , backingPoolDefinitionAssetAccounts
  , EnvelopeBackingAssignment
  , assignEnvelopeBackingPool
  , envelopeBackingAssignmentEnvelope
  , envelopeBackingAssignmentPool
  , BackingPolicy
  , BackingPolicyError(..)
  , mkBackingPolicy
  , backingPolicyPoolDefinitions
  , backingPolicyEnvelopeAssignments
  , backingPolicyPoolForAsset
  , backingPolicyPoolForEnvelope
  , BackingPolicyReferenceError(..)
  , validateBackingPolicyEnvelopeReferences
  , BackingPolicyAccountError(..)
  , validateBackingPolicyAccounts
  ) where

import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import HKernel.Account
  ( Account
  , AccountRegistry
  , AccountType(..)
  , declaredAccountType
  , lookupAccountDeclaration
  )
import HKernel.Backing.Identity (BackingPoolId)
import HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeRegistry
  , envelopeRegistryContains
  )

-- | Current membership policy for one funding pool.
--
-- This is not an accounting Account and does not claim historical truth. It
-- names which admitted Asset Accounts currently support one BackingPool.
data BackingPoolDefinition = BackingPoolDefinition
  { backingPoolDefinitionId            :: BackingPoolId
  , backingPoolDefinitionAssetAccounts :: [Account]
  } deriving (Eq, Show)

defineBackingPool :: BackingPoolId -> [Account] -> BackingPoolDefinition
defineBackingPool = BackingPoolDefinition

-- | Current relation from one stable Envelope identity to the BackingPool that
-- supports its claim.
--
-- This relation belongs to Backing rather than Envelope identity or accounting.
-- If historical Backing policy later becomes a requirement it needs its own
-- effective-dated evidence instead of pretending this current relation is old
-- truth.
data EnvelopeBackingAssignment = EnvelopeBackingAssignment
  { envelopeBackingAssignmentEnvelope :: EnvelopeId
  , envelopeBackingAssignmentPool     :: BackingPoolId
  } deriving (Eq, Show)

assignEnvelopeBackingPool
  :: EnvelopeId
  -> BackingPoolId
  -> EnvelopeBackingAssignment
assignEnvelopeBackingPool = EnvelopeBackingAssignment

-- | Canonical current Backing policy.
--
-- Source-order definitions are retained for deterministic publication while
-- indexed coordinates support calculation. The constructor is hidden so local
-- duplicate/unknown-pool conflicts cannot enter later lookups.
data BackingPolicy = BackingPolicy
  { policyPoolDefinitions      :: [BackingPoolDefinition]
  , policyEnvelopeAssignments :: [EnvelopeBackingAssignment]
  , policyPoolByAsset          :: Map.Map Account BackingPoolId
  , policyPoolByEnvelope       :: Map.Map EnvelopeId BackingPoolId
  } deriving (Eq, Show)

data BackingPolicyError
  = DuplicateBackingPoolDefinition BackingPoolId
  | BackingPoolHasNoAssetAccounts BackingPoolId
  | DuplicateAssetAccountMembership Account BackingPoolId BackingPoolId
  | DuplicateEnvelopeBackingAssignment EnvelopeId BackingPoolId BackingPoolId
  | EnvelopeReferencesUnknownBackingPool EnvelopeId BackingPoolId
  deriving (Eq, Show)

-- | Admit current Backing policy without consulting Envelope or Account source
-- registries.
--
-- Independent structural conflicts are accumulated deterministically. Repeated
-- coordinates retain the first admitted value and report later occurrences in
-- their source order. Cross-source Envelope existence and Asset roles are
-- separate named admissions below.
mkBackingPolicy
  :: [BackingPoolDefinition]
  -> [EnvelopeBackingAssignment]
  -> Either (NonEmpty BackingPolicyError) BackingPolicy
mkBackingPolicy poolDefinitions assignments =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right BackingPolicy
      { policyPoolDefinitions = poolDefinitions
      , policyEnvelopeAssignments = assignments
      , policyPoolByAsset = poolByAsset
      , policyPoolByEnvelope = poolByEnvelope
      }
  where
    declaredPools = Set.fromList
      (map backingPoolDefinitionId poolDefinitions)

    duplicatePoolErrors = duplicateErrors
      backingPoolDefinitionId
      DuplicateBackingPoolDefinition
      poolDefinitions

    emptyPoolErrors =
      [ BackingPoolHasNoAssetAccounts (backingPoolDefinitionId definition)
      | definition <- poolDefinitions
      , null (backingPoolDefinitionAssetAccounts definition)
      ]

    assetCoordinates =
      [ (account, backingPoolDefinitionId definition)
      | definition <- poolDefinitions
      , account <- backingPoolDefinitionAssetAccounts definition
      ]
    poolByAsset = firstMap assetCoordinates
    duplicateAssetErrors = coordinateConflictErrors
      (\account firstPool repeatedPool ->
        DuplicateAssetAccountMembership account firstPool repeatedPool)
      assetCoordinates

    envelopeCoordinates =
      [ ( envelopeBackingAssignmentEnvelope assignment
        , envelopeBackingAssignmentPool assignment
        )
      | assignment <- assignments
      ]
    poolByEnvelope = firstMap envelopeCoordinates
    duplicateEnvelopeErrors = coordinateConflictErrors
      (\envelope firstPool repeatedPool ->
        DuplicateEnvelopeBackingAssignment envelope firstPool repeatedPool)
      envelopeCoordinates

    unknownPoolErrors =
      [ EnvelopeReferencesUnknownBackingPool envelope pool
      | assignment <- assignments
      , let envelope = envelopeBackingAssignmentEnvelope assignment
            pool = envelopeBackingAssignmentPool assignment
      , pool `Set.notMember` declaredPools
      ]

    errors =
      duplicatePoolErrors
        ++ emptyPoolErrors
        ++ duplicateAssetErrors
        ++ duplicateEnvelopeErrors
        ++ unknownPoolErrors

backingPolicyPoolDefinitions :: BackingPolicy -> [BackingPoolDefinition]
backingPolicyPoolDefinitions = policyPoolDefinitions

backingPolicyEnvelopeAssignments :: BackingPolicy -> [EnvelopeBackingAssignment]
backingPolicyEnvelopeAssignments = policyEnvelopeAssignments

backingPolicyPoolForAsset :: Account -> BackingPolicy -> Maybe BackingPoolId
backingPolicyPoolForAsset account = Map.lookup account . policyPoolByAsset

backingPolicyPoolForEnvelope
  :: EnvelopeId
  -> BackingPolicy
  -> Maybe BackingPoolId
backingPolicyPoolForEnvelope envelope =
  Map.lookup envelope . policyPoolByEnvelope

-- | Stable Envelope references are separate from current Backing structure.
data BackingPolicyReferenceError
  = UnknownBackingPolicyEnvelope EnvelopeId BackingPoolId
  deriving (Eq, Show)

-- | Check every current Envelope assignment against the stable identity
-- Registry rather than current TOML-derived membership.
--
-- A registered historical identity remains a valid coordinate even if no other
-- current Envelope policy is attached to it. This admission owns existence only.
validateBackingPolicyEnvelopeReferences
  :: EnvelopeRegistry
  -> BackingPolicy
  -> Either (NonEmpty BackingPolicyReferenceError) BackingPolicy
validateBackingPolicyEnvelopeReferences registry policy =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right policy
    Just found -> Left found
  where
    errors =
      [ UnknownBackingPolicyEnvelope envelope pool
      | assignment <- backingPolicyEnvelopeAssignments policy
      , let envelope = envelopeBackingAssignmentEnvelope assignment
            pool = envelopeBackingAssignmentPool assignment
      , not (envelopeRegistryContains envelope registry)
      ]

-- | Account-role conflicts left after structural Backing policy admission.
data BackingPolicyAccountError
  = BackingPolicyAssetAccountUndeclared BackingPoolId Account
  | BackingPolicyAssetAccountNotAsset BackingPoolId Account AccountType
  deriving (Eq, Show)

-- | Prove that every funding member is an admitted Asset Account.
--
-- All independent Account conflicts accumulate in policy source order. This
-- boundary does not inspect balances or postings.
validateBackingPolicyAccounts
  :: AccountRegistry
  -> BackingPolicy
  -> Either (NonEmpty BackingPolicyAccountError) BackingPolicy
validateBackingPolicyAccounts registry policy =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right policy
    Just found -> Left found
  where
    errors = concatMap validatePool (backingPolicyPoolDefinitions policy)

    validatePool definition = concatMap
      (validateAsset (backingPoolDefinitionId definition))
      (backingPoolDefinitionAssetAccounts definition)

    validateAsset pool account =
      case lookupAccountDeclaration account registry of
        Nothing -> [BackingPolicyAssetAccountUndeclared pool account]
        Just declaration
          | declaredAccountType declaration == Asset -> []
          | otherwise ->
              [ BackingPolicyAssetAccountNotAsset
                  pool
                  account
                  (declaredAccountType declaration)
              ]

firstMap :: Ord key => [(key, value)] -> Map.Map key value
firstMap = foldl' insertFirst Map.empty
  where
    insertFirst accum (key, value) =
      Map.insertWith (\_new old -> old) key value accum

duplicateErrors
  :: Ord key
  => (value -> key)
  -> (key -> error)
  -> [value]
  -> [error]
duplicateErrors keyOf makeError = go Set.empty
  where
    go _ [] = []
    go seen (value : rest)
      | key `Set.member` seen = makeError key : go seen rest
      | otherwise = go (Set.insert key seen) rest
      where
        key = keyOf value

coordinateConflictErrors
  :: Ord key
  => (key -> value -> value -> error)
  -> [(key, value)]
  -> [error]
coordinateConflictErrors makeError = go Map.empty
  where
    go _ [] = []
    go seen ((key, value) : rest) = case Map.lookup key seen of
      Nothing -> go (Map.insert key value seen) rest
      Just firstValue -> makeError key firstValue value : go seen rest
