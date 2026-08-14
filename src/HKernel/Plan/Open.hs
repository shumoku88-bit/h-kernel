module HKernel.Plan.Open
  ( PlanObservationError(..)
  , CompletedPlanTransaction
  , completedPlan
  , completedActual
  , resolveOpenPlanTransactionsAt
  , resolveCompletedPlanTransactionsAt
  , OpenOutgoingPlanError(..)
  , CompletedOutgoingPlanTransaction
  , completedOutgoingPlan
  , completedOutgoingActual
  , resolveOpenOutgoingPlanTransactionsAt
  , resolveCompletedOutgoingPlanTransactionsAt
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time.Calendar (Day)
import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalCompletionDeclarations
  , actualJournalIdentifiedTransactions
  )
import HKernel.Ledger (transactionDate)
import HKernel.Plan (PlanId)
import HKernel.Plan.Completion
  ( IdentifiedActualTransaction
  , PlanCompletionError(..)
  , declaredCompletionActualId
  , declaredCompletionPlanId
  , identifiedActualId
  , identifiedActualTransaction
  )
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanClassificationError
  , PlanJournal
  , PlanLifecycleError
  , admitPlanRetirements
  , classifiedOutgoingPlanTransactions
  , classifyPlanJournal
  , identifiedPlanId
  , planJournalTransactions
  , retiredPlanIdsAt
  )

-- | Errors in observing Plan lifecycle/completion without assigning a payment
-- role to the transaction itself.
--
-- This owner is deliberately more general than the legacy outgoing projection:
-- a valid Plan Journal may contain an explicitly routed Asset-to-Asset savings
-- or investment target even though that transaction is neither Income nor an
-- accounting Expense/Liability outflow.
data PlanObservationError
  = PlanObservationLifecycleError PlanLifecycleError
  | PlanObservationCompletionError PlanCompletionError
  deriving (Eq, Show)

-- | One whole admitted Plan paired with the admitted Actual that explicitly
-- completes it, visible as of one observation day.
data CompletedPlanTransaction = CompletedPlanTransaction
  { completedPlan   :: IdentifiedPlanTransaction
  , completedActual :: IdentifiedActualTransaction
  } deriving (Eq, Show)

-- | Resolve admitted Plan transactions that are still active at one inclusive
-- observation day without assigning them an Income/outgoing role.
--
-- Planned date is not a selection coordinate. Retirement is interpreted as of
-- the observation day, and completion closes a Plan only when its completing
-- Actual is dated on or before that day. The original Plan transaction remains
-- whole and in source order.
resolveOpenPlanTransactionsAt
  :: Day
  -> PlanJournal
  -> ActualJournal
  -> Either (NonEmpty PlanObservationError) [IdentifiedPlanTransaction]
resolveOpenPlanTransactionsAt observedThrough plans actual = do
  retirements <- mapErrors PlanObservationLifecycleError
    (admitPlanRetirements plans)
  visibleCompletions <- completionActualsThrough observedThrough plans actual
  let retired = retiredPlanIdsAt observedThrough retirements
      completed = Set.fromList (map fst visibleCompletions)
  pure
    [ identified
    | identified <- planJournalTransactions plans
    , identifiedPlanId identified `Set.notMember` retired
    , identifiedPlanId identified `Set.notMember` completed
    ]

-- | Resolve whole Plan/Actual completion pairs visible at one inclusive day.
--
-- Output follows Plan source order. Retirement is not a filter: an explicit
-- Actual remains historical completion evidence even if lifecycle metadata later
-- retires that Plan. One Actual may complete several Plans, matching the generic
-- completion owner; domain projections that cannot interpret that relation must
-- reject ambiguity at their own boundary.
resolveCompletedPlanTransactionsAt
  :: Day
  -> PlanJournal
  -> ActualJournal
  -> Either (NonEmpty PlanObservationError) [CompletedPlanTransaction]
resolveCompletedPlanTransactionsAt observedThrough plans actual = do
  visibleCompletions <- completionActualsThrough observedThrough plans actual
  let actualByPlan = Map.fromList visibleCompletions
  pure
    [ CompletedPlanTransaction
        { completedPlan = identified
        , completedActual = completedActualValue
        }
    | identified <- planJournalTransactions plans
    , Just completedActualValue <-
        [Map.lookup (identifiedPlanId identified) actualByPlan]
    ]

-- | Compatibility errors for the narrower accounting-outgoing projection.
data OpenOutgoingPlanError
  = OpenOutgoingPlanLifecycleError PlanLifecycleError
  | OpenOutgoingPlanClassificationError PlanClassificationError
  | OpenOutgoingPlanCompletionError PlanCompletionError
  deriving (Eq, Show)

-- | Compatibility view of a completed accounting-outgoing Plan.
type CompletedOutgoingPlanTransaction = CompletedPlanTransaction

completedOutgoingPlan
  :: CompletedOutgoingPlanTransaction
  -> IdentifiedPlanTransaction
completedOutgoingPlan = completedPlan

