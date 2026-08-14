{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (assertEqual, assertTrue, mustRight)
import Data.List (find)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Actual.Journal
  ( actualJournalValue
  , parseActualJournal
  )
import HKernel.Backing.Identity (mkBackingPoolId)
import HKernel.Budget (Pacing(..))
import qualified HKernel.Budget.Policy as Budget
import HKernel.Budget.Remaining
  ( budgetRemainingEnvelopes
  , envelopeRemainingBalance
  , envelopeRemainingEnvelope
  )
import HKernel.Envelope.Consumption
  ( consumptionCharges
  , consumptionNet
  , consumptionRefunds
  , envelopeConsumptionFor
  , envelopeConsumptionUnmanaged
  , envelopeConsumptionUnrouted
  )
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Household.BudgetMovement
  ( householdBudgetMovement
  )
import HKernel.Household.BudgetObservation
  ( deriveHouseholdBudgetObservation
  , householdBudgetRemaining
  , householdEnvelopeConsumption
  )
import HKernel.Household.Policy
  ( defineHouseholdEnvelopeCoordinates
  , incomeAnchorCyclePolicy
  , mkHouseholdPolicy
  , validateHouseholdPolicyAccounts
  )
import HKernel.Journal (journalAccountRegistry)
import HKernel.Money
import HKernel.Period (mkPeriod)

main :: IO ()
main = characterizeNativeConsumptionOwnsHouseholdRemaining

characterizeNativeConsumptionOwnsHouseholdRemaining :: IO ()
characterizeNativeConsumptionOwnsHouseholdRemaining = do
  let jpy = mustRight (mkCommodity "JPY")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      observedThrough = fromGregorian 2026 8 10
      foodId = mustRight (mkEnvelopeId "food")
      operating = mustRight (mkBackingPoolId "operating")
      cash = mustRight (mkAccount "assets:cash")
      income = mustRight (mkAccount "income:salary")
      foodExpense = mustRight (mkAccount "expenses:food")
      unroutedExpense = mustRight (mkAccount "expenses:unrouted")
      unassigned = mustRight (mkAccount "budget:unassigned")
      foodAllocation = mustRight (mkAccount "budget:food")
      foodLabel = mustRight (Budget.mkEnvelopeLabel "Food")
      budgetPolicy = mustRight
        (Budget.mkBudgetPolicy
          [Budget.defineEnvelope
            foodId foodLabel Daily operating [foodExpense]]
          [Budget.defineBackingPool operating [cash]])
      householdPolicy = mustRight
        (mkHouseholdPolicy
          (incomeAnchorCyclePolicy income)
          budgetPolicy
          [defineHouseholdEnvelopeCoordinates foodId foodAllocation []]
          [unassigned])
      actualJournal = mustRight (parseActualJournal actualSource)
      validatedPolicy = mustRight
        (validateHouseholdPolicyAccounts
          (journalAccountRegistry (actualJournalValue actualJournal))
          householdPolicy)
      movements =
        [ householdBudgetMovement
            (fromGregorian 2026 8 1)
            "fund food"
            unassigned
            foodAllocation
            (mkAmount jpy (quantityFromInteger 150))
        ]
      observation = mustRight
        (deriveHouseholdBudgetObservation
          observedThrough period actualJournal validatedPolicy movements)
      consumption = householdEnvelopeConsumption observation
      foodConsumption = envelopeConsumptionFor foodId consumption
      remaining = householdBudgetRemaining observation
      foodRemaining = mustFindRemaining foodId remaining

  assertEqual
    "native managed charge is retained"
    (one jpy 50)
    (consumptionCharges foodConsumption)
  assertEqual
    "native managed refund is retained"
    (one jpy 10)
    (consumptionRefunds foodConsumption)
  assertEqual
    "native managed net is exact"
    (one jpy 40)
    (consumptionNet foodConsumption)
  assertEqual
    "BudgetRemaining compatibility surface subtracts native managed net"
    (one jpy 110)
    (envelopeRemainingBalance foodRemaining)
  assertEqual
    "unrouted Expense stays attention evidence rather than reducing an Envelope"
    (Just (one jpy 20))
    (consumptionNet <$> Map.lookup unroutedExpense
      (envelopeConsumptionUnrouted consumption))
  assertTrue
    "static compatibility routing never invents explicit unmanaged evidence"
    (Map.null (envelopeConsumptionUnmanaged consumption))

actualSource :: T.Text
actualSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "account income:salary"
  , "  type: Income"
  , "account expenses:food"
  , "  type: Expense"
  , "account expenses:unrouted"
  , "  type: Expense"
  , "account budget:unassigned"
  , "  type: Budget"
  , "account budget:food"
  , "  type: Budget"
  , ""
  , "2026-08-01 salary"
  , "  assets:cash  200 JPY"
  , "  income:salary  -200 JPY"
  , ""
  , "2026-08-02 food charge"
  , "  expenses:food  50 JPY"
  , "  assets:cash  -50 JPY"
  , ""
  , "2026-08-03 food refund"
  , "  expenses:food  -10 JPY"
  , "  assets:cash  10 JPY"
  , ""
  , "2026-08-04 unrouted charge"
  , "  expenses:unrouted  20 JPY"
  , "  assets:cash  -20 JPY"
  ]

mustFindRemaining envelope remaining =
  case find ((== envelope) . envelopeRemainingEnvelope)
      (budgetRemainingEnvelopes remaining) of
    Just value -> value
    Nothing -> error "invalid test fixture: expected Envelope remaining"

one :: Commodity -> Integer -> Balance
one commodity value =
  singletonBalance (mkAmount commodity (quantityFromInteger value))
