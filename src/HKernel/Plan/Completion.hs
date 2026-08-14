-- | Explicit Plan-to-Actual completion evidence.
--
-- This module does not infer completion from date, description, amount, or
-- account shape. A source boundary must provide durable Plan and Actual
-- identities plus an explicit relation. Resolution then proves that every
-- reference names admitted facts and is not ambiguous for one Plan.
module HKernel.Plan.Completion
  ( ActualTransactionId
  , ActualTransactionIdError(..)
  , mkActualTransactionId
  , actualTransactionIdText
  , IdentifiedActualTransaction
  , identifyActualTransaction
  , identifiedActualId
  , identifiedActualTransaction
  , PlanCompletionDeclaration
  , declarePlanCompletion
  , declaredCompletionPlanId
  , declaredCompletionActualId
  , PlanCompletionEvidence
  , completionPlan
  , completionActual
  , PlanCompletionError(..)
  , PlanCompletionShapeError(..)
  , validatePlanCompletionShape
  , resolvePlanCompletionEvidence
  , resolveOpenCommittedOutgoingPlans
  ) where

import Data.Char (isControl, isSpace)
import Data.Either (partitionEithers)
import qualified Data.Foldable as Foldable
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Ledger
  ( Transaction
  , postingAccount
  , postingAmount
  , transactionPostings
  )
import HKernel.Money
  ( amountCommodity
  , amountQuantity
  , zeroQuantity
  )
import HKernel.Plan
  ( CommittedOutgoingPlan
  , PlanId
  , committedPlanId
  )

-- | Durable source identity for one admitted Actual transaction.
--
-- This identity is deliberately separate from a Journal source line. A source
-- adapter may choose its own stable representation, but it must pass this
-- admission boundary before participating in a completion relation.
newtype ActualTransactionId = ActualTransactionId
  { actualTransactionIdText :: Text
  } deriving (Eq, Ord, Show)

data ActualTransactionIdError
  = EmptyActualTransactionId
  | ActualTransactionIdHasSurroundingWhitespace Text
  | ActualTransactionIdContainsControlCharacter Text
  | ActualTransactionIdContainsWhitespace Text
  deriving (Eq, Show)

mkActualTransactionId
  :: Text
  -> Either ActualTransactionIdError ActualTransactionId
mkActualTransactionId value
  | T.null value = Left EmptyActualTransactionId
  | T.strip value /= value =
      Left (ActualTransactionIdHasSurroundingWhitespace value)
  | T.any isControl value =
      Left (ActualTransactionIdContainsControlCharacter value)
  | T.any isSpace value =
      Left (ActualTransactionIdContainsWhitespace value)
  | otherwise = Right (ActualTransactionId value)

-- | One whole validated Actual transaction paired with durable source identity.
--
-- Plan relation declarations refer to this identity rather than duplicating or
-- flattening the transaction fact.
data IdentifiedActualTransaction = IdentifiedActualTransaction
  { identifiedActualId          :: ActualTransactionId
  , identifiedActualTransaction :: Transaction
  } deriving (Eq, Show)

identifyActualTransaction
  :: ActualTransactionId
  -> Transaction
  -> IdentifiedActualTransaction
identifyActualTransaction = IdentifiedActualTransaction

-- | An explicit source declaration that one Actual transaction completes one
-- Plan. It is not yet proof that either referenced fact exists.
data PlanCompletionDeclaration = PlanCompletionDeclaration
  { declaredCompletionPlanId   :: PlanId
  , declaredCompletionActualId :: ActualTransactionId
  } deriving (Eq, Show)

declarePlanCompletion
  :: PlanId
  -> ActualTransactionId
  -> PlanCompletionDeclaration
declarePlanCompletion = PlanCompletionDeclaration

-- | Rebuildable proof that one explicit relation resolves to admitted Plan and
-- Actual facts.
--
-- This is projection evidence, not state stored back into either source fact.
data PlanCompletionEvidence = PlanCompletionEvidence
  { completionPlan   :: CommittedOutgoingPlan
  , completionActual :: IdentifiedActualTransaction
  } deriving (Eq, Show)

data PlanCompletionError
  = DuplicateCompletionPlanId PlanId
  | DuplicateActualTransactionId ActualTransactionId
  | DuplicatePlanCompletionDeclaration PlanId ActualTransactionId
  | UnknownCompletionPlanReference PlanId ActualTransactionId
  | UnknownCompletionActualReference ActualTransactionId PlanId
  | PlanReferencedByMultipleActuals PlanId (NonEmpty ActualTransactionId)
  deriving (Eq, Show)

-- | Structural incompatibilities that prevent a whole Actual completion from
-- being interpreted posting-by-posting against its Plan.
--
-- This is deliberately separate from relation resolution above. The explicit
-- relation itself never depends on transaction resemblance; a domain projection
-- may opt into shape validation only when it needs positional interpretation.
data PlanCompletionShapeError
  = PlanCompletionAccountShapeMismatch PlanId
  | PlanCompletionDirectionMismatch PlanId
  | PlanCompletionCommodityMismatch PlanId
  deriving (Eq, Show)

-- | Prove positional compatibility between one Plan and its completing Actual.
--
-- Quantities may differ because Plan records intent and Actual records what
-- happened. Account order, posting directions, and commodity coordinates must
-- agree so callers can safely use Actual quantities at Plan-defined positions.
validatePlanCompletionShape
  :: PlanId
  -> Transaction
  -> Transaction
  -> Either PlanCompletionShapeError ()
