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
import HKernel.Envelope.FulfillmentRouting
  ( FulfillmentRoute(..)
  , FulfillmentRoutingHistory
  , fulfillmentRouteAt
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
  ( PlanClassificationError(..)
  , PlanJournal
  , PlanLifecycleError
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalValue
  )
import HKernel.Plan.Open
  ( PlanObservationError(..)
  , resolveOpenPlanTransactionsAt
  )

-- | Open Plan commitments against Envelope headroom at one resolved period/day
-- observation.
--
-- Expense destinations use Account routing. Explicit non-Expense fulfillment
-- intent such as savings, investment, or debt goals belongs to stable PlanId.
-- Ordinary non-Expense postings in unrelated Plans therefore do not inherit
-- Envelope meaning from a shared Account coordinate.
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

-- | Observe still-open Plan use through one inclusive observation day.
--
-- Plan lifecycle/completion meaning is owned by the role-neutral observer in
-- 'HKernel.Plan.Open'. This matters because an Asset-to-Asset target Plan is a
-- valid Envelope commitment even though generic accounting role classification
-- does not call it an outgoing Expense/Liability payment.
--
-- Expense postings remain conservative: a Plan that claims positive Expense
-- use must contain an Asset funding source. Non-Expense positive postings never
-- claim Envelope headroom from their Account alone; they require an explicit
-- PlanId fulfillment route. Open routed Plans use the route effective at the
-- observation day because they remain current household intent.
observeEnvelopeCommitment
  :: Period
  -> Day
  -> PlanJournal
  -> ActualJournal
  -> ExpenseRoutingHistory
  -> FulfillmentRoutingHistory
  -> Either (NonEmpty EnvelopeCommitmentError) EnvelopeCommitment
observeEnvelopeCommitment period observedThrough plans actual expenseRouting fulfillmentRouting
  | not (periodContains period observedThrough) =
      Left (EnvelopeCommitmentObservationOutsidePeriod observedThrough period NonEmpty.:| [])
  | otherwise = do
      openPlans <- mapErrors mapPlanObservationError
        (resolveOpenPlanTransactionsAt observedThrough plans actual)
      let openInHorizon =
            [ identified
            | identified <- openPlans
            , transactionDate (identifiedPlanTransaction identified)
                < periodEndExclusive period
            ]
      validated <- case traverse validateRelevantPlan openInHorizon of
        Left err -> Left (err NonEmpty.:| [])
        Right values -> Right values
      let (managed, unmanaged, unrouted) =
            foldl collectPlan (Map.empty, Map.empty, Map.empty) validated
      Right EnvelopeCommitment
        { envelopeCommitmentPeriod = period
        , envelopeCommitmentObservedThrough = observedThrough
        , managedCommitment = managed
        , envelopeCommitmentUnmanaged = unmanaged
        , envelopeCommitmentUnrouted = unrouted
        }
  where
    registry = journalAccountRegistry (planJournalValue plans)

    validateRelevantPlan identified
      | hasPositiveExpense && not hasNegativeAsset =
          Left (EnvelopeCommitmentPlanClassificationError
            (UnsupportedPlanRoleFlow (identifiedPlanId identified)))
      | otherwise = Right identified
      where
        postings = NonEmpty.toList
          (transactionPostings (identifiedPlanTransaction identified))
        hasPositiveExpense = any isPositiveExpense postings
        hasNegativeAsset = any isNegativeAsset postings
        isPositiveExpense posting =
          accountTypeFor (postingAccount posting) registry == Just Expense
            && amountQuantity (postingAmount posting) > zeroQuantity
        isNegativeAsset posting =
          accountTypeFor (postingAccount posting) registry == Just Asset
            && amountQuantity (postingAmount posting) < zeroQuantity

    collectPlan totals identified =
      foldl (collectPosting planFulfillmentRoute) totals
        (NonEmpty.toList
          (transactionPostings (identifiedPlanTransaction identified)))
      where
        planFulfillmentRoute =
          fulfillmentRouteAt observedThrough (identifiedPlanId identified) fulfillmentRouting

    collectPosting planFulfillmentRoute totals posting
      | amountQuantity amount <= zeroQuantity = totals
      | accountTypeFor account registry == Just Expense =
          case expenseRouteAt observedThrough account expenseRouting of
            Just (ManagedByEnvelope envelope) ->
              firstMap (addAt envelope amount) totals
            Just NotEnvelopeManaged ->
              secondMap (addAt account amount) totals
            Nothing ->
              thirdMap (addAt account amount) totals
      | otherwise = case planFulfillmentRoute of
          Just (FulfillsEnvelope envelope) ->
            firstMap (addAt envelope amount) totals
          Just NotFulfillmentTarget -> totals
          Nothing -> totals
      where
        account = postingAccount posting
        amount = postingAmount posting

mapPlanObservationError :: PlanObservationError -> EnvelopeCommitmentError
mapPlanObservationError err = case err of
  PlanObservationLifecycleError lifecycleError ->
    EnvelopeCommitmentPlanLifecycleError lifecycleError
  PlanObservationCompletionError completionError ->
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
