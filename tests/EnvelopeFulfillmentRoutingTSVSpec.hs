{-# LANGUAGE OverloadedStrings #-}

module EnvelopeFulfillmentRoutingTSVSpec (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Envelope.FulfillmentRouting
import HKernel.Envelope.FulfillmentRouting.TSV
import HKernel.Envelope.Identity (EnvelopeId, mkEnvelopeId)
import HKernel.Plan (PlanId, mkPlanId)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let source = T.unlines
        [ header
        , "# source order is provenance; effective date governs"
        , "2026-08-20\tplan-save\tnot-target\t-\tintent withdrawn"
        , "2026-08-01\tplan-save\tfulfills\tsavings\tinitial intent"
        , "2026-08-10\tplan-save\tfulfills\tlong-term-savings\tchanged intent"
        , "2026-08-01\tplan-future\tfulfills\tfuture-envelope\tsyntax only"
        ]
      history = mustRight (parseFulfillmentRoutingTSV source)
      savePlan = plan "plan-save"
      futurePlan = plan "plan-future"

  equal "TSV admits historical Plan route by effective date"
    (Just (FulfillsEnvelope (envelope "savings")))
    (fulfillmentRouteAt (day 5) savePlan history)
  equal "later TSV decision changes Plan intent"
    (Just (FulfillsEnvelope (envelope "long-term-savings")))
    (fulfillmentRouteAt (day 15) savePlan history)
  equal "not-target is explicit after its effective date"
    (Just NotFulfillmentTarget)
    (fulfillmentRouteAt (day 20) savePlan history)
  equal "source-local admission does not require current Envelope policy"
    (Just (FulfillsEnvelope (envelope "future-envelope")))
    (fulfillmentRouteAt (day 1) futurePlan history)

  right "CRLF input is admitted"
    (parseFulfillmentRoutingTSV
      (T.replace "\n" "\r\n"
        (header <> "\n2026-08-01\tplan-save\tfulfills\tsavings\tcrlf\n")))

  assertSingleError "missing header points to physical line 1"
    (\err -> fulfillmentRoutingTSVErrorLine err == 1
      && fulfillmentRoutingTSVErrorReason err == MissingFulfillmentRoutingHeader)
    (parseFulfillmentRoutingTSV "")

  assertSingleError "row width is exact"
    (\err -> fulfillmentRoutingTSVErrorLine err == 2
      && case fulfillmentRoutingTSVErrorReason err of
        InvalidFulfillmentRoutingRow _ -> True
        _ -> False)
    (parseFulfillmentRoutingTSV (T.unlines
      [ header
      , "2026-08-01\tplan-save\tfulfills\tsavings\tnote\textra"
      ]))

  assertSingleError "invalid effective date fails closed"
    (\err -> case fulfillmentRoutingTSVErrorReason err of
      InvalidFulfillmentRoutingDate "2026-99-99" -> True
      _ -> False)
    (parseFulfillmentRoutingTSV (T.unlines
      [ header
      , "2026-99-99\tplan-save\tfulfills\tsavings\tbad date"
      ]))

  assertSingleError "invalid PlanId fails at the source boundary"
    (\err -> case fulfillmentRoutingTSVErrorReason err of
      InvalidFulfillmentRoutingPlan _ -> True
      _ -> False)
    (parseFulfillmentRoutingTSV (T.unlines
      [ header
      , "2026-08-01\tplan save\tfulfills\tsavings\tbad plan"
      ]))

  assertSingleError "unknown route kind fails closed"
    (\err -> case fulfillmentRoutingTSVErrorReason err of
      InvalidFulfillmentRoutingKind "maybe" -> True
      _ -> False)
    (parseFulfillmentRoutingTSV (T.unlines
      [ header
      , "2026-08-01\tplan-save\tmaybe\tsavings\tbad route"
      ]))

  assertSingleError "fulfills route cannot use not-target sentinel"
    (\err -> fulfillmentRoutingTSVErrorReason err
      == FulfilledRoutingTargetCannotBeDash)
    (parseFulfillmentRoutingTSV (T.unlines
      [ header
      , "2026-08-01\tplan-save\tfulfills\t-\tbad target"
      ]))

  assertSingleError "not-target route requires dash target"
    (\err -> case fulfillmentRoutingTSVErrorReason err of
      NotTargetRoutingTargetMustBeDash "savings" -> True
      _ -> False)
    (parseFulfillmentRoutingTSV (T.unlines
      [ header
      , "2026-08-01\tplan-save\tnot-target\tsavings\tbad target"
      ]))

  assertSingleError "invalid EnvelopeId fails at the source boundary"
    (\err -> case fulfillmentRoutingTSVErrorReason err of
      InvalidFulfillmentRoutingEnvelope _ -> True
      _ -> False)
    (parseFulfillmentRoutingTSV (T.unlines
      [ header
      , "2026-08-01\tplan-save\tfulfills\tsavings target\tbad envelope"
      ]))

  assertSingleError "duplicate PlanId/day points at later physical row"
    (\err -> fulfillmentRoutingTSVErrorLine err == 3
      && case fulfillmentRoutingTSVErrorReason err of
        DuplicateFulfillmentRoutingCoordinate actualPlan actualDay ->
          actualPlan == savePlan && actualDay == day 1
        _ -> False)
    (parseFulfillmentRoutingTSV (T.unlines
      [ header
      , "2026-08-01\tplan-save\tfulfills\tsavings\tfirst"
      , "2026-08-01\tplan-save\tnot-target\t-\tsecond"
      ]))

header :: Text
header = "effective_from\tplan_id\troute\ttarget\tnote"

day :: Int -> Day
day = fromGregorian 2026 8

plan :: Text -> PlanId
plan = mustRight . mkPlanId

envelope :: Text -> EnvelopeId
envelope = mustRight . mkEnvelopeId

assertSingleError
  :: Show value
  => String
  -> (FulfillmentRoutingTSVError -> Bool)
  -> Either (NonEmpty.NonEmpty FulfillmentRoutingTSVError) value
  -> IO ()
assertSingleError label predicate result = case result of
  Left errors -> case NonEmpty.toList errors of
    [err] | predicate err -> pass label
    unexpected -> failTest label ("unexpected errors: " ++ show unexpected)
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
