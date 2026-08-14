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
import HKernel.Plan.CompletionShape (PlanCompletionShapeError(..))
import HKernel.Plan.Journal (PlanJournal, parsePlanJournal)
import System.Exit (exitFailure)

main :: IO ()
main = do
  fulfillmentLaws
  historicalRoutingLaw
  unrelatedTargetMovementLaw
  completionShapeLaw
  routingAdmissionLaw
  observationLaw

fulfillmentLaws :: IO ()
fulfillmentLaws = do
  let fulfillment = fulfillmentThrough observedDay actualSource
      jpy = commodity "JPY"
      oldSavings = envelope "savings-old"
      newSavings = envelope "savings-new"
      investing = envelope "investing"
      oldAmounts = envelopeFulfillmentFor oldSavings fulfillment

  equal "completed Plan uses Actual target amount rather than planned amount"
    (one jpy 100)
    (fulfillmentNet oldAmounts)
  equal "gross evidence keeps root application and reverse-of-reverse restoration"
    (one jpy 200)
    (fulfillmentApplied oldAmounts)
  equal "typed reversal of the completed target is kept separately"
    (one jpy 100)
    (fulfillmentReversed oldAmounts)
  equal "ordinary withdrawal and its reversal do not manufacture fulfillment"
    (one jpy 100)
    (fulfillmentNet oldAmounts)
  equal "later completed Plan follows target intent effective on its Actual day"
    (one jpy 30)
    (fulfillmentNet (envelopeFulfillmentFor newSavings fulfillment))
  equal "another explicit completed target can fulfill another Envelope"
    (one jpy 40)
    (fulfillmentNet (envelopeFulfillmentFor investing fulfillment))
  equal "Expense Plan remains owned by Expense Consumption even if mis-routed here"
    emptyBalance
    (fulfillmentNet (envelopeFulfillmentFor (envelope "should-not-count") fulfillment))

historicalRoutingLaw :: IO ()
historicalRoutingLaw = do
  let fulfillment = fulfillmentThrough (day 5) actualSource
      jpy = commodity "JPY"
  equal "future route changes do not rewrite earlier completed target fulfillment"
    (one jpy 100)
    (fulfillmentNet (envelopeFulfillmentFor (envelope "savings-old") fulfillment))
  equal "future target route is absent from the earlier observation"
    emptyBalance
    (fulfillmentNet (envelopeFulfillmentFor (envelope "savings-new") fulfillment))

unrelatedTargetMovementLaw :: IO ()
unrelatedTargetMovementLaw = do
  let fulfillment = fulfillmentThrough observedDay actualSource
  equal "ordinary positive movement to a target account is not Plan fulfillment"
    emptyBalance
    (fulfillmentNet (envelopeFulfillmentFor (envelope "unrelated") fulfillment))

completionShapeLaw :: IO () =
  leftSatisfies
    "Plan-linked Actual with incompatible Account shape fails closed"
    (any isShapeMismatch . NonEmpty.toList)
    (observeEnvelopeFulfillment
      period
      observedDay
      planJournal
      (mustRight (parseActualJournal shapeMismatchActualSource))
      routing)
  where
    isShapeMismatch err = case err of
      EnvelopeFulfillmentCompletionShapeError
        (PlanCompletionAccountShapeMismatch _) -> True
      _ -> False

routingAdmissionLaw :: IO ()
routingAdmissionLaw = do
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
      planJournal
      actual
      routing)

fulfillmentThrough :: Day -> T.Text -> EnvelopeFulfillment
fulfillmentThrough observedThrough actualText =
  mustRight
    (observeEnvelopeFulfillment
      period
      observedThrough
      planJournal
      (mustRight (parseActualJournal actualText))
      routing)

planJournal :: PlanJournal
planJournal = mustRight (parsePlanJournal planSource)

actual = mustRight (parseActualJournal actualSource)

routing :: FulfillmentRoutingHistory
routing = mustRight (mkFulfillmentRoutingHistory
  [ decision (day 1) "assets:savings" (FulfillsEnvelope (envelope "savings-old"))
  , decision (day 6) "assets:savings" (FulfillsEnvelope (envelope "savings-new"))
  , decision (day 1) "assets:investment" (FulfillsEnvelope (envelope "investing"))
  , decision (day 1) "assets:unrelated" (FulfillsEnvelope (envelope "unrelated"))
  , decision (day 1) "expenses:fee" (FulfillsEnvelope (envelope "should-not-count"))
  ])

planSource :: T.Text
planSource = declarations <> T.unlines
  [ "2026-08-02 * planned saving"
  , "  ; plan-id: p-save-original"
  , "  assets:savings      90 JPY"
  , "  assets:cash        -90 JPY"
  , ""
  , "2026-08-09 * planned saving under later intent"
  , "  ; plan-id: p-save-new"
  , "  assets:savings      25 JPY"
  , "  assets:cash        -25 JPY"
  , ""
  , "2026-08-10 * planned investment"
  , "  ; plan-id: p-invest"
  , "  assets:investment    40 JPY"
  , "  assets:cash         -40 JPY"
  , ""
  , "2026-08-10 * planned expense"
  , "  ; plan-id: p-fee"
  , "  expenses:fee          5 JPY"
  , "  assets:cash           -5 JPY"
  ]

actualSource :: T.Text
actualSource = declarations <> T.unlines
  [ "2026-08-02 * save more than planned"
  , "  ; event-id: save-original"
  , "  ; plan-id: p-save-original"
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
  , "2026-08-07 * reverse original completed saving after route change"
  , "  ; event-id: save-reversal"
  , "  ; reverses: save-original"
  , "  assets:savings    -100 JPY"
  , "  assets:cash        100 JPY"
  , ""
  , "2026-08-08 * restore original completed saving"
  , "  ; event-id: save-restored"
  , "  ; reverses: save-reversal"
  , "  assets:savings     100 JPY"
  , "  assets:cash       -100 JPY"
  , ""
  , "2026-08-09 * completed new saving"
  , "  ; event-id: save-new"
  , "  ; plan-id: p-save-new"
  , "  assets:savings      30 JPY"
  , "  assets:cash        -30 JPY"
  , ""
  , "2026-08-10 * completed investment"
  , "  ; event-id: invest"
  , "  ; plan-id: p-invest"
  , "  assets:investment    40 JPY"
  , "  assets:cash         -40 JPY"
  , ""
  , "2026-08-10 * unrelated target deposit"
  , "  assets:unrelated      50 JPY"
  , "  assets:cash          -50 JPY"
  , ""
  , "2026-08-10 * completed ordinary expense"
  , "  ; event-id: fee"
  , "  ; plan-id: p-fee"
  , "  expenses:fee          5 JPY"
  , "  assets:cash           -5 JPY"
  ]

shapeMismatchActualSource :: T.Text
shapeMismatchActualSource = declarations <> T.unlines
  [ "2026-08-02 * incompatible completed saving"
  , "  ; event-id: save-original"
  , "  ; plan-id: p-save-original"
  , "  assets:investment   100 JPY"
  , "  assets:cash        -100 JPY"
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
  , "account assets:unrelated"
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
