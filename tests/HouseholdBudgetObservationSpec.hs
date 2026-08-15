{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Backing.Identity (mkBackingPoolId)
import HKernel.Backing.Policy
  ( assignEnvelopeBackingPool
  , defineBackingPool
  , mkBackingPolicy
  )
import HKernel.Envelope
  ( Pacing(..)
  , defineEnvelope
  , mkCurrentEnvelopePolicy
  , mkEnvelopeLabel
  )
import HKernel.Envelope.Consumption
  ( consumptionCharges
  , consumptionRefunds
  , envelopeConsumptionFor
  )
import HKernel.Envelope.Entitlement (envelopeEntitlementBalance)
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , ExpenseRouteResolver(..)
  )
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Household.AccountProfile
  ( RetainedBudgetAccountKind(..)
  , mkHouseholdAccountPolicy
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.EnvelopeObservation
  ( deriveHouseholdEnvelopeObservation
  , householdEnvelopeConsumption
  , householdEnvelopeEntitlement
  )
import HKernel.Household.Policy
import HKernel.Money
import HKernel.Period (mkPeriod)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let jpy = mustRight (mkCommodity "JPY")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      observed = fromGregorian 2026 8 10
      foodId = mustRight (mkEnvelopeId "food")
      poolId = mustRight (mkBackingPoolId "cash")
      cash = mustRight (mkAccount "assets:cash")
      income = mustRight (mkAccount "income:pension")
      foodExpense = mustRight (mkAccount "expenses:food")
      opening = mustRight (mkAccount "budget:opening")
      unassigned = mustRight (mkAccount "budget:unassigned")
      spent = mustRight (mkAccount "budget:spent")
      foodAllocation = mustRight (mkAccount "budget:food")
      backingPolicy = mustRight (mkBackingPolicy
        [defineBackingPool poolId [cash]]
        [assignEnvelopeBackingPool foodId poolId])
      envelopePolicy = mustRight (mkCurrentEnvelopePolicy
        [ defineEnvelope foodId (mustRight (mkEnvelopeLabel "Food")) Daily [foodExpense] ]
        backingPolicy)
      policy = mustRight (mkHouseholdPolicy
        (incomeAnchorCyclePolicy income)
        envelopePolicy
        [defineHouseholdEnvelopeCoordinates foodId foodAllocation []]
        [unassigned])
      accountPolicy = mustRight (mkHouseholdAccountPolicy
        []
        [ (opening, RetainedOpeningBudgetAccount)
        , (unassigned, RetainedUnassignedBudgetAccount)
        , (spent, RetainedSpentBudgetAccount)
        , (foodAllocation, RetainedEnvelopeBudgetAccount)
        ]
        [] [] [])
      actual = mustRight (parseActualJournal
        "account assets:cash\n  type: Asset\naccount income:pension\n  type: Income\naccount expenses:food\n  type: Expense\naccount budget:opening\n  type: Budget\naccount budget:unassigned\n  type: Budget\naccount budget:spent\n  type: Budget\naccount budget:food\n  type: Budget\n\n2026-08-03 food\n  expenses:food  40 JPY\n  assets:cash  -40 JPY\n\n2026-08-04 refund\n  expenses:food  -10 JPY\n  assets:cash  10 JPY\n")
      movements =
        [ HouseholdBudgetMovement
            { householdBudgetMovementDate = fromGregorian 2026 8 1
            , householdBudgetMovementMemo = "food entitlement"
            , householdBudgetMovementFrom = unassigned
            , householdBudgetMovementTo = foodAllocation
            , householdBudgetMovementAmount = mkAmount jpy (quantityFromInteger 100)
            }
        ]
      resolver = ExpenseRouteResolver (\_ account ->
        if account == foodExpense then Just (ManagedByEnvelope foodId) else Nothing)
      observation = mustRight (deriveHouseholdEnvelopeObservation
        observed period actual policy accountPolicy resolver movements)
      consumption = householdEnvelopeConsumption observation
      entitlement = householdEnvelopeEntitlement observation

  assertEqual "entitlement comes from allocation movement"
    (one jpy 100) (envelopeEntitlementBalance foodId entitlement)
  assertEqual "charges are native Actual evidence"
    (one jpy 40) (consumptionCharges (envelopeConsumptionFor foodId consumption))
  assertEqual "refunds remain gross native evidence"
    (one jpy 10) (consumptionRefunds (envelopeConsumptionFor foodId consumption))

one :: Commodity -> Integer -> Balance
one commodity value = singletonBalance (mkAmount commodity (quantityFromInteger value))

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    actual:   " ++ show actual)
      exitFailure