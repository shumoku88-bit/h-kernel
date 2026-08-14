-- | Stable composition of admitted household Budget movements into one aligned
-- domain observation.
--
-- Stable Household policy is admitted by 'HKernel.Household.Config' and checked
-- against the canonical AccountRegistry before it reaches this module. Expense
-- routing is also admitted by its historical owner and arrives only as semantic
-- query capability; this module no longer reconstructs routing from the current
-- BudgetPolicy. During Envelope-native migration this owner also admits the same
-- ordered @budget.journal@ evidence as native Envelope Entitlement. Legacy
-- execution mirrors are deliberately excluded from that native projection so
-- Actual consumption / fulfillment can own execution without double counting.
module HKernel.Household.BudgetObservation
  ( HouseholdBudgetObservation
  , householdBudgetObservationPolicy
  , householdEnvelopeConsumption
  , householdBudgetEntitlement
  , householdBudgetRemaining
  , HouseholdBudgetError(..)
  , deriveHouseholdBudgetObservation
  , deriveHouseholdEnvelopeEntitlement
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time.Calendar (Day)
import HKernel.Account (Account)
import HKernel.Actual.Journal (ActualJournal)
import HKernel.Budget
  ( BudgetChange
  , BudgetChangeError
  , BudgetCycle
  , BudgetCycleError
  , BudgetObservation
  , BudgetObservationError
  , EnvelopeId
  , budgetCycleContains
  , budgetObservationObservedThrough
  , mkBudgetChange
  , mkBudgetCycle
  , mkBudgetObservation
  )
import HKernel.Budget.Entitlement
  ( BudgetEntitlement
  , EntitlementError
  , calculateBudgetEntitlement
  )
import HKernel.Budget.History
  ( BudgetHistory
  , BudgetHistoryError
  , mkBudgetHistory
  )
import HKernel.Budget.Remaining
  ( BudgetRemaining
  , RemainingError
  , calculateBudgetRemainingFromEnvelopeConsumption
  )
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
import HKernel.Household.AccountProfile
  ( HouseholdAccountPolicy
  , RetainedBudgetAccountKind(..)
  , householdBudgetKindByAccount
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Policy
  ( AccountValidatedHouseholdPolicy
  , HouseholdPolicy
  , accountValidatedHouseholdPolicy
  , householdAllocationEnvelopes
  , householdBudgetPolicy
  , householdUnassignedBudgetAccounts
  )
import HKernel.Money
  ( amountQuantity
  , negateAmount
  , zeroQuantity
  )
import HKernel.Period
  ( Period
  , periodContains
  , periodEndExclusive
  , periodStart
  )

-- | Aligned household budget results and the exact validated policy that
-- produced them.
--
-- Legacy 'BudgetConsumption' is deliberately absent: Actual Expense ownership
-- has migrated to 'EnvelopeConsumption'. Entitlement and Remaining are retained
-- as compatibility surfaces until native entitlement and target fulfillment can
-- cut over together.
data HouseholdBudgetObservation = HouseholdBudgetObservation
  { householdBudgetObservationPolicy :: HouseholdPolicy
  , householdEnvelopeConsumption     :: EnvelopeConsumption
  , householdBudgetEntitlement       :: BudgetEntitlement
  , householdBudgetRemaining         :: BudgetRemaining
  } deriving (Eq, Show)

data HouseholdBudgetError
  = HouseholdBudgetCycleError BudgetCycleError
  | HouseholdBudgetObservationError BudgetObservationError
  | HouseholdEnvelopeConsumptionError EnvelopeConsumptionError
  | HouseholdEnvelopeEntitlementBudgetKindMissing Int Int
  | HouseholdEnvelopeEntitlementCoordinateMismatch Int Int
  | HouseholdEnvelopeEntitlementTransferError
      Int EnvelopeEntitlementTransferError
  | HouseholdEnvelopeEntitlementHistoryError EnvelopeEntitlementHistoryError
  | HouseholdEnvelopeEntitlementObservationError EnvelopeEntitlementError
  | HouseholdBudgetChangeError Day BudgetChangeError
  | HouseholdBudgetHistoryError BudgetHistoryError
  | HouseholdBudgetEntitlementError EntitlementError
  | HouseholdBudgetRemainingError RemainingError
  deriving (Eq, Show)

-- | Admitted evidence required by the aligned compatibility calculations.
data HouseholdBudgetEvidence = HouseholdBudgetEvidence
  { householdBudgetEvidenceObservation :: BudgetObservation
  , householdBudgetEvidencePeriod      :: Period
  , householdBudgetEvidencePolicy      :: AccountValidatedHouseholdPolicy
  , householdBudgetEvidenceHistory     :: BudgetHistory
  }

data LegacyBudgetEndpoint
  = LegacyEnvelope EnvelopeId
  | LegacyUnallocated
  | LegacyOpening
  | LegacySpent

-- | Derive one aligned point-in-time household budget observation from ordered
-- movement facts, one already validated Household policy, and one already
-- admitted historical Expense routing query.
deriveHouseholdBudgetObservation
  :: Day
  -> Period
  -> ActualJournal
  -> AccountValidatedHouseholdPolicy
  -> ExpenseRouteResolver
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetObservation
deriveHouseholdBudgetObservation observedThrough period actualJournal policy routeResolver movements = do
  evidence <- admitHouseholdBudgetEvidence
    observedThrough period policy movements
  calculateHouseholdBudgetObservation actualJournal routeResolver evidence

-- | Admit the current canonical @budget.journal@ movement facts directly into
-- native Envelope entitlement for one resolved period/day.
--
-- Allocation is intentionally narrower than "any movement touching an Envelope
-- Budget Account". Transfers through configured unassigned capacity, direct
-- Envelope-to-Envelope rebalances, and direct opening allocations are genuine
-- entitlement decisions. Legacy @Envelope <-> spent@ rows are execution mirrors
-- and are excluded. Account-kind coordinates are required so an unknown or
-- contradictory Budget endpoint fails closed rather than being guessed.
deriveHouseholdEnvelopeEntitlement
  :: Day
  -> Period
  -> HouseholdPolicy
  -> HouseholdAccountPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdBudgetError) EnvelopeEntitlement
deriveHouseholdEnvelopeEntitlement observedThrough period policy accountPolicy movements = do
  history <- projectEnvelopeEntitlementHistory
    period policy accountPolicy movements
  singleLeft HouseholdEnvelopeEntitlementObservationError
    (observeEnvelopeEntitlement period observedThrough history)

admitHouseholdBudgetEvidence
  :: Day
  -> Period
  -> AccountValidatedHouseholdPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetEvidence
admitHouseholdBudgetEvidence observedThrough period validatedPolicy movements = do
  budgetCycle <- singleLeft HouseholdBudgetCycleError
    (mkBudgetCycle (periodStart period) (periodEndExclusive period))
  observation <- singleLeft HouseholdBudgetObservationError
    (mkBudgetObservation budgetCycle observedThrough)
  changes <- fmap concat
    (traverse
      (budgetChangesForMovement budgetCycle
        (householdAllocationEnvelopes policy))
      movements)
  history <- mapLeft (fmap HouseholdBudgetHistoryError)
    (mkBudgetHistory changes)
  Right HouseholdBudgetEvidence
    { householdBudgetEvidenceObservation = observation
    , householdBudgetEvidencePeriod = period
    , householdBudgetEvidencePolicy = validatedPolicy
    , householdBudgetEvidenceHistory = history
    }
  where
    policy = accountValidatedHouseholdPolicy validatedPolicy

calculateHouseholdBudgetObservation
  :: ActualJournal
  -> ExpenseRouteResolver
  -> HouseholdBudgetEvidence
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetObservation
calculateHouseholdBudgetObservation actualJournal routeResolver evidence = do
  envelopeConsumption <- singleLeft HouseholdEnvelopeConsumptionError
    (observeEnvelopeConsumption
      period observedThrough actualJournal routeResolver)
  entitlement <- mapLeft (fmap HouseholdBudgetEntitlementError)
    (calculateBudgetEntitlement observation budgetPolicy history)
  remaining <- mapLeft (fmap HouseholdBudgetRemainingError)
    (calculateBudgetRemainingFromEnvelopeConsumption
      entitlement envelopeConsumption)
  Right HouseholdBudgetObservation
    { householdBudgetObservationPolicy = policy
    , householdEnvelopeConsumption = envelopeConsumption
    , householdBudgetEntitlement = entitlement
    , householdBudgetRemaining = remaining
    }
  where
    observation = householdBudgetEvidenceObservation evidence
    period = householdBudgetEvidencePeriod evidence
    observedThrough = budgetObservationObservedThrough observation
    policy = accountValidatedHouseholdPolicy
      (householdBudgetEvidencePolicy evidence)
    budgetPolicy = householdBudgetPolicy policy
    history = householdBudgetEvidenceHistory evidence

projectEnvelopeEntitlementHistory
  :: Period
  -> HouseholdPolicy
  -> HouseholdAccountPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdBudgetError) EnvelopeEntitlementHistory
