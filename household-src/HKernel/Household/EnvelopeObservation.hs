-- | Native Household Envelope observation from admitted entitlement, Actual,
-- Plan, and historical routing evidence.
module HKernel.Household.EnvelopeObservation
  ( HouseholdEnvelopeObservation
  , householdEnvelopeObservationPeriod
  , householdEnvelopeObservationObservedThrough
  , householdEnvelopeConsumption
  , householdEnvelopeEntitlement
  , householdEnvelopeFulfillment
  , householdEnvelopeRemaining
  , householdEnvelopeCommitment
  , householdEnvelopeHeadroom
  , HouseholdEnvelopeError(..)
  , deriveHouseholdEnvelopeObservation
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time.Calendar (Day)
import HKernel.Actual.Journal (ActualJournal)
import HKernel.Envelope.Commitment
  ( EnvelopeCommitment
  , EnvelopeCommitmentError
  , observeEnvelopeCommitment
  )
import HKernel.Envelope.Consumption
  ( EnvelopeConsumption
  , EnvelopeConsumptionError
  , observeEnvelopeStockConsumption
  )
import HKernel.Envelope.Entitlement
  ( EnvelopeEntitlement
  , EnvelopeEntitlementError
  , observeEnvelopeEntitlement
  )
import HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , EnvelopeEntitlementHistoryError
  , mkEnvelopeEntitlementHistoryWithOrigins
  )
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransferError
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoutingHistory
  , expenseRoutingResolver
  )
import HKernel.Envelope.Fulfillment
  ( EnvelopeFulfillment
  , EnvelopeFulfillmentError
  , observeEnvelopeStockFulfillment
  )
import HKernel.Envelope.FulfillmentRouting (FulfillmentRoutingHistory)
import HKernel.Envelope.Headroom
  ( EnvelopeHeadroom
  , EnvelopeHeadroomError
  , calculateEnvelopeHeadroom
  )
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Envelope.Remaining
  ( EnvelopeRemaining
  , EnvelopeRemainingError
  , calculateEnvelopeRemaining
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdAllocationEnvelopes
  , householdOpeningBudgetAccounts
  , householdUnassignedBudgetAccounts
  )
import HKernel.Money
  ( amountCommodity
  , amountQuantity
  , negateAmount
  , zeroQuantity
  )
import HKernel.Period (Period)
import HKernel.Plan.Journal (PlanJournal)

data HouseholdEnvelopeObservation = HouseholdEnvelopeObservation
  { householdEnvelopeObservationPeriod          :: Period
  , householdEnvelopeObservationObservedThrough :: Day
  , householdEnvelopeConsumption                :: EnvelopeConsumption
  , householdEnvelopeEntitlement                :: EnvelopeEntitlement
  , householdEnvelopeFulfillment                :: EnvelopeFulfillment
  , householdEnvelopeRemaining                  :: EnvelopeRemaining
  , householdEnvelopeCommitment                 :: EnvelopeCommitment
  , householdEnvelopeHeadroom                   :: EnvelopeHeadroom
  } deriving (Eq, Show)

data HouseholdEnvelopeError
  = HouseholdEnvelopeConsumptionError EnvelopeConsumptionError
  | HouseholdEnvelopeEntitlementCoordinateMissing Int Int
  | HouseholdEnvelopeEntitlementTransferError Int EnvelopeEntitlementTransferError
  | HouseholdEnvelopeEntitlementHistoryError EnvelopeEntitlementHistoryError
  | HouseholdEnvelopeEntitlementObservationError EnvelopeEntitlementError
  | HouseholdEnvelopeFulfillmentError EnvelopeFulfillmentError
  | HouseholdEnvelopeRemainingError EnvelopeRemainingError
  | HouseholdEnvelopeCommitmentError EnvelopeCommitmentError
  | HouseholdEnvelopeHeadroomError EnvelopeHeadroomError
  deriving (Eq, Show)

data SourceEndpoint
  = SourceEnvelope EnvelopeId
  | SourceUnallocated
  | SourceOpening

