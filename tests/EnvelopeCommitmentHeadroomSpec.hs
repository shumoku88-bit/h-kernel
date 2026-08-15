{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Account (Account, mkAccount)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Envelope.Commitment
import HKernel.Envelope.Consumption (observeEnvelopeConsumption)
import HKernel.Envelope.Entitlement (observeEnvelopeEntitlement)
import HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , mkEnvelopeEntitlementHistory
  )
import HKernel.Envelope.EntitlementTransfer
import HKernel.Envelope.ExpenseRouting
import HKernel.Envelope.Fulfillment
import HKernel.Envelope.FulfillmentRouting
import HKernel.Envelope.Headroom
import HKernel.Envelope.Identity (EnvelopeId, mkEnvelopeId)
import HKernel.Envelope.Remaining (calculateEnvelopeRemaining)
import HKernel.Money
import HKernel.Period (Period, mkPeriod, periodStart)
import HKernel.Plan (PlanId, mkPlanId)
import HKernel.Plan.Completion (PlanCompletionError(..))
import HKernel.Plan.Journal (PlanJournal, parsePlanJournal)
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeCurrentCommitment
  characterizeHistoricalIntent
  rejectUnknownCompletionPlan
  characterizeHeadroom
  rejectHeadroomMisalignment

characterizeCurrentCommitment :: IO ()
characterizeCurrentCommitment = do
  let commitment = commitmentThrough observedDay period actualSource
      jpy = commodity "JPY"
      groceries = envelope "groceries"
      stock = envelope "stock"
      savings = envelope "savings"

  equal "Commitment keeps the selected Period"
    period
    (envelopeCommitmentPeriod commitment)
  equal "Commitment keeps the inclusive observation day"
    observedDay
    (envelopeCommitmentObservedThrough commitment)
  equal "overdue and future-in-period open Expense Plans bind current intent"
    (one jpy 160)
    (envelopeCommitmentFor groceries commitment)
  equal "whole multi-posting Plan Expense coordinates are routed independently"
    (one jpy 20)
    (envelopeCommitmentFor stock commitment)
  equal "explicit non-Expense target Plan also binds its Envelope"
    (one jpy 25)
    (envelopeCommitmentFor savings commitment)
  equal "explicit non-Envelope Plan Expense remains separate evidence"
    (Just (one jpy 7))
    (Map.lookup (account "expenses:unmanaged")
      (envelopeCommitmentUnmanaged commitment))
  equal "missing Expense Plan route remains attention evidence"
    (Just (one jpy 8))
    (Map.lookup (account "expenses:unrouted")
      (envelopeCommitmentUnrouted commitment))
  equal "unrouted Liability destination does not invent an Envelope claim"
    3
    (length (envelopeCommitmentEntries commitment))

characterizeHistoricalIntent :: IO ()
characterizeHistoricalIntent = do
  let commitment = commitmentThrough (day 4) period actualSource
      jpy = commodity "JPY"
      oldFood = envelope "food-old"
      groceries = envelope "groceries"

  equal "future retirement and completion do not rewrite an earlier observation"
    (one jpy 260)
    (envelopeCommitmentFor oldFood commitment)
  equal "open Expense Plan routing follows intent effective at the observation day"
    emptyBalance
    (envelopeCommitmentFor groceries commitment)
  equal "future-in-period target fulfillment Plan already reserves headroom"
    (one jpy 25)
    (envelopeCommitmentFor (envelope "savings") commitment)

rejectUnknownCompletionPlan :: IO ()
rejectUnknownCompletionPlan =
  leftSatisfies
    "cross-source completion of an unknown Plan fails closed"
    (any isUnknown . NonEmpty.toList)
    (observeEnvelopeCommitment
      period
      observedDay
      planJournal
      (mustRight (parseActualJournal unknownCompletionSource))
      expenseRouting
      fulfillmentRouting)
  where
    isUnknown err = case err of
      EnvelopeCommitmentCompletionError
        (UnknownCompletionPlanReference _ _) -> True
      _ -> False

characterizeHeadroom :: IO ()
characterizeHeadroom = do
  let actual = mustRight (parseActualJournal actualSource)
      entitlement = mustRight
        (observeEnvelopeEntitlement period observedDay entitlementHistory)
      consumption = mustRight
        (observeEnvelopeConsumption period observedDay actual (expenseRoutingResolver expenseRouting))
      fulfillment = mustRight
        (observeEnvelopeFulfillment
          period
          observedDay
          planJournal
          actual
          fulfillmentRouting)
      remaining = mustRight
        (calculateEnvelopeRemaining entitlement consumption fulfillment)
      commitment = commitmentThrough observedDay period actualSource
      headroom = mustRight (calculateEnvelopeHeadroom remaining commitment)
      jpy = commodity "JPY"

  equal "Headroom subtracts posted Actual and still-open Expense commitment"
    (one jpy 80)
    (envelopeHeadroomFor (envelope "groceries") headroom)
  equal "multi-posting stock commitment reduces only its routed Envelope"
    (one jpy 80)
    (envelopeHeadroomFor (envelope "stock") headroom)
  equal "target fulfillment Plan reserves non-Expense Envelope headroom"
    (one jpy 25)
    (envelopeHeadroomFor (envelope "savings") headroom)
  equal "unmanaged and unrouted Expense Plan evidence does not invent Headroom coordinates"
    3
    (length (envelopeHeadroomEntries headroom))

