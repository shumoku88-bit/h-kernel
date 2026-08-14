{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Account (Account, mkAccount)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Envelope.Consumption
import HKernel.Envelope.Entitlement
import HKernel.Envelope.EntitlementHistory (mkEnvelopeEntitlementHistory)
import HKernel.Envelope.EntitlementTransfer
import HKernel.Envelope.ExpenseRouting
import HKernel.Envelope.Fulfillment
import HKernel.Envelope.FulfillmentRouting
import HKernel.Envelope.Identity (EnvelopeId, mkEnvelopeId)
import HKernel.Envelope.Remaining
import HKernel.Money
import HKernel.Period (Period, mkPeriod, periodStart)
import HKernel.Plan.Journal (PlanJournal, parsePlanJournal)
import System.Exit (exitFailure)

main :: IO ()
main = do
  remainingLaws
  alignmentLaws

remainingLaws :: IO ()
remainingLaws = do
  let entitlement = entitlementThrough observedDay period
      consumption = consumptionThrough observedDay period
      fulfillment = fulfillmentThrough observedDay period
      remaining = mustRight
        (calculateEnvelopeRemaining entitlement consumption fulfillment)
      jpy = commodity "JPY"
      food = envelope "food"
      stock = envelope "stock"
      savings = envelope "savings"
      legacy = envelope "legacy"
      temporary = envelope "temporary"
      unused = envelope "unused"

  equal "Remaining keeps the aligned Period"
    period
    (envelopeRemainingPeriod remaining)
  equal "Remaining keeps the aligned observation day"
    observedDay
    (envelopeRemainingObservedThrough remaining)
  equal "Actual net Expense consumption subtracts from entitlement"
    (one jpy 70)
    (envelopeRemainingFor food remaining)
  equal "Plan-linked non-Expense target fulfillment also subtracts from entitlement"
    (one jpy 4)
    (envelopeRemainingFor savings remaining)
  equal "overspending remains negative evidence"
    (one jpy (-30))
    (envelopeRemainingFor stock remaining)
  equal "consumption-only historical Envelope remains visible"
    (one jpy (-5))
    (envelopeRemainingFor legacy remaining)
  equal "entitlement-only Envelope remains visible"
    (one jpy 10)
    (envelopeRemainingFor unused remaining)
  equal "exact zero becomes canonical sparse zero"
    emptyBalance
    (envelopeRemainingFor temporary remaining)
  assert "zero coordinate is omitted from sparse entries"
    (all ((/= temporary) . fst) (envelopeRemainingEntries remaining))
  equal "unmanaged and unrouted Actual activity do not invent Envelope coordinates"
    5
    (length (envelopeRemainingEntries remaining))

alignmentLaws :: IO ()
alignmentLaws = do
  let entitlement = entitlementThrough observedDay period
      consumption = consumptionThrough observedDay period
      fulfillment = fulfillmentThrough observedDay period
      earlierConsumption = consumptionThrough (day 9) period
      earlierFulfillment = fulfillmentThrough (day 9) period
      otherPeriod = mustRight
        (mkPeriod (fromGregorian 2026 9 1) (fromGregorian 2026 10 1))
      otherEntitlement = entitlementThrough (fromGregorian 2026 9 1) otherPeriod
      otherConsumption = consumptionThrough (fromGregorian 2026 9 1) otherPeriod
      otherFulfillment = fulfillmentThrough (fromGregorian 2026 9 1) otherPeriod

  left "different Consumption observation day fails closed"
    (calculateEnvelopeRemaining entitlement earlierConsumption fulfillment)
  left "different Fulfillment observation day fails closed"
    (calculateEnvelopeRemaining entitlement consumption earlierFulfillment)
  left "different Periods fail closed"
    (calculateEnvelopeRemaining entitlement otherConsumption otherFulfillment)
  right "independently derived observations align when coordinates match"
    (calculateEnvelopeRemaining
      otherEntitlement
      otherConsumption
      otherFulfillment)

entitlementThrough :: Day -> Period -> EnvelopeEntitlement
entitlementThrough observedThrough selectedPeriod =
  mustRight (observeEnvelopeEntitlement selectedPeriod observedThrough history)
  where
    jpy = commodity "JPY"
    start = periodStart selectedPeriod
    history = mustRight (mkEnvelopeEntitlementHistory
      [ grant selectedPeriod start (envelope "food") jpy 100
      , grant selectedPeriod start (envelope "stock") jpy 50
      , grant selectedPeriod start (envelope "savings") jpy 10
      , grant selectedPeriod start (envelope "temporary") jpy 20
      , grant selectedPeriod start (envelope "unused") jpy 10
      ])

consumptionThrough :: Day -> Period -> EnvelopeConsumption
consumptionThrough observedThrough selectedPeriod =
  mustRight
    (observeEnvelopeConsumption selectedPeriod observedThrough actual expenseRouting)
  where
    actual = mustRight (parseActualJournal actualSource)

fulfillmentThrough :: Day -> Period -> EnvelopeFulfillment
fulfillmentThrough observedThrough selectedPeriod =
  mustRight
    (observeEnvelopeFulfillment
      selectedPeriod
      observedThrough
      savingsPlanJournal
      actual
      fulfillmentRouting)
  where
    actual = mustRight (parseActualJournal actualSource)

savingsPlanJournal :: PlanJournal
savingsPlanJournal = mustRight (parsePlanJournal savingsPlanSource)

expenseRouting :: ExpenseRoutingHistory
expenseRouting = mustRight (mkExpenseRoutingHistory
  [ expenseRoute (day 1) "expenses:food" (ManagedByEnvelope (envelope "food"))
  , expenseRoute (day 1) "expenses:stock" (ManagedByEnvelope (envelope "stock"))
  , expenseRoute (day 1) "expenses:legacy" (ManagedByEnvelope (envelope "legacy"))
  , expenseRoute (day 1) "expenses:temporary" (ManagedByEnvelope (envelope "temporary"))
  , expenseRoute (day 1) "expenses:unmanaged" NotEnvelopeManaged
  ])

fulfillmentRouting :: FulfillmentRoutingHistory
fulfillmentRouting = mustRight (mkFulfillmentRoutingHistory
  [ FulfillmentRoutingDecision
      { fulfillmentRoutingEffectiveFrom = day 1
      , fulfillmentRoutingAccount = account "assets:savings"
      , fulfillmentRoutingRoute = FulfillsEnvelope (envelope "savings")
      , fulfillmentRoutingNote = "test"
      }
  ])

savingsPlanSource :: T.Text
savingsPlanSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account assets:savings"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "2026-08-09 * planned savings target"
  , "  ; plan-id: p-savings"
  , "  assets:cash       -6 JPY"
  , "  assets:savings     6 JPY"
  ]

