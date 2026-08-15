-- | Native Household Envelope observation from admitted Actual and entitlement
-- movement evidence.
module HKernel.Household.EnvelopeObservation
  ( HouseholdEnvelopeObservation
  , householdEnvelopeObservationPolicy
  , householdEnvelopeConsumption
  , householdEnvelopeEntitlement
  , HouseholdEnvelopeError(..)
  , deriveHouseholdEnvelopeObservation
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time.Calendar (Day)
import HKernel.Account (Account)
import HKernel.Actual.Journal (ActualJournal)
import HKernel.Envelope.Consumption
  ( EnvelopeConsumption
  , EnvelopeConsumptionError
  , observeEnvelopeConsumption
  )
import HKernel.Envelope.Entitlement
  ( EnvelopeEntitlement
  , EnvelopeEntitlementError
  , observeEnvelopeEntitlement
  )
import HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , EnvelopeEntitlementHistoryError
  , mkEnvelopeEntitlementHistory
  )
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransferError
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.ExpenseRouting (ExpenseRouteResolver)
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Household.AccountProfile
  ( HouseholdAccountPolicy
  , RetainedBudgetAccountKind(..)
  , householdBudgetKindByAccount
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdAllocationEnvelopes
  , householdUnassignedBudgetAccounts
  )
import HKernel.Money (amountQuantity, negateAmount, zeroQuantity)
import HKernel.Period (Period, periodContains)

data HouseholdEnvelopeObservation = HouseholdEnvelopeObservation
  { householdEnvelopeObservationPolicy :: HouseholdPolicy
  , householdEnvelopeConsumption       :: EnvelopeConsumption
  , householdEnvelopeEntitlement       :: EnvelopeEntitlement
  } deriving (Eq, Show)

data HouseholdEnvelopeError
  = HouseholdEnvelopeConsumptionError EnvelopeConsumptionError
  | HouseholdEnvelopeEntitlementKindMissing Int Int
  | HouseholdEnvelopeEntitlementCoordinateMismatch Int Int
  | HouseholdEnvelopeEntitlementTransferError Int EnvelopeEntitlementTransferError
  | HouseholdEnvelopeEntitlementHistoryError EnvelopeEntitlementHistoryError
  | HouseholdEnvelopeEntitlementObservationError EnvelopeEntitlementError
  deriving (Eq, Show)

data SourceEndpoint
  = SourceEnvelope EnvelopeId
  | SourceUnallocated
  | SourceOpening
  | SourceExecution

deriveHouseholdEnvelopeObservation
  :: Day
  -> Period
  -> ActualJournal
  -> HouseholdPolicy
  -> HouseholdAccountPolicy
  -> ExpenseRouteResolver
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdEnvelopeError) HouseholdEnvelopeObservation
deriveHouseholdEnvelopeObservation observedThrough period actual policy accountPolicy routeResolver movements = do
  history <- projectEntitlementHistory period policy accountPolicy movements
  entitlement <- singleLeft HouseholdEnvelopeEntitlementObservationError
    (observeEnvelopeEntitlement period observedThrough history)
  consumption <- singleLeft HouseholdEnvelopeConsumptionError
    (observeEnvelopeConsumption period observedThrough actual routeResolver)
  Right HouseholdEnvelopeObservation
    { householdEnvelopeObservationPolicy = policy
    , householdEnvelopeConsumption = consumption
    , householdEnvelopeEntitlement = entitlement
    }

projectEntitlementHistory
  :: Period
  -> HouseholdPolicy
  -> HouseholdAccountPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdEnvelopeError) EnvelopeEntitlementHistory
projectEntitlementHistory period policy accountPolicy movements =
  case partitionEithers (zipWith projectMovement [1..] movements) of
    ([], maybeTransfers) ->
      mapLeft (fmap HouseholdEnvelopeEntitlementHistoryError)
        (mkEnvelopeEntitlementHistory [transfer | Just transfer <- maybeTransfers])
    (errorGroups, _) -> Left (NonEmpty.fromList (concat errorGroups))
  where
    allocationByAccount = householdAllocationEnvelopes policy
    unassignedAccounts = householdUnassignedBudgetAccounts policy
    kinds = householdBudgetKindByAccount accountPolicy

    projectMovement transactionIndex movement
      | not (periodContains period (householdBudgetMovementDate movement)) = Right Nothing
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
      case (Map.lookup account allocationByAccount, Set.member account unassignedAccounts, Map.lookup account kinds) of
        (Just envelope, False, Just RetainedEnvelopeBudgetAccount) -> Right (SourceEnvelope envelope)
        (Nothing, True, Just RetainedUnassignedBudgetAccount) -> Right SourceUnallocated
        (Nothing, False, Just RetainedOpeningBudgetAccount) -> Right SourceOpening
        (Nothing, False, Just RetainedSpentBudgetAccount) -> Right SourceExecution
        (_, _, Nothing) -> Left (HouseholdEnvelopeEntitlementKindMissing transactionIndex postingIndex)
        _ -> Left (HouseholdEnvelopeEntitlementCoordinateMismatch transactionIndex postingIndex)

    projectEndpoints transactionIndex movement amount fromEndpoint toEndpoint =
      case (fromEndpoint, toEndpoint) of
        (SourceEnvelope _, SourceExecution) -> Right Nothing
        (SourceExecution, SourceEnvelope _) -> Right Nothing
        (SourceEnvelope fromEnvelope, SourceEnvelope toEnvelope) ->
          makeTransfer (Spendable fromEnvelope) (Spendable toEnvelope)
        (SourceEnvelope fromEnvelope, _) -> makeTransfer (Spendable fromEnvelope) Unallocated
        (_, SourceEnvelope toEnvelope) -> makeTransfer Unallocated (Spendable toEnvelope)
        _ -> Right Nothing
      where
        makeTransfer fromNative toNative =
          case mkEnvelopeEntitlementTransfer
              (householdBudgetMovementDate movement)
              period
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

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value