rejectHeadroomMisalignment :: IO ()
rejectHeadroomMisalignment = do
  let actual = mustRight (parseActualJournal actualSource)
      entitlement = mustRight
        (observeEnvelopeEntitlement period observedDay entitlementHistory)
      consumption = mustRight
        (observeEnvelopeConsumption period observedDay actual (expenseRoutingResolver expenseRouting))
      fulfillment = mustRight
        (observeEnvelopeFulfillment
          period
          observedDay
          planJournal
          actual
          fulfillmentRouting)
      remaining = mustRight
        (calculateEnvelopeRemaining entitlement consumption fulfillment)
      earlierCommitment = commitmentThrough (day 9) period actualSource
      september = mustRight
        (mkPeriod (fromGregorian 2026 9 1) (fromGregorian 2026 10 1))
      septemberCommitment = commitmentThrough (fromGregorian 2026 9 1) september actualSource

  left "different observation days fail closed"
    (calculateEnvelopeHeadroom remaining earlierCommitment)
  left "different Periods fail closed"
    (calculateEnvelopeHeadroom remaining septemberCommitment)

commitmentThrough :: Day -> Period -> T.Text -> EnvelopeCommitment
commitmentThrough observedThrough selectedPeriod actualText =
  mustRight
    (observeEnvelopeCommitment
      selectedPeriod
      observedThrough
      planJournal
      (mustRight (parseActualJournal actualText))
      expenseRouting
      fulfillmentRouting)

planJournal :: PlanJournal
planJournal = mustRight (parsePlanJournal planSource)

expenseRouting :: ExpenseRoutingHistory
expenseRouting = mustRight (mkExpenseRoutingHistory
  [ expenseRoute (day 1) "expenses:food" (ManagedByEnvelope (envelope "food-old"))
  , expenseRoute (day 6) "expenses:food" (ManagedByEnvelope (envelope "groceries"))
  , expenseRoute (day 1) "expenses:stock" (ManagedByEnvelope (envelope "stock"))
  , expenseRoute (day 1) "expenses:unmanaged" NotEnvelopeManaged
  ])

fulfillmentRouting :: FulfillmentRoutingHistory
fulfillmentRouting = mustRight (mkFulfillmentRoutingHistory
  [ FulfillmentRoutingDecision
      { fulfillmentRoutingEffectiveFrom = day 1
      , fulfillmentRoutingPlanId = planId "p-save"
      , fulfillmentRoutingRoute = FulfillsEnvelope (envelope "savings")
      , fulfillmentRoutingNote = "test"
      }
  ])

entitlementHistory :: EnvelopeEntitlementHistory
entitlementHistory = mustRight (mkEnvelopeEntitlementHistory
  [ grant (envelope "groceries") 300
  , grant (envelope "stock") 100
  , grant (envelope "savings") 50
  ])
  where
    grant target quantity = mustRight
      (mkEnvelopeEntitlementTransfer
        (periodStart period)
        Unallocated
        (Spendable target)
        (mkAmount (commodity "JPY") (quantityFromInteger quantity))
        "grant")

planSource :: T.Text
planSource = declarations <> T.unlines
  [ "2026-07-20 * overdue food"
  , "    ; plan-id: p-overdue"
  , "    assets:cash      -10 JPY"
  , "    expenses:food     10 JPY"
  , ""
  , "2026-08-20 * current food"
  , "    ; plan-id: p-current"
  , "    assets:cash      -20 JPY"
  , "    expenses:food     20 JPY"
  , ""
  , "2026-09-01 * next period"
  , "    ; plan-id: p-next"
  , "    assets:cash      -30 JPY"
  , "    expenses:food     30 JPY"
  , ""
  , "2026-08-15 * cancelled"
  , "    ; plan-id: p-cancelled"
  , "    ; cancelled-on: 2026-08-05"
  , "    assets:cash      -40 JPY"
  , "    expenses:food     40 JPY"
  , ""
  , "2026-08-16 * cancellation not yet effective"
  , "    ; plan-id: p-future-cancel"
  , "    ; cancelled-on: 2026-08-12"
  , "    assets:cash      -50 JPY"
  , "    expenses:food     50 JPY"
  , ""
  , "2026-08-18 * completed before observation"
  , "    ; plan-id: p-completed"
  , "    assets:cash      -60 JPY"
  , "    expenses:food     60 JPY"
  , ""
  , "2026-08-19 * completion after observation"
  , "    ; plan-id: p-future-complete"
  , "    assets:cash      -70 JPY"
  , "    expenses:food     70 JPY"
  , ""
  , "2026-08-25 * split expense"
  , "    ; plan-id: p-split"
  , "    assets:cash      -30 JPY"
  , "    expenses:food     10 JPY"
  , "    expenses:stock    20 JPY"
  , ""
  , "2026-08-24 * save to explicit target"
  , "    ; plan-id: p-save"
  , "    assets:cash       -25 JPY"
  , "    assets:savings     25 JPY"
  , ""
  , "2026-08-26 * liability settlement"
  , "    ; plan-id: p-liability"
  , "    assets:cash        -15 JPY"
  , "    liabilities:card    15 JPY"
  , ""
  , "2026-08-22 * explicit unmanaged"
  , "    ; plan-id: p-unmanaged"
  , "    assets:cash           -7 JPY"
  , "    expenses:unmanaged     7 JPY"
  , ""
  , "2026-08-23 * unrouted attention"
  , "    ; plan-id: p-unrouted"
  , "    assets:cash         -8 JPY"
  , "    expenses:unrouted    8 JPY"
  ]

