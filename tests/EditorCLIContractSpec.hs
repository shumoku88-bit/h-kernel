{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Editor.ActualAppend (intentDescription, intentMetadata)
import HKernel.Editor.ActualReverse
  ( reverseDescription
  , reverseEventId
  , reverseTargetId
  )
import HKernel.Editor.CLI
import HKernel.Editor.IssueAppend (intentAmount, intentDetails)
import HKernel.Editor.PlanLifecycle (addDate, finishActualEventId)
import HKernel.Household.BudgetMovement (householdBudgetMovementMemo)
import HKernel.Plan.Completion (actualTransactionIdText)

main :: IO ()
main = do
  let results =
        [ ("append command accepts canonical event-id parameter", testAppendExplicitEventId)
        , ("append command without explicit event-id is rejected", testAppendOldGrammarRejected)
        , ("append command rejects non-canonical event-ids", testAppendInvalidEventIds)
        , ("budget usage shape is admitted", testBudgetUsageShape)
        , ("budget extra argument is rejected", testBudgetExtraArgument)
        , ("budget memo named --commit remains data", testBudgetCommitTextIsData)
        , ("commit is admitted after the leaf command", testCommandLocalCommit)
        , ("reverse admits canonical new ID + legacy target ID", testReverseCanonicalNewAndLegacyTarget)
        , ("reverse admits canonical new ID + plan-derived target ID", testReverseCanonicalNewAndPlanDerivedTarget)
        , ("reverse rejects non-canonical new IDs", testReverseInvalidNewIds)
        , ("reverse rejects malformed target IDs", testReverseMalformedTargetId)
        , ("Issue amount pair rejects one-sided omission", testIssueAmountPair)
        , ("Issue blank amount and details are preserved", testIssueBlankAmount)
        , ("Plan add requires explicit date", testPlanAddDateRequired)
        , ("Plan finish accepts canonical event-id", testPlanFinishCanonicalEventId)
        , ("Plan finish requires explicit event-id", testPlanFinishEventIdRequired)
        , ("Plan finish rejects non-canonical event-ids", testPlanFinishInvalidEventIds)
        , ("Plan finish permits option order independence", testPlanFinishOptionOrderIndependence)
        , ("Plan finish requires explicit actual date", testPlanFinishDateRequired)
        , ("Plan finish rejects negative actual amount", testPlanFinishNegativeAmount)
        , ("Plan finish rejects zero actual amount", testPlanFinishZeroAmount)
        , ("Plan add admits command-local commit", testPlanAddCommit)
        , ("usage text contains --event-id with canonical format", testUsageTextContainsEventId)
        , ("usage text for reverse command contains <evt-uuid-v4> and <target-actual-id>", testUsageTextReverseCommand)
        ]
  mapM_ print results
  if all snd results
    then exitSuccess
    else exitFailure

testAppendExplicitEventId :: Bool
testAppendExplicitEventId = case parseEditorCommand
  [ "append"
  , "--commit"
  , "actual.journal"
  , "evt-550e8400-e29b-41d4-a716-446655440010"
  , "2026-08-05"
  , "Groceries"
  , "expenses:food"
  , "100"
  , "JPY"
  ] of
    Right (CommitRequested, AppendCmd "actual.journal" intent) ->
      intentDescription intent == "Groceries"
        && intentMetadata intent == [("event-id", "evt-550e8400-e29b-41d4-a716-446655440010")]
    _ -> False

testAppendOldGrammarRejected :: Bool
testAppendOldGrammarRejected = case parseEditorCommand
  [ "append"
  , "actual.journal"
  , "2026-08-05"
  , "Groceries"
  , "expenses:food"
  , "100"
  , "JPY"
  ] of
    Left CliInvalidActualTransactionId -> True
    Left CliInvalidDate -> True
    Left CliUsage -> True
    _ -> False

testAppendInvalidEventIds :: Bool
testAppendInvalidEventIds =
  all isRejected
    [ "invalid event id with spaces"
    , "evt-synthetic-cli-001"
    , "banana"
    , "evt-550E8400-E29B-41D4-A716-446655440010"
    , "evt-550e8400-e29b-11d4-a716-446655440010"
    , "550e8400-e29b-41d4-a716-446655440010"
    ]
  where
    isRejected eventIdText = parseEditorCommand
      [ "append"
      , "actual.journal"
      , eventIdText
      , "2026-08-05"
      , "Groceries"
      , "expenses:food"
      , "100"
      , "JPY"
      ] == Left CliInvalidActualTransactionId

testBudgetUsageShape :: Bool
testBudgetUsageShape = case parseEditorCommand
  [ "budget"
  , "budget.tsv"
  , "2026-08-05"
  , "move"
  , "budget:daily"
  , "budget:flex"
  , "100"
  , "JPY"
  ] of
    Right (PreviewOnly, BudgetMovementCmd "budget.tsv" movement) ->
      householdBudgetMovementMemo movement == "move"
    _ -> False

testBudgetExtraArgument :: Bool
testBudgetExtraArgument =
  parseEditorCommand
    [ "budget"
    , "budget.tsv"
    , "2026-08-05"
    , "move"
    , "budget:daily"
    , "budget:flex"
    , "100"
    , "JPY"
    , "extra"
    ] == Left CliInvalidBudgetArguments

testBudgetCommitTextIsData :: Bool
testBudgetCommitTextIsData = case parseEditorCommand
  [ "budget"
  , "budget.tsv"
  , "2026-08-05"
  , "--commit"
  , "budget:daily"
  , "budget:flex"
  , "100"
  , "JPY"
  ] of
    Right (PreviewOnly, BudgetMovementCmd _ movement) ->
      householdBudgetMovementMemo movement == "--commit"
    _ -> False

testCommandLocalCommit :: Bool
testCommandLocalCommit = case parseEditorCommand
  [ "reverse"
  , "--commit"
  , "actual.journal"
  , "evt-550e8400-e29b-41d4-a716-446655440200"
  , "event-123"
  , "2026-08-05"
  , "refund"
  , "--commit"
  ] of
    Right (CommitRequested, ReverseCmd _ intent) ->
      actualTransactionIdText (reverseEventId intent) == "evt-550e8400-e29b-41d4-a716-446655440200"
        && actualTransactionIdText (reverseTargetId intent) == "event-123"
        && reverseDescription intent == "refund --commit"
    _ -> False

testReverseCanonicalNewAndLegacyTarget :: Bool
testReverseCanonicalNewAndLegacyTarget = case parseEditorCommand
  [ "reverse"
  , "actual.journal"
  , "evt-550e8400-e29b-41d4-a716-446655440200"
  , "event-123"
  , "2026-08-05"
  , "refund"
  ] of
    Right (PreviewOnly, ReverseCmd "actual.journal" intent) ->
      actualTransactionIdText (reverseEventId intent) == "evt-550e8400-e29b-41d4-a716-446655440200"
        && actualTransactionIdText (reverseTargetId intent) == "event-123"
    _ -> False

testReverseCanonicalNewAndPlanDerivedTarget :: Bool
testReverseCanonicalNewAndPlanDerivedTarget = case parseEditorCommand
  [ "reverse"
  , "actual.journal"
  , "evt-550e8400-e29b-41d4-a716-446655440200"
  , "plan-completion-plan-alpha"
  , "2026-08-05"
  , "reverse plan completion"
  ] of
    Right (PreviewOnly, ReverseCmd "actual.journal" intent) ->
      actualTransactionIdText (reverseEventId intent) == "evt-550e8400-e29b-41d4-a716-446655440200"
        && actualTransactionIdText (reverseTargetId intent) == "plan-completion-plan-alpha"
    _ -> False

testReverseInvalidNewIds :: Bool
testReverseInvalidNewIds =
  all isRejected
    [ "banana"
    , "event-124"
    , "evt-synthetic-reversal"
    , "missing-prefix"
    , "evt-550E8400-E29B-41D4-A716-446655440200"
    , "evt-550e8400-e29b-11d4-a716-446655440200"
    , "evt-550e8400-e29b-31d4-a716-446655440200"
    , "evt-550e8400-e29b-51d4-a716-446655440200"
    , "evt-00000000-0000-0000-0000-000000000000"
    , "evt-550e8400-e29b-41d4-c716-446655440200"
    , "evt-550e8400-e29b-41d4-a716-446655440200 extra"
    , " evt-550e8400-e29b-41d4-a716-446655440200"
    ]
  where
    isRejected newIdText = parseEditorCommand
      [ "reverse"
      , "actual.journal"
      , newIdText
      , "event-123"
      , "2026-08-05"
      , "refund"
      ] == Left CliInvalidActualTransactionId

testReverseMalformedTargetId :: Bool
testReverseMalformedTargetId =
  parseEditorCommand
    [ "reverse"
    , "actual.journal"
    , "evt-550e8400-e29b-41d4-a716-446655440200"
    , "target with spaces"
    , "2026-08-05"
    , "refund"
    ] == Left CliInvalidActualTransactionId

testIssueAmountPair :: Bool
testIssueAmountPair =
  parseEditorCommand
    [ "issue"
    , "issues.tsv"
    , "ISSUE-2"
    , "open"
    , "2026-08-05"
    , "misc"
    , "title"
    , "-"
    , "JPY"
    ] == Left CliIssueAmountPairRequired

testIssueBlankAmount :: Bool
testIssueBlankAmount = case parseEditorCommand
  [ "issue"
  , "issues.tsv"
  , "ISSUE-2"
  , "open"
  , "2026-08-05"
  , "misc"
  , "title"
  , "-"
  , "-"
  , "keep"
  , "--commit"
  ] of
    Right (PreviewOnly, IssueCmd _ intent) ->
      intentAmount intent == Nothing
        && intentDetails intent == "keep --commit"
    _ -> False

testPlanAddDateRequired :: Bool
testPlanAddDateRequired =
  parseEditorCommand
    [ "plan"
    , "add"
    , "plan.journal"
    , "actual.journal"
    , "--description"
    , "meal"
    , "--posting"
    , "expenses:food"
    , "100"
    , "JPY"
    ] == Left CliPlanAddDateRequired

testPlanFinishCanonicalEventId :: Bool
testPlanFinishCanonicalEventId = case parseEditorCommand
  [ "plan"
  , "finish"
  , "--commit"
  , "plan.journal"
  , "actual.journal"
  , "--id"
  , "plan-2026-08-05-meal"
  , "--event-id"
  , "evt-550e8400-e29b-41d4-a716-446655440100"
  , "--actual-date"
  , "2026-08-05"
  , "--actual-amount"
  , "500"
  ] of
    Right (CommitRequested, PlanFinishCmd "plan.journal" "actual.journal" intent) ->
      actualTransactionIdText (finishActualEventId intent) == "evt-550e8400-e29b-41d4-a716-446655440100"
    _ -> False

testPlanFinishEventIdRequired :: Bool
testPlanFinishEventIdRequired =
  parseEditorCommand
    [ "plan"
    , "finish"
    , "plan.journal"
    , "actual.journal"
    , "--id"
    , "plan-2026-08-05-meal"
    , "--actual-date"
    , "2026-08-05"
    ] == Left CliPlanFinishEventIdRequired

testPlanFinishInvalidEventIds :: Bool
testPlanFinishInvalidEventIds =
  all isRejected
    [ "banana"
    , "evt-legacy-plan-finish"
    , "evt-550E8400-E29B-41D4-A716-446655440100"
    , "evt-550e8400-e29b-11d4-a716-446655440100"
    , "evt-550e8400-e29b-51d4-a716-446655440100"
    , "550e8400-e29b-41d4-a716-446655440100"
    ]
  where
    isRejected eventIdText = parseEditorCommand
      [ "plan"
      , "finish"
      , "plan.journal"
      , "actual.journal"
      , "--id"
      , "plan-2026-08-05-meal"
      , "--event-id"
      , eventIdText
      , "--actual-date"
      , "2026-08-05"
      ] == Left CliInvalidActualTransactionId

testPlanFinishOptionOrderIndependence :: Bool
testPlanFinishOptionOrderIndependence = case parseEditorCommand
  [ "plan"
  , "finish"
  , "plan.journal"
  , "actual.journal"
  , "--actual-date"
  , "2026-08-05"
  , "--event-id"
  , "evt-550e8400-e29b-41d4-a716-446655440100"
  , "--actual-amount"
  , "500"
  , "--id"
  , "plan-2026-08-05-meal"
  ] of
    Right (PreviewOnly, PlanFinishCmd _ _ intent) ->
      actualTransactionIdText (finishActualEventId intent) == "evt-550e8400-e29b-41d4-a716-446655440100"
    _ -> False

testPlanFinishDateRequired :: Bool
testPlanFinishDateRequired =
  parseEditorCommand
    [ "plan"
    , "finish"
    , "plan.journal"
    , "actual.journal"
    , "--id"
    , "plan-2026-08-05-meal"
    , "--event-id"
    , "evt-550e8400-e29b-41d4-a716-446655440100"
    ] == Left CliPlanFinishDateRequired

testPlanFinishNegativeAmount :: Bool
testPlanFinishNegativeAmount =
  parseEditorCommand
    [ "plan"
    , "finish"
    , "plan.journal"
    , "actual.journal"
    , "--id"
    , "plan-2026-08-05-meal"
    , "--event-id"
    , "evt-550e8400-e29b-41d4-a716-446655440100"
    , "--actual-date"
    , "2026-08-05"
    , "--actual-amount"
    , "-100"
    ] == Left CliPlanFinishAmountMustBePositive

testPlanFinishZeroAmount :: Bool
testPlanFinishZeroAmount =
  parseEditorCommand
    [ "plan"
    , "finish"
    , "plan.journal"
    , "actual.journal"
    , "--id"
    , "plan-2026-08-05-meal"
    , "--event-id"
    , "evt-550e8400-e29b-41d4-a716-446655440100"
    , "--actual-date"
    , "2026-08-05"
    , "--actual-amount"
    , "0"
    ] == Left CliPlanFinishAmountMustBePositive

testPlanAddCommit :: Bool
testPlanAddCommit = case parseEditorCommand
  [ "plan"
  , "add"
  , "--commit"
  , "plan.journal"
  , "actual.journal"
  , "--date"
  , "2026-08-05"
  , "--description"
  , "meal"
  , "--posting"
  , "expenses:food"
  , "100"
  , "JPY"
  ] of
    Right (CommitRequested, PlanAddCmd _ _ intent) ->
      addDate intent == fromGregorian 2026 8 5
    _ -> False

testUsageTextContainsEventId :: Bool
testUsageTextContainsEventId =
  "--event-id EVT-UUID-V4" `elem` lines usageText
    || any (\l -> "--event-id" `elem` words l && "EVT-UUID-V4" `elem` words l) (lines usageText)

testUsageTextReverseCommand :: Bool
testUsageTextReverseCommand =
  any (\l -> "reverse" `elem` words l && "<evt-uuid-v4>" `elem` words l && "<target-actual-id>" `elem` words l) (lines usageText)
