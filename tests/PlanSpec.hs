{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import Data.Time.Calendar (fromGregorian)
import HKernel.Account
import HKernel.Money
import HKernel.Plan
import HKernel.Plan.Render
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizePlanIdentity
  characterizePositiveAmount
  characterizePaymentDirection
  characterizeDeclaredPaymentDirection
  characterizeOutgoingPaymentDirection
  characterizeCommittedOutgoingPlan
  characterizePlannedTransactionRendering

characterizePlanIdentity :: IO ()
characterizePlanIdentity = do
  let planId = mustRight (mkPlanId "plan-2026-001")

  assertEqual "plan identity retains its stable text"
    "plan-2026-001"
    (planIdText planId)
  assertLeft "empty plan identity is rejected"
    (mkPlanId "")
  assertLeft "plan identity with surrounding whitespace is rejected"
    (mkPlanId " plan-2026-001")
  assertLeft "plan identity with embedded whitespace is rejected"
    (mkPlanId "plan 2026 001")
  assertLeft "plan identity with a control character is rejected"
    (mkPlanId "plan\t2026")

characterizePositiveAmount :: IO ()
characterizePositiveAmount = do
  let jpy = mustRight (mkCommodity "JPY")
      amount = mkAmount jpy (quantityFromInteger 4810)
      positive = mustRight (mkPositiveAmount amount)

  assertEqual "positive amount retains its exact monetary value"
    amount
    (positiveAmountValue positive)
  assertLeft "zero is not a positive payment amount"
    (mkPositiveAmount (mkAmount jpy zeroQuantity))
  assertLeft "negative quantity is not a positive payment amount"
    (mkPositiveAmount (mkAmount jpy (quantityFromInteger (-4810))))

characterizePaymentDirection :: IO ()
characterizePaymentDirection = do
  let fromAccount = mustRight (mkAccount "assets:smbc")
      toAccount = mustRight (mkAccount "expenses:wifi")
      direction = mustRight (mkPaymentDirection fromAccount toAccount)

  assertEqual "payment direction retains its source account"
    fromAccount
    (paymentDirectionFrom direction)
  assertEqual "payment direction retains its destination account"
    toAccount
    (paymentDirectionTo direction)
  assertLeft "one account cannot be both sides of a payment direction"
    (mkPaymentDirection fromAccount fromAccount)

characterizeDeclaredPaymentDirection :: IO ()
characterizeDeclaredPaymentDirection = do
  let fromAccount = mustRight (mkAccount "assets:smbc")
      toAccount = mustRight (mkAccount "expenses:wifi")
      unknownSource = mustRight (mkAccount "assets:unknown")
      unknownDestination = mustRight (mkAccount "expenses:unknown")
      sourceDeclaration = declareAccount fromAccount Asset
      destinationDeclaration = declareAccount toAccount Expense
      direction = mustRight (mkPaymentDirection fromAccount toAccount)
      registry = mustRight $ do
        withSource <- registerAccount
          sourceDeclaration
          emptyAccountRegistry
        registerAccount destinationDeclaration withSource
      declared = mustRight (admitPaymentDirection registry direction)

  assertEqual "declared direction retains its source declaration"
    sourceDeclaration
    (declaredPaymentSource declared)
  assertEqual "declared direction retains its destination declaration"
    destinationDeclaration
    (declaredPaymentDestination declared)
  assertLeft "undeclared payment source is rejected"
    (admitPaymentDirection registry
      (mustRight (mkPaymentDirection unknownSource toAccount)))
  assertLeft "undeclared payment destination is rejected"
    (admitPaymentDirection registry
      (mustRight (mkPaymentDirection fromAccount unknownDestination)))

characterizeOutgoingPaymentDirection :: IO ()
characterizeOutgoingPaymentDirection = do
  let assetAccount = mustRight (mkAccount "assets:smbc")
      expenseAccount = mustRight (mkAccount "expenses:wifi")
      liabilityAccount = mustRight (mkAccount "liabilities:card")
      savingsAccount = mustRight (mkAccount "assets:savings")
      incomeAccount = mustRight (mkAccount "income:pension")
      expenseDirection = declaredDirectionFixtureWithTypes
        Asset Expense assetAccount expenseAccount
      liabilityDirection = declaredDirectionFixtureWithTypes
        Asset Liability assetAccount liabilityAccount
      assetTransfer = declaredDirectionFixtureWithTypes
        Asset Asset assetAccount savingsAccount
      incomingDirection = declaredDirectionFixtureWithTypes
        Income Asset incomeAccount assetAccount
      admittedExpense = mustRight
        (admitOutgoingPaymentDirection expenseDirection)

  assertEqual "outgoing direction retains its declared evidence"
    expenseDirection
    (declaredOutgoingPaymentDirection admittedExpense)
  assertEqual "Asset to Liability is an admitted outgoing commitment"
    liabilityDirection
    (declaredOutgoingPaymentDirection
      (mustRight (admitOutgoingPaymentDirection liabilityDirection)))
  assertLeft "Asset transfer requires a distinct Plan kind"
    (admitOutgoingPaymentDirection assetTransfer)
  assertLeft "Income to Asset cannot masquerade as an outgoing commitment"
    (admitOutgoingPaymentDirection incomingDirection)

characterizeCommittedOutgoingPlan :: IO ()
characterizeCommittedOutgoingPlan = do
  let planId = mustRight (mkPlanId "plan-2026-001")
      plannedDate = fromGregorian 2026 8 8
      jpy = mustRight (mkCommodity "JPY")
      amount = mustRight
        (mkPositiveAmount (mkAmount jpy (quantityFromInteger 4810)))
      fromAccount = mustRight (mkAccount "assets:smbc")
      toAccount = mustRight (mkAccount "expenses:wifi")
      direction = outgoingDirectionFixture fromAccount toAccount
      plan = mustRight (mkCommittedOutgoingPlan
        planId
        plannedDate
        "Wi-Fi支払い"
        amount
        direction)

  assertEqual "committed plan retains durable identity"
    planId
    (committedPlanId plan)
  assertEqual "committed plan retains its planned date"
    plannedDate
    (committedPlanDate plan)
  assertEqual "committed plan retains its complete memo"
    "Wi-Fi支払い"
    (committedPlanMemo plan)
  assertEqual "committed plan composes an admitted positive amount"
    amount
    (committedPlanAmount plan)
  assertEqual "committed plan composes an admitted outgoing direction"
    direction
    (committedPlanDirection plan)

  assertLeft "empty committed plan memo is rejected"
    (mkCommittedOutgoingPlan planId plannedDate "" amount direction)
  assertLeft "committed plan memo with surrounding whitespace is rejected"
    (mkCommittedOutgoingPlan
      planId plannedDate " Wi-Fi支払い" amount direction)
  assertLeft "committed plan memo cannot contain a hidden second line"
    (mkCommittedOutgoingPlan
      planId plannedDate "Wi-Fi支払い\n来週" amount direction)

characterizePlannedTransactionRendering :: IO ()
characterizePlannedTransactionRendering = do
  let planId = mustRight (mkPlanId "plan-2026-001")
      jpy = mustRight (mkCommodity "JPY")
      amount = mustRight
        (mkPositiveAmount (mkAmount jpy (quantityFromInteger 4810)))
      fromAccount = mustRight (mkAccount "assets:smbc")
      toAccount = mustRight (mkAccount "expenses:wifi")
      direction = outgoingDirectionFixture fromAccount toAccount
      plan = mustRight (mkCommittedOutgoingPlan
        planId
        (fromGregorian 2026 8 8)
        "Wi-Fi支払い"
        amount
        direction)

  assertEqual "planned transaction line publishes every admitted Plan fact"
    "2026-08-08 | plan-2026-001 | 4810 JPY | assets:smbc -> expenses:wifi | Wi-Fi支払い"
    (renderCommittedOutgoingPlanLine plan)

declaredDirectionFixture
  :: Account
  -> Account
  -> DeclaredPaymentDirection
declaredDirectionFixture =
  declaredDirectionFixtureWithTypes Asset Expense

outgoingDirectionFixture
  :: Account
  -> Account
  -> DeclaredOutgoingPaymentDirection
outgoingDirectionFixture fromAccount toAccount =
  mustRight (admitOutgoingPaymentDirection
    (declaredDirectionFixture fromAccount toAccount))

declaredDirectionFixtureWithTypes
  :: AccountType
  -> AccountType
  -> Account
  -> Account
  -> DeclaredPaymentDirection
declaredDirectionFixtureWithTypes sourceType destinationType fromAccount toAccount =
  mustRight (admitPaymentDirection registry direction)
  where
    direction = mustRight (mkPaymentDirection fromAccount toAccount)
    registry = mustRight $ do
      withSource <- registerAccount
        (declareAccount fromAccount sourceType)
        emptyAccountRegistry
      registerAccount
        (declareAccount toAccount destinationType)
        withSource



assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure


