{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Account
import HKernel.Ledger
import HKernel.Money
import HKernel.Plan
import HKernel.Plan.Completion
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeActualTransactionIdentity
  characterizeExplicitCompletionEvidence
  characterizeOpenPlanProjection
  characterizeExplicitSharedActualRelation
  rejectUnknownPlanReference
  rejectUnknownActualReference
  rejectDuplicatePlanIdentity
  rejectDuplicateActualIdentity
  rejectDuplicateCompletionDeclaration
  rejectCompetingActualReferences

characterizeActualTransactionIdentity :: IO ()
characterizeActualTransactionIdentity = do
  let actualId = mustRight (mkActualTransactionId "actual-2026-001")

  assertEqual "Actual identity retains durable source text"
    "actual-2026-001"
    (actualTransactionIdText actualId)
  assertLeft "empty Actual identity is rejected"
    (mkActualTransactionId "")
  assertLeft "Actual identity with surrounding whitespace is rejected"
    (mkActualTransactionId " actual-2026-001")
  assertLeft "Actual identity with embedded whitespace is rejected"
    (mkActualTransactionId "actual 2026 001")
  assertLeft "Actual identity with a control character is rejected"
    (mkActualTransactionId "actual\t2026")

characterizeExplicitCompletionEvidence :: IO ()
characterizeExplicitCompletionEvidence = do
  let plan = planFixture "plan-wifi" 4810
      actualTransaction = transactionFixture
        (fromGregorian 2026 7 1)
        "description deliberately differs"
        999
      actualId = mustRight (mkActualTransactionId "actual-bank-42")
      actual = identifyActualTransaction actualId actualTransaction
      declaration = declarePlanCompletion (committedPlanId plan) actualId
      evidence = exactlyOne
        (mustRight
          (resolvePlanCompletionEvidence [plan] [actual] [declaration]))

  assertEqual "explicit relation resolves the admitted Plan"
    plan
    (completionPlan evidence)
  assertEqual "completion evidence retains durable Actual identity"
    actualId
    (identifiedActualId (completionActual evidence))
  assertEqual "completion evidence retains the whole validated Transaction"
    actualTransaction
    (identifiedActualTransaction (completionActual evidence))
  assertEqual "completion does not require date, memo, or amount resemblance"
    actual
    (completionActual evidence)

characterizeOpenPlanProjection :: IO ()
characterizeOpenPlanProjection = do
  let overduePlan = planFixtureOn
        "plan-overdue"
        (fromGregorian 2026 7 20)
        100
      completedPlan = planFixtureOn
        "plan-completed"
        (fromGregorian 2026 8 8)
        200
      futurePlan = planFixtureOn
        "plan-future"
        (fromGregorian 2026 8 10)
        300
      actualId = mustRight (mkActualTransactionId "actual-completed")
      actual = identifyActualTransaction actualId
        (transactionFixture
          (fromGregorian 2026 7 25)
          "completion before planned date"
          999)
      declaration = declarePlanCompletion
        (committedPlanId completedPlan)
        actualId
      openPlans = mustRight
        (resolveOpenCommittedOutgoingPlans
          [overduePlan, completedPlan, futurePlan]
          [actual]
          [declaration])

  assertEqual "only explicit completion evidence removes a Plan"
    [committedPlanId overduePlan, committedPlanId futurePlan]
    (map committedPlanId openPlans)
  assertEqual "open Plan projection preserves Plan source order"
    [overduePlan, futurePlan]
    openPlans
  assertEqual "an overdue Plan remains open without completion evidence"
    [fromGregorian 2026 7 20, fromGregorian 2026 8 10]
    (map committedPlanDate openPlans)

characterizeExplicitSharedActualRelation :: IO ()
characterizeExplicitSharedActualRelation = do
  let firstPlan = planFixture "plan-first" 100
      secondPlan = planFixture "plan-second" 200
      actualId = mustRight (mkActualTransactionId "actual-combined")
      actual = identifyActualTransaction actualId
        (transactionFixture (fromGregorian 2026 7 1) "combined" 300)
      declarations =
        [ declarePlanCompletion (committedPlanId firstPlan) actualId
        , declarePlanCompletion (committedPlanId secondPlan) actualId
        ]
      evidence = mustRight
        (resolvePlanCompletionEvidence
          [firstPlan, secondPlan]
          [actual]
          declarations)

  assertEqual "one Actual may carry several explicit Plan relations"
    [committedPlanId firstPlan, committedPlanId secondPlan]
    (map (committedPlanId . completionPlan) evidence)

rejectUnknownPlanReference :: IO ()
rejectUnknownPlanReference = do
  let actualId = mustRight (mkActualTransactionId "actual-one")
      actual = identifyActualTransaction actualId
        (transactionFixture (fromGregorian 2026 7 1) "Actual" 100)
      missingPlanId = mustRight (mkPlanId "plan-missing")
      declaration = declarePlanCompletion missingPlanId actualId

  assertLeftSatisfies "unknown explicit Plan reference is rejected"
    (any isUnknown . NonEmpty.toList)
    (resolvePlanCompletionEvidence [] [actual] [declaration])
  assertLeftSatisfies "open Plan projection inherits fail-closed validation"
    (any isUnknown . NonEmpty.toList)
    (resolveOpenCommittedOutgoingPlans [] [actual] [declaration])
  where
    isUnknown err = case err of
      UnknownCompletionPlanReference _ _ -> True
      _ -> False

rejectUnknownActualReference :: IO ()
rejectUnknownActualReference = do
  let plan = planFixture "plan-known" 100
      missingActualId = mustRight (mkActualTransactionId "actual-missing")
      declaration = declarePlanCompletion
        (committedPlanId plan)
        missingActualId

  assertLeftSatisfies "unknown explicit Actual reference is rejected"
    (any isUnknown . NonEmpty.toList)
    (resolvePlanCompletionEvidence [plan] [] [declaration])
  where
    isUnknown err = case err of
      UnknownCompletionActualReference _ _ -> True
      _ -> False

rejectDuplicatePlanIdentity :: IO ()
rejectDuplicatePlanIdentity = do
  let plan = planFixture "plan-duplicate" 100
      actualId = mustRight (mkActualTransactionId "actual-one")
      actual = identifyActualTransaction actualId
        (transactionFixture (fromGregorian 2026 7 1) "Actual" 100)
      declaration = declarePlanCompletion (committedPlanId plan) actualId

  assertLeftSatisfies "duplicate Plan identity is rejected as ambiguous"
    (any isDuplicate . NonEmpty.toList)
    (resolvePlanCompletionEvidence [plan, plan] [actual] [declaration])
  where
    isDuplicate err = case err of
      DuplicateCompletionPlanId _ -> True
      _ -> False

rejectDuplicateActualIdentity :: IO ()
rejectDuplicateActualIdentity = do
  let plan = planFixture "plan-one" 100
      actualId = mustRight (mkActualTransactionId "actual-duplicate")
      firstActual = identifyActualTransaction actualId
        (transactionFixture (fromGregorian 2026 7 1) "first" 100)
      secondActual = identifyActualTransaction actualId
        (transactionFixture (fromGregorian 2026 7 2) "second" 100)
      declaration = declarePlanCompletion (committedPlanId plan) actualId

  assertLeftSatisfies "duplicate Actual fact identity is rejected"
    (any isDuplicate . NonEmpty.toList)
    (resolvePlanCompletionEvidence
      [plan]
      [firstActual, secondActual]
      [declaration])
  where
    isDuplicate err = case err of
      DuplicateActualTransactionId _ -> True
      _ -> False

rejectDuplicateCompletionDeclaration :: IO ()
rejectDuplicateCompletionDeclaration = do
  let plan = planFixture "plan-one" 100
      actualId = mustRight (mkActualTransactionId "actual-one")
      actual = identifyActualTransaction actualId
        (transactionFixture (fromGregorian 2026 7 1) "Actual" 100)
      declaration = declarePlanCompletion (committedPlanId plan) actualId

  assertLeftSatisfies "duplicate completion relation is rejected"
    (any isDuplicate . NonEmpty.toList)
    (resolvePlanCompletionEvidence
      [plan]
      [actual]
      [declaration, declaration])
  where
    isDuplicate err = case err of
      DuplicatePlanCompletionDeclaration _ _ -> True
      _ -> False

rejectCompetingActualReferences :: IO ()
rejectCompetingActualReferences = do
  let plan = planFixture "plan-one" 100
      firstActualId = mustRight (mkActualTransactionId "actual-first")
      secondActualId = mustRight (mkActualTransactionId "actual-second")
      firstActual = identifyActualTransaction firstActualId
        (transactionFixture (fromGregorian 2026 7 1) "first" 100)
      secondActual = identifyActualTransaction secondActualId
        (transactionFixture (fromGregorian 2026 7 2) "second" 100)
      declarations =
        [ declarePlanCompletion (committedPlanId plan) firstActualId
        , declarePlanCompletion (committedPlanId plan) secondActualId
        ]

  assertLeftSatisfies "multiple Actuals cannot silently complete one Plan"
    (any isCompeting . NonEmpty.toList)
    (resolvePlanCompletionEvidence
      [plan]
      [firstActual, secondActual]
      declarations)
  where
    isCompeting err = case err of
      PlanReferencedByMultipleActuals _ actualIds ->
        NonEmpty.length actualIds == 2
      _ -> False

planFixture :: T.Text -> Integer -> CommittedOutgoingPlan
planFixture planIdValue =
  planFixtureOn planIdValue (fromGregorian 2026 8 8)

planFixtureOn :: T.Text -> Day -> Integer -> CommittedOutgoingPlan
planFixtureOn planIdValue plannedDate amountValue =
  mustRight (mkCommittedOutgoingPlan
    (mustRight (mkPlanId planIdValue))
    plannedDate
    "planned memo"
    (mustRight (mkPositiveAmount
      (mkAmount jpy (quantityFromInteger amountValue))))
    outgoingDirection)
  where
    jpy = mustRight (mkCommodity "JPY")
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

transactionFixture :: Day -> T.Text -> Integer -> Transaction
transactionFixture day description amountValue =
  mustRight (mkTransaction
    day
    description
    ( mkPosting expense (mkAmount jpy positiveQuantity)
      :| [mkPosting asset (mkAmount jpy negativeQuantity)]
    ))
  where
    jpy = mustRight (mkCommodity "JPY")
    asset = mustRight (mkAccount "assets:cash")
    expense = mustRight (mkAccount "expenses:wifi")
    positiveQuantity = quantityFromInteger amountValue
    negativeQuantity = quantityFromInteger (-amountValue)

exactlyOne :: Show value => [value] -> value
exactlyOne [value] = value
exactlyOne values = error ("expected exactly one value, got " ++ show values)

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

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

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    expected: " ++ show expected)
    putStrLn ("    but got:  " ++ show actual)
    exitFailure
