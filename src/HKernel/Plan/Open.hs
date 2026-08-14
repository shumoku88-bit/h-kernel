module HKernel.Plan.Open
  ( OpenOutgoingPlanError(..)
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

data OpenOutgoingPlanError
  = OpenOutgoingPlanLifecycleError PlanLifecycleError
  | OpenOutgoingPlanClassificationError PlanClassificationError
  | OpenOutgoingPlanCompletionError PlanCompletionError
  deriving (Eq, Show)

-- | One whole outgoing Plan paired with the admitted Actual that explicitly
-- completes it, visible as of one observation day.
data CompletedOutgoingPlanTransaction = CompletedOutgoingPlanTransaction
  { completedOutgoingPlan   :: IdentifiedPlanTransaction
  , completedOutgoingActual :: IdentifiedActualTransaction
  } deriving (Eq, Show)

-- | Resolve whole outgoing Plan transactions that are still active at one
-- inclusive observation day.
--
-- Planned date is deliberately not a selection coordinate here. An overdue Plan
-- remains open until lifecycle or completion evidence closes it, while callers
-- such as Envelope and Backing may apply their own funding/report horizons.
-- Retirement is interpreted as of the observation day. Completion closes a Plan
-- only when the completing Actual transaction is dated on or before that day, so
-- future Actual evidence cannot rewrite an earlier Plan observation.
resolveOpenOutgoingPlanTransactionsAt
  :: Day
  -> PlanJournal
  -> ActualJournal
  -> Either (NonEmpty OpenOutgoingPlanError) [IdentifiedPlanTransaction]
resolveOpenOutgoingPlanTransactionsAt observedThrough plans actual = do
  retirements <- mapErrors OpenOutgoingPlanLifecycleError
    (admitPlanRetirements plans)
  classified <- mapErrors OpenOutgoingPlanClassificationError
    (classifyPlanJournal plans)
  visibleCompletions <- completionActualsThrough observedThrough plans actual
  let retired = retiredPlanIdsAt observedThrough retirements
      completed = Set.fromList (map fst visibleCompletions)
  pure
    [ identified
    | identified <- classifiedOutgoingPlanTransactions classified
    , identifiedPlanId identified `Set.notMember` retired
    , identifiedPlanId identified `Set.notMember` completed
    ]

-- | Resolve whole outgoing Plan/Actual completion pairs visible at one inclusive
-- observation day.
--
-- Output follows outgoing Plan source order. Retirement is not a filter here:
-- an explicit admitted Actual remains historical completion evidence even if the
-- Plan later acquires lifecycle metadata. Callers decide what the completion
-- means for their own projection.
resolveCompletedOutgoingPlanTransactionsAt
  :: Day
  -> PlanJournal
  -> ActualJournal
  -> Either (NonEmpty OpenOutgoingPlanError) [CompletedOutgoingPlanTransaction]
resolveCompletedOutgoingPlanTransactionsAt observedThrough plans actual = do
  classified <- mapErrors OpenOutgoingPlanClassificationError
    (classifyPlanJournal plans)
  visibleCompletions <- completionActualsThrough observedThrough plans actual
  let actualByPlan = Map.fromList visibleCompletions
  pure
    [ CompletedOutgoingPlanTransaction
        { completedOutgoingPlan = identified
        , completedOutgoingActual = completedActual
        }
    | identified <- classifiedOutgoingPlanTransactions classified
    , Just completedActual <- [Map.lookup (identifiedPlanId identified) actualByPlan]
    ]

completionActualsThrough
  :: Day
  -> PlanJournal
  -> ActualJournal
  -> Either
       (NonEmpty OpenOutgoingPlanError)
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
      [ OpenOutgoingPlanCompletionError
          (UnknownCompletionPlanReference planId actualId)
      | declaration <- declarations
      , let planId = declaredCompletionPlanId declaration
            actualId = declaredCompletionActualId declaration
      , planId `Set.notMember` knownPlans
      ]

    unknownActualErrors =
      [ OpenOutgoingPlanCompletionError
          (UnknownCompletionActualReference actualId planId)
      | declaration <- declarations
      , let planId = declaredCompletionPlanId declaration
            actualId = declaredCompletionActualId declaration
      , planId `Set.member` knownPlans
      , Map.notMember actualId actualById
      ]

    actualIdsByPlan = Map.fromListWith Set.union
      [ ( declaredCompletionPlanId declaration
        , Set.singleton (declaredCompletionActualId declaration)
        )
      | declaration <- declarations
      , declaredCompletionPlanId declaration `Set.member` knownPlans
      ]
    multipleActualErrors =
      [ OpenOutgoingPlanCompletionError
          (PlanReferencedByMultipleActuals planId actualIds)
      | (planId, actualIdSet) <- Map.toAscList actualIdsByPlan
      , Just actualIds <- [NonEmpty.nonEmpty (Set.toAscList actualIdSet)]
      , NonEmpty.length actualIds > 1
      ]

    visibleCompleted =
      [ (planId, identified)
      | declaration <- declarations
      , let planId = declaredCompletionPlanId declaration
            actualId = declaredCompletionActualId declaration
      , planId `Set.member` knownPlans
      , Just identified <- [Map.lookup actualId actualById]
      , transactionDate (identifiedActualTransaction identified) <= observedThrough
      ]

    errors = unknownPlanErrors ++ unknownActualErrors ++ multipleActualErrors

mapErrors
  :: (left -> right)
  -> Either (NonEmpty left) value
  -> Either (NonEmpty right) value
mapErrors f = either (Left . fmap f) Right