deriveHouseholdEnvelopeObservation
  :: Day
  -> Period
  -> ActualJournal
  -> PlanJournal
  -> HouseholdPolicy
  -> ExpenseRoutingHistory
  -> FulfillmentRoutingHistory
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdEnvelopeError) HouseholdEnvelopeObservation
deriveHouseholdEnvelopeObservation observedThrough period actual plans policy expenseRouting fulfillmentRouting movements = do
  history <- projectEntitlementHistory policy movements
  entitlement <- singleLeft HouseholdEnvelopeEntitlementObservationError
    (observeEnvelopeEntitlement period observedThrough history)
  consumption <- singleLeft HouseholdEnvelopeConsumptionError
    (observeEnvelopeStockConsumption
      history period observedThrough actual (expenseRoutingResolver expenseRouting))
  fulfillment <- mapLeft (fmap HouseholdEnvelopeFulfillmentError)
    (observeEnvelopeStockFulfillment
      history period observedThrough plans actual fulfillmentRouting)
  remaining <- valueLeft HouseholdEnvelopeRemainingError
    (calculateEnvelopeRemaining entitlement consumption fulfillment)
  commitment <- mapLeft (fmap HouseholdEnvelopeCommitmentError)
    (observeEnvelopeCommitment
      period observedThrough plans actual expenseRouting fulfillmentRouting)
  headroom <- valueLeft HouseholdEnvelopeHeadroomError
    (calculateEnvelopeHeadroom remaining commitment)
  Right HouseholdEnvelopeObservation
    { householdEnvelopeObservationPeriod = period
    , householdEnvelopeObservationObservedThrough = observedThrough
    , householdEnvelopeConsumption = consumption
    , householdEnvelopeEntitlement = entitlement
    , householdEnvelopeFulfillment = fulfillment
    , householdEnvelopeRemaining = remaining
    , householdEnvelopeCommitment = commitment
    , householdEnvelopeHeadroom = headroom
    }

projectEntitlementHistory
  :: HouseholdPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdEnvelopeError) EnvelopeEntitlementHistory
projectEntitlementHistory policy movements =
  case partitionEithers (zipWith projectMovement [1..] movements) of
    ([], maybeTransfers) ->
      mapLeft (fmap HouseholdEnvelopeEntitlementHistoryError)
        (mkEnvelopeEntitlementHistoryWithOrigins
          sourceOrigins
          [transfer | Just transfer <- maybeTransfers])
    (errorGroups, _) -> Left (NonEmpty.fromList (concat errorGroups))
  where
    sourceOrigins = Map.fromListWith min
      [ ( amountCommodity (householdBudgetMovementAmount movement)
        , householdBudgetMovementDate movement
        )
      | movement <- movements
      ]

    allocationByAccount = householdAllocationEnvelopes policy
    openingAccounts = householdOpeningBudgetAccounts policy
    unassignedAccounts = householdUnassignedBudgetAccounts policy

    projectMovement transactionIndex movement
      | amountQuantity sourceAmount == zeroQuantity = Right Nothing
      | otherwise = do
          let (fromAccount, toAccount, amount)
                | amountQuantity sourceAmount > zeroQuantity =
                    (householdBudgetMovementFrom movement, householdBudgetMovementTo movement, sourceAmount)
                | otherwise =
                    (householdBudgetMovementTo movement, householdBudgetMovementFrom movement, negateAmount sourceAmount)
          (fromEndpoint, toEndpoint) <- classifyEndpoints transactionIndex fromAccount toAccount
          projectEndpoints transactionIndex movement amount fromEndpoint toEndpoint
      where
        sourceAmount = householdBudgetMovementAmount movement

    classifyEndpoints transactionIndex fromAccount toAccount =
      case partitionEithers
        [ classifyEndpoint transactionIndex 1 fromAccount
        , classifyEndpoint transactionIndex 2 toAccount
        ] of
        ([], [fromEndpoint, toEndpoint]) -> Right (fromEndpoint, toEndpoint)
        (errors, _) -> Left errors
        _ -> error "unreachable: exactly two entitlement endpoints are classified"

    classifyEndpoint transactionIndex postingIndex account =
      case (Map.lookup account allocationByAccount, Set.member account openingAccounts, Set.member account unassignedAccounts) of
        (Just envelope, False, False) -> Right (SourceEnvelope envelope)
        (Nothing, True, False) -> Right SourceOpening
        (Nothing, False, True) -> Right SourceUnallocated
        _ -> Left (HouseholdEnvelopeEntitlementCoordinateMissing transactionIndex postingIndex)

    projectEndpoints transactionIndex movement amount fromEndpoint toEndpoint =
      case (fromEndpoint, toEndpoint) of
        (SourceEnvelope fromEnvelope, SourceEnvelope toEnvelope) ->
          makeTransfer (Spendable fromEnvelope) (Spendable toEnvelope)
        (SourceEnvelope fromEnvelope, _) -> makeTransfer (Spendable fromEnvelope) Unallocated
        (_, SourceEnvelope toEnvelope) -> makeTransfer Unallocated (Spendable toEnvelope)
        _ -> Right Nothing
      where
        makeTransfer fromNative toNative =
          case mkEnvelopeEntitlementTransfer
              (householdBudgetMovementDate movement)
              fromNative
              toNative
              amount
              (householdBudgetMovementMemo movement) of
            Right transfer -> Right (Just transfer)
            Left err -> Left [HouseholdEnvelopeEntitlementTransferError transactionIndex err]

singleLeft
  :: (error -> HouseholdEnvelopeError)
  -> Either error value
  -> Either (NonEmpty HouseholdEnvelopeError) value
singleLeft wrap = mapLeft (NonEmpty.singleton . wrap)

valueLeft
  :: (error -> HouseholdEnvelopeError)
  -> Either error value
  -> Either (NonEmpty HouseholdEnvelopeError) value
valueLeft = singleLeft

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value
