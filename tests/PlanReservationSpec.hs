{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account
import HKernel.Money
import HKernel.Plan
import HKernel.Plan.Reservation
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeReservationIdentity
  characterizeBoundedReservationEvidence
  acceptFullReservation
  rejectUnknownPlanReference
  rejectCrossCommodityReservation
  rejectOverReservation
  rejectDuplicateReservationIdentity
  rejectMultipleReservationsForOnePlan
  rejectDuplicatePlanIdentity

characterizeReservationIdentity :: IO ()
characterizeReservationIdentity = do
  let reservationId = mustRight (mkReservationId "reservation:wifi")

  assertEqual "reservation identity retains durable source text"
    "reservation:wifi"
    (reservationIdText reservationId)
  assertLeft "empty reservation identity is rejected"
    (mkReservationId "")
  assertLeft "reservation identity with surrounding whitespace is rejected"
    (mkReservationId " reservation:wifi")
  assertLeft "reservation identity with embedded whitespace is rejected"
    (mkReservationId "reservation wifi")
  assertLeft "reservation identity with a control character is rejected"
    (mkReservationId "reservation\twifi")

characterizeBoundedReservationEvidence :: IO ()
characterizeBoundedReservationEvidence = do
  let firstPlan = planFixture "plan-wifi" jpy 200
      secondPlan = planFixture "plan-rent" jpy 1000
      firstDeclaration = reservationDeclaration
        "reservation:wifi" firstPlan jpy 50
      secondDeclaration = reservationDeclaration
        "reservation:rent" secondPlan jpy 200
      evidence = mustRight
        (resolvePlanReservationEvidence
          [firstPlan, secondPlan]
          [firstDeclaration, secondDeclaration])

  assertEqual "reservation evidence follows declaration source order"
    [committedPlanId firstPlan, committedPlanId secondPlan]
    (map (committedPlanId . reservationEvidencePlan) evidence)
  assertEqual "reservation evidence retains durable identity"
    ["reservation:wifi", "reservation:rent"]
    (map (reservationIdText . reservationEvidenceId) evidence)
  assertEqual "reservation evidence retains exact admitted amounts"
    [mkAmount jpy (quantityFromInteger 50), mkAmount jpy (quantityFromInteger 200)]
    (map (positiveAmountValue . reservationEvidenceAmount) evidence)

acceptFullReservation :: IO ()
acceptFullReservation = do
  let plan = planFixture "plan-full" jpy 200
      declaration = reservationDeclaration
        "reservation:full" plan jpy 200
      evidence = exactlyOne
        (mustRight (resolvePlanReservationEvidence [plan] [declaration]))

  assertEqual "reservation may equal the full Plan amount"
    (positiveAmountValue (committedPlanAmount plan))
    (positiveAmountValue (reservationEvidenceAmount evidence))

rejectUnknownPlanReference :: IO ()
rejectUnknownPlanReference = do
  let missingPlanId = mustRight (mkPlanId "plan-missing")
      declaration = declarePlanReservation
        (mustRight (mkReservationId "reservation:missing"))
        missingPlanId
        (positiveAmount jpy 50)

  assertLeftSatisfies "unknown reservation Plan reference fails closed"
    (any isUnknown . NonEmpty.toList)
    (resolvePlanReservationEvidence [] [declaration])
  where
    isUnknown err = case err of
      UnknownReservationPlanReference _ _ -> True
      _ -> False

rejectCrossCommodityReservation :: IO ()
rejectCrossCommodityReservation = do
  let plan = planFixture "plan-jpy" jpy 200
      declaration = reservationDeclaration
        "reservation:usd" plan usd 50

  assertLeftSatisfies "cross-Commodity reservation is rejected"
    (any isMismatch . NonEmpty.toList)
    (resolvePlanReservationEvidence [plan] [declaration])
  where
    isMismatch err = case err of
      ReservationCommodityMismatch _ _ expected actual ->
        expected == jpy && actual == usd
      _ -> False

rejectOverReservation :: IO ()
rejectOverReservation = do
  let plan = planFixture "plan-small" jpy 200
      declaration = reservationDeclaration
        "reservation:too-large" plan jpy 300

  assertLeftSatisfies "reservation cannot exceed its Plan amount"
    (any isExcess . NonEmpty.toList)
    (resolvePlanReservationEvidence [plan] [declaration])
  where
    isExcess err = case err of
      ReservationExceedsPlanAmount _ _ planAmount reservationAmount ->
        amountQuantity planAmount == quantityFromInteger 200
          && amountQuantity reservationAmount == quantityFromInteger 300
      _ -> False

rejectDuplicateReservationIdentity :: IO ()
rejectDuplicateReservationIdentity = do
  let firstPlan = planFixture "plan-first" jpy 100
      secondPlan = planFixture "plan-second" jpy 100
      reservationId = mustRight (mkReservationId "reservation:duplicate")
      firstDeclaration = declarePlanReservation
        reservationId (committedPlanId firstPlan) (positiveAmount jpy 10)
      secondDeclaration = declarePlanReservation
        reservationId (committedPlanId secondPlan) (positiveAmount jpy 10)

  assertLeftSatisfies "duplicate reservation identity is rejected"
    (any isDuplicate . NonEmpty.toList)
    (resolvePlanReservationEvidence
      [firstPlan, secondPlan]
      [firstDeclaration, secondDeclaration])
  where
    isDuplicate err = case err of
      DuplicateReservationId _ -> True
      _ -> False

rejectMultipleReservationsForOnePlan :: IO ()
rejectMultipleReservationsForOnePlan = do
  let plan = planFixture "plan-one" jpy 200
      firstDeclaration = reservationDeclaration
        "reservation:first" plan jpy 50
      secondDeclaration = reservationDeclaration
        "reservation:second" plan jpy 50

  assertLeftSatisfies "one Plan cannot receive competing reservations"
    (any isCompeting . NonEmpty.toList)
    (resolvePlanReservationEvidence
      [plan]
      [firstDeclaration, secondDeclaration])
  where
    isCompeting err = case err of
      PlanReservedByMultipleReservations _ reservationIds ->
        NonEmpty.length reservationIds == 2
      _ -> False

rejectDuplicatePlanIdentity :: IO ()
rejectDuplicatePlanIdentity = do
  let plan = planFixture "plan-duplicate" jpy 200
      declaration = reservationDeclaration
        "reservation:one" plan jpy 50

  assertLeftSatisfies "duplicate Plan facts are rejected as ambiguous"
    (any isDuplicate . NonEmpty.toList)
    (resolvePlanReservationEvidence [plan, plan] [declaration])
  where
    isDuplicate err = case err of
      DuplicateReservationPlanId _ -> True
      _ -> False

reservationDeclaration
  :: T.Text
  -> CommittedOutgoingPlan
  -> Commodity
  -> Integer
  -> PlanReservationDeclaration
reservationDeclaration identity plan commodity amountValue =
  declarePlanReservation
    (mustRight (mkReservationId identity))
    (committedPlanId plan)
    (positiveAmount commodity amountValue)

positiveAmount :: Commodity -> Integer -> PositiveAmount
positiveAmount commodity amountValue =
  mustRight (mkPositiveAmount
    (mkAmount commodity (quantityFromInteger amountValue)))

planFixture
  :: T.Text
  -> Commodity
  -> Integer
  -> CommittedOutgoingPlan
planFixture planIdValue commodity amountValue =
  mustRight (mkCommittedOutgoingPlan
    (mustRight (mkPlanId planIdValue))
    (fromGregorian 2026 8 8)
    "planned memo"
    (positiveAmount commodity amountValue)
    outgoingDirection)
  where
    asset = mustRight (mkAccount "assets:cash")
    expense = mustRight (mkAccount "expenses:wifi")
    registry = mustRight $ do
      withAsset <- registerAccount
        (declareAccount asset Asset)
        emptyAccountRegistry
      registerAccount
        (declareAccount expense Expense)
        withAsset
    declaredDirection = mustRight
      (admitPaymentDirection registry
        (mustRight (mkPaymentDirection asset expense)))
    outgoingDirection = mustRight
      (admitOutgoingPaymentDirection declaredDirection)

jpy :: Commodity
jpy = mustRight (mkCommodity "JPY")

usd :: Commodity
usd = mustRight (mkCommodity "USD")

exactlyOne :: Show value => [value] -> value
exactlyOne [value] = value
exactlyOne values = error ("expected exactly one value, got " ++ show values)



assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure

assertLeftSatisfies
  :: Show value
  => String
  -> (NonEmpty error -> Bool)
  -> Either (NonEmpty error) value
  -> IO ()
assertLeftSatisfies label predicate result = case result of
  Left errors
    | predicate errors -> putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn "    errors did not satisfy predicate"
        exitFailure
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure

