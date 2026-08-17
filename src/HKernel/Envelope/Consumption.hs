module HKernel.Envelope.Consumption
  ( ConsumptionAmounts(..)
  , consumptionNet
  , EnvelopeConsumption
  , EnvelopeConsumptionError(..)
  , observeEnvelopeConsumption
  , observeEnvelopeStockConsumption
  , envelopeConsumptionPeriod
  , envelopeConsumptionObservedThrough
  , envelopeConsumptionFor
  , envelopeConsumptionEntries
  , envelopeConsumptionUnmanaged
  , envelopeConsumptionUnrouted
  ) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day)
import HKernel.Account (Account, AccountType(..), accountTypeFor)
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
import HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , envelopeEntitlementHistoryOriginDateFor
  )
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , ExpenseRouteResolver
  , resolveExpenseRoute
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
  , negateAmount
  , singletonBalance
  , subtractBalance
  , zeroQuantity
  )
import HKernel.Period (Period, periodContains)
import HKernel.Plan.Completion (ActualTransactionId)

-- | Gross charge/refund evidence at one consumption coordinate.
--
-- Keeping both sides prevents zero-net activity from disappearing. Refunds are
-- stored as positive magnitudes; net consumption is @charges - refunds@.
data ConsumptionAmounts = ConsumptionAmounts
  { consumptionCharges :: Balance
  , consumptionRefunds :: Balance
  } deriving (Eq, Show)

instance Semigroup ConsumptionAmounts where
  left <> right = ConsumptionAmounts
    { consumptionCharges =
        addBalance (consumptionCharges left) (consumptionCharges right)
    , consumptionRefunds =
        addBalance (consumptionRefunds left) (consumptionRefunds right)
    }

instance Monoid ConsumptionAmounts where
  mempty = ConsumptionAmounts emptyBalance emptyBalance

consumptionNet :: ConsumptionAmounts -> Balance
consumptionNet amounts =
  consumptionCharges amounts `subtractBalance` consumptionRefunds amounts

-- | Actual Expense consumption at one resolved period/day observation.
--
-- Managed Envelope activity, explicit non-Envelope activity, and missing-route
-- attention remain separate coordinates. The constructor stays private so every
-- value is produced from one admitted ActualJournal and routing history.
data EnvelopeConsumption = EnvelopeConsumption
  { envelopeConsumptionPeriod          :: Period
  , envelopeConsumptionObservedThrough :: Day
  , managedConsumption                 :: Map EnvelopeId ConsumptionAmounts
  , envelopeConsumptionUnmanaged       :: Map Account ConsumptionAmounts
  , envelopeConsumptionUnrouted        :: Map Account ConsumptionAmounts
  } deriving (Eq, Show)

data EnvelopeConsumptionError
  = EnvelopeConsumptionObservationOutsidePeriod Day Period
  deriving (Eq, Show)

-- | Observe bounded Actual Expense activity inside the selected Period.
--
-- This remains useful as an activity observation. Household Envelope Remaining
-- must use 'observeEnvelopeStockConsumption' instead, because a report Period is
-- not the lower boundary of live Envelope capacity.
observeEnvelopeConsumption
  :: Period
  -> Day
  -> ActualJournal
  -> ExpenseRouteResolver
  -> Either EnvelopeConsumptionError EnvelopeConsumption
observeEnvelopeConsumption period observedThrough actual routingResolver =
  observeEnvelopeConsumptionWith
    (\ownDay _routeDay _amount -> periodContains period ownDay)
    period observedThrough actual routingResolver

-- | Observe cumulative Expense use from the native Entitlement origin of each
-- Commodity through the inclusive observation day.
--
-- A typed reversal inherits the root Actual route date. The same root date also
-- decides stock-origin membership, so reversing a pre-Envelope accounting fact
-- after Envelope inception cannot manufacture a refund in Envelope capacity.
-- A Commodity with no admitted Entitlement history has no Envelope stock world
-- and therefore contributes no managed, unmanaged, or unrouted stock evidence.
observeEnvelopeStockConsumption
  :: EnvelopeEntitlementHistory
  -> Period
  -> Day
  -> ActualJournal
  -> ExpenseRouteResolver
  -> Either EnvelopeConsumptionError EnvelopeConsumption
