{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account
import HKernel.Actual.Journal
import HKernel.Journal (journalTransactions)
import HKernel.Ledger (transactionDescription)
import HKernel.Money
import HKernel.Plan
import HKernel.Plan.Completion
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeCompletionMetadataAdmission
  characterizeExplicitCompletionResolution
  characterizePlanReferenceWithoutEventIdentity
  rejectDuplicateMetadataKey
  rejectDuplicateEventIdentity
  rejectInvalidPlanIdentity
  retainJournalSyntaxDiagnostics

characterizeCompletionMetadataAdmission :: IO ()
characterizeCompletionMetadataAdmission = do
  let admitted = mustRight (parseActualJournal validActualJournal)
      transactions = journalTransactions (actualJournalValue admitted)
      identified = actualJournalIdentifiedTransactions admitted
      declarations = actualJournalCompletionDeclarations admitted

  assertEqual "ordinary Actual transactions remain admitted without durable identity"
    ["ordinary", "durable unrelated", "completed payment"]
    (map transactionDescription transactions)
  assertEqual "explicit and derived identities create identified Actual facts"
    ["actual-durable", "plan-completion-plan-wifi"]
    (map (actualTransactionIdText . identifiedActualId) identified)
  assertEqual "only explicit plan-id metadata creates a completion declaration"
    [("plan-wifi", "plan-completion-plan-wifi")]
    [ ( planIdText (declaredCompletionPlanId declaration)
      , actualTransactionIdText (declaredCompletionActualId declaration)
      )
    | declaration <- declarations
    ]

characterizeExplicitCompletionResolution :: IO ()
characterizeExplicitCompletionResolution = do
  let admitted = mustRight (parseActualJournal validActualJournal)
      plan = planFixture
      evidence = exactlyOne (mustRight
        (resolvePlanCompletionEvidence
          [plan]
          (actualJournalIdentifiedTransactions admitted)
          (actualJournalCompletionDeclarations admitted)))

  assertEqual "source admission feeds the explicit completion resolver"
    (committedPlanId plan)
    (committedPlanId (completionPlan evidence))
  assertEqual "completion evidence retains the whole validated Actual transaction"
    "completed payment"
    (transactionDescription
      (identifiedActualTransaction (completionActual evidence)))

characterizePlanReferenceWithoutEventIdentity :: IO ()
characterizePlanReferenceWithoutEventIdentity = do
  let admitted = mustRight (parseActualJournal planWithoutEventIdJournal)
      identified = actualJournalIdentifiedTransactions admitted
      declarations = actualJournalCompletionDeclarations admitted

  assertEqual "plan-id derives one rebuildable runtime Actual identity"
    ["plan-completion-plan-wifi"]
    (map (actualTransactionIdText . identifiedActualId) identified)
  assertEqual "plan-id directly retains the explicit completion relation"
    [("plan-wifi", "plan-completion-plan-wifi")]
    [ ( planIdText (declaredCompletionPlanId declaration)
      , actualTransactionIdText (declaredCompletionActualId declaration)
      )
    | declaration <- declarations
    ]

rejectDuplicateMetadataKey :: IO ()
rejectDuplicateMetadataKey =
  assertLeftSatisfies "repeated event-id metadata is diagnosed"
    (any isDuplicateKey . NonEmpty.toList)
    (parseActualJournal duplicateEventKeyJournal)
  where
    isDuplicateKey err = case err of
      DuplicateActualMetadataKey _ "event-id" -> True
      _ -> False

rejectDuplicateEventIdentity :: IO ()
rejectDuplicateEventIdentity =
  assertLeftSatisfies "one durable Actual identity cannot name two transactions"
    (any isDuplicateIdentity . NonEmpty.toList)
    (parseActualJournal duplicateEventIdentityJournal)
  where
    isDuplicateIdentity err = case err of
      DuplicateActualEventIdDefinition _ lines' ->
        NonEmpty.length lines' == 2
      _ -> False

rejectInvalidPlanIdentity :: IO ()
rejectInvalidPlanIdentity =
  assertLeftSatisfies "invalid explicit Plan identity remains a typed source error"
    (any isInvalidPlan . NonEmpty.toList)
    (parseActualJournal invalidPlanIdJournal)
  where
    isInvalidPlan err = case err of
      InvalidActualPlanId _ _ -> True
      _ -> False

retainJournalSyntaxDiagnostics :: IO ()
retainJournalSyntaxDiagnostics =
  assertLeftSatisfies "accounting syntax remains owned by the canonical Journal parser"
    (any isJournalError . NonEmpty.toList)
    (parseActualJournal unbalancedActualJournal)
  where
    isJournalError err = case err of
      ActualJournalSyntaxError _ -> True
      _ -> False

validActualJournal :: T.Text
validActualJournal = declarations <> T.unlines
  [ "2026-08-01 * ordinary"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  , ""
  , "2026-08-02 * durable unrelated"
  , "  ; event-id: actual-durable"
  , "  assets:cash      -200 JPY"
  , "  expenses:wifi    200 JPY"
  , ""
  , "2026-08-03 * completed payment"
  , "  ; plan-id: plan-wifi"
  , "  assets:cash      -300 JPY"
  , "  expenses:wifi    300 JPY"
  ]

planWithoutEventIdJournal :: T.Text
planWithoutEventIdJournal = declarations <> T.unlines
  [ "2026-08-03 * completed payment"
  , "  ; plan-id: plan-wifi"
  , "  assets:cash      -300 JPY"
  , "  expenses:wifi    300 JPY"
  ]

duplicateEventKeyJournal :: T.Text
duplicateEventKeyJournal = declarations <> T.unlines
  [ "2026-08-03 * completed payment"
  , "  ; event-id: actual-one"
  , "  ; event-id: actual-two"
  , "  ; plan-id: plan-wifi"
  , "  assets:cash      -300 JPY"
  , "  expenses:wifi    300 JPY"
  ]

duplicateEventIdentityJournal :: T.Text
duplicateEventIdentityJournal = declarations <> T.unlines
  [ "2026-08-02 * first"
  , "  ; event-id: actual-duplicate"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  , ""
  , "2026-08-03 * second"
  , "  ; event-id: actual-duplicate"
  , "  assets:cash      -200 JPY"
  , "  expenses:wifi    200 JPY"
  ]

invalidPlanIdJournal :: T.Text
invalidPlanIdJournal = declarations <> T.unlines
  [ "2026-08-03 * completed payment"
  , "  ; event-id: actual-one"
  , "  ; plan-id: invalid plan id"
  , "  assets:cash      -300 JPY"
  , "  expenses:wifi    300 JPY"
  ]

unbalancedActualJournal :: T.Text
unbalancedActualJournal = declarations <> T.unlines
  [ "2026-08-03 * unbalanced"
  , "  ; event-id: actual-one"
  , "  assets:cash      -300 JPY"
  , "  expenses:wifi    200 JPY"
  ]

declarations :: T.Text
declarations = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:wifi"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  ]

planFixture :: CommittedOutgoingPlan
planFixture = mustRight (mkCommittedOutgoingPlan
  (mustRight (mkPlanId "plan-wifi"))
  (fromGregorian 2026 8 3)
  "Wi-Fi"
  (mustRight (mkPositiveAmount
    (mkAmount jpy (quantityFromInteger 300))))
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

exactlyOne :: Show value => [value] -> value
exactlyOne [value] = value
exactlyOne values = error ("expected exactly one value, got " ++ show values)

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

assertLeftSatisfies
  :: Show value
  => String
  -> (NonEmpty.NonEmpty error -> Bool)
  -> Either (NonEmpty.NonEmpty error) value
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
