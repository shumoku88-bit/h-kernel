module HKernel.Envelope.Commitment
  ( EnvelopeCommitment
  , EnvelopeCommitmentError(..)
  , observeEnvelopeCommitment
  , envelopeCommitmentPeriod
  , envelopeCommitmentObservedThrough
  , envelopeCommitmentFor
  , envelopeCommitmentEntries
  , envelopeCommitmentUnmanaged
  , envelopeCommitmentUnrouted
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day)
import HKernel.Account (Account, AccountType(..), accountTypeFor)
import HKernel.Actual.Journal (ActualJournal)
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , ExpenseRoutingHistory
  , expenseRouteAt
  )
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Journal (journalAccountRegistry)
import HKernel.Ledger
  ( postingAccount
  , postingAmount
  , transactionDate
  , transactionPostings
  )
import HKernel.Money
  ( Amount
  , Balance
  , addBalance
  , amountQuantity
  , emptyBalance
  , singletonBalance
  , zeroQuantity
  )
import HKernel.Period (Period, periodContains, periodEndExclusive)
import HKernel.Plan.Completion (PlanCompletionError)
import HKernel.Plan.Journal
  ( PlanClassificationError
  , PlanJournal
  , PlanLifecycleError
  , identifiedPlanTransaction
  , planJournalValue
  )
import HKernel.Plan.Open
  ( OpenOutgoingPlanError(..)
  , resolveOpenOutgoingPlanTransactionsAt
  )

-- | Open Plan Expense commitments at one resolved period/day observation.
--
-- Managed Envelope claims, explicit non-Envelope Plans, and missing-route
-- attention remain separate. Only Expense postings enter this projection;
-- Liability settlement remains a funding commitment for Backing rather than an
-- Envelope consumption claim.
data EnvelopeCommitment = EnvelopeCommitment
  { envelopeCommitmentPeriod          :: Period
  , envelopeCommitmentObservedThrough :: Day
  , managedCommitment                 :: Map.Map EnvelopeId Balance
  , envelopeCommitmentUnmanaged       :: Map.Map Account Balance
  , envelopeCommitmentUnrouted        :: Map.Map Account Balance
  } deriving (Eq, Show)

data EnvelopeCommitmentError
  = EnvelopeCommitmentObservationOutsidePeriod Day Period
  | EnvelopeCommitmentPlanLifecycleError PlanLifecycleError
  | EnvelopeCommitmentPlanClassificationError PlanClassificationError
  | EnvelopeCommitmentCompletionError PlanCompletionError
  deriving (Eq, Show)

-- | Observe still-open outgoing Plan Expense postings through one inclusive
-- observation day.
--
-- Plan lifecycle/completion meaning is owned by 'HKernel.Plan.Open'. This owner
-- applies only the Envelope horizon and routing meanings: overdue open Plans
-- remain binding, while Plans at or beyond the next Period boundary do not
-- consume current headroom.
--
-- Open Plans use the routing decision effective at the observation day: unlike
-- posted Actuals, they are still household intent and may move when current
-- Envelope policy changes. Whole multi-posting Plan transactions are retained;
-- each positive Expense posting is routed independently.
observeEnvelopeCommitment
  :: Period
  -> Day
  -> PlanJournal
  -> ActualJournal
  -> ExpenseRoutingHistory
  -> Either (NonEmpty EnvelopeCommitmentError) EnvelopeCommitment
observeEnvelopeCommitment period observedThrough plans actual routing
  | not (periodContains period observedThrough) =
      Left (EnvelopeCommitmentObservationOutsidePeriod observedThrough period NonEmpty.:| [])
  | otherwise = do
      openPlans <- mapErrors mapOpenPlanError
        (resolveOpenOutgoingPlanTransactionsAt observedThrough plans actual)
      let openInHorizon =
            [ identified
            | identified <- openPlans
            , transactionDate (identifiedPlanTransaction identified)
                < periodEndExclusive period
            ]
          (managed, unmanaged, unrouted) =
            foldl collectPlan (Map.empty, Map.empty, Map.empty) openInHorizon
      Right EnvelopeCommitment
        { envelopeCommitmentPeriod = period
        , envelopeCommitmentObservedThrough = observedThrough
        , managedCommitment = managed
        , envelopeCommitmentUnmanaged = unmanaged
        , envelopeCommitmentUnrouted = unrouted
        }
  where
    registry = journalAccountRegistry (planJournalValue plans)

    collectPlan totals identified =
      foldl collectPosting totals
        (NonEmpty.toList
          (transactionPostings (identifiedPlanTransaction identified)))

    collectPosting totals posting
      | accountTypeFor account registry /= Just Expense = totals
      | amountQuantity amount <= zeroQuantity = totals
      | otherwise = case expenseRouteAt observedThrough account routing of
          Just (ManagedByEnvelope envelope) ->
            firstMap (addAt envelope amount) totals
          Just NotEnvelopeManaged ->
            secondMap (addAt account amount) totals
          Nothing ->
            thirdMap (addAt account amount) totals
      where
        account = postingAccount posting
        amount = postingAmount posting

mapOpenPlanError :: OpenOutgoingPlanError -> EnvelopeCommitmentError
mapOpenPlanError err = case err of
  OpenOutgoingPlanLifecycleError lifecycleError ->
    EnvelopeCommitmentPlanLifecycleError lifecycleError
  OpenOutgoingPlanClassificationError classificationError ->
    EnvelopeCommitmentPlanClassificationError classificationError
  OpenOutgoingPlanCompletionError completionError ->
    EnvelopeCommitmentCompletionError completionError

addAt :: Ord key => key -> Amount -> Map.Map key Balance -> Map.Map key Balance
addAt key amount = Map.insertWith addBalance key (singletonBalance amount)

firstMap
  :: (first -> first)
  -> (first, second, third)
  -> (first, second, third)
firstMap f (first, second, third) = (f first, second, third)

secondMap
  :: (second -> second)
  -> (first, second, third)
  -> (first, second, third)
secondMap f (first, second, third) = (first, f second, third)

thirdMap
  :: (third -> third)
  -> (first, second, third)
  -> (first, second, third)
thirdMap f (first, second, third) = (first, second, f third)

mapErrors
  :: (left -> right)
  -> Either (NonEmpty left) value
  -> Either (NonEmpty right) value
mapErrors f = either (Left . fmap f) Right

envelopeCommitmentFor :: EnvelopeId -> EnvelopeCommitment -> Balance
envelopeCommitmentFor envelope =
  Map.findWithDefault emptyBalance envelope . managedCommitment

envelopeCommitmentEntries :: EnvelopeCommitment -> [(EnvelopeId, Balance)]
envelopeCommitmentEntries = Map.toAscList . managedCommitment
