{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Account (Account, mkAccount)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Envelope.Fulfillment
import HKernel.Envelope.FulfillmentRouting
import HKernel.Envelope.Identity (EnvelopeId, mkEnvelopeId)
import HKernel.Money
import HKernel.Period (Period, mkPeriod)
import System.Exit (exitFailure)

main :: IO ()
main = do
  fulfillmentLaws
  historicalRoutingLaw
  routingAdmissionLaw
  observationLaw

fulfillmentLaws :: IO ()
fulfillmentLaws = do
  let fulfillment = fulfillmentThrough observedDay
      jpy = commodity "JPY"
      oldSavings = envelope "savings-old"
      newSavings = envelope "savings-new"
      investing = envelope "investing"
      oldAmounts = envelopeFulfillmentFor oldSavings fulfillment

  equal "positive non-Expense target movement fulfills the historical Envelope"
    (one jpy 100)
    (fulfillmentNet oldAmounts)
  equal "gross evidence keeps root application and reverse-of-reverse restoration"
    (one jpy 200)
    (fulfillmentApplied oldAmounts)
  equal "typed reversal of the original fulfillment is kept separately"
    (one jpy 100)
    (fulfillmentReversed oldAmounts)
  equal "ordinary withdrawal and its reversal do not manufacture fulfillment"
    (one jpy 100)
    (fulfillmentNet oldAmounts)
  equal "a later positive target movement follows the route effective on its own day"
    (one jpy 30)
    (fulfillmentNet (envelopeFulfillmentFor newSavings fulfillment))
  equal "another explicit target can fulfill another Envelope"
    (one jpy 40)
    (fulfillmentNet (envelopeFulfillmentFor investing fulfillment))
  equal "Expense postings remain owned by Expense Consumption even if mis-routed here"
    emptyBalance
    (fulfillmentNet (envelopeFulfillmentFor (envelope "should-not-count") fulfillment))

historicalRoutingLaw :: IO ()
  = do
      let fulfillment = fulfillmentThrough (day 5)
          jpy = commodity "JPY"
      equal "future route changes do not rewrite earlier target fulfillment"
        (one jpy 100)
        (fulfillmentNet (envelopeFulfillmentFor (envelope "savings-old") fulfillment))
      equal "future target route is absent from the earlier observation"
        emptyBalance
        (fulfillmentNet (envelopeFulfillmentFor (envelope "savings-new") fulfillment))

routingAdmissionLaw :: IO () = do
  let duplicate =
        [ decision (day 1) "assets:savings" (FulfillsEnvelope (envelope "a"))
        , decision (day 1) "assets:savings" (FulfillsEnvelope (envelope "b"))
        ]
  leftSatisfies
    "two target-routing decisions on one Account/day fail closed"
    (any isDuplicate . NonEmpty.toList)
    (mkFulfillmentRoutingHistory duplicate)
  where
    isDuplicate err = case err of
      DuplicateFulfillmentRoutingDecision accountName effectiveFrom ->
        accountName == account "assets:savings" && effectiveFrom == day 1

observationLaw :: IO () =
  left "observation outside the selected Period fails closed"
    (observeEnvelopeFulfillment
      period
      (fromGregorian 2026 9 1)
      actual
      routing)

fulfillmentThrough :: Day -> EnvelopeFulfillment
fulfillmentThrough observedThrough =
  mustRight (observeEnvelopeFulfillment period observedThrough actual routing)

actual = mustRight (parseActualJournal actualSource)

routing :: FulfillmentRoutingHistory
routing = mustRight (mkFulfillmentRoutingHistory
  [ decision (day 1) "assets:savings" (FulfillsEnvelope (envelope "savings-old"))
  , decision (day 6) "assets:savings" (FulfillsEnvelope (envelope "savings-new"))
  , decision (day 1) "assets:investment" (FulfillsEnvelope (envelope "investing"))
  , decision (day 1) "expenses:fee" (FulfillsEnvelope (envelope "should-not-count"))
  ])

actualSource :: T.Text
actualSource = declarations <> T.unlines
  [ "2026-08-02 * save"
  , "  ; event-id: save-original"
  , "  assets:savings     100 JPY"
  , "  assets:cash       -100 JPY"
  , ""
  , "2026-08-03 * ordinary withdrawal"
  , "  ; event-id: withdrawal-original"
  , "  assets:savings     -20 JPY"
  , "  assets:cash         20 JPY"
  , ""
  , "2026-08-04 * reverse ordinary withdrawal"
  , "  ; event-id: withdrawal-reversal"
  , "  ; reverses: withdrawal-original"
  , "  assets:savings      20 JPY"
  , "  assets:cash        -20 JPY"
  , ""
  , "2026-08-07 * reverse original saving after route change"
  , "  ; event-id: save-reversal"
  , "  ; reverses: save-original"
  , "  assets:savings    -100 JPY"
  , "  assets:cash        100 JPY"
  , ""
  , "2026-08-08 * restore original saving"
  , "  ; event-id: save-restored"
  , "  ; reverses: save-reversal"
  , "  assets:savings     100 JPY"
  , "  assets:cash       -100 JPY"
  , ""
  , "2026-08-09 * new saving under new intent"
  , "  assets:savings      30 JPY"
  , "  assets:cash        -30 JPY"
  , ""
  , "2026-08-10 * invest"
  , "  assets:investment    40 JPY"
  , "  assets:cash         -40 JPY"
  , ""
  , "2026-08-10 * ordinary expense remains Consumption-owned"
  , "  expenses:fee          5 JPY"
  , "  assets:cash           -5 JPY"
  ]

declarations :: T.Text
declarations = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account assets:savings"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account assets:investment"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:fee"
  , "  type: Expense"
  , "  commodity: JPY"
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

envelope :: T.Text -> EnvelopeId
envelope = mustRight . mkEnvelopeId

commodity :: T.Text -> Commodity
commodity = mustRight . mkCommodity

decision :: Day -> T.Text -> FulfillmentRoute -> FulfillmentRoutingDecision
decision effectiveFrom accountName routeValue = FulfillmentRoutingDecision
  { fulfillmentRoutingEffectiveFrom = effectiveFrom
  , fulfillmentRoutingAccount = account accountName
  , fulfillmentRoutingRoute = routeValue
  , fulfillmentRoutingNote = "test"
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
equal label expected actualValue
  | expected == actualValue = pass label
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actualValue)

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
