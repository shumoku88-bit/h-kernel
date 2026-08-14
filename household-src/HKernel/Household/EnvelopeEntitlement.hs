{-# LANGUAGE OverloadedStrings #-}

-- | Household admission bridge from the current canonical @budget.journal@
-- movement evidence to native Envelope entitlement history.
--
-- The physical Budget-Account journal is a migration source, not the target
-- domain model. Only allocation decisions become Envelope transfers here.
-- Synthetic capacity movements and legacy @Envelope <-> spent@ execution
-- mirrors are deliberately not entitlement: Actual consumption / fulfillment
-- own those meanings in the native model.
module HKernel.Household.EnvelopeEntitlement
  ( HouseholdEnvelopeEntitlementError(..)
  , deriveHouseholdEnvelopeEntitlementHistory
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import HKernel.Account (Account)
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
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Household.AccountProfile
  ( HouseholdAccountPolicy
  , RetainedBudgetAccountKind(..)
  , householdBudgetKindByAccount
  )
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  )
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdAllocationEnvelopes
  , householdUnassignedBudgetAccounts
  )
import HKernel.Money
  ( amountQuantity
  , negateAmount
  , zeroQuantity
  )
import HKernel.Period (Period, periodContains)

-- | Privacy-preserving failures while interpreting the current canonical
-- Budget-Account source as native Envelope allocation evidence.
--
-- Transaction/posting indexes identify the bad coordinate without retaining a
-- private Account name or amount in configuration errors.
data HouseholdEnvelopeEntitlementError
  = HouseholdEnvelopeEntitlementBudgetKindMissing Int Int
  | HouseholdEnvelopeEntitlementCoordinateMismatch Int Int
  | HouseholdEnvelopeEntitlementTransferRejected
      Int EnvelopeEntitlementTransferError
  | HouseholdEnvelopeEntitlementHistoryRejected
      EnvelopeEntitlementHistoryError
  deriving (Eq, Show)

data LegacyBudgetEndpoint
  = LegacyEnvelope EnvelopeId
  | LegacyUnallocated
  | LegacyOpening
  | LegacySpent
  deriving (Eq, Show)

-- | Project one observation period of canonical Budget movement evidence into
-- native Envelope entitlement history.
--
-- Signed source movements are normalized without reinterpreting posting order:
-- a negative amount reverses the admitted from/to direction, while an exact zero
-- carries no entitlement effect. Movements outside the observation period are
-- ignored, matching the existing cycle-scoped Budget observation.
--
-- @Envelope <-> spent@ is legacy execution evidence, not allocation. It is
-- intentionally excluded so later Expense routing / target fulfillment can own
-- consumption without double counting. @opening@ and other movements that touch
-- no Envelope are capacity evidence and likewise do not create entitlement.
deriveHouseholdEnvelopeEntitlementHistory
  :: Period
  -> HouseholdPolicy
  -> HouseholdAccountPolicy
  -> [HouseholdBudgetMovement]
  -> Either
      (NonEmpty HouseholdEnvelopeEntitlementError)
      EnvelopeEntitlementHistory
deriveHouseholdEnvelopeEntitlementHistory period policy accountPolicy movements =
  case partitionEithers projected of
    ([], maybeTransfers) ->
      case mkEnvelopeEntitlementHistory [value | Just value <- maybeTransfers] of
        Right history -> Right history
        Left errors -> Left
          (fmap HouseholdEnvelopeEntitlementHistoryRejected errors)
    (errorGroups, _) ->
      Left (NonEmpty.fromList (concat errorGroups))
  where
    projected = zipWith projectMovement [1..] movements

    projectMovement transactionIndex movement
      | not (periodContains period (householdBudgetMovementDate movement)) =
          Right Nothing
      | amountQuantity sourceAmount == zeroQuantity = Right Nothing
      | otherwise = do
          let (fromAccount, toAccount, amount)
                | amountQuantity sourceAmount > zeroQuantity =
                    ( householdBudgetMovementFrom movement
                    , householdBudgetMovementTo movement
                    , sourceAmount
                    )
                | otherwise =
                    ( householdBudgetMovementTo movement
                    , householdBudgetMovementFrom movement
                    , negateAmount sourceAmount
                    )
          (fromEndpoint, toEndpoint) <- classifyEndpoints
            transactionIndex fromAccount toAccount
          projectEndpoints transactionIndex movement amount
            fromEndpoint toEndpoint
      where
        sourceAmount = householdBudgetMovementAmount movement

    classifyEndpoints transactionIndex fromAccount toAccount =
      case partitionEithers
        [ classifyEndpoint transactionIndex 1 fromAccount
        , classifyEndpoint transactionIndex 2 toAccount
        ] of
        ([], [fromEndpoint, toEndpoint]) -> Right (fromEndpoint, toEndpoint)
        (errors, _) -> Left errors
        _ -> error "unreachable: exactly two Budget endpoints are classified"

    classifyEndpoint transactionIndex postingIndex account =
      case ( Map.lookup account allocationByAccount
           , Set.member account unassignedAccounts
           , Map.lookup account budgetKinds
           ) of
        (Just envelope, False, Just RetainedEnvelopeBudgetAccount) ->
          Right (LegacyEnvelope envelope)
        (Nothing, True, Just RetainedUnassignedBudgetAccount) ->
          Right LegacyUnallocated
        (Nothing, False, Just RetainedOpeningBudgetAccount) ->
          Right LegacyOpening
        (Nothing, False, Just RetainedSpentBudgetAccount) ->
          Right LegacySpent
        (_, _, Nothing) -> Left
          (HouseholdEnvelopeEntitlementBudgetKindMissing
            transactionIndex postingIndex)
        _ -> Left
          (HouseholdEnvelopeEntitlementCoordinateMismatch
            transactionIndex postingIndex)

    projectEndpoints transactionIndex movement amount fromEndpoint toEndpoint =
      case (fromEndpoint, toEndpoint) of
        -- Legacy execution mirrors must not become entitlement deallocations or
        -- refunds. Their native owner is Actual consumption / fulfillment.
        (LegacyEnvelope _, LegacySpent) -> Right Nothing
        (LegacySpent, LegacyEnvelope _) -> Right Nothing

        -- If neither side names an Envelope this movement only changes retained
        -- Budget capacity bookkeeping and has no entitlement coordinate.
        (LegacyEnvelope _, _) -> makeTransfer
          (nativeEnvelopeEndpoint fromEndpoint)
          (nativeCounterpart toEndpoint)
        (_, LegacyEnvelope _) -> makeTransfer
          (nativeCounterpart fromEndpoint)
          (nativeEnvelopeEndpoint toEndpoint)
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
            Left err -> Left
              [ HouseholdEnvelopeEntitlementTransferRejected
                  transactionIndex err
              ]

    nativeEnvelopeEndpoint endpoint = case endpoint of
      LegacyEnvelope envelope -> Spendable envelope
      _ -> error "unreachable: nativeEnvelopeEndpoint requires LegacyEnvelope"

    -- All non-spent counterparts of an Envelope allocation are a retained
    -- representation of native Unallocated capacity. LegacySpent is handled by
    -- the execution cases above before this helper is called.
    nativeCounterpart endpoint = case endpoint of
      LegacyEnvelope envelope -> Spendable envelope
      LegacyUnallocated -> Unallocated
      LegacyOpening -> Unallocated
      LegacySpent -> error "unreachable: LegacySpent handled before counterpart"

    allocationByAccount = householdAllocationEnvelopes policy
    unassignedAccounts = householdUnassignedBudgetAccounts policy
    budgetKinds = householdBudgetKindByAccount accountPolicy
