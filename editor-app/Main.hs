{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import HKernel.Actual.Journal (parseActualJournal)
import qualified HKernel.Editor.ActualAccountAppend as ActualAccountAppend
import qualified HKernel.Editor.ActualAppend as ActualAppend
import qualified HKernel.Editor.ActualReverse as ActualReverse
import HKernel.Editor.ActualWriter
import qualified HKernel.Editor.BudgetMovementAppend as BudgetMovementAppend
import HKernel.Editor.CLI
import qualified HKernel.Editor.IssueAppend as IssueAppend
import qualified HKernel.Editor.PlanLifecycle as PlanLifecycle
import HKernel.Household.BudgetMovement.TSV
  ( parseHouseholdBudgetMovements )
import HKernel.Household.Issue.TSV (parseHouseholdIssues)
import HKernel.Plan.Journal (parsePlanJournal)

die :: String -> IO a
die message = hPutStrLn stderr message >> exitFailure

main :: IO ()
main = do
  args <- getArgs
  case parseEditorCommand args of
    Left cliError ->
      die
        ("CLI admission failed: "
          <> renderCliError cliError
          <> "\n"
          <> usageText)
    Right (commitMode, command) -> executeCommand commitMode command

executeCommand :: CommitMode -> EditorCommand -> IO ()
executeCommand commitMode command = case command of
  AppendCmd journalFile intent -> do
    existingSource <- TIO.readFile journalFile
    case ActualAppend.prepareActualAppend existingSource intent of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          parseActualJournal
          journalFile
          existingSource
          (ActualAppend.candidateBlock preview)
          (ActualAppend.candidateCompleteSource preview)
          commitMode

  ReverseCmd journalFile intent -> do
    existingSource <- TIO.readFile journalFile
    case ActualReverse.prepareActualReverse existingSource intent of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          parseActualJournal
          journalFile
          existingSource
          (ActualReverse.candidateBlock preview)
          (ActualReverse.candidateCompleteSource preview)
          commitMode

  AccountCmd journalFile declaration -> do
    existingSource <- TIO.readFile journalFile
    case ActualAccountAppend.prepareActualAccountAppend existingSource declaration of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          parseActualJournal
          journalFile
          existingSource
          (ActualAccountAppend.candidateBlock preview)
          (ActualAccountAppend.candidateCompleteSource preview)
          commitMode

  BudgetMovementCmd tsvFile movement -> do
    existingSource <- TIO.readFile tsvFile
    case BudgetMovementAppend.prepareBudgetMovementAppend existingSource movement of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          parseHouseholdBudgetMovements
          tsvFile
          existingSource
          (BudgetMovementAppend.candidateBlock preview)
          (BudgetMovementAppend.candidateCompleteSource preview)
          commitMode

  IssueCmd tsvFile intent -> do
    existingSource <- TIO.readFile tsvFile
    case IssueAppend.prepareIssueAppend existingSource intent of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          parseHouseholdIssues
          tsvFile
          existingSource
          (IssueAppend.candidateBlock preview)
          (IssueAppend.candidateCompleteSource preview)
          commitMode

  PlanAddCmd planFile actualFile intent -> do
    planSource <- TIO.readFile planFile
    actualSource <- TIO.readFile actualFile
    case PlanLifecycle.preparePlanAdd planSource actualSource intent of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          parsePlanJournal
          planFile
          planSource
          (PlanLifecycle.addCandidateBlock preview)
          (PlanLifecycle.addCandidateCompleteSource preview)
          commitMode

  PlanFinishCmd planFile actualFile intent -> do
    planSource <- TIO.readFile planFile
    actualSource <- TIO.readFile actualFile
    case PlanLifecycle.preparePlanFinish planSource actualSource intent of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          parseActualJournal
          actualFile
          actualSource
          (PlanLifecycle.finishCandidateBlock preview)
          (PlanLifecycle.finishCandidateCompleteSource preview)
          commitMode

validationFailed :: Show error => NonEmpty.NonEmpty error -> IO a
validationFailed errors =
  die
    ("Validation errors:\n"
      <> unlines (map show (NonEmpty.toList errors)))

executePreview
  :: Show sourceError
  => (Text -> Either (NonEmpty.NonEmpty sourceError) admitted)
  -> FilePath
  -> Text
  -> Text
  -> Text
  -> CommitMode
  -> IO ()
executePreview admit sourceFile existingSource block completeSource commitMode = do
  TIO.putStrLn "--- Preview ---"
  TIO.putStr block
  TIO.putStrLn "---------------"

  case commitMode of
    PreviewOnly ->
      TIO.putStrLn
        "Run with --commit immediately after the command name to apply changes."
    CommitRequested -> do
      let writeIntent = WriteIntent
            { targetFilePath = sourceFile
            , expectedOldBytes = existingSource
            , candidateNewBytes = completeSource
            }
      writeResult <- publishWithAdmission admit writeIntent
      case writeResult of
        Right () -> TIO.putStrLn "Successfully updated source."
        Left writeError -> die ("Write failed: " <> show writeError)