projectEnvelopeEntitlementHistory period policy accountPolicy movements =
  case partitionEithers (zipWith projectMovement [1..] movements) of
    ([], maybeTransfers) ->
      mapLeft (fmap HouseholdEnvelopeEntitlementHistoryError)
        (mkEnvelopeEntitlementHistory
          [transfer | Just transfer <- maybeTransfers])
    (errorGroups, _) -> Left (NonEmpty.fromList (concat errorGroups))
  where
    allocationByAccount = householdAllocationEnvelopes policy
    unassignedAccounts = householdUnassignedBudgetAccounts policy
    budgetKinds = householdBudgetKindByAccount accountPolicy

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
        (LegacyEnvelope _, LegacySpent) -> Right Nothing
        (LegacySpent, LegacyEnvelope _) -> Right Nothing
        (LegacyEnvelope fromEnvelope, LegacyEnvelope toEnvelope) ->
          makeTransfer
            (Spendable fromEnvelope)
            (Spendable toEnvelope)
        (LegacyEnvelope fromEnvelope, _) ->
          makeTransfer (Spendable fromEnvelope) Unallocated
        (_, LegacyEnvelope toEnvelope) ->
          makeTransfer Unallocated (Spendable toEnvelope)
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
              [ HouseholdEnvelopeEntitlementTransferError
                  transactionIndex err
              ]

