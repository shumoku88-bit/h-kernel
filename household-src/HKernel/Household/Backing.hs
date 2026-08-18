{-# LANGUAGE OverloadedStrings #-}

-- | Household composition of native BackingPool arithmetic from admitted
-- Envelope claims, ledger facts, and open funding Plans.
module HKernel.Household.Backing
  ( HouseholdBackingPlan(..)
  , HouseholdBackingPlanProjectionError(..)
  , projectHouseholdBackingPlans
  , EnvelopeBackingLine(..)
  , envelopePostPlanHeadroom
  , EnvelopeBacking(..)
  , envelopeFundingBalance
  , envelopeFundingCommitment
  , envelopeAvailableFunding
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeAvailableBackingRequired
  , envelopeBackingSurplus
  , envelopeAvailableBackingSurplus
  , deriveHouseholdBacking
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Account
  ( Account
  , AccountRegistry
  , AccountType(..)
  , accountTypeFor
  )
import HKernel.Backing
  ( BackedEnvelopeClaim(..)
  , BackingPoolError
  , BackingPoolPosition
  , backingPoolAvailableEnvelopeRequired
  , backingPoolAvailableFunding
  , backingPoolAvailableSurplus
  , backingPoolFundingBalance
  , backingPoolFundingCommitment
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
import HKernel.Journal (Journal)
import HKernel.Ledger
  ( postingAccount
  , postingAmount
  , transactionDate
  , transactionPostings
  )
import HKernel.Money
import HKernel.Period (Period, periodEndExclusive)
import HKernel.Plan
  ( PlanId
  , PositiveAmount
  , mkPositiveAmount
  , positiveAmountValue
  )
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , identifiedPlanId
  , identifiedPlanTransaction
  )

data HouseholdBackingPlan = HouseholdBackingPlan
  { householdBackingPlanSource :: Account
  , householdBackingPlanAmount :: PositiveAmount
  } deriving (Eq, Show)

-- | Failure while projecting role-neutral open Plan funding into Backing.
-- The source Plan identity and funding Account are retained without exposing a
-- private amount value in the diagnostic.
data HouseholdBackingPlanProjectionError
  = HouseholdBackingPlanSignNormalizationFailed PlanId Account
  deriving (Eq, Show)

-- | Project every negative Asset posting of every supplied role-neutral open
-- Plan into the independent Backing funding horizon.
--
-- Plan destination semantics never enter this projection. Callers own open Plan
-- lifecycle observation; this owner only interprets source-Asset funding before
-- the current Period boundary.
projectHouseholdBackingPlans
  :: Period
  -> AccountRegistry
  -> [IdentifiedPlanTransaction]
  -> Either (NonEmpty HouseholdBackingPlanProjectionError) [HouseholdBackingPlan]
projectHouseholdBackingPlans period registry = fmap concat . traverse projectPlan
  where
    projectPlan identified
      | transactionDate transaction >= periodEndExclusive period = Right []
      | otherwise = traverse (projectPosting identified) fundingPostings
      where
        transaction = identifiedPlanTransaction identified
        fundingPostings =
          [ posting
          | posting <- NonEmpty.toList (transactionPostings transaction)
          , accountTypeFor (postingAccount posting) registry == Just Asset
          , amountQuantity (postingAmount posting) < zeroQuantity
          ]

    projectPosting identified posting =
      case mkPositiveAmount (negateAmount (postingAmount posting)) of
        Right amount -> Right HouseholdBackingPlan
          { householdBackingPlanSource = postingAccount posting
          , householdBackingPlanAmount = amount
          }
        Left _ -> Left
          ( HouseholdBackingPlanSignNormalizationFailed
              (identifiedPlanId identified)
              (postingAccount posting)
            NonEmpty.:| []
          )

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
  , envelopeUnassignedExpenses  :: [(Account, Balance)]
  } deriving (Eq, Show)

envelopeFundingBalance :: EnvelopeBacking -> Balance
envelopeFundingBalance = foldMap backingPoolFundingBalance . envelopeBackingPools

envelopeFundingCommitment :: EnvelopeBacking -> Balance
envelopeFundingCommitment =
  foldMap backingPoolFundingCommitment . envelopeBackingPools

envelopeAvailableFunding :: EnvelopeBacking -> Balance
envelopeAvailableFunding =
  foldMap backingPoolAvailableFunding . envelopeBackingPools

envelopeSignedTotal :: EnvelopeBacking -> Balance
envelopeSignedTotal = foldMap envelopeLedgerRemaining . envelopeBackingLines

envelopeBackingRequired :: EnvelopeBacking -> Balance
envelopeBackingRequired = foldMap backingPoolGrossEnvelopeRequired . envelopeBackingPools

envelopeAvailableBackingRequired :: EnvelopeBacking -> Balance
envelopeAvailableBackingRequired =
  foldMap backingPoolAvailableEnvelopeRequired . envelopeBackingPools

envelopeBackingSurplus :: EnvelopeBacking -> Balance
envelopeBackingSurplus = foldMap backingPoolGrossSurplus . envelopeBackingPools

envelopeAvailableBackingSurplus :: EnvelopeBacking -> Balance
envelopeAvailableBackingSurplus = foldMap backingPoolAvailableSurplus . envelopeBackingPools

-- | Compose pool-local Backing from native Envelope Remaining/Headroom and an
-- independent BackingPolicy.
deriveHouseholdBacking
  :: Day
  -> Period
  -> Journal
  -> BackingPolicy
  -> [EnvelopeId]
  -> EnvelopeEntitlement
  -> EnvelopeConsumption
  -> EnvelopeRemaining
  -> EnvelopeHeadroom
  -> [HouseholdBackingPlan]
  -> Either (NonEmpty BackingPoolError) EnvelopeBacking
deriveHouseholdBacking observation _period journal backingPolicy envelopes entitlement consumption remaining headroom plans = do
  pools <- traverse poolFor poolDefinitions
  pure EnvelopeBacking
    { envelopeBackingPeriod = _period
    , envelopeBackingObservedOn = observation
    , envelopeBackingLines = map lineFor envelopes
    , envelopeBackingPools = pools
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

    accountScopeBalance selected = foldMap (`accountBalance` balances) selected
    balances = accountBalancesThrough observation journal
