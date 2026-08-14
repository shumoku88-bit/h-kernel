{-# LANGUAGE OverloadedStrings #-}

-- | Household composition of native BackingPool arithmetic from already
-- admitted policy, ledger, Budget-compatibility, and open Plan facts.
--
-- The pool-local arithmetic itself is owned by 'HKernel.Backing'. This module
-- resolves current Household policy coordinates and retains the legacy
-- destination-Account Envelope reserve only as a compatibility bridge while the
-- canonical Household migrates to PlanId fulfillment routing.
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

-- | One still-open outgoing Plan inside the current funding horizon.
--
-- Source and destination remain separate evidence. The source Asset may reserve
-- funding in one BackingPool. During the Budget compatibility window only, the
-- destination Account may also feed the old Envelope reserve lookup. Native
-- Envelope commitment does not infer that intent from Account.
data HouseholdBackingPlan = HouseholdBackingPlan
  { householdBackingPlanSource      :: Account
  , householdBackingPlanDestination :: Account
  , householdBackingPlanAmount      :: PositiveAmount
  } deriving (Eq, Show)

-- | Compatibility-facing Envelope detail retained while Household Report still
-- publishes the old Budget observation beside native BackingPool coordinates.
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

-- | One Household Backing observation.
--
-- Pool positions are retained before any Household aggregate is calculated so a
-- shortage in one funding pool cannot disappear merely because another pool has
-- surplus. Aggregate helpers remain compatibility/report summaries only.
data EnvelopeBacking = EnvelopeBacking
  { envelopeBackingPeriod       :: Period
  , envelopeBackingObservedOn   :: Day
  , envelopeBackingLines        :: [EnvelopeBackingLine]
  , envelopeBackingPools        :: [BackingPoolPosition]
  , envelopeLedgerUnassigned    :: Balance
  , envelopeUnassignedExpenses  :: [(Account, Balance)]
  } deriving (Eq, Show)

-- | Summary only. Pool-local adequacy must be read from
-- 'envelopeBackingPools'.
envelopeFundingBalance :: EnvelopeBacking -> Balance
envelopeFundingBalance =
  foldMap backingPoolFundingBalance . envelopeBackingPools

-- | Signed total of every Envelope's ledger remaining. Overspent Envelopes stay
-- negative evidence here.
envelopeSignedTotal :: EnvelopeBacking -> Balance
envelopeSignedTotal =
  foldMap envelopeLedgerRemaining . envelopeBackingLines

-- | Gross positive Envelope claim across all pools. This is a Household summary;
-- it does not erase the retained pool coordinates.
envelopeBackingRequired :: EnvelopeBacking -> Balance
envelopeBackingRequired =
  foldMap backingPoolGrossEnvelopeRequired . envelopeBackingPools

-- | Gross Household Backing surplus. A zero aggregate may still contain a
-- pool-local shortage and surplus, which remain visible in the pool positions.
envelopeBackingSurplus :: EnvelopeBacking -> Balance
envelopeBackingSurplus =
  foldMap backingPoolGrossSurplus . envelopeBackingPools

-- | Household summary after both source-funding and Envelope commitments.
envelopeAvailableBackingSurplus :: EnvelopeBacking -> Balance
envelopeAvailableBackingSurplus =
  foldMap backingPoolAvailableSurplus . envelopeBackingPools

-- | Gross reconciliation against the retained unassigned Budget ledger
-- coordinate. This remains compatibility evidence, not a movement instruction.
envelopeReconciliationDelta :: EnvelopeBacking -> Balance
envelopeReconciliationDelta report =
  envelopeBackingSurplus report
    `subtractBalance` envelopeLedgerUnassigned report

-- | Compose pool-local native Backing from one admitted Household observation.
--
-- Source Asset -> BackingPool uses policy membership. The caller is responsible
-- for selecting still-open Plans inside the funding horizon; overdue open Plans
-- therefore remain commitments until lifecycle/completion evidence releases
-- them.
--
-- Envelope headroom still uses the old destination-Account lookup in this
-- compatibility surface. That lookup is deliberately isolated here and must be
-- removed when canonical Household composition adopts native PlanId Envelope
-- commitment. It is not used to derive funding-pool membership.
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
  -> Either (NonEmpty BackingPoolError) EnvelopeBacking
deriveHouseholdBacking observation period journal policy movements entitlement consumption remaining plans = do
  pools <- traverse poolFor poolDefinitions
  pure EnvelopeBacking
    { envelopeBackingPeriod = period
    , envelopeBackingObservedOn = observation
    , envelopeBackingLines = map lineFor envelopes
    , envelopeBackingPools = pools
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
      , envelopeEntitlement = maybe mempty
          envelopeEntitlementBalance
          (Map.lookup envelope entitlementByEnvelope)
      , envelopeActualConsumption = maybe mempty
          envelopeConsumptionCharges
          (Map.lookup envelope consumptionByEnvelope)
      , envelopeActualRefunds = maybe mempty
          envelopeConsumptionRefunds
          (Map.lookup envelope consumptionByEnvelope)
      , envelopeBudgetRemaining = remainingFor envelope
      , envelopeOpenPlanReserve = reserveFor envelope
      }

    remainingFor envelope = maybe mempty
      envelopeRemainingBalance
      (Map.lookup envelope remainingByEnvelope)

    -- Legacy compatibility only. Native Envelope commitment is PlanId-routed.
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
          , budgetPolicyBackingPoolForAsset
              (householdBackingPlanSource plan) budgetPolicy == Just poolId
          ]
        claims =
          [ BackedEnvelopeClaim
              { backedEnvelopeId = envelope
              , backedEnvelopeRemaining = remainingFor envelope
              , backedEnvelopeHeadroom =
                  remainingFor envelope `subtractBalance` reserveFor envelope
              }
          | definition' <- envelopeDefinitions
          , envelopeDefinitionBackingPool definition' == poolId
          , let envelope = envelopeDefinitionId definition'
          ]

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
      (`accountBalance` balances) selected
    balances = accountBalancesThrough observation journal
