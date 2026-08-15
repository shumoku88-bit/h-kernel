{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Actual.Journal (actualJournalValue, parseActualJournal)
import HKernel.Backing
import HKernel.Backing.Identity
import HKernel.Backing.Policy
  ( assignEnvelopeBackingPool
  , defineBackingPool
  , mkBackingPolicy
  )
import HKernel.Envelope.Commitment (observeEnvelopeCommitment)
import HKernel.Envelope.Consumption
  ( ConsumptionAmounts(ConsumptionAmounts)
  , consumptionCharges
  , consumptionRefunds
  , envelopeConsumptionUnmanaged
  , observeEnvelopeConsumption
  )
import HKernel.Envelope.Entitlement
  ( observeEnvelopeEntitlement )
import HKernel.Envelope.EntitlementHistory (mkEnvelopeEntitlementHistory)
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , InitialExpenseRoutingDecision(..)
  , expenseRoutingResolver
  , mkExpenseRoutingHistoryWithInitial
  )
import HKernel.Envelope.Fulfillment (observeEnvelopeFulfillment)
import HKernel.Envelope.FulfillmentRouting (mkFulfillmentRoutingHistory)
import HKernel.Envelope.Headroom (calculateEnvelopeHeadroom)
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Envelope.Remaining (calculateEnvelopeRemaining)
import HKernel.Household.Backing
import HKernel.Money
import HKernel.Period
import HKernel.Plan (mkPositiveAmount)
import HKernel.Plan.Journal (parsePlanJournal)
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeHouseholdBackingLines
  characterizeHouseholdBackingNativeDerivation

characterizeHouseholdBackingLines :: IO ()
characterizeHouseholdBackingLines = do
  let jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      foodId = mustRight (mkEnvelopeId "food")
      travelId = mustRight (mkEnvelopeId "travel")
      cashPoolId = mustRight (mkBackingPoolId "cash")
      reservePoolId = mustRight (mkBackingPoolId "reserve")
      food = EnvelopeBackingLine
        { envelopeBackingName = "food"
        , envelopeEntitlement = one jpy 150
        , envelopeActualConsumption = one jpy 30
        , envelopeActualRefunds = mempty
        , envelopeLedgerRemaining = one jpy 120 <> one usd (-5)
        , envelopeOpenPlanReserve = one jpy 30
        }
      travel = EnvelopeBackingLine
        { envelopeBackingName = "travel"
        , envelopeEntitlement = one usd 3
        , envelopeActualConsumption = one jpy 20
        , envelopeActualRefunds = mempty
        , envelopeLedgerRemaining = one jpy (-20) <> one usd 3
        , envelopeOpenPlanReserve = mempty
        }
      cashPool = mustRight (deriveBackingPoolPosition
        cashPoolId (one jpy 100) (one jpy 40)
        [ BackedEnvelopeClaim foodId
            (envelopeLedgerRemaining food)
            (envelopePostPlanHeadroom food)
        ])
      reservePool = mustRight (deriveBackingPoolPosition
        reservePoolId (one jpy 150 <> one usd 4) mempty
        [ BackedEnvelopeClaim travelId
            (envelopeLedgerRemaining travel)
            (envelopePostPlanHeadroom travel)
        ])
      report = EnvelopeBacking
        { envelopeBackingPeriod = period
        , envelopeBackingObservedOn = fromGregorian 2026 8 10
        , envelopeBackingLines = [food, travel]
        , envelopeBackingPools = [cashPool, reservePool]
        , envelopeLedgerUnassigned = one jpy 10 <> one usd 1
        , envelopeUnassignedExpenses = []
        }

  assertEqual "signed total preserves exact Envelope evidence"
    (one jpy 100 <> one usd (-2)) (envelopeSignedTotal report)
  assertEqual "funding remains pool-local before aggregation"
    (one jpy 250 <> one usd 4) (envelopeFundingBalance report)
  assertEqual "negative Envelope does not cancel positive required backing"
    (one jpy 120 <> one usd 3) (envelopeBackingRequired report)
  assertEqual "headroom subtracts open Plan reserve"
    (one jpy 90 <> one usd (-5)) (envelopePostPlanHeadroom food)
  assertEqual "pool-local shortage survives another pool surplus"
    (one jpy (-20)) (backingPoolGrossSurplus cashPool)

