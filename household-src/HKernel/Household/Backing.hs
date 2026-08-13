{-# LANGUAGE OverloadedStrings #-}

-- | Stable household Backing projection from already admitted facts.
module HKernel.Household.Backing
  ( HouseholdBackingPlan(..)
  , EnvelopeBackingLine(..)
  , envelopeLedgerRemaining
  , envelopePostPlanHeadroom
  , BackingPoolBacking(..)
  , backingPoolAvailableFunding
  , backingPoolGrossSurplus
  , backingPoolAvailableSurplus
  , EnvelopeBacking(..)
  , envelopeFundingBalance
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeBackingSurplus
  , envelopeAvailableBackingSurplus
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
  ( BackingPoolId
  , backingPoolDefinitionAssetAccounts
  , backingPoolDefinitionId
  , budgetPolicyBackingPoolDefinitions
  , budgetPolicyBackingPoolForAsset
  , budgetPolicyEnvelopeDefinitions
  , envelopeDefinitionBackingPool
  , envelopeDefinitionId
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

-- | One open outgoing Plan after lifecycle and funding-horizon selection.
-- Source and destination remain separate because one Plan can create an Asset
-- pool commitment, an Envelope commitment, both, or neither.
data HouseholdBackingPlan = HouseholdBackingPlan
  { householdBackingPlanSource      :: Account
  , householdBackingPlanDestination :: Account
  , householdBackingPlanAmount      :: PositiveAmount
  } deriving (Eq, Show)

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

-- | One BackingPool coordinate at one Household observation.
-- Gross values describe recorded facts; available values additionally apply
-- still-open commitments. A normal envelope payment reduces both sides while a
-- fixed payment outside the spendable Envelope set reduces only funding.
data BackingPoolBacking = BackingPoolBacking
  { backingPoolBackingId                 :: BackingPoolId
  , backingPoolFundingBalance            :: Balance
  , backingPoolOpenPlanCommitment        :: Balance
  , backingPoolGrossEnvelopeRequired     :: Balance
  , backingPoolAvailableEnvelopeRequired :: Balance
  } deriving (Eq, Show)

backingPoolAvailableFunding :: BackingPoolBacking -> Balance
backingPoolAvailableFunding pool =
  backingPoolFundingBalance pool
    `subtractBalance` backingPoolOpenPlanCommitment pool

backingPoolGrossSurplus :: BackingPoolBacking -> Balance
backingPoolGrossSurplus pool =
  backingPoolFundingBalance pool
    `subtractBalance` backingPoolGrossEnvelopeRequired pool

backingPoolAvailableSurplus :: BackingPoolBacking -> Balance
backingPoolAvailableSurplus pool =
  backingPoolAvailableFunding pool
    `subtractBalance` backingPoolAvailableEnvelopeRequired pool

-- | Pool coordinates are preserved before Household summaries are produced.
-- Explicit Budget-ledger unassigned remains a Household-level reconciliation
-- coordinate because current policy does not map it to individual pools.
data EnvelopeBacking = EnvelopeBacking
  { envelopeBackingPeriod       :: Period
  , envelopeBackingObservedOn   :: Day
  , envelopeBackingLines        :: [EnvelopeBackingLine]
  , envelopeBackingPools        :: [BackingPoolBacking]
  , envelopeLedgerUnassigned    :: Balance
  , envelopeUnassignedExpenses  :: [(Account, Balance)]
  } deriving (Eq, Show)

-- | Summary only. Pool-local adequacy must not be inferred from this aggregate.
envelopeFundingBalance :: EnvelopeBacking -> Balance
envelopeFundingBalance = foldMap backingPoolFundingBalance . envelopeBackingPools

envelopeSignedTotal :: EnvelopeBacking -> Balance
envelopeSignedTotal = foldMap envelopeLedgerRemaining . envelopeBackingLines

envelopeBackingRequired :: EnvelopeBacking -> Balance
envelopeBackingRequired =
  foldMap backingPoolGrossEnvelopeRequired . envelopeBackingPools

-- | Gross reconciliation keeps future commitments separate from recorded
-- Budget-ledger evidence.
envelopeBackingSurplus :: EnvelopeBacking -> Balance
envelopeBackingSurplus = foldMap backingPoolGrossSurplus . envelopeBackingPools

-- | Planning headroom after both pool and envelope commitments.
envelopeAvailableBackingSurplus :: EnvelopeBacking -> Balance
envelopeAvailableBackingSurplus =
  foldMap backingPoolAvailableSurplus . envelopeBackingPools

envelopeReconciliationDelta :: EnvelopeBacking -> Balance
envelopeReconciliationDelta report =
  envelopeBackingSurplus report
    `subtractBalance` envelopeLedgerUnassigned report

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
    , envelopeBackingPools = map poolFor poolDefinitions
    , envelopeLedgerUnassigned = budgetClosing unassignedAccounts
    , envelopeUnassignedExpenses =
        [ (unassignedExpenseAccount entry, unassignedExpenseBalance entry)
        | entry <- budgetConsumptionUnassignedExpenses consumption
        ]
    }
  where
    budgetPolicy = householdBudgetPolicy policy
    poolDefinitions = budgetPolicyBackingPoolDefinitions budgetPolicy
    envelopeDefinitions = budgetPolicyEnvelopeDefinitions budgetPolicy
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
      , envelopeEntitlement = maybe mempty envelopeEntitlementBalance
          (Map.lookup envelope entitlementByEnvelope)
      , envelopeActualConsumption = maybe mempty envelopeConsumptionCharges
          (Map.lookup envelope consumptionByEnvelope)
      , envelopeActualRefunds = maybe mempty envelopeConsumptionRefunds
          (Map.lookup envelope consumptionByEnvelope)
      , envelopeBudgetRemaining = remainingFor envelope
      , envelopeOpenPlanReserve = reserveFor envelope
      }

    remainingFor envelope = maybe mempty envelopeRemainingBalance
      (Map.lookup envelope remainingByEnvelope)

    reserveFor envelope = foldMap
      (singletonBalance . positiveAmountValue . householdBackingPlanAmount)
      [ plan
      | plan <- plans
      , householdEnvelopeForPlanDestination
          (householdBackingPlanDestination plan) policy == Just envelope
      ]

    poolFor definition = BackingPoolBacking
      { backingPoolBackingId = poolId
      , backingPoolFundingBalance = accountScopeBalance
          (backingPoolDefinitionAssetAccounts definition)
      , backingPoolOpenPlanCommitment = foldMap
          (singletonBalance . positiveAmountValue . householdBackingPlanAmount)
          [ plan
          | plan <- plans
          , budgetPolicyBackingPoolForAsset
              (householdBackingPlanSource plan) budgetPolicy == Just poolId
          ]
      , backingPoolGrossEnvelopeRequired = foldMap
          (positiveBalance . remainingFor) poolEnvelopes
      , backingPoolAvailableEnvelopeRequired = foldMap
          (positiveBalance . availableFor) poolEnvelopes
      }
      where
        poolId = backingPoolDefinitionId definition
        poolEnvelopes =
          [ envelopeDefinitionId envelopeDefinition
          | envelopeDefinition <- envelopeDefinitions
          , envelopeDefinitionBackingPool envelopeDefinition == poolId
          ]
        availableFor envelope =
          remainingFor envelope `subtractBalance` reserveFor envelope

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
    accountScopeBalance selected = foldMap (`accountBalance` balances) selected
    balances = accountBalancesThrough observation journal

positiveBalance :: Balance -> Balance
positiveBalance = balanceFromAmounts . mapMaybe positiveAmount . balanceEntries
  where
    positiveAmount (commodity, quantity)
      | quantity > zeroQuantity = Just (mkAmount commodity quantity)
      | otherwise = Nothing
