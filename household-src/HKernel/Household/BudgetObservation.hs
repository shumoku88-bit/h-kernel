-- | Stable composition of admitted household Budget movements into one aligned
-- domain observation.
--
-- Stable Household policy is admitted by 'HKernel.Household.Config' and checked
-- against the canonical AccountRegistry before it reaches this module. During
-- Envelope-native migration this owner interprets the same ordered
-- @budget.journal@ evidence twice: legacy Budget Entitlement remains only for
-- compatibility Remaining, while allocation decisions also produce native
-- Envelope Entitlement. Legacy execution mirrors are deliberately excluded from
-- that native history so Actual consumption / fulfillment can own execution.
module HKernel.Household.BudgetObservation
  ( HouseholdBudgetObservation
  , householdBudgetObservationPolicy
  , householdEnvelopeConsumption
  , householdEnvelopeEntitlement
  , householdBudgetEntitlement
  , householdBudgetRemaining
  , HouseholdBudgetError(..)
  , deriveHouseholdBudgetObservation
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
import HKernel.Budget.Policy
  ( AccountValidatedBudgetPolicy
  , accountValidatedBudgetPolicy
  , budgetPolicyEnvelopeForExpense
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
  , EnvelopeEntitlementTransfer
  , EnvelopeEntitlementTransferError
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , ExpenseRouteResolver(..)
  )
import HKernel.Household.AccountProfile
  ( HouseholdAccountPolicy
  , RetainedBudgetAccountKind(..)
  , householdBudgetKindByAccount
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Policy
  ( AccountValidatedHouseholdPolicy
  , HouseholdPolicy
  , accountValidatedHouseholdBudgetPolicy
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
-- Actual Expense ownership is native. Native Entitlement is now derived from
-- canonical allocation decisions side-by-side with the compatibility Budget
-- Entitlement/Remaining surface. This lets the next routing cutover remove the
-- legacy execution mirror without inventing historical allocation dates.
data HouseholdBudgetObservation = HouseholdBudgetObservation
  { householdBudgetObservationPolicy :: HouseholdPolicy
  , householdEnvelopeConsumption     :: EnvelopeConsumption
  , householdEnvelopeEntitlement     :: EnvelopeEntitlement
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

-- | Admitted evidence required by the aligned domain calculations.
data HouseholdBudgetEvidence = HouseholdBudgetEvidence
  { householdBudgetEvidenceObservation      :: BudgetObservation
  , householdBudgetEvidencePeriod           :: Period
  , householdBudgetEvidencePolicy           :: AccountValidatedHouseholdPolicy
  , householdBudgetEvidenceHistory          :: BudgetHistory
  , householdEnvelopeEntitlementHistory     :: EnvelopeEntitlementHistory
  }

data LegacyBudgetEndpoint
  = LegacyEnvelope EnvelopeId
  | LegacyUnallocated
  | LegacyOpening
  | LegacySpent

-- | Derive one aligned point-in-time household budget observation from ordered
-- movement facts and one already validated Household policy/account policy.
deriveHouseholdBudgetObservation
  :: Day
  -> Period
  -> ActualJournal
  -> AccountValidatedHouseholdPolicy
  -> HouseholdAccountPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetObservation
deriveHouseholdBudgetObservation observedThrough period actualJournal policy accountPolicy movements = do
  evidence <- admitHouseholdBudgetEvidence
    observedThrough period policy accountPolicy movements
  calculateHouseholdBudgetObservation actualJournal evidence

admitHouseholdBudgetEvidence
  :: Day
  -> Period
  -> AccountValidatedHouseholdPolicy
  -> HouseholdAccountPolicy
  -> [HouseholdBudgetMovement]
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetEvidence
admitHouseholdBudgetEvidence observedThrough period validatedPolicy accountPolicy movements = do
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
  envelopeHistory <- projectEnvelopeEntitlementHistory
    period policy accountPolicy movements
  Right HouseholdBudgetEvidence
    { householdBudgetEvidenceObservation = observation
    , householdBudgetEvidencePeriod = period
    , householdBudgetEvidencePolicy = validatedPolicy
    , householdBudgetEvidenceHistory = history
    , householdEnvelopeEntitlementHistory = envelopeHistory
    }
  where
    policy = accountValidatedHouseholdPolicy validatedPolicy

calculateHouseholdBudgetObservation
  :: ActualJournal
  -> HouseholdBudgetEvidence
  -> Either (NonEmpty HouseholdBudgetError) HouseholdBudgetObservation
calculateHouseholdBudgetObservation actualJournal evidence = do
  envelopeConsumption <- singleLeft HouseholdEnvelopeConsumptionError
    (observeEnvelopeConsumption period observedThrough actualJournal
      (legacyStaticExpenseRouteResolver validatedBudgetPolicy))
  envelopeEntitlement <- singleLeft HouseholdEnvelopeEntitlementObservationError
    (observeEnvelopeEntitlement
      period observedThrough envelopeEntitlementHistory)
  entitlement <- mapLeft (fmap HouseholdBudgetEntitlementError)
    (calculateBudgetEntitlement observation budgetPolicy history)
  remaining <- mapLeft (fmap HouseholdBudgetRemainingError)
    (calculateBudgetRemainingFromEnvelopeConsumption
      entitlement envelopeConsumption)
  Right HouseholdBudgetObservation
    { householdBudgetObservationPolicy = policy
    , householdEnvelopeConsumption = envelopeConsumption
    , householdEnvelopeEntitlement = envelopeEntitlement
    , householdBudgetEntitlement = entitlement
    , householdBudgetRemaining = remaining
    }
  where
    observation = householdBudgetEvidenceObservation evidence
    period = householdBudgetEvidencePeriod evidence
    observedThrough = budgetObservationObservedThrough observation
    validatedPolicy = householdBudgetEvidencePolicy evidence
    policy = accountValidatedHouseholdPolicy validatedPolicy
    budgetPolicy = householdBudgetPolicy policy
    validatedBudgetPolicy =
      accountValidatedHouseholdBudgetPolicy validatedPolicy
    history = householdBudgetEvidenceHistory evidence
    envelopeEntitlementHistory =
      householdEnvelopeEntitlementHistory evidence

-- | Project the current canonical Budget-Account source into native Envelope
-- entitlement history for one resolved period.
--
-- Only movements that actually touch an Envelope allocation coordinate can
-- become native entitlement. @opening@ and unrelated capacity bookkeeping do
-- not. @Envelope <-> spent@ is explicitly excluded because those rows mirror
-- execution that belongs to Actual consumption / target fulfillment in the
-- native model.
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

-- | Adapt the current static 'BudgetPolicy' into the native Expense route
-- resolver while production historical routing is not connected yet.
--
-- Static compatibility semantics ignore transaction dates and route exclusively
-- through Account-to-Envelope policy membership. 'NotEnvelopeManaged' is never
-- invented; unmapped Expense Accounts remain 'Nothing' (unrouted).
legacyStaticExpenseRouteResolver
  :: AccountValidatedBudgetPolicy
  -> ExpenseRouteResolver
legacyStaticExpenseRouteResolver validatedPolicy =
  ExpenseRouteResolver (\_day account ->
    case budgetPolicyEnvelopeForExpense account policy of
      Just envelope -> Just (ManagedByEnvelope envelope)
      Nothing       -> Nothing)
  where
    policy = accountValidatedBudgetPolicy validatedPolicy

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
