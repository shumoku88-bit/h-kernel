{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import HKernel.Account.Journal (parseAccountJournal)
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
import HKernel.Journal (Journal)
import HKernel.Loader (loadJournal)
import HKernel.Plan.Journal (parsePlanJournal)
import System.FilePath ((</>), takeDirectory)

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
    resolvedJournal <- loadResolvedActualJournal journalFile
    case ActualAppend.prepareActualAppendFromResolvedJournal
        resolvedJournal existingSource intent of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          publishActualAppendFromResolvedJournal
          journalFile
          existingSource
          (ActualAppend.candidateBlock preview)
          (ActualAppend.candidateCompleteSource preview)
          commitMode

  ReverseCmd journalFile intent -> do
    existingSource <- TIO.readFile journalFile
    resolvedJournal <- loadResolvedActualJournal journalFile
    case ActualReverse.prepareActualReverseFromResolvedJournal
        resolvedJournal existingSource intent of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          publishActualAppendFromResolvedJournal
          journalFile
          existingSource
          (ActualReverse.candidateBlock preview)
          (ActualReverse.candidateCompleteSource preview)
          commitMode

  AccountCmd journalFile declaration -> do
    existingSource <- TIO.readFile journalFile
    if "accounts.journal" `T.isSuffixOf` T.pack journalFile
      then case ActualAccountAppend.prepareAccountJournalAppend existingSource declaration of
        Left errors -> validationFailed errors
        Right preview ->
          executePreview
            (publishWithAdmission parseAccountJournal)
            journalFile
            existingSource
            (ActualAccountAppend.accountCandidateBlock preview)
            (ActualAccountAppend.accountCandidateCompleteSource preview)
            commitMode
      else case ActualAccountAppend.prepareActualAccountAppend existingSource declaration of
        Left errors -> validationFailed errors
        Right preview ->
          executePreview
            (publishWithAdmission parseActualJournal)
            journalFile
            existingSource
            (ActualAccountAppend.candidateBlock preview)
            (ActualAccountAppend.candidateCompleteSource preview)
            commitMode

  BudgetMovementCmd targetFile movement -> do
    existingSource <- TIO.readFile targetFile
    if ".journal" `T.isSuffixOf` T.pack targetFile
      then do
        let dir = takeDirectory targetFile
            accountsFile = dir </> "accounts.journal"
        accountsText <- TIO.readFile accountsFile
        registry <- case parseAccountJournal accountsText of
          Left errors -> validationFailed errors
          Right r -> pure r
        case BudgetMovementAppend.prepareBudgetJournalMovementAppend registry existingSource movement of
          Left errors -> validationFailed errors
          Right preview ->
            executePreview
              (publishWithAdmission parseActualJournal)
              targetFile
              existingSource
              (BudgetMovementAppend.budgetJournalCandidateBlock preview)
              (BudgetMovementAppend.budgetJournalCandidateCompleteSource preview)
              commitMode
      else case BudgetMovementAppend.prepareBudgetMovementAppend existingSource movement of
        Left errors -> validationFailed errors
        Right preview ->
          executePreview
            (publishWithAdmission parseHouseholdBudgetMovements)
            targetFile
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
          (publishWithAdmission parseHouseholdIssues)
          tsvFile
          existingSource
          (IssueAppend.candidateBlock preview)
          (IssueAppend.candidateCompleteSource preview)
          commitMode

  PlanAddCmd planFile actualFile intent -> do
    planSource <- TIO.readFile planFile
    actualSource <- TIO.readFile actualFile
    resolvedActual <- loadResolvedActualJournal actualFile
    case PlanLifecycle.preparePlanAddFromResolvedActualJournal
        resolvedActual planSource actualSource intent of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          (publishWithAdmission parsePlanJournal)
          planFile
          planSource
          (PlanLifecycle.addCandidateBlock preview)
          (PlanLifecycle.addCandidateCompleteSource preview)
          commitMode

  PlanFinishCmd planFile actualFile intent -> do
    planSource <- TIO.readFile planFile
    actualSource <- TIO.readFile actualFile
    resolvedActual <- loadResolvedActualJournal actualFile
    case PlanLifecycle.preparePlanFinishFromResolvedActualJournal
        resolvedActual planSource actualSource intent of
      Left errors -> validationFailed errors
      Right preview ->
        executePreview
          publishActualAppendFromResolvedJournal
          actualFile
          actualSource
          (PlanLifecycle.finishCandidateBlock preview)
          (PlanLifecycle.finishCandidateCompleteSource preview)
          commitMode

loadResolvedActualJournal :: FilePath -> IO Journal
loadResolvedActualJournal sourceFile = do
  result <- loadJournal sourceFile
  case result of
    Left loadError -> die ("Actual Journal load failed: " <> show loadError)
    Right journal -> pure journal

validationFailed :: Show error => NonEmpty.NonEmpty error -> IO a
validationFailed errors =
  die
    ("Validation errors:\n"
      <> unlines (map show (NonEmpty.toList errors)))

executePreview
  :: Show sourceError
  => (WriteIntent -> IO (Either (WriteError sourceError) ()))
  -> FilePath
  -> Text
  -> Text
  -> Text
  -> CommitMode
  -> IO ()
executePreview publish sourceFile existingSource block completeSource commitMode = do
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
            , expectedOldBytes = ExpectedSource existingSource
            , candidateNewBytes = CandidateSource completeSource
            }
      writeResult <- publish writeIntent
      case writeResult of
        Right () -> TIO.putStrLn "Successfully updated source."
        Left writeError -> die ("Write failed: " <> show writeError)