actualSource :: T.Text
actualSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account assets:savings"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "account expenses:stock"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "account expenses:legacy"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "account expenses:temporary"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "account expenses:unmanaged"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "account expenses:unrouted"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2026-08-02 * food charge"
  , "  assets:cash       -40 JPY"
  , "  expenses:food      40 JPY"
  , ""
  , "2026-08-03 * food refund"
  , "  assets:cash        10 JPY"
  , "  expenses:food     -10 JPY"
  , ""
  , "2026-08-04 * stock overspend"
  , "  assets:cash       -80 JPY"
  , "  expenses:stock     80 JPY"
  , ""
  , "2026-08-05 * retired historical envelope activity"
  , "  assets:cash        -5 JPY"
  , "  expenses:legacy     5 JPY"
  , ""
  , "2026-08-06 * exactly consume temporary"
  , "  assets:cash             -20 JPY"
  , "  expenses:temporary       20 JPY"
  , ""
  , "2026-08-07 * explicit unmanaged"
  , "  assets:cash             -7 JPY"
  , "  expenses:unmanaged       7 JPY"
  , ""
  , "2026-08-08 * missing route attention"
  , "  assets:cash            -8 JPY"
  , "  expenses:unrouted       8 JPY"
  , ""
  , "2026-08-09 * fulfill savings target"
  , "  ; event-id: actual-savings"
  , "  ; plan-id: p-savings"
  , "  assets:cash       -6 JPY"
  , "  assets:savings     6 JPY"
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

grant
  :: Period
  -> Day
  -> EnvelopeId
  -> Commodity
  -> Integer
  -> EnvelopeEntitlementTransfer
grant selectedPeriod effectiveDay target unit quantity =
  mustRight
    (mkEnvelopeEntitlementTransfer
      effectiveDay
      selectedPeriod
      Unallocated
      (Spendable target)
      (mkAmount unit (quantityFromInteger quantity))
      "grant")

one :: Commodity -> Integer -> Balance
one unit quantity = singletonBalance
  (mkAmount unit (quantityFromInteger quantity))

left :: Show value => String -> Either error value -> IO ()
left label result = case result of
  Left _ -> pass label
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

right :: Show error => String -> Either error value -> IO ()
right label result = case result of
  Right _ -> pass label
  Left err -> failTest label ("unexpectedly rejected: " ++ show err)

equal :: (Eq value, Show value) => String -> value -> value -> IO ()
equal label expected actual
  | expected == actual = pass label
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actual)

assert :: String -> Bool -> IO ()
assert label condition
  | condition = pass label
  | otherwise = failTest label "condition was false"

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