validatePlanCompletionShape planId planTransaction actualTransaction = do
  if planAccounts == actualAccounts
    then Right ()
    else Left (PlanCompletionAccountShapeMismatch planId)
  if planDirections == actualDirections
    then Right ()
    else Left (PlanCompletionDirectionMismatch planId)
  if planCommodities == actualCommodities
    then Right ()
    else Left (PlanCompletionCommodityMismatch planId)
  where
    planPostings = NonEmpty.toList (transactionPostings planTransaction)
    actualPostings = NonEmpty.toList (transactionPostings actualTransaction)
    planAccounts = map postingAccount planPostings
    actualAccounts = map postingAccount actualPostings
    planDirections = map (direction . postingAmount) planPostings
    actualDirections = map (direction . postingAmount) actualPostings
    planCommodities = map (amountCommodity . postingAmount) planPostings
    actualCommodities = map (amountCommodity . postingAmount) actualPostings

    direction amount = compare (amountQuantity amount) zeroQuantity

-- | Resolve explicit Plan-to-Actual declarations without examining transaction
-- content.
--
-- Output order follows declaration order. Duplicate fact identities, duplicate
-- relation declarations, unknown references, and multiple distinct Actuals for
-- one Plan are rejected rather than silently selecting a winner. One Actual may
-- participate in several explicit Plan relations; this boundary does not invent
-- amount allocation or partial-completion rules.
resolvePlanCompletionEvidence
  :: ( Foldable planCollection
     , Foldable actualCollection
     , Foldable declarationCollection
     )
  => planCollection CommittedOutgoingPlan
  -> actualCollection IdentifiedActualTransaction
  -> declarationCollection PlanCompletionDeclaration
  -> Either (NonEmpty PlanCompletionError) [PlanCompletionEvidence]
resolvePlanCompletionEvidence plans actuals declarations =
  case NonEmpty.nonEmpty errors of
    Just completionErrors -> Left completionErrors
    Nothing -> Right resolvedEvidence
  where
    planList = Foldable.toList plans
    actualList = Foldable.toList actuals
    declarationList = Foldable.toList declarations

    planById = Map.fromList
      [ (committedPlanId plan, plan)
      | plan <- planList
      ]
    actualById = Map.fromList
      [ (identifiedActualId actual, actual)
      | actual <- actualList
      ]

    (referenceErrors, resolvedEvidence) =
      partitionEithers (map resolveDeclaration declarationList)

    errors =
      duplicatePlanErrors
        ++ duplicateActualErrors
        ++ duplicateDeclarationErrors
        ++ referenceErrors
        ++ multipleActualErrors

    duplicatePlanErrors =
      [ DuplicateCompletionPlanId planId
      | planId <- duplicateKeys committedPlanId planList
      ]

    duplicateActualErrors =
      [ DuplicateActualTransactionId actualId
      | actualId <- duplicateKeys identifiedActualId actualList
      ]

    duplicateDeclarationErrors =
      [ DuplicatePlanCompletionDeclaration planId actualId
      | (planId, actualId) <- duplicateKeys declarationIdentity declarationList
      ]

    multipleActualErrors =
      [ PlanReferencedByMultipleActuals planId actualIds
      | (planId, actualIdSet) <- Map.toAscList actualIdsByPlan
      , Map.member planId planById
      , let ids = Set.toAscList actualIdSet
      , Just actualIds <- [NonEmpty.nonEmpty ids]
      , NonEmpty.length actualIds > 1
      ]

    actualIdsByPlan = Map.fromListWith Set.union
      [ ( declaredCompletionPlanId declaration
        , Set.singleton (declaredCompletionActualId declaration)
        )
      | declaration <- declarationList
      ]

    resolveDeclaration declaration =
      case ( Map.lookup planId planById
           , Map.lookup actualId actualById
           ) of
        (Nothing, _) ->
          Left (UnknownCompletionPlanReference planId actualId)
        (_, Nothing) ->
          Left (UnknownCompletionActualReference actualId planId)
        (Just plan, Just actual) ->
          Right PlanCompletionEvidence
            { completionPlan = plan
            , completionActual = actual
            }
      where
        planId = declaredCompletionPlanId declaration
        actualId = declaredCompletionActualId declaration

-- | Resolve the explicit relation and retain only Plans without completion
-- evidence.
--
-- Output order follows Plan source order. No date enters this projection:
-- overdue, due, and future are presentation coordinates, while open means only
-- that no valid explicit completion relation was admitted. All validation and
-- fail-closed behaviour is inherited from 'resolvePlanCompletionEvidence'.
resolveOpenCommittedOutgoingPlans
  :: ( Foldable planCollection
     , Foldable actualCollection
     , Foldable declarationCollection
     )
  => planCollection CommittedOutgoingPlan
  -> actualCollection IdentifiedActualTransaction
  -> declarationCollection PlanCompletionDeclaration
  -> Either (NonEmpty PlanCompletionError) [CommittedOutgoingPlan]
resolveOpenCommittedOutgoingPlans plans actuals declarations = do
  completionEvidence <-
    resolvePlanCompletionEvidence planList actuals declarations
  let completedPlanIds = Set.fromList
        [ committedPlanId (completionPlan evidence)
        | evidence <- completionEvidence
        ]
  pure
    [ plan
    | plan <- planList
    , committedPlanId plan `Set.notMember` completedPlanIds
    ]
  where
    planList = Foldable.toList plans

declarationIdentity
  :: PlanCompletionDeclaration
  -> (PlanId, ActualTransactionId)
declarationIdentity declaration =
  ( declaredCompletionPlanId declaration
  , declaredCompletionActualId declaration
  )

duplicateKeys :: Ord key => (value -> key) -> [value] -> [key]
duplicateKeys keyOf values =
  [ key
  | (key, count) <- Map.toAscList
      (Map.fromListWith (+) [(keyOf value, 1 :: Int) | value <- values])
  , count > 1
  ]
