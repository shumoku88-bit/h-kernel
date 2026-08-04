{-# LANGUAGE OverloadedStrings #-}

-- | Stable household Backing projection.
--
-- Backing asks which admitted Asset balances support the household's remaining
-- envelope claims at one observation. Current source admission is outside this
-- module; the calculation receives typed policy, budget results, movements,
-- and open Plan evidence.
module HKernel.Household.Backing
  ( HouseholdBackingPlan(..)
  , EnvelopeBackingLine(..)
  , envelopeLedgerRemaining
  , envelopePostPlanHeadroom
  , EnvelopeBacking(..)
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeBackingSurplus
  , envelopeReconciliationDelta
  , deriveHouseholdBacking
  ) where

import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Account (Account)
import HKernel.Budget (envelopeIdText)
import HKernel.Budget.Consumption
  ( BudgetConsumption
  , budgetConsumptionEnvelopes
  , budgetConsumptionUnassignedExpenses
  , envelopeConsumptionCharges
  , envelopeConsumptionEnvelope
  , envelopeConsumptionRefunds
  , unassignedExpenseAccount
  , unassignedExpenseBalance
  )
import HKernel.Budget.Entitlement
  ( BudgetEntitlement
  , budgetEntitlementEnvelopes
  , envelopeEntitlementBalance
  , envelopeEntitlementEnvelope
  )
import HKernel.Budget.Policy
  ( backingPoolDefinitionAssetAccounts
  , budgetPolicyBackingPoolDefinitions
  )
import HKernel.Budget.Remaining
  ( BudgetRemaining
  , budgetRemainingEnvelopes
  , envelopeRemainingBalance
  , envelopeRemainingEnvelope
  )
import HKernel.Engine (accountBalance, accountBalancesThrough)
import HKernel.Household.BudgetMovement
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdBudgetPolicy
  , householdEnvelopeForPlanDestination
  , householdEnvelopeOrder
  , householdUnassignedBudgetAccounts
  )
import HKernel.Journal (Journal)
import HKernel.Money
import HKernel.Period (Period, periodEndExclusive)
import HKernel.Plan (PositiveAmount, positiveAmountValue)

-- | One open outgoing Plan after lifecycle and period selection. Its amount
-- remains proven positive by the Plan owner.
data HouseholdBackingPlan = HouseholdBackingPlan
  { householdBackingPlanDestination :: Account
  , householdBackingPlanAmount      :: PositiveAmount
  } deriving (Eq, Show)

-- | Evidence for one spendable envelope. The ledger result and the open Plan
-- reserve remain separate so the report can explain post-Plan headroom.
data EnvelopeBackingLine = EnvelopeBackingLine
  { envelopeBackingName        :: Text
  , envelopeEntitlement        :: Balance
  , envelopeActualConsumption  :: Balance
  , envelopeActualRefunds      :: Balance
  , envelopeBudgetRemaining    :: Balance
  , envelopeOpenPlanReserve    :: Balance
  } deriving (Eq, Show)

envelopeLedgerRemaining :: EnvelopeBackingLine -> Balance
envelopeLedgerRemaining = envelopeBudgetRemaining

envelopePostPlanHeadroom :: EnvelopeBackingLine -> Balance
envelopePostPlanHeadroom line =
  envelopeLedgerRemaining line
    `subtractBalance` envelopeOpenPlanReserve line

-- | One point-in-time Backing observation. Funding, envelope claims,
-- unassigned Budget balance, and unassigned Expense evidence are retained as
-- distinct coordinates rather than collapsed into one verdict.
data EnvelopeBacking = EnvelopeBacking
  { envelopeBackingPeriod       :: Period
  , envelopeBackingObservedOn   :: Day
  , envelopeBackingLines        :: [EnvelopeBackingLine]
  , envelopeFundingBalance      :: Balance
  , envelopeLedgerUnassigned    :: Balance
  , envelopeUnassignedExpenses  :: [(Account, Balance)]
  } deriving (Eq, Show)

-- | Signed total of every envelope's ledger remaining. Overspent envelopes
-- remain negative evidence here.
envelopeSignedTotal :: EnvelopeBacking -> Balance
envelopeSignedTotal =
  foldMap envelopeLedgerRemaining . envelopeBackingLines

-- | Funding required to support positive envelope claims. Negative remaining
-- does not cancel another envelope's positive claim.
envelopeBackingRequired :: EnvelopeBacking -> Balance
envelopeBackingRequired =
  foldMap (positiveBalance . envelopeLedgerRemaining)
    . envelopeBackingLines

