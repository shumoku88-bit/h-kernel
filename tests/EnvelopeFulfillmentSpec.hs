{-# LANGUAGE OverloadedStrings #-}

module EnvelopeFulfillmentSpec (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Envelope.Fulfillment
import HKernel.Envelope.FulfillmentRouting
import HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeRegistryError(..)
  , mkEnvelopeId
  , mkEnvelopeRegistry
  )
import HKernel.Money
import HKernel.Period (Period, mkPeriod)
import HKernel.Plan (PlanId, mkPlanId)
import HKernel.Plan.Journal (PlanJournal, parsePlanJournal)
import System.Exit (exitFailure)

main :: IO ()
main = do
  fulfillmentLaws
  historicalRoutingLaw
  sharedAccountLaw
  repeatedTargetPositionLaw
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
  equal "later completed Plan follows its own PlanId intent"
    (one jpy 30)
    (fulfillmentNet (envelopeFulfillmentFor newSavings fulfillment))
  equal "another explicit completed target can fulfill another Envelope"
    (one jpy 40)
    (fulfillmentNet (envelopeFulfillmentFor investing fulfillment))
  equal "Expense Plan remains owned by Expense Consumption even if PlanId-routed here"
    emptyBalance
    (fulfillmentNet (envelopeFulfillmentFor (envelope "should-not-count") fulfillment))

historicalRoutingLaw :: IO ()
historicalRoutingLaw = do
  let fulfillment = fulfillmentThrough (day 5) actualSource
      jpy = commodity "JPY"
  equal "future PlanId route changes do not rewrite earlier completed fulfillment"
    (one jpy 100)
    (fulfillmentNet (envelopeFulfillmentFor (envelope "savings-old") fulfillment))
  equal "future route is absent from the earlier observation"
    emptyBalance
    (fulfillmentNet (envelopeFulfillmentFor (envelope "savings-new") fulfillment))

sharedAccountLaw :: IO ()
sharedAccountLaw = do
  let fulfillment = fulfillmentThrough observedDay actualSource
      jpy = commodity "JPY"
  equal "unrouted Plan sharing the savings Account does not inherit Envelope meaning"
    (one jpy 100)
    (fulfillmentNet (envelopeFulfillmentFor (envelope "savings-old") fulfillment))
  equal "shared Account completion does not leak into the later savings Envelope"
    (one jpy 30)
    (fulfillmentNet (envelopeFulfillmentFor (envelope "savings-new") fulfillment))

repeatedTargetPositionLaw :: IO ()
repeatedTargetPositionLaw = do
  let fulfillment = fulfillmentThrough observedDay actualSource
      jpy = commodity "JPY"
  equal "repeated target Account uses the positive Plan position, not whole-Account net"
    (one jpy 110)
    (fulfillmentNet (envelopeFulfillmentFor (envelope "repeated") fulfillment))

unrelatedTargetMovementLaw :: IO ()
unrelatedTargetMovementLaw = do
  let fulfillment = fulfillmentThrough observedDay actualSource
  equal "ordinary positive movement to an Account is not Plan fulfillment"
    emptyBalance
    (fulfillmentNet (envelopeFulfillmentFor (envelope "unrelated") fulfillment))

completionShapeLaw :: IO ()
completionShapeLaw =
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
      EnvelopeFulfillmentCompletionShapeError _ -> True
      _ -> False

routingAdmissionLaw :: IO ()
routingAdmissionLaw = do
  let duplicate =
        [ decision (day 1) "p-save-original" (FulfillsEnvelope (envelope "a"))
        , decision (day 1) "p-save-original" (FulfillsEnvelope (envelope "b"))
        ]
      knownHistoricalPlan = planId "p-retired-historical"
      missingPlan = planId "p-missing"
      historicalEnvelope = envelope "historical"
      missingEnvelope = envelope "missing-envelope"
      registry = mustRight (mkEnvelopeRegistry [historicalEnvelope])
      knownHistory = mustRight (mkFulfillmentRoutingHistory
        [ FulfillmentRoutingDecision
            { fulfillmentRoutingEffectiveFrom = day 2
            , fulfillmentRoutingPlanId = knownHistoricalPlan
            , fulfillmentRoutingRoute = FulfillsEnvelope historicalEnvelope
            , fulfillmentRoutingNote = "historical identities remain referable"
            }
        ])
      missingPlanHistory = mustRight (mkFulfillmentRoutingHistory
        [ FulfillmentRoutingDecision
            { fulfillmentRoutingEffectiveFrom = day 3
            , fulfillmentRoutingPlanId = missingPlan
            , fulfillmentRoutingRoute = NotFulfillmentTarget
            , fulfillmentRoutingNote = "dangling Plan reference"
            }
        ])
      missingEnvelopeHistory = mustRight (mkFulfillmentRoutingHistory
        [ FulfillmentRoutingDecision
            { fulfillmentRoutingEffectiveFrom = day 4
            , fulfillmentRoutingPlanId = knownHistoricalPlan
            , fulfillmentRoutingRoute = FulfillsEnvelope missingEnvelope
            , fulfillmentRoutingNote = "dangling Envelope reference"
            }
        ])
      doublyDanglingHistory = mustRight (mkFulfillmentRoutingHistory
        [ FulfillmentRoutingDecision
            { fulfillmentRoutingEffectiveFrom = day 5
            , fulfillmentRoutingPlanId = missingPlan
            , fulfillmentRoutingRoute = FulfillsEnvelope missingEnvelope
            , fulfillmentRoutingNote = "both references are missing"
            }
        ])

  leftSatisfies
    "two fulfillment-routing decisions on one PlanId/day fail closed"
    (any isDuplicate . NonEmpty.toList)
    (mkFulfillmentRoutingHistory duplicate)
  leftSatisfies
    "Envelope registry does not silently collapse duplicate identities"
    (any isDuplicateEnvelope . NonEmpty.toList)
    (mkEnvelopeRegistry [historicalEnvelope, historicalEnvelope])
  right "historical Plan and Envelope identities remain valid independent of current policy"
    (admitFulfillmentRoutingReferences
      [knownHistoricalPlan]
      registry
      knownHistory)
  equal "unknown PlanId in fulfillment routing fails closed"
    (Left (UnknownFulfillmentRoutingPlan missingPlan (day 3) NonEmpty.:| []))
    (admitFulfillmentRoutingReferences
      [knownHistoricalPlan]
      registry
      missingPlanHistory)
  equal "unknown EnvelopeId is rejected by stable registry rather than current TOML"
    (Left (UnknownFulfillmentRoutingEnvelope
      knownHistoricalPlan (day 4) missingEnvelope NonEmpty.:| []))
    (admitFulfillmentRoutingReferences
      [knownHistoricalPlan]
      registry
      missingEnvelopeHistory)
  equal "one routing decision retains both dangling identity coordinates"
    (Left
      ( UnknownFulfillmentRoutingPlan missingPlan (day 5)
        NonEmpty.:|
          [ UnknownFulfillmentRoutingEnvelope
              missingPlan (day 5) missingEnvelope
          ]
      ))
    (admitFulfillmentRoutingReferences
      [knownHistoricalPlan]
      registry
      doublyDanglingHistory)
  where
    isDuplicate err = case err of
      DuplicateFulfillmentRoutingDecision routedPlanId effectiveFrom ->
        routedPlanId == planId "p-save-original" && effectiveFrom == day 1
    isDuplicateEnvelope err = case err of
      DuplicateEnvelopeRegistryIdentity envelopeId ->
        envelopeId == envelope "historical"

observationLaw :: IO ()
observationLaw =
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
  [ decision (day 1) "p-save-original" (FulfillsEnvelope (envelope "savings-old"))
  , decision (day 6) "p-save-original" (FulfillsEnvelope (envelope "savings-new"))
  , decision (day 1) "p-save-new" (FulfillsEnvelope (envelope "savings-new"))
  , decision (day 1) "p-invest" (FulfillsEnvelope (envelope "investing"))
  , decision (day 1) "p-repeated" (FulfillsEnvelope (envelope "repeated"))
  , decision (day 1) "p-fee" (FulfillsEnvelope (envelope "should-not-count"))
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
  , "2026-08-10 * repeated savings coordinate"
  , "  ; plan-id: p-repeated"
  , "  assets:savings     100 JPY"
  , "  assets:savings     -40 JPY"
  , "  assets:cash        -60 JPY"
  , ""
  , "2026-08-10 * unrelated Plan sharing savings Account"
  , "  ; plan-id: p-shared-unrouted"
  , "  assets:savings      70 JPY"
  , "  assets:cash        -70 JPY"
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
  , "2026-08-10 * complete repeated savings coordinate"
  , "  ; event-id: repeated"
  , "  ; plan-id: p-repeated"
  , "  assets:savings     110 JPY"
  , "  assets:savings     -40 JPY"
  , "  assets:cash        -70 JPY"
  , ""
  , "2026-08-10 * completed unrelated Plan on shared savings Account"
  , "  ; event-id: shared-unrouted"
  , "  ; plan-id: p-shared-unrouted"
  , "  assets:savings      70 JPY"
  , "  assets:cash        -70 JPY"
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

planId :: T.Text -> PlanId
planId = mustRight . mkPlanId

envelope :: T.Text -> EnvelopeId
envelope = mustRight . mkEnvelopeId

commodity :: T.Text -> Commodity
commodity = mustRight . mkCommodity

decision :: Day -> T.Text -> FulfillmentRoute -> FulfillmentRoutingDecision
decision effectiveFrom planIdTextValue routeValue = FulfillmentRoutingDecision
  { fulfillmentRoutingEffectiveFrom = effectiveFrom
  , fulfillmentRoutingPlanId = planId planIdTextValue
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

right :: Show error => String -> Either error value -> IO ()
right label result = case result of
  Right _ -> pass label
  Left err -> failTest label ("unexpectedly rejected: " ++ show err)

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