observeEnvelopeStockConsumption history period observedThrough actual routingResolver =
  observeEnvelopeConsumptionWith included
    period observedThrough actual routingResolver
  where
    included _ownDay routeDay amount =
      case envelopeEntitlementHistoryOriginDateFor (amountCommodity amount) history of
        Nothing -> False
        Just originDay -> routeDay >= originDay

observeEnvelopeConsumptionWith
  :: (Day -> Day -> Amount -> Bool)
  -> Period
  -> Day
  -> ActualJournal
  -> ExpenseRouteResolver
  -> Either EnvelopeConsumptionError EnvelopeConsumption
observeEnvelopeConsumptionWith included period observedThrough actual routingResolver
  | not (periodContains period observedThrough) =
      Left (EnvelopeConsumptionObservationOutsidePeriod observedThrough period)
  | otherwise = Right EnvelopeConsumption
      { envelopeConsumptionPeriod = period
      , envelopeConsumptionObservedThrough = observedThrough
      , managedConsumption = managed
      , envelopeConsumptionUnmanaged = unmanaged
      , envelopeConsumptionUnrouted = unrouted
      }
  where
    entries = actualJournalTransactionEntries actual
    registry = journalAccountRegistry (actualJournalValue actual)
    transactionDateById = Map.fromList
      [ (actualId, transactionDate (actualTransactionEntryTransaction entry))
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
      , transactionDate (actualTransactionEntryTransaction entry) <= observedThrough
      ]

    (managed, unmanaged, unrouted) =
      foldr observeEntry (Map.empty, Map.empty, Map.empty) visibleEntries

    observeEntry entry accum =
      foldr (observePosting ownDay routeDay) accum
        (NonEmpty.toList (transactionPostings transaction))
      where
        transaction = actualTransactionEntryTransaction entry
        ownDay = transactionDate transaction
        routeDay = case actualTransactionEntryIdentity entry of
          Nothing -> ownDay
          Just actualId -> rootRoutingDate
            transactionDateById reversalTargetById ownDay actualId

    observePosting ownDay routeDay posting accum@(managedAcc, unmanagedAcc, unroutedAcc)
      | accountTypeFor account registry /= Just Expense = accum
      | quantity == zeroQuantity = accum
      | not (included ownDay routeDay amount) = accum
      | otherwise = case resolveExpenseRoute routingResolver routeDay account of
          Just (ManagedByEnvelope envelope) ->
            ( Map.insertWith (<>) envelope amounts managedAcc
            , unmanagedAcc
            , unroutedAcc
            )
          Just NotEnvelopeManaged ->
            ( managedAcc
            , Map.insertWith (<>) account amounts unmanagedAcc
            , unroutedAcc
            )
          Nothing ->
            ( managedAcc
            , unmanagedAcc
            , Map.insertWith (<>) account amounts unroutedAcc
            )
      where
        account = postingAccount posting
        amount = postingAmount posting
        quantity = amountQuantity amount
        amounts = consumptionAmounts amount

envelopeConsumptionFor :: EnvelopeId -> EnvelopeConsumption -> ConsumptionAmounts
envelopeConsumptionFor envelope =
  Map.findWithDefault mempty envelope . managedConsumption

envelopeConsumptionEntries
  :: EnvelopeConsumption
  -> [(EnvelopeId, ConsumptionAmounts)]
envelopeConsumptionEntries = Map.toAscList . managedConsumption

consumptionAmounts :: Amount -> ConsumptionAmounts
consumptionAmounts amount
  | amountQuantity amount > zeroQuantity =
      ConsumptionAmounts (singletonBalance amount) emptyBalance
  | otherwise =
      ConsumptionAmounts emptyBalance (singletonBalance (negateAmount amount))

rootRoutingDate
  :: Map ActualTransactionId Day
  -> Map ActualTransactionId ActualTransactionId
  -> Day
  -> ActualTransactionId
  -> Day
rootRoutingDate transactionDateById reversalTargetById ownDay = go
  where
    go actualId = case Map.lookup actualId reversalTargetById of
      Nothing -> Map.findWithDefault ownDay actualId transactionDateById
      Just targetId -> go targetId