budgetChangesForMovement
  :: BudgetCycle
  -> Map.Map Account EnvelopeId
  -> HouseholdBudgetMovement
  -> Either (NonEmpty HouseholdBudgetError) [BudgetChange]
budgetChangesForMovement budgetCycle envelopeByAccount movement
  | not (budgetCycleContains budgetCycle day) = Right []
  | otherwise = traverse changeFor touchedEnvelopes
  where
    day = householdBudgetMovementDate movement
    fromAccount = householdBudgetMovementFrom movement
    toAccount = householdBudgetMovementTo movement
    amount = householdBudgetMovementAmount movement
    note = householdBudgetMovementMemo movement
    touchedEnvelopes =
      [ (account, envelope)
      | (account, envelope) <- Map.toAscList envelopeByAccount
      , fromAccount == account || toAccount == account
      ]
    changeFor (account, envelope) =
      singleLeft (HouseholdBudgetChangeError day)
        (mkBudgetChange day budgetCycle envelope (signedAmount account) note)
    signedAmount account
      | toAccount == account = amount
      | otherwise = negateAmount amount

singleLeft
  :: (error -> HouseholdBudgetError)
  -> Either error value
  -> Either (NonEmpty HouseholdBudgetError) value
singleLeft wrap = mapLeft (NonEmpty.singleton . wrap)

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value