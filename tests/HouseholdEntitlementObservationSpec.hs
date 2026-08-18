{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Map.Strict as Map
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
  , mkEnvelopeLabel
  )
import HKernel.Envelope.Consumption
  ( consumptionCharges
  , consumptionRefunds
  , envelopeConsumptionFor
  )
import HKernel.Envelope.Entitlement (envelopeEntitlementBalance)
import HKernel.Envelope.EntitlementHistory (mkEnvelopeEntitlementHistory)
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.StockOrigin (StockOrigin(..))
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
import HKernel.Household.EnvelopeObservation
  ( HouseholdEnvelopeChangeError(..)
  , deriveHouseholdEnvelopeObservation
  , envelopeChangeCommitment
  , envelopeChangeConsumptionCharges
  , envelopeChangeConsumptionNet
  , envelopeChangeEntitlement
  , envelopeChangeFulfillmentApplied
  , envelopeChangeFulfillmentNet
  , envelopeChangeHeadroom
  , envelopeChangeRemaining
  , envelopeExplanationCommitment
  , envelopeExplanationConsumptionCharges
  , envelopeExplanationConsumptionNet
  , envelopeExplanationConsumptionRefunds
  , envelopeExplanationEntitlement
  , envelopeExplanationFulfillmentApplied
  , envelopeExplanationFulfillmentNet
  , envelopeExplanationFulfillmentReversed
  , envelopeExplanationHeadroom
  , envelopeExplanationRemaining
  , explainHouseholdEnvelope
  , householdEnvelopeChangeFrom
  , householdEnvelopeChangeLines
  , householdEnvelopeChangeThrough
  , householdEnvelopeConsumption
  , householdEnvelopeEntitlement
  , householdEnvelopeExplanationLines
  , householdEnvelopeHeadroom
  , householdEnvelopeRemaining
  , observeHouseholdEnvelopeChange
  )