actualSource :: T.Text
actualSource = actualDeclarations <> T.unlines
  [ "2026-08-08 * complete one plan"
  , "    ; event-id: actual-completed"
  , "    ; plan-id: p-completed"
  , "    assets:cash      -60 JPY"
  , "    expenses:food     60 JPY"
  , ""
  , "2026-08-12 * future completion"
  , "    ; event-id: actual-future"
  , "    ; plan-id: p-future-complete"
  , "    assets:cash      -70 JPY"
  , "    expenses:food     70 JPY"
  ]

unknownCompletionSource :: T.Text
unknownCompletionSource = actualDeclarations <> T.unlines
  [ "2026-08-08 * unknown plan completion"
  , "    ; event-id: actual-unknown"
  , "    ; plan-id: p-unknown"
  , "    assets:cash      -10 JPY"
  , "    expenses:food     10 JPY"
  ]

declarations :: T.Text
declarations = T.unlines
  [ "account assets:cash"
  , "    type: Asset"
  , "    commodity: JPY"
  , ""
  , "account assets:savings"
  , "    type: Asset"
  , "    commodity: JPY"
  , ""
  , "account expenses:food"
  , "    type: Expense"
  , "    commodity: JPY"
  , ""
  , "account expenses:stock"
  , "    type: Expense"
  , "    commodity: JPY"
  , ""
  , "account expenses:unmanaged"
  , "    type: Expense"
  , "    commodity: JPY"
  , ""
  , "account expenses:unrouted"
  , "    type: Expense"
  , "    commodity: JPY"
  , ""
  , "account liabilities:card"
  , "    type: Liability"
  , "    commodity: JPY"
  , ""
  ]

actualDeclarations :: T.Text
actualDeclarations = T.unlines
  [ "account assets:cash"
  , "    type: Asset"
  , "    commodity: JPY"
  , ""
  , "account assets:savings"
  , "    type: Asset"
  , "    commodity: JPY"
  , ""
  , "account expenses:food"
  , "    type: Expense"
  , "    commodity: JPY"
  , ""
  ]

period :: Period
period = mustRight
  (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))

observedDay :: Day
observedDay = day 10

day :: Int -> Day
day = fromGregorian 2026 8

account :: T.Text -> Account
account = mustRight . mkAccount

planId :: T.Text -> PlanId
planId = mustRight . mkPlanId

envelope :: T.Text -> EnvelopeId
envelope = mustRight . mkEnvelopeId

commodity :: T.Text -> Commodity
commodity = mustRight . mkCommodity

expenseRoute :: Day -> T.Text -> ExpenseRoute -> ExpenseRoutingDecision
expenseRoute effectiveFrom accountName routeValue = ExpenseRoutingDecision
  { expenseRoutingEffectiveFrom = effectiveFrom
  , expenseRoutingAccount = account accountName
  , expenseRoutingRoute = routeValue
  , expenseRoutingNote = "test"
  }

one :: Commodity -> Integer -> Balance
one unit quantity = singletonBalance
  (mkAmount unit (quantityFromInteger quantity))

left :: Show value => String -> Either error value -> IO ()
left label result = case result of
  Left _ -> pass label
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

leftSatisfies
  :: Show value
  => String
  -> (error -> Bool)
  -> Either error value
  -> IO ()
leftSatisfies label predicate result = case result of
  Left err
    | predicate err -> pass label
    | otherwise -> failTest label "rejected for the wrong reason"
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

equal :: (Eq value, Show value) => String -> value -> value -> IO ()
equal label expected actual
  | expected == actual = pass label
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actual)

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

pass :: String -> IO ()
pass label = putStrLn ("  [PASS] " ++ label)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
