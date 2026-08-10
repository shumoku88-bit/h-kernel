{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Editor.ActualReverse
  ( reverseDescription
  , reverseEventId
  , reverseTargetId
  )
import HKernel.Editor.CLI
import HKernel.Editor.IssueAppend (intentAmount, intentDetails)
import HKernel.Editor.PlanCompleteAdvance (positivePlanMagnitudeQuantity)
import HKernel.Editor.PlanLifecycle
  ( addDate
  , editAmount
  , editDate
  , editPlanId
  , positivePlanEditAmountQuantity
  )
import HKernel.Household.BudgetMovement (householdBudgetMovementMemo)
import HKernel.Money (quantityFromInteger)
import HKernel.Plan.Completion (actualTransactionIdText)

main :: IO ()
main = do
  let results =
        [ ("budget usage shape is admitted", testBudgetUsageShape)
        , ("budget extra argument is rejected", testBudgetExtraArgument)
        , ("budget memo named --commit remains data", testBudgetCommitTextIsData)
        , ("commit is admitted after the leaf command", testCommandLocalCommit)
        , ("reverse admits new and target identities", testReverseIdentityAdmission)
        , ("Issue amount pair rejects one-sided omission", testIssueAmountPair)
        , ("Issue blank amount and details are preserved", testIssueBlankAmount)
        , ("Plan add requires explicit date", testPlanAddDateRequired)
        , ("Plan edit admits identity date and amount", testPlanEditAdmission)
        , ("Plan edit requires identity", testPlanEditIdRequired)
        , ("Plan edit requires at least one change coordinate", testPlanEditChangeRequired)
        , ("Plan edit rejects non-positive amount", testPlanEditNonPositiveAmount)
        , ("Plan edit admits command-local commit", testPlanEditCommit)
        , ("Plan finish admits direct identity date and amount", testPlanFinishAdmission)
        , ("Plan finish requires explicit actual date", testPlanFinishDateRequired)
        , ("Plan finish rejects negative actual amount", testPlanFinishNegativeAmount)
        , ("Plan finish rejects zero actual amount", testPlanFinishZeroAmount)
        , ("Plan add admits command-local commit", testPlanAddCommit)
        ]
  mapM_ print results
  if all snd results
    then exitSuccess
    else exitFailure

testBudgetUsageShape :: Bool
testBudgetUsageShape = case parseEditorCommand
  [ "budget"
  , "budget_alloc.tsv"
  , "2026-08-05"
  , "move"
  , "budget:daily"
  , "budget:flex"
  , "100"
  , "JPY"
  ] of
    Right (PreviewOnly, BudgetMovementCmd "budget_alloc.tsv" movement) ->
      householdBudgetMovementMemo movement == "move"
    _ -> False

testBudgetExtraArgument :: Bool
testBudgetExtraArgument =
  parseEditorCommand
    [ "budget"
    , "budget_alloc.tsv"
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
  , "budget_alloc.tsv"
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
  , "event-124"
  , "event-123"
  , "2026-08-05"
  , "refund"
  , "--commit"
  ] of
    Right (CommitRequested, ReverseCmd _ intent) ->
      reverseDescription intent == "refund --commit"
    _ -> False

testReverseIdentityAdmission :: Bool
testReverseIdentityAdmission = case parseEditorCommand
  [ "reverse"
  , "actual.journal"
  , "event-124"
  , "event-123"
  , "2026-08-05"
  , "refund"
  ] of
    Right (PreviewOnly, ReverseCmd "actual.journal" intent) ->
      actualTransactionIdText (reverseEventId intent) == "event-124"
        && actualTransactionIdText (reverseTargetId intent) == "event-123"
    _ -> False

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

testPlanEditAdmission :: Bool
testPlanEditAdmission = case parseEditorCommand
  [ "plan"
  , "edit"
  , "plan.journal"
  , "actual.journal"
  , "--id"
  , "plan-2026-08-05-meal"
  , "--date"
  , "2026-08-06"
  , "--amount"
  , "250"
  ] of
    Right (PreviewOnly, PlanEditCmd "plan.journal" "actual.journal" intent) ->
      editPlanId intent == "plan-2026-08-05-meal"
        && editDate intent == Just (fromGregorian 2026 8 6)
        && fmap positivePlanEditAmountQuantity (editAmount intent)
          == Just (quantityFromInteger 250)
    _ -> False

testPlanEditIdRequired :: Bool
testPlanEditIdRequired =
  parseEditorCommand
    [ "plan"
    , "edit"
    , "plan.journal"
    , "actual.journal"
    , "--date"
    , "2026-08-06"
    ] == Left CliPlanEditIdRequired

testPlanEditChangeRequired :: Bool
testPlanEditChangeRequired =
  parseEditorCommand
    [ "plan"
    , "edit"
    , "plan.journal"
    , "actual.journal"
    , "--id"
    , "plan-2026-08-05-meal"
    ] == Left CliPlanEditChangeRequired

testPlanEditNonPositiveAmount :: Bool
testPlanEditNonPositiveAmount =
  parseEditorCommand
    [ "plan"
    , "edit"
    , "plan.journal"
    , "actual.journal"
    , "--id"
    , "plan-2026-08-05-meal"
    , "--amount"
    , "0"
    ] == Left CliPlanEditAmountMustBePositive

testPlanEditCommit :: Bool
testPlanEditCommit = case parseEditorCommand
  [ "plan"
  , "edit"
  , "--commit"
  , "plan.journal"
  , "actual.journal"
  , "--id"
  , "plan-2026-08-05-meal"
  , "--date"
  , "2026-08-06"
  ] of
    Right (CommitRequested, PlanEditCmd _ _ intent) ->
      editDate intent == Just (fromGregorian 2026 8 6)
    _ -> False

testPlanFinishAdmission :: Bool
testPlanFinishAdmission = case parseEditorCommand
  [ "plan"
  , "finish"
  , "plan.journal"
  , "actual.journal"
  , "--id"
  , "plan-2026-08-05-meal"
  , "--actual-date"
  , "2026-08-06"
  , "--actual-amount"
  , "275"
  ] of
    Right
      ( PreviewOnly
      , PlanFinishCmd "plan.journal" "actual.journal" planId actualDate amount
      ) ->
        planId == "plan-2026-08-05-meal"
          && actualDate == fromGregorian 2026 8 6
          && fmap positivePlanMagnitudeQuantity amount
            == Just (quantityFromInteger 275)
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