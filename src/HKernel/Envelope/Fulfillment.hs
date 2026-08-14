module HKernel.Envelope.Fulfillment
  ( FulfillmentAmounts(..)
  , fulfillmentNet
  , EnvelopeFulfillment
  , EnvelopeFulfillmentError(..)
  , observeEnvelopeFulfillment
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
  ( Balance
  , addBalance
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
  , identifiedActualId
  , identifiedActualTransaction
  )
import HKernel.Plan.CompletionShape
  ( PlanCompletionShapeError
  , validatePlanCompletionShape
  )
import HKernel.Plan.Journal
  ( PlanJournal
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalValue
  )
import HKernel.Plan.Open
  ( CompletedPlanTransaction
  , PlanObservationError
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

-- | Observe completed non-Expense target Plans and their typed reversal chains
-- through one inclusive day.
--
-- Fulfillment intent is selected by stable PlanId, never by Account or by the
-- generic Income/outgoing classifier. This matters for Asset-to-Asset savings
-- and investment Plans, whose Envelope meaning is explicit household intent
-- rather than an accounting role inferred from Account types.
--
-- Once a routed Plan completes, its root Plan/Actual shape identifies target
-- posting positions. Actual quantities at those positions are authoritative.
-- Reversal chains then reverse or restore that whole root fulfillment evidence.
-- They do not re-derive target meaning from the reversal transaction's Account
-- aggregate, so repeated target postings remain positionally well-defined.
--
-- Route identity is frozen at the root completion Actual date. A single Actual
-- may generically complete several Plans, but if more than one of those Plans is
-- routed as Envelope fulfillment this projection fails closed rather than
-- inventing an amount-allocation rule.
observeEnvelopeFulfillment
  :: Period
  -> Day
  -> PlanJournal
  -> ActualJournal
  -> FulfillmentRoutingHistory
  -> Either (NonEmpty.NonEmpty EnvelopeFulfillmentError) EnvelopeFulfillment
observeEnvelopeFulfillment period observedThrough plans actual routing
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
      , periodContains period entryDay
      , entryDay <= observedThrough
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
      ]

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
        [ singletonBalance (postingAmount actualPosting)
        | (planPosting, actualPosting) <- zip planPostings actualPostings
        , amountQuantity (postingAmount planPosting) > zeroQuantity
        , accountTypeFor (postingAccount planPosting) registry /= Just Expense
        ]
      where
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
