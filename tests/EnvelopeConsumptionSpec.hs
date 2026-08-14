{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Account (Account, mkAccount)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Envelope.Consumption
import HKernel.Envelope.ExpenseRouting
import HKernel.Envelope.Identity (EnvelopeId, mkEnvelopeId)
import HKernel.Money
import HKernel.Period (Period, mkPeriod)
import System.Exit (exitFailure)

main :: IO ()
main = do
  observationBoundary
  consumptionLaws

observationBoundary :: IO ()
observationBoundary = do
  let actual = mustRight (parseActualJournal actualSource)
      routing = routingHistory
  left "observation before Period is rejected"
    (observeEnvelopeConsumption period (fromGregorian 2026 7 31) actual routing)
  left "Period end stays exclusive"
    (observeEnvelopeConsumption period (fromGregorian 2026 9 1) actual routing)

consumptionLaws :: IO ()
consumptionLaws = do
  let actual = mustRight (parseActualJournal actualSource)
      routing = routingHistory
      fixed = envelope "fixed"
      general = envelope "general"
      jpy = commodity "JPY"
      usd = commodity "USD"
      travel = account "expenses:travel"
      newExpense = account "expenses:new"
      beforeReversal = mustRight
        (observeEnvelopeConsumption period (day 6) actual routing)
      observed = mustRight
        (observeEnvelopeConsumption period (day 11) actual routing)
      fixedAmounts = envelopeConsumptionFor fixed observed
      generalAmounts = envelopeConsumptionFor general observed
      unroutedAmounts = Map.lookup newExpense (envelopeConsumptionUnrouted observed)
      unmanagedAmounts = Map.lookup travel (envelopeConsumptionUnmanaged observed)

  equal "original Actual uses route effective on its own date"
    (one jpy 100)
    (consumptionCharges (envelopeConsumptionFor fixed beforeReversal))
  equal "ordinary later charge uses changed route"
    (one jpy 20 <> one usd 3)
    (consumptionCharges (envelopeConsumptionFor general beforeReversal))

  equal "reversal inherits the root Actual route after policy changed"
    (one jpy 200)
    (consumptionCharges fixedAmounts)
  equal "root-routed reversal records positive refund evidence"
    (one jpy 100)
    (consumptionRefunds fixedAmounts)
  equal "reverse-of-reverse restores charge at the original route"
    (one jpy 100)
    (consumptionNet fixedAmounts)

  equal "ordinary negative Expense uses its own date route"
    (one jpy 20 <> one usd 3)
    (consumptionCharges generalAmounts)
  equal "ordinary negative Expense is positive refund evidence"
    (one jpy 10)
    (consumptionRefunds generalAmounts)
  equal "multi-commodity net remains exact"
    (one jpy 10 <> one usd 3)
    (consumptionNet generalAmounts)

  equal "explicit unmanaged activity stays separate"
    (Just (ConsumptionAmounts (one jpy 50) emptyBalance))
    unmanagedAmounts
  equal "unrouted charge/refund activity survives zero net"
    (Just (ConsumptionAmounts (one jpy 30) (one jpy 30)))
    unroutedAmounts
  equal "unrouted zero-net evidence really has zero net"
    (Just emptyBalance)
    (consumptionNet <$> unroutedAmounts)
  assert "non-Expense postings never become consumption"
    (Map.notMember (account "assets:cash") (envelopeConsumptionUnrouted observed))
  equal "untouched Envelope lookup is canonical zero evidence"
    mempty
    (envelopeConsumptionFor (envelope "absent") observed)
  assert "managed entries retain gross zero-net evidence when present"
    (all hasGrossEvidence (map snd (envelopeConsumptionEntries observed)))
  where
    hasGrossEvidence amounts =
      not (isZeroBalance (consumptionCharges amounts)
        && isZeroBalance (consumptionRefunds amounts))

routingHistory :: ExpenseRoutingHistory
routingHistory = mustRight (mkExpenseRoutingHistory
  [ decision (day 5) (account "expenses:wifi")
      (ManagedByEnvelope (envelope "general")) "changed"
  , decision (day 1) (account "expenses:wifi")
      (ManagedByEnvelope (envelope "fixed")) "initial"
  , decision (day 1) (account "expenses:travel")
      NotEnvelopeManaged "outside envelope management"
  ])

actualSource :: T.Text
actualSource = declarations <> T.unlines
  [ "2026-08-02 * original wifi"
  , "  ; event-id: actual-original"
  , "  assets:cash       -100 JPY"
  , "  expenses:wifi      100 JPY"
  , ""
  , "2026-08-06 * later wifi after route change"
  , "  assets:cash        -20 JPY"
  , "  expenses:wifi       20 JPY"
  , ""
  , "2026-08-06 * foreign wifi after route change"
  , "  assets:cash-usd      -3 USD"
  , "  expenses:wifi         3 USD"
  , ""
  , "2026-08-07 * reverse original"
  , "  ; event-id: actual-reversal-1"
  , "  ; reverses: actual-original"
  , "  expenses:wifi     -100 JPY"
  , "  assets:cash        100 JPY"
  , ""
  , "2026-08-08 * reverse the reversal"
  , "  ; event-id: actual-reversal-2"
  , "  ; reverses: actual-reversal-1"
  , "  assets:cash       -100 JPY"
  , "  expenses:wifi      100 JPY"
  , ""
  , "2026-08-09 * ordinary refund after route change"
  , "  assets:cash          10 JPY"
  , "  expenses:wifi       -10 JPY"
  , ""
  , "2026-08-10 * explicit unmanaged travel"
  , "  assets:cash         -50 JPY"
  , "  expenses:travel      50 JPY"
  , ""
  , "2026-08-10 * unrouted charge"
  , "  assets:cash         -30 JPY"
  , "  expenses:new         30 JPY"
  , ""
  , "2026-08-11 * unrouted refund"
  , "  assets:cash          30 JPY"
  , "  expenses:new        -30 JPY"
  , ""
  , "2026-08-11 * asset transfer is not consumption"
  , "  assets:cash         -10 JPY"
  , "  assets:savings       10 JPY"
  , ""
  , "2026-09-01 * outside half-open Period"
  , "  assets:cash         -99 JPY"
  , "  expenses:wifi       99 JPY"
  ]

declarations :: T.Text
declarations = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account assets:cash-usd"
  , "  type: Asset"
  , "  commodity: USD"
  , ""
  , "account assets:savings"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:wifi"
  , "  type: Expense"
  , ""
  , "account expenses:travel"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "account expenses:new"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  ]

period :: Period
period = mustRight
  (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))

day :: Int -> Day
day = fromGregorian 2026 8

account :: T.Text -> Account
account = mustRight . mkAccount

envelope :: T.Text -> EnvelopeId
envelope = mustRight . mkEnvelopeId

commodity :: T.Text -> Commodity
commodity = mustRight . mkCommodity

decision :: Day -> Account -> ExpenseRoute -> T.Text -> ExpenseRoutingDecision
decision effectiveFrom expenseAccount route note = ExpenseRoutingDecision
  { expenseRoutingEffectiveFrom = effectiveFrom
  , expenseRoutingAccount = expenseAccount
  , expenseRoutingRoute = route
  , expenseRoutingNote = note
  }

one :: Commodity -> Integer -> Balance
one unit value = singletonBalance
  (mkAmount unit (quantityFromInteger value))

left :: Show value => String -> Either error value -> IO ()
left label result = case result of
  Left _ -> pass label
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

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
