{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Application.Config (HouseholdSourcePaths(..), householdSourcePaths, mkHouseholdRoot)
import qualified HKernel.Editor.ActualAccountAppend as ActualAccountAppend
import qualified HKernel.Editor.ActualAppend as ActualAppend
import qualified HKernel.Editor.ActualReverse as ActualReverse
import HKernel.Editor.ActualWriter
import qualified HKernel.Editor.BudgetMovementAppend as BudgetMovementAppend
import HKernel.Editor.CLI
import qualified HKernel.Editor.IssueAppend as IssueAppend
import qualified HKernel.Editor.PlanLifecycle as PlanLifecycle
import HKernel.Household.Application
  ( HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , loadCanonicalHousehold
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Household.BudgetMovement.TSV
  ( parseHouseholdBudgetMovements )
import HKernel.Household.Issue.TSV (parseHouseholdIssues)
import HKernel.Journal (Journal)
import HKernel.Loader (loadJournal, loadJournalFromRootSource)
import System.FilePath ((</>), normalise, takeDirectory)

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
    let dir = takeDirectory journalFile
        rootDir = if dir == "" then "." else dir
    root <- case mkHouseholdRoot rootDir of
      Right r -> pure r
      Left _ -> case mkHouseholdRoot "." of
        Right r -> pure r
        Left _ -> error "unreachable"
    let paths = householdSourcePaths root
    if normalise journalFile == normalise (householdAccountsJournalPath paths)
      then case ActualAccountAppend.prepareAccountJournalAppend existingSource declaration of
        Left errors -> validationFailed errors
        Right preview ->
          executePreview
            (publishWithPathAdmission (\_ -> loadCanonicalHousehold root))
            journalFile
            existingSource
            (ActualAccountAppend.accountCandidateBlock preview)
            (ActualAccountAppend.accountCandidateCompleteSource preview)
            commitMode
      else case ActualAccountAppend.prepareActualAccountAppend existingSource declaration of
        Left errors -> validationFailed errors
        Right preview ->
          executePreview
            publishActualAppendFromResolvedJournal
            journalFile
            existingSource
            (ActualAccountAppend.candidateBlock preview)
            (ActualAccountAppend.candidateCompleteSource preview)
            commitMode

  BudgetMovementCmd targetFile movement -> do
    let dir = takeDirectory targetFile
        rootDir = if dir == "" then "." else dir
    root <- case mkHouseholdRoot rootDir of
      Right r -> pure r
      Left _ -> case mkHouseholdRoot "." of
        Right r -> pure r
        Left _ -> error "unreachable"
    let paths = householdSourcePaths root
    if normalise targetFile == normalise (householdBudgetJournalPath paths)
      then do
        snapshotResult <- loadCanonicalHouseholdWriteSnapshot root
        snapshot <- case snapshotResult of
          Left errors -> validationFailed errors
          Right value -> pure value
        let state = householdWriteSnapshotState snapshot
            registry = householdStateAccountsRegistry state
            existingSource = householdWriteSnapshotBudgetSource snapshot
        case BudgetMovementAppend.prepareBudgetJournalMovementAppend registry existingSource movement of
          Left errors -> validationFailed errors
          Right preview ->
            executePreview
              (publishWithPathAdmission (\_ -> loadCanonicalHousehold root))
              targetFile
              existingSource
              (BudgetMovementAppend.budgetJournalCandidateBlock preview)
              (BudgetMovementAppend.budgetJournalCandidateCompleteSource preview)
              commitMode
      else do
        existingSource <- TIO.readFile targetFile
        case BudgetMovementAppend.prepareBudgetMovementAppend existingSource movement of
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
    let dir = takeDirectory tsvFile
        rootDir = if dir == "" then "." else dir
    root <- case mkHouseholdRoot rootDir of
      Right r -> pure r
      Left _ -> case mkHouseholdRoot "." of
        Right r -> pure r
        Left _ -> error "unreachable"
    let paths = householdSourcePaths root
    if normalise tsvFile == normalise (householdIssuesPath paths)
      then do
        snapshotResult <- loadCanonicalHouseholdWriteSnapshot root
        snapshot <- case snapshotResult of
          Left errors -> validationFailed errors
          Right value -> pure value
        let existingSource = householdWriteSnapshotIssuesSource snapshot
        case IssueAppend.prepareIssueAppend existingSource intent of
          Left errors -> validationFailed errors
          Right preview ->
            executePreview
              (publishWithPathAdmission (\_ -> loadCanonicalHousehold root))
              tsvFile
              existingSource
              (IssueAppend.candidateBlock preview)
              (IssueAppend.candidateCompleteSource preview)
              commitMode
      else do
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
    resolvedPlan <- loadResolvedPlanJournal planFile planSource
    resolvedActual <- loadResolvedActualJournal actualFile
    case PlanLifecycle.preparePlanAddFromResolvedJournals
        resolvedPlan resolvedActual planSource actualSource intent of
      Left errors -> validationFailed errors
      Right preview -> do
        admitPlanCandidate planFile
          (PlanLifecycle.addCandidateCompleteSource preview)
        executePreview
          publishPlanJournalFromResolvedJournal
          planFile
          planSource
          (PlanLifecycle.addCandidateBlock preview)
          (PlanLifecycle.addCandidateCompleteSource preview)
          commitMode

  PlanEditCmd planFile actualFile intent -> do
    planSource <- TIO.readFile planFile
    actualSource <- TIO.readFile actualFile
    resolvedPlan <- loadResolvedPlanJournal planFile planSource
    resolvedActual <- loadResolvedActualJournal actualFile
    case PlanLifecycle.preparePlanEditFromResolvedJournals
        resolvedPlan resolvedActual planSource actualSource intent of
      Left errors -> validationFailed errors
      Right preview -> do
        admitPlanCandidate planFile
          (PlanLifecycle.editCandidateCompleteSource preview)
        executeReplacementPreview
          publishPlanJournalFromResolvedJournal
          planFile
          planSource
          (PlanLifecycle.editOriginalBlock preview)
          (PlanLifecycle.editCandidateBlock preview)
          (PlanLifecycle.editCandidateCompleteSource preview)
          commitMode

  PlanFinishCmd planFile actualFile intent -> do
    planSource <- TIO.readFile planFile
    actualSource <- TIO.readFile actualFile
    resolvedPlan <- loadResolvedPlanJournal planFile planSource
    resolvedActual <- loadResolvedActualJournal actualFile
    case PlanLifecycle.preparePlanFinishFromResolvedJournals
        resolvedPlan resolvedActual planSource actualSource intent of
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

loadResolvedPlanJournal :: FilePath -> Text -> IO Journal
loadResolvedPlanJournal sourceFile rootSource = do
  result <- loadJournalFromRootSource sourceFile rootSource
  case result of
    Left loadError -> die ("Plan Journal load failed: " <> show loadError)
    Right journal -> pure journal

admitPlanCandidate :: FilePath -> Text -> IO ()
admitPlanCandidate sourceFile candidateSource = do
  result <- admitPlanJournalRootSource sourceFile candidateSource
  case result of
    Left errors -> validationFailed errors
    Right _ -> pure ()

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
  putPreviewBlock block
  TIO.putStrLn "---------------"
  executePublication publish sourceFile existingSource completeSource commitMode

executeReplacementPreview
  :: Show sourceError
  => (WriteIntent -> IO (Either (WriteError sourceError) ()))
  -> FilePath
  -> Text
  -> Text
  -> Text
  -> Text
  -> CommitMode
  -> IO ()
executeReplacementPreview publish sourceFile existingSource originalBlock candidateBlock completeSource commitMode = do
  TIO.putStrLn "--- Before ---"
  putPreviewBlock originalBlock
  TIO.putStrLn "--- After ----"
  putPreviewBlock candidateBlock
  TIO.putStrLn "---------------"
  executePublication publish sourceFile existingSource completeSource commitMode

putPreviewBlock :: Text -> IO ()
putPreviewBlock block = do
  TIO.putStr block
  if "\n" `T.isSuffixOf` block
    then pure ()
    else TIO.putStrLn ""

executePublication
  :: Show sourceError
  => (WriteIntent -> IO (Either (WriteError sourceError) ()))
  -> FilePath
  -> Text
  -> Text
  -> CommitMode
  -> IO ()
executePublication publish sourceFile existingSource completeSource commitMode =
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