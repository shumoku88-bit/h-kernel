{-# LANGUAGE OverloadedStrings #-}

-- | Household composition of native BackingPool arithmetic from admitted
-- Envelope claims, ledger facts, allocation movements, and open funding Plans.
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
import Data.Set (Set)
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
  ( BackingPolicy
  , backingPoolDefinitionAssetAccounts
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
import HKernel.Envelope.Headroom
  ( EnvelopeHeadroom
  , envelopeHeadroomFor
  )
import HKernel.Envelope.Identity (EnvelopeId, envelopeIdText)
import HKernel.Envelope.Remaining
  ( EnvelopeRemaining
  , envelopeRemainingFor
  )
import HKernel.Engine (accountBalance, accountBalancesThrough)
import HKernel.Household.BudgetMovement
import HKernel.Journal (Journal)
import HKernel.Money
import HKernel.Period (Period, periodEndExclusive)
import HKernel.Plan (PositiveAmount, positiveAmountValue)

data HouseholdBackingPlan = HouseholdBackingPlan
  { householdBackingPlanSource :: Account
  , householdBackingPlanAmount :: PositiveAmount
  } deriving (Eq, Show)

-- | Envelope detail for the current observation.
--
-- Remaining and Headroom are native Envelope projections. Backing only presents
-- them beside entitlement/consumption evidence and compares the outstanding
-- claims with real Asset funding.
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

-- | Compose pool-local Backing from native Envelope Remaining/Headroom and an
-- independent BackingPolicy. The retained allocation journal is used only for
-- source-era unallocated reconciliation, not for Envelope claim arithmetic.
deriveHouseholdBacking
  :: Day
  -> Period
  -> Journal
  -> BackingPolicy
  -> [EnvelopeId]
  -> Set Account
  -> [HouseholdBudgetMovement]
  -> EnvelopeEntitlement
  -> EnvelopeConsumption
  -> EnvelopeRemaining
  -> EnvelopeHeadroom
  -> [HouseholdBackingPlan]
  -> Either (NonEmpty BackingPoolError) EnvelopeBacking
deriveHouseholdBacking observation period journal backingPolicy envelopes unassignedAccounts movements entitlement consumption remaining headroom plans = do
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
    poolDefinitions = backingPolicyPoolDefinitions backingPolicy
    envelopeAssignments = backingPolicyEnvelopeAssignments backingPolicy

    lineFor envelope =
      let amounts = envelopeConsumptionFor envelope consumption
          nativeRemaining = envelopeRemainingFor envelope remaining
          nativeHeadroom = envelopeHeadroomFor envelope headroom
      in EnvelopeBackingLine
        { envelopeBackingName = envelopeIdText envelope
        , envelopeEntitlement = envelopeEntitlementBalance envelope entitlement
        , envelopeActualConsumption = consumptionCharges amounts
        , envelopeActualRefunds = consumptionRefunds amounts
        , envelopeLedgerRemaining = nativeRemaining
        , envelopeOpenPlanReserve = nativeRemaining `subtractBalance` nativeHeadroom
        }

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
              , backedEnvelopeRemaining = envelopeRemainingFor envelope remaining
              , backedEnvelopeHeadroom = envelopeHeadroomFor envelope headroom
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
