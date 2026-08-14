{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Account (Account, mkAccount)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Envelope.Consumption
import HKernel.Envelope.Entitlement
import HKernel.Envelope.EntitlementHistory (mkEnvelopeEntitlementHistory)
import HKernel.Envelope.EntitlementTransfer
import HKernel.Envelope.ExpenseRouting
import HKernel.Envelope.Identity (EnvelopeId, mkEnvelopeId)
import HKernel.Envelope.Remaining
import HKernel.Money
import HKernel.Period (Period, mkPeriod)
import System.Exit (exitFailure)

main :: IO ()
main = do
  remainingLaws
  alignmentLaws

remainingLaws :: IO ()
remainingLaws = do
  let entitlement = entitlementThrough observedDay period
      consumption = consumptionThrough observedDay period
      remaining = mustRight (calculateEnvelopeRemaining entitlement consumption)
      jpy = commodity "JPY"
      food = envelope "food"
      stock = envelope "stock"
      legacy = envelope "legacy"
      temporary = envelope "temporary"
      unused = envelope "unused"

  equal "Remaining keeps the aligned Period"
    period
    (envelopeRemainingPeriod remaining)
  equal "Remaining keeps the aligned observation day"
    observedDay
    (envelopeRemainingObservedThrough remaining)
  equal "Actual net consumption subtracts from entitlement"
    (one jpy 70)
    (envelopeRemainingFor food remaining)
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
    4
    (length (envelopeRemainingEntries remaining))

alignmentLaws :: IO ()
alignmentLaws = do
  let entitlement = entitlementThrough observedDay period
      earlierConsumption = consumptionThrough (day 9) period
      otherPeriod = mustRight
        (mkPeriod (fromGregorian 2026 9 1) (fromGregorian 2026 10 1))
      otherEntitlement = entitlementThrough (fromGregorian 2026 9 1) otherPeriod
      otherConsumption = consumptionThrough (fromGregorian 2026 9 1) otherPeriod

  left "different observation days fail closed"
    (calculateEnvelopeRemaining entitlement earlierConsumption)
  left "different Periods fail closed"
    (calculateEnvelopeRemaining entitlement otherConsumption)
  right "independently derived observations align when coordinates match"
    (calculateEnvelopeRemaining otherEntitlement otherConsumption)

entitlementThrough :: Day -> Period -> EnvelopeEntitlement
entitlementThrough observedThrough selectedPeriod =
  mustRight (observeEnvelopeEntitlement selectedPeriod observedThrough history)
  where
    jpy = commodity "JPY"
    history = mustRight (mkEnvelopeEntitlementHistory
      [ grant selectedPeriod (periodStartDay selectedPeriod) (envelope "food") jpy 100
      , grant selectedPeriod (periodStartDay selectedPeriod) (envelope "stock") jpy 50
      , grant selectedPeriod (periodStartDay selectedPeriod) (envelope "temporary") jpy 20
      , grant selectedPeriod (periodStartDay selectedPeriod) (envelope "unused") jpy 10
      ])

consumptionThrough :: Day -> Period -> EnvelopeConsumption
consumptionThrough observedThrough selectedPeriod =
  mustRight
    (observeEnvelopeConsumption selectedPeriod observedThrough actual routing)
  where
    actual = mustRight (parseActualJournal actualSource)
    routing = mustRight (mkExpenseRoutingHistory
      [ route (day 1) "expenses:food" (ManagedByEnvelope (envelope "food"))
      , route (day 1) "expenses:stock" (ManagedByEnvelope (envelope "stock"))
      , route (day 1) "expenses:legacy" (ManagedByEnvelope (envelope "legacy"))
      , route (day 1) "expenses:temporary" (ManagedByEnvelope (envelope "temporary"))
      , route (day 1) "expenses:unmanaged" NotEnvelopeManaged
      ])

actualSource :: Data.Text.Text
actualSource = Data.Text.unlines
  [ "account assets:cash"
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
  ]

period :: Period
period = mustRight
  (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))

observedDay :: Day
observedDay = day 10

day :: Int -> Day
day = fromGregorian 2026 8

periodStartDay :: Period -> Day
periodStartDay selectedPeriod =
  if selectedPeriod == period
    then fromGregorian 2026 8 1
    else fromGregorian 2026 9 1

account :: Data.Text.Text -> Account
account = mustRight . mkAccount

envelope :: Data.Text.Text -> EnvelopeId
envelope = mustRight . mkEnvelopeId

commodity :: Data.Text.Text -> Commodity
commodity = mustRight . mkCommodity

route :: Day -> Data.Text.Text -> ExpenseRoute -> ExpenseRoutingDecision
route effectiveFrom accountName routeValue = ExpenseRoutingDecision
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