import HKernel.Household.Policy
  ( householdEnvelopeOrder
  , incomeAnchorCyclePolicy
  , mkHouseholdPolicy
  )
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
      earlierObserved = fromGregorian 2026 8 7
      observed = fromGregorian 2026 8 10
      foodId = mustRight (mkEnvelopeId "food")
      retiredId = mustRight (mkEnvelopeId "retired-savings")
      poolId = mustRight (mkBackingPoolId "cash")
      cash = mustRight (mkAccount "assets:cash")
      income = mustRight (mkAccount "income:pension")
      foodExpense = mustRight (mkAccount "expenses:food")
      backingPolicy = mustRight (mkBackingPolicy
        [defineBackingPool poolId [cash]]
        [assignEnvelopeBackingPool foodId poolId])
      envelopePolicy = mustRight (mkCurrentEnvelopePolicy
        [defineEnvelope foodId (mustRight (mkEnvelopeLabel "Food")) Daily])
      policy = mustRight (mkHouseholdPolicy
        (incomeAnchorCyclePolicy income)
        envelopePolicy
        backingPolicy)
      declarations = T.unlines
        [ "account assets:cash", "  type: Asset"
        , "account assets:savings", "  type: Asset"
        , "account income:pension", "  type: Income"
        , "account expenses:food", "  type: Expense"
        ]
      actual = mustRight (parseActualJournal
        (declarations <>
          "\n2026-06-20 pre-grant food\n  expenses:food  5 JPY\n  assets:cash  -5 JPY\n" <>
          "\n2026-08-03 food\n  expenses:food  40 JPY\n  assets:cash  -40 JPY\n" <>
          "\n2026-08-04 refund\n  expenses:food  -10 JPY\n  assets:cash  10 JPY\n" <>
          "\n2026-08-08 completed saving\n  ; event-id: save-done\n  ; plan-id: plan-done\n  assets:savings  15 JPY\n  assets:cash  -15 JPY\n"))
      savingsPlanId = mustRight (mkPlanId "plan-save")
      donePlanId = mustRight (mkPlanId "plan-done")
      plans = mustRight (parsePlanJournal
        (declarations <>
          "\n2026-08-08 completed saving\n  ; plan-id: plan-done\n  assets:savings  15 JPY\n  assets:cash  -15 JPY\n" <>
          "\n2026-08-09 save\n  ; plan-id: plan-save\n  assets:savings  20 JPY\n  assets:cash  -20 JPY\n"))
      origins = Map.singleton jpy
        (StockOrigin (fromGregorian 2026 6 15) jpy "June stock origin")
      transfers =
        [ mustRight (mkEnvelopeEntitlementTransfer
            (fromGregorian 2026 7 1)
            Unallocated
            (Spendable foodId)
            (mkAmount jpy (quantityFromInteger 50))
            "First food grant")
        , mustRight (mkEnvelopeEntitlementTransfer
            (fromGregorian 2026 7 5)
            Unallocated
            (Spendable retiredId)
            (mkAmount jpy (quantityFromInteger 30))
            "Historical grant to retired savings Envelope")
        , mustRight (mkEnvelopeEntitlementTransfer
            (fromGregorian 2026 7 20)
            (Spendable foodId)
            Unallocated
            (mkAmount jpy (quantityFromInteger 10))
            "July release")
        , mustRight (mkEnvelopeEntitlementTransfer
            (fromGregorian 2026 8 1)
            Unallocated
            (Spendable foodId)
            (mkAmount jpy (quantityFromInteger 100))
            "food entitlement")
        , mustRight (mkEnvelopeEntitlementTransfer
            (fromGregorian 2026 8 15)
            Unallocated
            (Spendable foodId)
            (mkAmount jpy (quantityFromInteger 20))
            "future grant after observation")
        ]
      entitlementHistory = mustRight
        (mkEnvelopeEntitlementHistory origins transfers)
      expenseRouting = mustRight (mkExpenseRoutingHistoryWithInitial
        [ InitialExpenseRoutingDecision
            foodExpense (ManagedByEnvelope foodId) "food initial route"
        ] [])
      fulfillmentRouting = mustRight (mkFulfillmentRoutingHistory
        [ FulfillmentRoutingDecision
            { fulfillmentRoutingEffectiveFrom = fromGregorian 2026 8 1
            , fulfillmentRoutingPlanId = savingsPlanId
            , fulfillmentRoutingRoute = FulfillsEnvelope foodId
            , fulfillmentRoutingNote = "explicit open savings intent"
            }
        , FulfillmentRoutingDecision
            { fulfillmentRoutingEffectiveFrom = fromGregorian 2026 8 1
            , fulfillmentRoutingPlanId = donePlanId
            , fulfillmentRoutingRoute = FulfillsEnvelope foodId
            , fulfillmentRoutingNote = "explicit completed savings intent"
            }
        ])
      earlierObservation = mustRight (deriveHouseholdEnvelopeObservation
        earlierObserved period actual plans expenseRouting fulfillmentRouting entitlementHistory)
      observation = mustRight (deriveHouseholdEnvelopeObservation
        observed period actual plans expenseRouting fulfillmentRouting entitlementHistory)
      consumption = householdEnvelopeConsumption observation
      entitlement = householdEnvelopeEntitlement observation
      remaining = householdEnvelopeRemaining observation
      headroom = householdEnvelopeHeadroom observation
      envelopeOrder = householdEnvelopeOrder policy
      earlierExplanation = explainHouseholdEnvelope envelopeOrder earlierObservation
      explanation = explainHouseholdEnvelope envelopeOrder observation
      explanationLine = case householdEnvelopeExplanationLines explanation of
        [line] -> line
        _ -> error "expected one current Envelope explanation line"
      earlierExplanationLine = case householdEnvelopeExplanationLines earlierExplanation of
        [line] -> line
        _ -> error "expected one earlier Envelope explanation line"
      reconstructedRemaining =
        envelopeExplanationEntitlement explanationLine
          `subtractBalance` envelopeExplanationConsumptionNet explanationLine
          `subtractBalance` envelopeExplanationFulfillmentNet explanationLine
      reconstructedHeadroom =
        envelopeExplanationRemaining explanationLine
          `subtractBalance` envelopeExplanationCommitment explanationLine
      change = mustRight (observeHouseholdEnvelopeChange earlierExplanation explanation)
      changeLine = case householdEnvelopeChangeLines change of
        [line] -> line
        _ -> error "expected one Envelope change line"
      incompatibleExplanation = explainHouseholdEnvelope
        [foodId, retiredId] observation

  assertEqual "current Envelope order excludes retired stable allocation identity"
    [foodId] envelopeOrder
  assertEqual "entitlement carries pre-period grant and release while cutting off future"
    (one jpy 140) (envelopeEntitlementBalance foodId entitlement)
  assertEqual "source opening makes routed pre-grant Actual part of live stock"
    (one jpy 45) (consumptionCharges (envelopeConsumptionFor foodId consumption))
  assertEqual "refunds remain gross native evidence"
    (one jpy 10) (consumptionRefunds (envelopeConsumptionFor foodId consumption))
  assertEqual "completed Plan fulfillment consumes native Remaining"
    (one jpy 90) (envelopeRemainingFor foodId remaining)
  assertEqual "still-open PlanId-routed Asset transfer reserves native Headroom"
    (one jpy 70) (envelopeHeadroomFor foodId headroom)
  assertEqual "Explain retains gross consumption charges"
    (one jpy 45) (envelopeExplanationConsumptionCharges explanationLine)
  assertEqual "Explain retains gross consumption refunds"
    (one jpy 10) (envelopeExplanationConsumptionRefunds explanationLine)
  assertEqual "Explain retains completed fulfillment application"
    (one jpy 15) (envelopeExplanationFulfillmentApplied explanationLine)
  assertEqual "Explain retains fulfillment reversal coordinate at zero"
    mempty (envelopeExplanationFulfillmentReversed explanationLine)
  assertEqual "Explain Remaining closes exactly from typed evidence"
    (envelopeExplanationRemaining explanationLine) reconstructedRemaining
  assertEqual "Explain Headroom closes exactly from typed evidence"
    (envelopeExplanationHeadroom explanationLine) reconstructedHeadroom
  assertEqual "earlier observation sees both unresolved routed Plans as commitment"
    (one jpy 35) (envelopeExplanationCommitment earlierExplanationLine)
  assertEqual "Change retains explicit observation interval"
    (earlierObserved, observed)
    (householdEnvelopeChangeFrom change, householdEnvelopeChangeThrough change)
  assertEqual "Change sees no Entitlement movement across the interval"
    mempty (envelopeChangeEntitlement changeLine)
  assertEqual "Change sees no additional consumption across the interval"
    mempty (envelopeChangeConsumptionCharges changeLine)
  assertEqual "Change keeps consumption net unchanged"
    mempty (envelopeChangeConsumptionNet changeLine)
  assertEqual "Change sees completed Fulfillment become realized evidence"
    (one jpy 15) (envelopeChangeFulfillmentApplied changeLine)
  assertEqual "Change sees Fulfillment net increase"
    (one jpy 15) (envelopeChangeFulfillmentNet changeLine)
  assertEqual "Change sees Remaining fall by realized Fulfillment"
    (one jpy (-15)) (envelopeChangeRemaining changeLine)
  assertEqual "Change sees resolved commitment leave active intent"
    (one jpy (-15)) (envelopeChangeCommitment changeLine)
  assertEqual "Change preserves unchanged Headroom despite internal transition"
    mempty (envelopeChangeHeadroom changeLine)
  assertBool "Change rejects reversed observation time"
    (case observeHouseholdEnvelopeChange explanation earlierExplanation of
      Left (HouseholdEnvelopeChangeObservationOrderInvalid fromDay throughDay) ->
        fromDay == observed && throughDay == earlierObserved
      _ -> False)
  assertBool "Change rejects different current Envelope coordinates"
    (case observeHouseholdEnvelopeChange earlierExplanation incompatibleExplanation of
      Left (HouseholdEnvelopeChangeEnvelopeOrderMismatch beforeIds afterIds) ->
        beforeIds == [foodId] && afterIds == [foodId, retiredId]
      _ -> False)

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

assertBool :: String -> Bool -> IO ()
assertBool label actual = assertEqual label True actual
