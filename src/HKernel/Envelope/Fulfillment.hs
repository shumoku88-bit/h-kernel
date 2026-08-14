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
  , amountCommodity
  , amountQuantity
  , emptyBalance
  , lookupBalance
  , mkAmount
  , negateQuantity
  , singletonBalance
  , subtractBalance
  , zeroQuantity
  )
import HKernel.Period (Period, periodContains)
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
  ( CompletedOutgoingPlanTransaction
  , OpenOutgoingPlanError
  , completedOutgoingActual
  , completedOutgoingPlan
  , resolveCompletedOutgoingPlanTransactionsAt
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
  | EnvelopeFulfillmentPlanObservationError OpenOutgoingPlanError
  | EnvelopeFulfillmentCompletionShapeError PlanCompletionShapeError
  deriving (Eq, Show)

-- | Observe completed non-Expense target Plans and their typed reversal chains
-- through one inclusive day.
--
-- A positive target posting only fulfills an Envelope when its root Actual is
-- explicit completion evidence for an admitted outgoing Plan. The root Plan and
-- Actual must have compatible Account order, posting directions, and commodity
-- coordinates; quantities may differ and the Actual quantity is authoritative.
--
-- Target routing is anchored to the root completion Actual date. Later routing
-- changes therefore cannot rewrite completed fulfillment. A typed reversal of
-- the completion reverses fulfillment and a reverse-of-reverse restores it.
-- Unrelated withdrawals, deposits, and their reversals never become fulfillment
-- merely because they touch the same target account.
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
        (resolveCompletedOutgoingPlanTransactionsAt observedThrough plans actual)
      validated <- validateCompleted completed
      let completionByActualId = Map.fromList
            [ (identifiedActualId (completedOutgoingActual pair), pair)
            | pair <- validated
            ]
          managed = foldr (observeEntry completionByActualId) Map.empty visibleEntries
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

    validateCompleted completed =
      case traverse validateOne completed of
        Left err -> Left (EnvelopeFulfillmentCompletionShapeError err NonEmpty.:| [])
        Right values -> Right values

    validateOne pair = do
      let identifiedPlan = completedOutgoingPlan pair
          identifiedActual = completedOutgoingActual pair
      validatePlanCompletionShape
        (identifiedPlanId identifiedPlan)
        (identifiedPlanTransaction identifiedPlan)
        (identifiedActualTransaction identifiedActual)
      Right pair

    observeEntry completionByActualId entry accum =
      case actualTransactionEntryIdentity entry of
        Nothing -> accum
        Just actualId ->
          case Map.lookup rootId completionByActualId of
            Nothing -> accum
            Just pair ->
              foldr
                (observeTarget typedReversal currentEffects)
                accum
                (targetCoordinates pair)
          where
            rootId = rootActualId reversalTargetById actualId
            typedReversal = Map.member actualId reversalTargetById
            currentEffects = transactionEffects
              (actualTransactionEntryTransaction entry)

    targetCoordinates pair =
      [ (account, commodity, envelope)
      | posting <- NonEmpty.toList
          (transactionPostings
            (identifiedPlanTransaction (completedOutgoingPlan pair)))
      , let account = postingAccount posting
            amount = postingAmount posting
            commodity = amountCommodity amount
      , amountQuantity amount > zeroQuantity
      , accountTypeFor account registry /= Just Expense
      , Just (FulfillsEnvelope envelope) <-
          [fulfillmentRouteAt routeDay account routing]
      ]
      where
        routeDay = transactionDate
          (identifiedActualTransaction (completedOutgoingActual pair))

    observeTarget typedReversal currentEffects (account, commodity, envelope) accum
      | currentQuantity > zeroQuantity =
          Map.insertWith (<>) envelope
            (FulfillmentAmounts
              (singletonBalance (mkAmount commodity currentQuantity))
              emptyBalance)
            accum
      | typedReversal && currentQuantity < zeroQuantity =
          Map.insertWith (<>) envelope
            (FulfillmentAmounts
              emptyBalance
              (singletonBalance (mkAmount commodity (negateQuantity currentQuantity))))
            accum
      | otherwise = accum
      where
        currentQuantity = lookupBalance commodity
          (Map.findWithDefault emptyBalance account currentEffects)

transactionEffects transaction = Map.fromListWith addBalance
  [ (postingAccount posting, singletonBalance (postingAmount posting))
  | posting <- NonEmpty.toList (transactionPostings transaction)
  ]

rootActualId
  :: Map.Map ActualTransactionId ActualTransactionId
  -> ActualTransactionId
  -> ActualTransactionId
rootActualId reversalTargetById = go
  where
    go actualId = case Map.lookup actualId reversalTargetById of
      Nothing -> actualId
      Just targetId -> go targetId

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
