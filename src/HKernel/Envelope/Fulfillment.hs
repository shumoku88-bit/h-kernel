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
  , actualJournalValue
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
  , balanceEntries
  , emptyBalance
  , lookupBalance
  , mkAmount
  , negateQuantity
  , singletonBalance
  , subtractBalance
  , zeroQuantity
  )
import HKernel.Period (Period, periodContains)
import HKernel.Plan.Completion (ActualTransactionId)

-- | Gross fulfillment/reversal evidence for one Envelope.
--
-- Fulfillment is intentionally distinct from Expense consumption. It models
-- explicit non-Expense targets such as moving liquid money into savings or an
-- investment account. Ordinary withdrawals from such a target do not restore
-- Envelope entitlement; only an admitted typed reversal of an originally
-- positive fulfillment does so.
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
  deriving (Eq, Show)

-- | Observe explicit non-Expense target fulfillment through one inclusive day.
--
-- Routing is anchored to the root Actual date for typed reversal chains. The
-- root Account/Commodity effect must itself be positive before the chain can
-- affect fulfillment, so reversing an ordinary withdrawal cannot accidentally
-- create new Envelope fulfillment. Actual admission already proves reversal
-- effects are exact negations and the relation graph is acyclic.
observeEnvelopeFulfillment
  :: Period
  -> Day
  -> ActualJournal
  -> FulfillmentRoutingHistory
  -> Either EnvelopeFulfillmentError EnvelopeFulfillment
observeEnvelopeFulfillment period observedThrough actual routing
  | not (periodContains period observedThrough) =
      Left (EnvelopeFulfillmentObservationOutsidePeriod observedThrough period)
  | otherwise = Right EnvelopeFulfillment
      { envelopeFulfillmentPeriod = period
      , envelopeFulfillmentObservedThrough = observedThrough
      , managedFulfillment = foldr observeEntry Map.empty visibleEntries
      }
  where
    entries = actualJournalTransactionEntries actual
    registry = journalAccountRegistry (actualJournalValue actual)
    transactionById = Map.fromList
      [ (actualId, actualTransactionEntryTransaction entry)
      | entry <- entries
      , Just actualId <- [actualTransactionEntryIdentity entry]
      ]
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

    observeEntry entry accum =
      foldr (observeAccount typedReversal routeDay rootEffects) accum
        (Map.toAscList currentEffects)
      where
        transaction = actualTransactionEntryTransaction entry
        maybeActualId = actualTransactionEntryIdentity entry
        typedReversal = maybe False (`Map.member` reversalTargetById) maybeActualId
        rootTransaction = case maybeActualId of
          Nothing -> transaction
          Just actualId -> Map.findWithDefault transaction
            (rootActualId reversalTargetById actualId)
            transactionById
        routeDay = transactionDate rootTransaction
        rootEffects = transactionEffects rootTransaction
        currentEffects = transactionEffects transaction

    observeAccount typedReversal routeDay rootEffects (account, currentBalance) accum
      | accountTypeFor account registry == Just Expense = accum
      | otherwise = case fulfillmentRouteAt routeDay account routing of
          Just (FulfillsEnvelope envelope) ->
            let amounts = fulfillmentAmounts
                  typedReversal
                  (Map.findWithDefault emptyBalance account rootEffects)
                  currentBalance
            in if amounts == mempty
                then accum
                else Map.insertWith (<>) envelope amounts accum
          Just NotFulfillmentTarget -> accum
          Nothing -> accum

transactionEffects transaction = Map.fromListWith addBalance
  [ (postingAccount posting, singletonBalance (postingAmount posting))
  | posting <- NonEmpty.toList (transactionPostings transaction)
  ]

fulfillmentAmounts :: Bool -> Balance -> Balance -> FulfillmentAmounts
fulfillmentAmounts typedReversal rootBalance currentBalance =
  foldMap classify (balanceEntries currentBalance)
  where
    classify (commodity, currentQuantity)
      | lookupBalance commodity rootBalance <= zeroQuantity = mempty
      | currentQuantity > zeroQuantity =
          FulfillmentAmounts
            (singletonBalance (mkAmount commodity currentQuantity))
            emptyBalance
      | typedReversal && currentQuantity < zeroQuantity =
          FulfillmentAmounts
            emptyBalance
            (singletonBalance (mkAmount commodity (negateQuantity currentQuantity)))
      | otherwise = mempty

rootActualId
  :: Map.Map ActualTransactionId ActualTransactionId
  -> ActualTransactionId
  -> ActualTransactionId
rootActualId reversalTargetById = go
  where
    go actualId = case Map.lookup actualId reversalTargetById of
      Nothing -> actualId
      Just targetId -> go targetId

envelopeFulfillmentFor :: EnvelopeId -> EnvelopeFulfillment -> FulfillmentAmounts
envelopeFulfillmentFor envelope =
  Map.findWithDefault mempty envelope . managedFulfillment

envelopeFulfillmentEntries
  :: EnvelopeFulfillment
  -> [(EnvelopeId, FulfillmentAmounts)]
envelopeFulfillmentEntries = Map.toAscList . managedFulfillment
