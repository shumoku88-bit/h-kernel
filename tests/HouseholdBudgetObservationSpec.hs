{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text as T
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
  , mkCurrentExpenseAssignments
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
  , InitialExpenseRoutingDecision(..)
  , mkExpenseRoutingHistoryWithInitial
  )
import HKernel.Envelope.FulfillmentRouting
  ( FulfillmentRoute(..)
  , FulfillmentRoutingDecision(..)
  , mkFulfillmentRoutingHistory
  )
import HKernel.Envelope.Headroom (envelopeHeadroomFor)
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Envelope.Remaining (envelopeRemainingFor)
import HKernel.Household.AccountProfile
  ( RetainedBudgetAccountKind(..)
  , mkHouseholdAccountPolicy
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.EnvelopeObservation
  ( deriveHouseholdEnvelopeObservation
  , householdEnvelopeConsumption
  , householdEnvelopeEntitlement
  , householdEnvelopeHeadroom
  , householdEnvelopeRemaining
  )
import HKernel.Household.Policy
import HKernel.Household.Report (admitPlanJournal, admittedOutgoingPlanValues)
import HKernel.Money
import HKernel.Period (mkPeriod)
import HKernel.Plan (mkPlanId)
import HKernel.Plan.Journal (parsePlanJournal)
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
        [defineEnvelope foodId (mustRight (mkEnvelopeLabel "Food")) Daily])
      currentExpenses = mustRight (mkCurrentExpenseAssignments
        [(foodExpense, foodId)])
      policy = mustRight (mkHouseholdPolicy
        (incomeAnchorCyclePolicy income)
        envelopePolicy
        backingPolicy
        currentExpenses
        [defineHouseholdEnvelopeCoordinates foodId foodAllocation]
        [unassigned])
      accountPolicy = mustRight (mkHouseholdAccountPolicy
        []
        [ (opening, RetainedOpeningBudgetAccount)
        , (unassigned, RetainedUnassignedBudgetAccount)
        , (spent, RetainedSpentBudgetAccount)
        , (foodAllocation, RetainedEnvelopeBudgetAccount)
        ]
        [] [] [])
      declarations = T.unlines
        [ "account assets:cash", "  type: Asset"
        , "account assets:savings", "  type: Asset"
        , "account income:pension", "  type: Income"
        , "account expenses:food", "  type: Expense"
        , "account budget:opening", "  type: Budget"
        , "account budget:unassigned", "  type: Budget"
        , "account budget:spent", "  type: Budget"
        , "account budget:food", "  type: Budget"
        ]
      actual = mustRight (parseActualJournal
        (declarations <> "\n2026-08-03 food\n  expenses:food  40 JPY\n  assets:cash  -40 JPY\n\n2026-08-04 refund\n  expenses:food  -10 JPY\n  assets:cash  10 JPY\n"))
      savingsPlanId = mustRight (mkPlanId "plan-save")
      plans = mustRight (parsePlanJournal
        (declarations <>
          "\n2026-08-09 save\n  ; plan-id: plan-save\n  assets:savings  20 JPY\n  assets:cash  -20 JPY\n"))
      narrowPlans = mustRight (admitPlanJournal plans)
      movements =
        [ HouseholdBudgetMovement
            { householdBudgetMovementDate = fromGregorian 2026 6 15
            , householdBudgetMovementMemo = "June grant"
            , householdBudgetMovementFrom = unassigned
            , householdBudgetMovementTo = foodAllocation
            , householdBudgetMovementAmount = mkAmount jpy (quantityFromInteger 50)
            }
        , HouseholdBudgetMovement
            { householdBudgetMovementDate = fromGregorian 2026 7 20
            , householdBudgetMovementMemo = "July release"
            , householdBudgetMovementFrom = foodAllocation
            , householdBudgetMovementTo = unassigned
            , householdBudgetMovementAmount = mkAmount jpy (quantityFromInteger 10)
            }
        , HouseholdBudgetMovement
            { householdBudgetMovementDate = fromGregorian 2026 7 25
            , householdBudgetMovementMemo = "legacy expense execution"
            , householdBudgetMovementFrom = foodAllocation
            , householdBudgetMovementTo = spent
            , householdBudgetMovementAmount = mkAmount jpy (quantityFromInteger 5)
            }
        , HouseholdBudgetMovement
            { householdBudgetMovementDate = fromGregorian 2026 7 26
            , householdBudgetMovementMemo = "legacy refund execution"
            , householdBudgetMovementFrom = spent
            , householdBudgetMovementTo = foodAllocation
            , householdBudgetMovementAmount = mkAmount jpy (quantityFromInteger 5)
            }
        , HouseholdBudgetMovement
            { householdBudgetMovementDate = fromGregorian 2026 8 1
            , householdBudgetMovementMemo = "food entitlement"
            , householdBudgetMovementFrom = unassigned
            , householdBudgetMovementTo = foodAllocation
            , householdBudgetMovementAmount = mkAmount jpy (quantityFromInteger 100)
            }
        , HouseholdBudgetMovement
            { householdBudgetMovementDate = fromGregorian 2026 8 15
            , householdBudgetMovementMemo = "future grant after observation"
            , householdBudgetMovementFrom = unassigned
            , householdBudgetMovementTo = foodAllocation
            , householdBudgetMovementAmount = mkAmount jpy (quantityFromInteger 20)
            }
        ]
      expenseRouting = mustRight (mkExpenseRoutingHistoryWithInitial
        [ InitialExpenseRoutingDecision
            foodExpense (ManagedByEnvelope foodId) "food initial route"
        ] [])
      fulfillmentRouting = mustRight (mkFulfillmentRoutingHistory
        [ FulfillmentRoutingDecision
            { fulfillmentRoutingEffectiveFrom = fromGregorian 2026 8 1
            , fulfillmentRoutingPlanId = savingsPlanId
            , fulfillmentRoutingRoute = FulfillsEnvelope foodId
            , fulfillmentRoutingNote = "explicit savings intent"
            }
        ])
      observation = mustRight (deriveHouseholdEnvelopeObservation
        observed period actual plans policy accountPolicy
        expenseRouting fulfillmentRouting movements)
      consumption = householdEnvelopeConsumption observation
      entitlement = householdEnvelopeEntitlement observation
      remaining = householdEnvelopeRemaining observation
      headroom = householdEnvelopeHeadroom observation

  assertEqual "role-neutral Plan stays out of narrow outgoing report subset"
    [] (admittedOutgoingPlanValues narrowPlans)
  assertEqual "entitlement carries pre-period grant and release while inverting legacy spent and cutting off future"
    (one jpy 140) (envelopeEntitlementBalance foodId entitlement)
  assertEqual "charges are native Actual evidence"
    (one jpy 40) (consumptionCharges (envelopeConsumptionFor foodId consumption))
  assertEqual "refunds remain gross native evidence"
    (one jpy 10) (consumptionRefunds (envelopeConsumptionFor foodId consumption))
  assertEqual "Remaining is entitlement minus net consumption and fulfillment"
    (one jpy 110) (envelopeRemainingFor foodId remaining)
  assertEqual "PlanId-routed Asset transfer reserves native Headroom"
    (one jpy 90) (envelopeHeadroomFor foodId headroom)

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
