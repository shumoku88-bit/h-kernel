{-# LANGUAGE OverloadedStrings #-}

-- | Household composition of native BackingPool arithmetic from admitted
-- Envelope, ledger, entitlement-movement, and open Plan facts.
module HKernel.Household.Backing
  ( HouseholdBackingPlan(..)
  , EnvelopeBackingLine(..)
  , envelopeLedgerRemaining
  , envelopePostPlanHeadroom
  , EnvelopeBacking(..)
  , envelopeFundingBalance
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeBackingSurplus
  , envelopeAvailableBackingSurplus
  , envelopeReconciliationDelta
  , deriveHouseholdBacking
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Account (Account)
import HKernel.Backing
  ( BackedEnvelopeClaim(..)
  , BackingPoolError
  , BackingPoolPosition
  , backingPoolAvailableSurplus
  , backingPoolFundingBalance
  , backingPoolGrossEnvelopeRequired
  , backingPoolGrossSurplus
  , deriveBackingPoolPosition
  )
import HKernel.Backing.Policy
  ( backingPoolDefinitionAssetAccounts
  , backingPoolDefinitionId
  , backingPolicyEnvelopeAssignments
  , backingPolicyPoolDefinitions
  , backingPolicyPoolForAsset
  , envelopeBackingAssignmentEnvelope
  , envelopeBackingAssignmentPool
  )
import HKernel.Envelope.Consumption
  ( EnvelopeConsumption
  , consumptionCharges
  , consumptionNet
  , consumptionRefunds
  , envelopeConsumptionFor
  , envelopeConsumptionUnrouted
  )
import HKernel.Envelope.Entitlement
  ( EnvelopeEntitlement
  , envelopeEntitlementBalance
  )
import HKernel.Envelope.Identity (envelopeIdText)
import HKernel.Engine (accountBalance, accountBalancesThrough)
import HKernel.Household.BudgetMovement
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdBackingPolicy
  , householdEnvelopeForPlanDestination
  , householdEnvelopeOrder
  , householdUnassignedBudgetAccounts
  )
import HKernel.Journal (Journal)
import HKernel.Money
import HKernel.Period (Period, periodEndExclusive)
import HKernel.Plan (PositiveAmount, positiveAmountValue)

data HouseholdBackingPlan = HouseholdBackingPlan
  { householdBackingPlanSource      :: Account
  , householdBackingPlanDestination :: Account
  , householdBackingPlanAmount      :: PositiveAmount
  } deriving (Eq, Show)

-- | Envelope detail for the current observation.
--
-- Ledger remaining here is the exact current entitlement minus posted Expense
-- use. Non-Expense target fulfillment remains a separate native Envelope owner
-- until its historical PlanId routing is admitted by the production Household.
data EnvelopeBackingLine = EnvelopeBackingLine
  { envelopeBackingName        :: Text
  , envelopeEntitlement        :: Balance
  , envelopeActualConsumption  :: Balance
  , envelopeActualRefunds      :: Balance
  , envelopeLedgerRemaining    :: Balance
  , envelopeOpenPlanReserve    :: Balance
  } deriving (Eq, Show)

envelopePostPlanHeadroom :: EnvelopeBackingLine -> Balance
envelopePostPlanHeadroom line =
  envelopeLedgerRemaining line `subtractBalance` envelopeOpenPlanReserve line

data EnvelopeBacking = EnvelopeBacking
  { envelopeBackingPeriod       :: Period
  , envelopeBackingObservedOn   :: Day
  , envelopeBackingLines        :: [EnvelopeBackingLine]
  , envelopeBackingPools        :: [BackingPoolPosition]
  , envelopeLedgerUnassigned    :: Balance
  , envelopeUnassignedExpenses  :: [(Account, Balance)]
  } deriving (Eq, Show)

envelopeFundingBalance :: EnvelopeBacking -> Balance
envelopeFundingBalance = foldMap backingPoolFundingBalance . envelopeBackingPools

envelopeSignedTotal :: EnvelopeBacking -> Balance
envelopeSignedTotal = foldMap envelopeLedgerRemaining . envelopeBackingLines

envelopeBackingRequired :: EnvelopeBacking -> Balance
envelopeBackingRequired = foldMap backingPoolGrossEnvelopeRequired . envelopeBackingPools

envelopeBackingSurplus :: EnvelopeBacking -> Balance
envelopeBackingSurplus = foldMap backingPoolGrossSurplus . envelopeBackingPools

envelopeAvailableBackingSurplus :: EnvelopeBacking -> Balance
envelopeAvailableBackingSurplus = foldMap backingPoolAvailableSurplus . envelopeBackingPools

envelopeReconciliationDelta :: EnvelopeBacking -> Balance
envelopeReconciliationDelta report =
  envelopeBackingSurplus report `subtractBalance` envelopeLedgerUnassigned report

-- | Compose pool-local Backing directly from native Envelope entitlement and
-- consumption. There is no intermediate Budget entitlement/remaining model.
deriveHouseholdBacking
  :: Day
  -> Period
  -> Journal
  -> HouseholdPolicy
  -> [HouseholdBudgetMovement]
  -> EnvelopeEntitlement
  -> EnvelopeConsumption
  -> [HouseholdBackingPlan]
  -> Either (NonEmpty BackingPoolError) EnvelopeBacking
deriveHouseholdBacking observation period journal policy movements entitlement consumption plans = do
  pools <- traverse poolFor poolDefinitions
  pure EnvelopeBacking
    { envelopeBackingPeriod = period
    , envelopeBackingObservedOn = observation
    , envelopeBackingLines = map lineFor envelopes
    , envelopeBackingPools = pools
    , envelopeLedgerUnassigned = ledgerClosing unassignedAccounts
    , envelopeUnassignedExpenses =
        [ (account, consumptionNet amounts)
        | (account, amounts) <- Map.toAscList (envelopeConsumptionUnrouted consumption)
        ]
    }
  where
    backingPolicy = householdBackingPolicy policy
    poolDefinitions = backingPolicyPoolDefinitions backingPolicy
    envelopeAssignments = backingPolicyEnvelopeAssignments backingPolicy
    envelopes = householdEnvelopeOrder policy
    unassignedAccounts = householdUnassignedBudgetAccounts policy

    lineFor envelope =
      let amounts = envelopeConsumptionFor envelope consumption
      in EnvelopeBackingLine
        { envelopeBackingName = envelopeIdText envelope
        , envelopeEntitlement = envelopeEntitlementBalance envelope entitlement
        , envelopeActualConsumption = consumptionCharges amounts
        , envelopeActualRefunds = consumptionRefunds amounts
        , envelopeLedgerRemaining = remainingFor envelope
        , envelopeOpenPlanReserve = reserveFor envelope
        }

    remainingFor envelope =
      envelopeEntitlementBalance envelope entitlement
        `subtractBalance` consumptionNet (envelopeConsumptionFor envelope consumption)

    -- Destination-Account commitment remains isolated compatibility evidence.
    -- It is independent from the removed Budget calculation model and can be
    -- replaced by native PlanId commitment routing separately.
    reserveFor envelope = foldMap
      (singletonBalance . positiveAmountValue . householdBackingPlanAmount)
      [ plan
      | plan <- plans
      , householdEnvelopeForPlanDestination
          (householdBackingPlanDestination plan) policy == Just envelope
      ]

    poolFor definition =
      deriveBackingPoolPosition
        poolId
        (accountScopeBalance (backingPoolDefinitionAssetAccounts definition))
        poolCommitment
        claims
      where
        poolId = backingPoolDefinitionId definition
        poolCommitment = foldMap
          (singletonBalance . positiveAmountValue . householdBackingPlanAmount)
          [ plan
          | plan <- plans
          , backingPolicyPoolForAsset
              (householdBackingPlanSource plan) backingPolicy == Just poolId
          ]
        claims =
          [ BackedEnvelopeClaim
              { backedEnvelopeId = envelope
              , backedEnvelopeRemaining = remainingFor envelope
              , backedEnvelopeHeadroom =
                  remainingFor envelope `subtractBalance` reserveFor envelope
              }
          | assignment <- envelopeAssignments
          , envelopeBackingAssignmentPool assignment == poolId
          , let envelope = envelopeBackingAssignmentEnvelope assignment
          ]

    ledgerClosing selected = foldMap
      (singletonBalance . signedLedgerAmountFor selected)
      [ movement
      | movement <- movements
      , householdBudgetMovementDate movement < periodEndExclusive period
      , Set.member (householdBudgetMovementFrom movement) selected
          || Set.member (householdBudgetMovementTo movement) selected
      ]

    signedLedgerAmountFor selected movement
      | Set.member (householdBudgetMovementTo movement) selected =
          householdBudgetMovementAmount movement
      | otherwise = negateAmount (householdBudgetMovementAmount movement)

    accountScopeBalance selected = foldMap (`accountBalance` balances) selected
    balances = accountBalancesThrough observation journal
