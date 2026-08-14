{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Backing.Identity (mkBackingPoolId)
import HKernel.Budget (Pacing(..))
import qualified HKernel.Budget.Policy as Budget
import HKernel.Envelope.Entitlement
  ( envelopeEntitlementBalance
  , observeEnvelopeEntitlement
  )
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Household.AccountProfile
  ( RetainedBudgetAccountKind(..)
  , mkHouseholdAccountPolicy
  )
import HKernel.Household.BudgetMovement (householdBudgetMovement)
import HKernel.Household.EnvelopeEntitlement
import HKernel.Household.Policy
  ( defineHouseholdEnvelopeCoordinates
  , incomeAnchorCyclePolicy
  , mkHouseholdPolicy
  )
import HKernel.Money
import HKernel.Period (mkPeriod)
import Test.Support (assertEqual, mustRight)

main :: IO ()
main = do
  characterizeAllocationProjection
  characterizeCoordinateMismatchFailsClosed

characterizeAllocationProjection :: IO ()
characterizeAllocationProjection = do
  let jpy = mustRight (mkCommodity "JPY")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      observedThrough = fromGregorian 2026 8 20
      foodId = mustRight (mkEnvelopeId "food")
      travelId = mustRight (mkEnvelopeId "travel")
      poolId = mustRight (mkBackingPoolId "operating")
      income = mustRight (mkAccount "income:salary")
      asset = mustRight (mkAccount "assets:cash")
      opening = mustRight (mkAccount "budget:opening")
      unassigned = mustRight (mkAccount "budget:unassigned")
      spent = mustRight (mkAccount "budget:spent")
      food = mustRight (mkAccount "budget:food")
      travel = mustRight (mkAccount "budget:travel")
      foodLabel = mustRight (Budget.mkEnvelopeLabel "Food")
      travelLabel = mustRight (Budget.mkEnvelopeLabel "Travel")
      budgetPolicy = mustRight
        (Budget.mkBudgetPolicy
          [ Budget.defineEnvelope foodId foodLabel Daily poolId []
          , Budget.defineEnvelope travelId travelLabel Flex poolId []
          ]
          [Budget.defineBackingPool poolId [asset]])
      policy = mustRight
        (mkHouseholdPolicy
          (incomeAnchorCyclePolicy income)
          budgetPolicy
          [ defineHouseholdEnvelopeCoordinates foodId food []
          , defineHouseholdEnvelopeCoordinates travelId travel []
          ]
          [unassigned])
      accountPolicy = mustRight
        (mkHouseholdAccountPolicy
          []
          [ (opening, RetainedOpeningBudgetAccount)
          , (unassigned, RetainedUnassignedBudgetAccount)
          , (spent, RetainedSpentBudgetAccount)
          , (food, RetainedEnvelopeBudgetAccount)
          , (travel, RetainedEnvelopeBudgetAccount)
          ]
          [] [] [])
      movements =
        [ movement jpy (fromGregorian 2026 8 1) opening unassigned 100 "capacity seed"
        , movement jpy (fromGregorian 2026 8 2) unassigned food 60 "allocate food"
        , movement jpy (fromGregorian 2026 8 2) unassigned travel 40 "allocate travel"
        , movement jpy (fromGregorian 2026 8 3) food travel 10 "rebalance"
        , movement jpy (fromGregorian 2026 8 4) food spent 20 "legacy execution"
        , movement jpy (fromGregorian 2026 8 5) spent food 5 "legacy execution reversal"
        , movement jpy (fromGregorian 2026 8 6) food unassigned 5 "release"
        , movement jpy (fromGregorian 2026 8 7) unassigned food (-5) "signed reverse release"
        , movement jpy (fromGregorian 2026 9 2) unassigned food 100 "outside period"
        , movement jpy (fromGregorian 2026 8 8) unassigned food 0 "zero movement"
        ]
      history = mustRight
        (deriveHouseholdEnvelopeEntitlementHistory
          period policy accountPolicy movements)
      entitlement = mustRight
        (observeEnvelopeEntitlement period observedThrough history)

  assertEqual
    "native food entitlement contains allocations/releases but not legacy spent execution"
    (one jpy 40)
    (envelopeEntitlementBalance foodId entitlement)
  assertEqual
    "native travel entitlement contains allocation and envelope rebalance"
    (one jpy 50)
    (envelopeEntitlementBalance travelId entitlement)

characterizeCoordinateMismatchFailsClosed :: IO ()
characterizeCoordinateMismatchFailsClosed = do
  let jpy = mustRight (mkCommodity "JPY")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      foodId = mustRight (mkEnvelopeId "food")
      poolId = mustRight (mkBackingPoolId "operating")
      income = mustRight (mkAccount "income:salary")
      asset = mustRight (mkAccount "assets:cash")
      unassigned = mustRight (mkAccount "budget:unassigned")
      food = mustRight (mkAccount "budget:food")
      orphan = mustRight (mkAccount "budget:orphan")
      foodLabel = mustRight (Budget.mkEnvelopeLabel "Food")
      budgetPolicy = mustRight
        (Budget.mkBudgetPolicy
          [Budget.defineEnvelope foodId foodLabel Daily poolId []]
          [Budget.defineBackingPool poolId [asset]])
      policy = mustRight
        (mkHouseholdPolicy
          (incomeAnchorCyclePolicy income)
          budgetPolicy
          [defineHouseholdEnvelopeCoordinates foodId food []]
          [unassigned])
      accountPolicy = mustRight
        (mkHouseholdAccountPolicy
          []
          [ (unassigned, RetainedUnassignedBudgetAccount)
          , (food, RetainedEnvelopeBudgetAccount)
          , (orphan, RetainedEnvelopeBudgetAccount)
          ]
          [] [] [])
      result = deriveHouseholdEnvelopeEntitlementHistory
        period policy accountPolicy
        [movement jpy (fromGregorian 2026 8 2) unassigned orphan 10 "orphan"]

  assertEqual
    "Budget Envelope kind without Household Envelope coordinate fails closed"
    (Left
      (HouseholdEnvelopeEntitlementCoordinateMismatch 1 2
        :| []))
    result

movement commodity day fromAccount toAccount quantity note =
  householdBudgetMovement
    day note fromAccount toAccount
    (mkAmount commodity (quantityFromInteger quantity))

one :: Commodity -> Integer -> Balance
one commodity value =
  singletonBalance (mkAmount commodity (quantityFromInteger value))