completedOutgoingActual
  :: CompletedOutgoingPlanTransaction
  -> IdentifiedActualTransaction
completedOutgoingActual = completedActual

-- | Resolve the legacy accounting-outgoing subset.
--
-- Unlike 'resolveOpenPlanTransactionsAt', this projection intentionally inherits
-- the existing Plan role-classification contract. Callers that own explicit
-- non-Expense target meaning should use the role-neutral observer instead of
-- broadening the generic outgoing vocabulary.
resolveOpenOutgoingPlanTransactionsAt
  :: Day
  -> PlanJournal
  -> ActualJournal
  -> Either (NonEmpty OpenOutgoingPlanError) [IdentifiedPlanTransaction]
resolveOpenOutgoingPlanTransactionsAt observedThrough plans actual = do
  openPlans <- mapErrors fromPlanObservationError
    (resolveOpenPlanTransactionsAt observedThrough plans actual)
  classified <- mapErrors OpenOutgoingPlanClassificationError
    (classifyPlanJournal plans)
  let outgoingIds = Set.fromList
        (map identifiedPlanId (classifiedOutgoingPlanTransactions classified))
  pure
    [ identified
    | identified <- openPlans
    , identifiedPlanId identified `Set.member` outgoingIds
    ]

resolveCompletedOutgoingPlanTransactionsAt
  :: Day
  -> PlanJournal
  -> ActualJournal
  -> Either (NonEmpty OpenOutgoingPlanError) [CompletedOutgoingPlanTransaction]
resolveCompletedOutgoingPlanTransactionsAt observedThrough plans actual = do
  completed <- mapErrors fromPlanObservationError
    (resolveCompletedPlanTransactionsAt observedThrough plans actual)
  classified <- mapErrors OpenOutgoingPlanClassificationError
    (classifyPlanJournal plans)
  let outgoingIds = Set.fromList
        (map identifiedPlanId (classifiedOutgoingPlanTransactions classified))
  pure
    [ pair
    | pair <- completed
    , identifiedPlanId (completedPlan pair) `Set.member` outgoingIds
    ]

completionActualsThrough
  :: Day
  -> PlanJournal
  -> ActualJournal
  -> Either
       (NonEmpty PlanObservationError)
       [(PlanId, IdentifiedActualTransaction)]
completionActualsThrough observedThrough plans actual =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right visibleCompleted
  where
    knownPlans = Set.fromList (map identifiedPlanId (planJournalTransactions plans))
    actualById = Map.fromList
      [ (identifiedActualId identified, identified)
      | identified <- actualJournalIdentifiedTransactions actual
      ]
    declarations = actualJournalCompletionDeclarations actual

    unknownPlanErrors =
      [ PlanObservationCompletionError
          (UnknownCompletionPlanReference planId actualId)
      | declaration <- declarations
      , let planId = declaredCompletionPlanId declaration
            actualId = declaredCompletionActualId declaration
      , planId `Set.notMember` knownPlans
      ]

    unknownActualErrors =
      [ PlanObservationCompletionError
          (UnknownCompletionActualReference actualId planId)
      | declaration <- declarations
      , let planId = declaredCompletionPlanId declaration
            actualId = declaredCompletionActualId declaration
      , planId `Set.member` knownPlans
      , Map.notMember actualId actualById
      ]

    validDeclarations =
      [ declaration
      | declaration <- declarations
      , declaredCompletionPlanId declaration `Set.member` knownPlans
      , Map.member (declaredCompletionActualId declaration) actualById
      ]

    actualIdsByPlan = Map.fromListWith Set.union
      [ ( declaredCompletionPlanId declaration
        , Set.singleton (declaredCompletionActualId declaration)
        )
      | declaration <- validDeclarations
      ]

    multipleActualErrors =
      [ PlanObservationCompletionError
          (PlanReferencedByMultipleActuals planId actualIds)
      | (planId, actualIdSet) <- Map.toAscList actualIdsByPlan
      , Just actualIds <- [NonEmpty.nonEmpty (Set.toAscList actualIdSet)]
      , NonEmpty.length actualIds > 1
      ]

    visibleCompleted =
      [ (planId, identified)
      | declaration <- validDeclarations
      , let planId = declaredCompletionPlanId declaration
            actualId = declaredCompletionActualId declaration
      , Just identified <- [Map.lookup actualId actualById]
      , transactionDate (identifiedActualTransaction identified) <= observedThrough
      ]

    errors =
      unknownPlanErrors
        ++ unknownActualErrors
        ++ multipleActualErrors

fromPlanObservationError :: PlanObservationError -> OpenOutgoingPlanError
fromPlanObservationError err = case err of
  PlanObservationLifecycleError lifecycleError ->
    OpenOutgoingPlanLifecycleError lifecycleError
  PlanObservationCompletionError completionError ->
    OpenOutgoingPlanCompletionError completionError

mapErrors
  :: (left -> right)
  -> Either (NonEmpty left) value
  -> Either (NonEmpty right) value
mapErrors f = either (Left . fmap f) Right