-- | Funding not required by positive envelope claims. A negative value is a
-- Backing shortfall, retained independently per Commodity.
envelopeBackingSurplus :: EnvelopeBacking -> Balance
envelopeBackingSurplus report =
  envelopeFundingBalance report
    `subtractBalance` envelopeBackingRequired report

-- | Difference after also accounting for the unassigned Budget ledger balance.
-- This is reconciliation evidence, not an instruction to move money.
envelopeReconciliationDelta :: EnvelopeBacking -> Balance
envelopeReconciliationDelta report =
  envelopeBackingSurplus report
    `subtractBalance` envelopeLedgerUnassigned report

-- | Calculate Backing from one admitted Household policy and aligned Budget
-- results produced from that same policy.
deriveHouseholdBacking
  :: Day
  -> Period
  -> Journal
  -> HouseholdPolicy
  -> [HouseholdBudgetMovement]
  -> BudgetEntitlement
  -> BudgetConsumption
  -> BudgetRemaining
  -> [HouseholdBackingPlan]
  -> EnvelopeBacking
deriveHouseholdBacking observation period journal policy movements entitlement consumption remaining plans =
  EnvelopeBacking
    { envelopeBackingPeriod = period
    , envelopeBackingObservedOn = observation
    , envelopeBackingLines = map lineFor envelopes
    , envelopeFundingBalance = accountScopeBalance fundingAssets
    , envelopeLedgerUnassigned = budgetClosing unassignedAccounts
    , envelopeUnassignedExpenses =
        [ (unassignedExpenseAccount entry, unassignedExpenseBalance entry)
        | entry <- budgetConsumptionUnassignedExpenses consumption
        ]
    }
  where
    budgetPolicy = householdBudgetPolicy policy
    fundingAssets = concatMap backingPoolDefinitionAssetAccounts
      (budgetPolicyBackingPoolDefinitions budgetPolicy)
    envelopes = householdEnvelopeOrder policy
    unassignedAccounts = householdUnassignedBudgetAccounts policy
    entitlementByEnvelope = Map.fromList
      [ (envelopeEntitlementEnvelope entry, entry)
      | entry <- budgetEntitlementEnvelopes entitlement
      ]
    consumptionByEnvelope = Map.fromList
      [ (envelopeConsumptionEnvelope entry, entry)
      | entry <- budgetConsumptionEnvelopes consumption
      ]
    remainingByEnvelope = Map.fromList
      [ (envelopeRemainingEnvelope entry, entry)
      | entry <- budgetRemainingEnvelopes remaining
      ]
    lineFor envelope = EnvelopeBackingLine
      { envelopeBackingName = envelopeIdText envelope
      , envelopeEntitlement = maybe mempty
          envelopeEntitlementBalance
          (Map.lookup envelope entitlementByEnvelope)
      , envelopeActualConsumption = maybe mempty
          envelopeConsumptionCharges
          (Map.lookup envelope consumptionByEnvelope)
      , envelopeActualRefunds = maybe mempty
          envelopeConsumptionRefunds
          (Map.lookup envelope consumptionByEnvelope)
      , envelopeBudgetRemaining = maybe mempty
          envelopeRemainingBalance
          (Map.lookup envelope remainingByEnvelope)
      , envelopeOpenPlanReserve = foldMap
          (singletonBalance . positiveAmountValue . householdBackingPlanAmount)
          [ plan
          | plan <- plans
          , householdEnvelopeForPlanDestination
              (householdBackingPlanDestination plan)
              policy == Just envelope
          ]
      }
    budgetClosing selected = foldMap
      (singletonBalance . signedBudgetAmountFor selected)
      [ movement
      | movement <- movements
      , householdBudgetMovementDate movement < periodEndExclusive period
      , Set.member (householdBudgetMovementFrom movement) selected
          || Set.member (householdBudgetMovementTo movement) selected
      ]
    signedBudgetAmountFor selected movement
      | Set.member (householdBudgetMovementTo movement) selected =
          householdBudgetMovementAmount movement
      | otherwise = negateAmount (householdBudgetMovementAmount movement)
    accountScopeBalance selected = foldMap
      (`accountBalance` balances)
      selected
    balances = accountBalancesThrough observation journal

positiveBalance :: Balance -> Balance
positiveBalance = balanceFromAmounts . mapMaybe positiveAmount . balanceEntries
  where
    positiveAmount (commodity, quantity)
      | quantity > zeroQuantity = Just (mkAmount commodity quantity)
      | otherwise = Nothing