characterizeHouseholdBackingNativeDerivation :: IO ()
characterizeHouseholdBackingNativeDerivation = do
  let jpy = mustRight (mkCommodity "JPY")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      obsDay = fromGregorian 2026 8 15
      foodId = mustRight (mkEnvelopeId "food")
      travelId = mustRight (mkEnvelopeId "travel")
      cashPoolId = mustRight (mkBackingPoolId "cash")
      reservePoolId = mustRight (mkBackingPoolId "reserve")
      cash = mustRight (mkAccount "assets:cash")
      bank = mustRight (mkAccount "assets:bank")
      income = mustRight (mkAccount "income:salary")
      unassigned = mustRight (mkAccount "budget:unassigned")
      foodAlloc = mustRight (mkAccount "budget:food")
      travelAlloc = mustRight (mkAccount "budget:travel")
      foodExpense = mustRight (mkAccount "expenses:food")
      travelExpense = mustRight (mkAccount "expenses:travel")
      taxExpense = mustRight (mkAccount "expenses:tax")
      unroutedExpense = mustRight (mkAccount "expenses:unrouted")
      backingPolicy = mustRight (mkBackingPolicy
        [ defineBackingPool cashPoolId [cash]
        , defineBackingPool reservePoolId [bank]
        ]
        [ assignEnvelopeBackingPool foodId cashPoolId
        , assignEnvelopeBackingPool travelId reservePoolId
        ])
      declarations =
        [ "account assets:cash", "  type: Asset"
        , "account assets:bank", "  type: Asset"
        , "account income:salary", "  type: Income"
        , "account expenses:food", "  type: Expense"
        , "account expenses:travel", "  type: Expense"
        , "account expenses:tax", "  type: Expense"
        , "account expenses:unrouted", "  type: Expense"
        , "account budget:unassigned", "  type: Budget"
        , "account budget:food", "  type: Budget"
        , "account budget:travel", "  type: Budget"
        ]
      journalSource = T.unlines
        (declarations ++
        [ ""
        , "2026-08-01 salary"
        , "  assets:cash  500 JPY"
        , "  assets:bank  300 JPY"
        , "  income:salary  -800 JPY"
        , ""
        , "2026-08-02 food charge"
        , "  expenses:food  50 JPY"
        , "  assets:cash  -50 JPY"
        , ""
        , "2026-08-03 food refund"
        , "  expenses:food  -10 JPY"
        , "  assets:cash  10 JPY"
        , ""
        , "2026-08-04 tax unmanaged"
        , "  expenses:tax  100 JPY"
        , "  assets:cash  -100 JPY"
        , ""
        , "2026-08-05 unrouted charge"
        , "  expenses:unrouted  20 JPY"
        , "  assets:cash  -20 JPY"
        , ""
        , "2026-08-06 unrouted refund"
        , "  expenses:unrouted  -5 JPY"
        , "  assets:cash  5 JPY"
        ])
      actualJournal = mustRight (parseActualJournal journalSource)
      planJournal = mustRight (parsePlanJournal (T.unlines declarations))
      journal = actualJournalValue actualJournal
      entitlementHistory = mustRight (mkEnvelopeEntitlementHistory
        [ mustRight (mkEnvelopeEntitlementTransfer
            (fromGregorian 2026 8 1) period Unallocated (Spendable foodId)
            (mkAmount jpy (quantityFromInteger 150)) "food entitlement")
        , mustRight (mkEnvelopeEntitlementTransfer
            (fromGregorian 2026 8 1) period Unallocated (Spendable travelId)
            (mkAmount jpy (quantityFromInteger 200)) "travel entitlement")
        ])
      entitlement = mustRight
        (observeEnvelopeEntitlement period obsDay entitlementHistory)
      expenseRouting = mustRight (mkExpenseRoutingHistoryWithInitial
        [ InitialExpenseRoutingDecision foodExpense (ManagedByEnvelope foodId) "food"
        , InitialExpenseRoutingDecision travelExpense (ManagedByEnvelope travelId) "travel"
        , InitialExpenseRoutingDecision taxExpense NotEnvelopeManaged "tax unmanaged"
        ] [])
      consumption = mustRight
        (observeEnvelopeConsumption
          period obsDay actualJournal (expenseRoutingResolver expenseRouting))
      fulfillmentRouting = mustRight (mkFulfillmentRoutingHistory [])
      fulfillment = mustRight
        (observeEnvelopeFulfillment
          period obsDay planJournal actualJournal fulfillmentRouting)
      remaining = mustRight
        (calculateEnvelopeRemaining entitlement consumption fulfillment)
      commitment = mustRight
        (observeEnvelopeCommitment
          period obsDay planJournal actualJournal expenseRouting fulfillmentRouting)
      headroom = mustRight (calculateEnvelopeHeadroom remaining commitment)
      plans =
        [ HouseholdBackingPlan
            { householdBackingPlanSource = cash
            , householdBackingPlanAmount = mustRight
                (mkPositiveAmount (mkAmount jpy (quantityFromInteger 30)))
            }
        ]
      backing = mustRight
        (deriveHouseholdBacking
          obsDay period journal backingPolicy [foodId, travelId]
          (Set.singleton unassigned) [] entitlement consumption remaining headroom plans)

  case envelopeBackingLines backing of
    [foodLine, travelLine] -> do
      assertEqual "managed charge reaches Envelope line"
        (one jpy 50) (envelopeActualConsumption foodLine)
      assertEqual "managed refund remains gross evidence"
        (one jpy 10) (envelopeActualRefunds foodLine)
      assertEqual "food remaining is native entitlement minus net consumption"
        (one jpy 110) (envelopeLedgerRemaining foodLine)
      assertEqual "travel untouched consumption remains zero"
        mempty (envelopeActualConsumption travelLine)
      assertEqual "travel remaining is native entitlement"
        (one jpy 200) (envelopeLedgerRemaining travelLine)
      assertEqual "unrelated funding Plan does not invent Envelope commitment"
        mempty (envelopeOpenPlanReserve foodLine)
    _ -> failTest "native lines" "expected food and travel lines"

  assertEqual "unrouted Expense reaches attention surface"
    [(unroutedExpense, one jpy 15)] (envelopeUnassignedExpenses backing)
  assertEqual "explicit unmanaged Expense does not become unrouted"
    Nothing (lookup taxExpense (envelopeUnassignedExpenses backing))
  assertEqual "explicit unmanaged evidence remains in native consumption"
    (Just (ConsumptionAmounts (one jpy 100) mempty))
    (Map.lookup taxExpense (envelopeConsumptionUnmanaged consumption))

one :: Commodity -> Integer -> Balance
one commodity value =
  singletonBalance (mkAmount commodity (quantityFromInteger value))

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = failTest label
      ("expected: " ++ show expected ++ "\n    actual:   " ++ show actual)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure