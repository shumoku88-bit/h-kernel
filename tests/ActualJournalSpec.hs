{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account
import HKernel.Actual.Journal
import HKernel.Journal (journalTransactions, parseJournal)
import HKernel.Ledger (transactionDescription)
import HKernel.Money
import HKernel.Plan
import HKernel.Plan.Completion
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeCompletionMetadataAdmission
  characterizeResolvedJournalAdmission
  rejectResolvedJournalTransactionDrift
  rejectResolvedJournalEqualCountTransactionDrift
  characterizeDetachedMetadataBoundary
  characterizeExplicitCompletionResolution
  characterizePlanReferenceWithoutEventIdentity
  characterizeReversalMetadataAdmission
  allowReverseOfReverse
  rejectReversalWithoutEventIdentity
  rejectUnknownReversalTarget
  rejectDuplicateReversalTarget
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

characterizeResolvedJournalAdmission :: IO ()
characterizeResolvedJournalAdmission = do
  let resolvedJournal = mustRight (parseJournal resolvedAccountingJournal)
      admitted = mustRight
        (admitActualJournalFromResolvedJournal resolvedJournal resolvedActualRoot)
      direct = mustRight (parseActualJournal resolvedAccountingJournal)

  assertEqual
    "resolved Account includes preserve the complete Actual semantic projection"
    direct
    admitted

rejectResolvedJournalTransactionDrift :: IO ()
rejectResolvedJournalTransactionDrift =
  assertLeftSatisfies
    "resolved admission rejects transactions not represented by the Actual root"
    (any isAlignmentMismatch . NonEmpty.toList)
    (admitActualJournalFromResolvedJournal driftedJournal resolvedActualRoot)
  where
    driftedJournal = mustRight (parseJournal driftedResolvedAccountingJournal)
    isAlignmentMismatch err = case err of
      ActualTransactionMetadataAlignmentMismatch 2 1 -> True
      _ -> False

rejectResolvedJournalEqualCountTransactionDrift :: IO ()
rejectResolvedJournalEqualCountTransactionDrift =
  assertLeftSatisfies
    "resolved admission rejects equal-count source evidence for a different Actual transaction"
    (any isSourceMismatch . NonEmpty.toList)
    (admitActualJournalFromResolvedJournal
      resolvedJournal
      equalCountDifferentActualRoot)
  where
    resolvedJournal = mustRight (parseJournal resolvedAccountingJournal)
    isSourceMismatch err = case err of
      ActualTransactionSourceAlignmentMismatch 1 -> True
      _ -> False

characterizeDetachedMetadataBoundary :: IO ()
characterizeDetachedMetadataBoundary = do
  let admitted = mustRight (parseActualJournal detachedEventMetadataJournal)
  assertEqual
    "metadata detached by a blank line does not identify the preceding Actual transaction"
    []
    (map (actualTransactionIdText . identifiedActualId)
      (actualJournalIdentifiedTransactions admitted))

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

characterizeReversalMetadataAdmission :: IO ()
characterizeReversalMetadataAdmission = do
  let admitted = mustRight (parseActualJournal reversalJournal)
  assertEqual "reverses metadata remains typed after Actual admission"
    [("actual-reversal-1", "actual-original")]
    [ ( actualTransactionIdText (reversalTransactionId declaration)
      , actualTransactionIdText (reversedTransactionId declaration)
      )
    | declaration <- actualJournalReversalDeclarations admitted
    ]

allowReverseOfReverse :: IO ()
allowReverseOfReverse = do
  let admitted = mustRight (parseActualJournal reverseOfReverseJournal)
  assertEqual "a reversal may itself be reversed through its durable identity"
    [ ("actual-reversal-1", "actual-original")
    , ("actual-reversal-2", "actual-reversal-1")
    ]
    [ ( actualTransactionIdText (reversalTransactionId declaration)
      , actualTransactionIdText (reversedTransactionId declaration)
      )
    | declaration <- actualJournalReversalDeclarations admitted
    ]

rejectReversalWithoutEventIdentity :: IO ()
rejectReversalWithoutEventIdentity =
  assertLeftSatisfies "reversal provenance requires its own explicit event-id"
    (any isMissingIdentity . NonEmpty.toList)
    (parseActualJournal reversalWithoutEventIdJournal)
  where
    isMissingIdentity err = case err of
      ActualReversalMissingEventId _ targetId ->
        actualTransactionIdText targetId == "actual-original"
      _ -> False

rejectUnknownReversalTarget :: IO ()
rejectUnknownReversalTarget =
  assertLeftSatisfies "reversal target must name an admitted Actual identity"
    (any isUnknownTarget . NonEmpty.toList)
    (parseActualJournal unknownReversalTargetJournal)
  where
    isUnknownTarget err = case err of
      UnknownActualReversalTarget reversalId targetId ->
        actualTransactionIdText reversalId == "actual-reversal-1"
          && actualTransactionIdText targetId == "actual-missing"
      _ -> False

rejectDuplicateReversalTarget :: IO ()
rejectDuplicateReversalTarget =
  assertLeftSatisfies "one target cannot be reversed directly more than once"
    (any isDuplicateTarget . NonEmpty.toList)
    (parseActualJournal duplicateReversalTargetJournal)
  where
    isDuplicateTarget err = case err of
      DuplicateActualReversalTarget targetId reversalIds ->
        actualTransactionIdText targetId == "actual-original"
          && map actualTransactionIdText (NonEmpty.toList reversalIds)
            == ["actual-reversal-1", "actual-reversal-2"]
      _ -> False

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

resolvedActualRoot :: T.Text
resolvedActualRoot = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-08-03 * completed payment"
  , "  ; event-id: actual-one"
  , "  ; plan-id: plan-wifi"
  , "  assets:cash      -300 JPY"
  , "  expenses:wifi    300 JPY"
  ]

equalCountDifferentActualRoot :: T.Text
equalCountDifferentActualRoot = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-08-03 * different payment"
  , "  ; event-id: actual-wrong-source"
  , "  ; plan-id: plan-wifi"
  , "  assets:cash      -301 JPY"
  , "  expenses:wifi    301 JPY"
  ]

resolvedAccountingJournal :: T.Text
resolvedAccountingJournal = declarations <> T.unlines
  [ "2026-08-03 * completed payment"
  , "  ; event-id: actual-one"
  , "  ; plan-id: plan-wifi"
  , "  assets:cash      -300 JPY"
  , "  expenses:wifi    300 JPY"
  ]

driftedResolvedAccountingJournal :: T.Text
driftedResolvedAccountingJournal = resolvedAccountingJournal <> T.unlines
  [ ""
  , "2026-08-04 * included transaction must not hide here"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  ]

detachedEventMetadataJournal :: T.Text
detachedEventMetadataJournal = declarations <> T.unlines
  [ "2026-08-02 * ordinary"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  , ""
  , "  ; event-id: actual-detached"
  ]

planWithoutEventIdJournal :: T.Text
planWithoutEventIdJournal = declarations <> T.unlines
  [ "2026-08-03 * completed payment"
  , "  ; plan-id: plan-wifi"
  , "  assets:cash      -300 JPY"
  , "  expenses:wifi    300 JPY"
  ]

reversalJournal :: T.Text
reversalJournal = declarations <> T.unlines
  [ "2026-08-01 * original"
  , "  ; event-id: actual-original"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  , ""
  , "2026-08-02 * reversal"
  , "  ; event-id: actual-reversal-1"
  , "  ; reverses: actual-original"
  , "  assets:cash      100 JPY"
  , "  expenses:wifi    -100 JPY"
  ]

reverseOfReverseJournal :: T.Text
reverseOfReverseJournal = reversalJournal <> T.unlines
  [ ""
  , "2026-08-03 * restore original effect"
  , "  ; event-id: actual-reversal-2"
  , "  ; reverses: actual-reversal-1"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  ]

reversalWithoutEventIdJournal :: T.Text
reversalWithoutEventIdJournal = declarations <> T.unlines
  [ "2026-08-01 * original"
  , "  ; event-id: actual-original"
  , "  assets:cash      -100 JPY"
  , "  expenses:wifi    100 JPY"
  , ""
  , "2026-08-02 * anonymous reversal"
  , "  ; reverses: actual-original"
  , "  assets:cash      100 JPY"
  , "  expenses:wifi    -100 JPY"
  ]

unknownReversalTargetJournal :: T.Text
unknownReversalTargetJournal = declarations <> T.unlines
  [ "2026-08-02 * orphan reversal"
  , "  ; event-id: actual-reversal-1"
  , "  ; reverses: actual-missing"
  , "  assets:cash      100 JPY"
  , "  expenses:wifi    -100 JPY"
  ]

duplicateReversalTargetJournal :: T.Text
duplicateReversalTargetJournal = reversalJournal <> T.unlines
  [ ""
  , "2026-08-03 * duplicate direct reversal"
  , "  ; event-id: actual-reversal-2"
  , "  ; reverses: actual-original"
  , "  assets:cash      100 JPY"
  , "  expenses:wifi    -100 JPY"
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

