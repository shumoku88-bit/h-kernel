module HKernel.Envelope.Fulfillment
  ( FulfillmentAmounts(..)
  , fulfillmentNet
  , EnvelopeFulfillment
  , EnvelopeFulfillmentError(..)
  , observeEnvelopeFulfillment
  , observeEnvelopeStockFulfillment
  , envelopeFulfillmentPeriod
  , envelopeFulfillmentObservedThrough
  , envelopeFulfillmentFor
  , envelopeFulfillmentEntries
  ) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day)
import HKernel.Account (AccountType(..), accountTypeFor)
import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalReversalDeclarations
  , actualJournalTransactionEntries
  , actualTransactionEntryIdentity
  , actualTransactionEntryTransaction
  , reversedTransactionId
  , reversalTransactionId
  )
import HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , envelopeEntitlementHistoryOriginDateFor
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
  , amountCommodity
  , amountQuantity
  , emptyBalance
  , singletonBalance
  , subtractBalance
  , zeroQuantity
  )
import HKernel.Period (Period, periodContains)
import HKernel.Plan (PlanId)
import HKernel.Plan.Completion
  ( ActualTransactionId
  , PlanCompletionShapeError
  , identifiedActualId
  , identifiedActualTransaction
  , validatePlanCompletionShape
  )
import HKernel.Plan.Journal
  ( PlanJournal
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalValue
  )
import HKernel.Plan.Open
  ( PlanObservationError
  , completedActual
  , completedPlan
  , resolveCompletedPlanTransactionsAt
  )

-- | Gross fulfillment/reversal evidence for one Envelope.
--
-- Fulfillment is intentionally distinct from Expense consumption. It models an
-- explicit completed Plan whose non-Expense target is declared to fulfill an
-- Envelope, such as moving liquid money into savings or an investment account.
-- Ordinary transfers to the same account are not completion evidence and do not
-- affect Envelope Remaining.
data FulfillmentAmounts = FulfillmentAmounts
  { fulfillmentApplied  :: Balance
  , fulfillmentReversed :: Balance
  } deriving (Eq, Show)

instance Semigroup FulfillmentAmounts where
  left <> right = FulfillmentAmounts
    { fulfillmentApplied =
        addBalance (fulfillmentApplied left) (fulfillmentApplied right)
    , fulfillmentReversed =
        addBalance (fulfillmentReversed left) (fulfillmentReversed right)
    }

instance Monoid FulfillmentAmounts where
  mempty = FulfillmentAmounts emptyBalance emptyBalance

fulfillmentNet :: FulfillmentAmounts -> Balance
fulfillmentNet amounts =
  fulfillmentApplied amounts `subtractBalance` fulfillmentReversed amounts

data EnvelopeFulfillment = EnvelopeFulfillment
  { envelopeFulfillmentPeriod          :: Period
  , envelopeFulfillmentObservedThrough :: Day
  , managedFulfillment                 :: Map.Map EnvelopeId FulfillmentAmounts
  } deriving (Eq, Show)

data EnvelopeFulfillmentError
  = EnvelopeFulfillmentObservationOutsidePeriod Day Period
  | EnvelopeFulfillmentPlanObservationError PlanObservationError
  | EnvelopeFulfillmentCompletionShapeError PlanCompletionShapeError
  | EnvelopeFulfillmentActualFulfillsMultiplePlans
      ActualTransactionId
      (NonEmpty.NonEmpty PlanId)
  deriving (Eq, Show)

-- | Observe bounded completed non-Expense target activity in one Period.
--
-- This remains an activity observation. Household Envelope Remaining must use
-- 'observeEnvelopeStockFulfillment' so completed capacity use survives report
-- Period boundaries.
observeEnvelopeFulfillment
  :: Period
  -> Day
  -> PlanJournal
  -> ActualJournal
  -> FulfillmentRoutingHistory
  -> Either (NonEmpty.NonEmpty EnvelopeFulfillmentError) EnvelopeFulfillment
observeEnvelopeFulfillment period observedThrough plans actual routing =
  observeEnvelopeFulfillmentWith
    False
    (periodContains period)
    (\_day _amount -> True)
    period observedThrough plans actual routing

-- | Observe cumulative non-Expense target Fulfillment from each Commodity's
-- native Entitlement origin through the inclusive observation day.
--
-- A completion before its target Commodity enters the Envelope stock world is
-- absent together with its entire reversal chain. This prevents a later reversal
-- of pre-Envelope accounting history from manufacturing live Envelope capacity.
observeEnvelopeStockFulfillment
  :: EnvelopeEntitlementHistory
  -> Period
  -> Day
  -> PlanJournal
  -> ActualJournal
  -> FulfillmentRoutingHistory
  -> Either (NonEmpty.NonEmpty EnvelopeFulfillmentError) EnvelopeFulfillment
observeEnvelopeStockFulfillment history period observedThrough plans actual routing =
  observeEnvelopeFulfillmentWith
    True
    (const True)
    targetInStock
    period observedThrough plans actual routing
  where
    targetInStock completionDay amount =
      case envelopeEntitlementHistoryOriginDateFor (amountCommodity amount) history of
        Nothing -> False
        Just originDay -> completionDay >= originDay

observeEnvelopeFulfillmentWith
  :: Bool
  -> (Day -> Bool)
  -> (Day -> Amount -> Bool)
  -> Period
  -> Day
  -> PlanJournal
  -> ActualJournal
  -> FulfillmentRoutingHistory
  -> Either (NonEmpty.NonEmpty EnvelopeFulfillmentError) EnvelopeFulfillment
observeEnvelopeFulfillmentWith requireStockTarget entryInHorizon targetInHorizon
    period observedThrough plans actual routing
  | not (periodContains period observedThrough) =
      Left (EnvelopeFulfillmentObservationOutsidePeriod observedThrough period NonEmpty.:| [])
  | otherwise = do
      completed <- mapErrors EnvelopeFulfillmentPlanObservationError
        (resolveCompletedPlanTransactionsAt observedThrough plans actual)
      let routed = routedCompleted completed
      rejectAmbiguousRoutedActuals routed
      validated <- validateCompleted routed
      let fulfillmentByRoot = Map.fromList
            [ (actualId, (envelope, balance))
            | (pair, envelope) <- validated
            , let actualId = identifiedActualId (completedActual pair)
                  balance = targetBalance pair
            , balance /= emptyBalance
            ]
          managed = foldr (observeEntry fulfillmentByRoot) Map.empty visibleEntries
      Right EnvelopeFulfillment
        { envelopeFulfillmentPeriod = period
        , envelopeFulfillmentObservedThrough = observedThrough
        , managedFulfillment = managed
        }
  where
    registry = journalAccountRegistry (planJournalValue plans)
    entries = actualJournalTransactionEntries actual
    reversalTargetById = Map.fromList
      [ (reversalTransactionId declaration, reversedTransactionId declaration)
      | declaration <- actualJournalReversalDeclarations actual
      ]

    visibleEntries =
      [ entry
      | entry <- entries
      , let entryDay = transactionDate (actualTransactionEntryTransaction entry)
      , entryDay <= observedThrough
      , entryInHorizon entryDay
      ]

    routedCompleted completed =
      [ (pair, envelope)
      | pair <- completed
      , let identifiedPlan = completedPlan pair
            identifiedActual = completedActual pair
            routeDay = transactionDate (identifiedActualTransaction identifiedActual)
            planId = identifiedPlanId identifiedPlan
      , Just (FulfillsEnvelope envelope) <-
          [fulfillmentRouteAt routeDay planId routing]
      , not requireStockTarget || hasStockTarget routeDay pair
      ]

    hasStockTarget routeDay pair =
      any isVisibleTarget
        (NonEmpty.toList
          (transactionPostings
            (identifiedPlanTransaction (completedPlan pair))))
      where
        isVisibleTarget posting =
          amountQuantity amount > zeroQuantity
            && accountTypeFor (postingAccount posting) registry /= Just Expense
            && targetInHorizon routeDay amount
          where
            amount = postingAmount posting

    rejectAmbiguousRoutedActuals routed =
      case NonEmpty.nonEmpty errors of
        Nothing -> Right ()
        Just found -> Left found
      where
        plansByActual = Map.fromListWith (++)
          [ ( identifiedActualId (completedActual pair)
            , [identifiedPlanId (completedPlan pair)]
            )
          | (pair, _) <- routed
          ]
        errors =
          [ EnvelopeFulfillmentActualFulfillsMultiplePlans actualId planIds
          | (actualId, planIdList) <- Map.toAscList plansByActual
          , Just planIds <- [NonEmpty.nonEmpty planIdList]
          , NonEmpty.length planIds > 1
          ]

    validateCompleted routed =
      case traverse validateOne routed of
        Left err -> Left (EnvelopeFulfillmentCompletionShapeError err NonEmpty.:| [])
        Right values -> Right values

    validateOne routedPair@(pair, _) = do
      let identifiedPlan = completedPlan pair
          identifiedActual = completedActual pair
      validatePlanCompletionShape
        (identifiedPlanId identifiedPlan)
        (identifiedPlanTransaction identifiedPlan)
        (identifiedActualTransaction identifiedActual)
      Right routedPair

    targetBalance pair =
      foldl addBalance emptyBalance
        [ singletonBalance actualAmount
        | (planPosting, actualPosting) <- zip planPostings actualPostings
        , amountQuantity (postingAmount planPosting) > zeroQuantity
        , accountTypeFor (postingAccount planPosting) registry /= Just Expense
        , let actualAmount = postingAmount actualPosting
        , targetInHorizon completionDay actualAmount
        ]
      where
        completionDay = transactionDate
          (identifiedActualTransaction (completedActual pair))
        planPostings = NonEmpty.toList
          (transactionPostings
            (identifiedPlanTransaction (completedPlan pair)))
        actualPostings = NonEmpty.toList
          (transactionPostings
            (identifiedActualTransaction (completedActual pair)))

    observeEntry fulfillmentByRoot entry accum =
      case actualTransactionEntryIdentity entry of
        Nothing -> accum
        Just actualId ->
          case Map.lookup rootId fulfillmentByRoot of
            Nothing -> accum
            Just (envelope, balance) ->
              Map.insertWith (<>) envelope amounts accum
              where
                amounts
                  | even depth = FulfillmentAmounts balance emptyBalance
                  | otherwise = FulfillmentAmounts emptyBalance balance
          where
            (rootId, depth) = rootActualWithDepth reversalTargetById actualId

rootActualWithDepth
  :: Map.Map ActualTransactionId ActualTransactionId
  -> ActualTransactionId
  -> (ActualTransactionId, Int)
rootActualWithDepth reversalTargetById = go 0
  where
    go depth actualId = case Map.lookup actualId reversalTargetById of
      Nothing -> (actualId, depth)
      Just targetId -> go (depth + 1) targetId

mapErrors
  :: (left -> right)
  -> Either (NonEmpty.NonEmpty left) value
  -> Either (NonEmpty.NonEmpty right) value
mapErrors f = either (Left . fmap f) Right

envelopeFulfillmentFor :: EnvelopeId -> EnvelopeFulfillment -> FulfillmentAmounts
envelopeFulfillmentFor envelope =
  Map.findWithDefault mempty envelope . managedFulfillment

envelopeFulfillmentEntries
  :: EnvelopeFulfillment
  -> [(EnvelopeId, FulfillmentAmounts)]
envelopeFulfillmentEntries = Map.toAscList . managedFulfillment
