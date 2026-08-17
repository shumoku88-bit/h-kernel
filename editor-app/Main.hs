{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError, tryIOError)

import HKernel.Actual.Journal
  ( admitActualJournalFromResolvedJournal
  )
import HKernel.Application.Config
  ( HouseholdRoot
  , HouseholdRootError(..)
  , HouseholdSourcePaths(..)
  , householdSourcePaths
  , mkHouseholdRoot
  )
import qualified HKernel.Editor.AccountAppend as AccountAppend
import qualified HKernel.Editor.ActualAppend as ActualAppend
import qualified HKernel.Editor.ActualReverse as ActualReverse
import HKernel.Editor.SourcePublication
import qualified HKernel.Editor.EntitlementTransferAppend as EntitlementTransferAppend
import HKernel.Editor.CLI
import qualified HKernel.Editor.HouseholdWorkspace as HouseholdWorkspace
import qualified HKernel.Editor.IssueAppend as IssueAppend
import qualified HKernel.Editor.PlanCompleteAdvance as PlanCompleteAdvance
import qualified HKernel.Editor.PlanLifecycle as PlanLifecycle
import HKernel.Household.Application
  ( HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , loadCanonicalHousehold
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Household.EnvelopeHistory (householdEnvelopeRegistry)
import HKernel.Household.Issue.TSV (parseHouseholdIssues)
import HKernel.Journal (Journal)
import HKernel.Loader (loadJournal, loadJournalFromRootSource)
import HKernel.Plan (mkPlanId)
import HKernel.Plan.Journal (admitPlanJournalFromResolvedJournal)
import System.FilePath (normalise, takeDirectory)

die :: String -> IO a
die message = hPutStrLn stderr message >> exitFailure

resolveHouseholdRoot
  :: FilePath
  -> Either HouseholdRootError HouseholdRoot
resolveHouseholdRoot targetFile =
  let dir = takeDirectory targetFile
      rootDir = if null dir then "." else dir
  in mkHouseholdRoot rootDir

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
    root <- case resolveHouseholdRoot journalFile of
      Left err -> die ("Invalid Household root: " <> show err)
      Right r -> pure r
    let paths = householdSourcePaths root
    if normalise journalFile == normalise (householdAccountsJournalPath paths)
      then case AccountAppend.prepareAccountJournalAppend existingSource declaration of
        Left errors -> validationFailed errors
        Right preview ->
          executePreview
            (publishWithPathAdmission (\_ -> loadCanonicalHousehold root))
            journalFile
            existingSource
            (AccountAppend.accountCandidateBlock preview)
            (AccountAppend.accountCandidateCompleteSource preview)
            commitMode
      else case AccountAppend.prepareActualAccountAppend existingSource declaration of
        Left errors -> validationFailed errors
        Right preview ->
          executePreview
            publishActualAppendFromResolvedJournal
            journalFile
            existingSource
            (AccountAppend.candidateBlock preview)
            (AccountAppend.candidateCompleteSource preview)
            commitMode

  EntitlementTransferCmd targetFile transfer -> do
    root <- case resolveHouseholdRoot targetFile of
      Left err -> die ("Invalid Household root: " <> show err)
      Right r -> pure r
    let paths = householdSourcePaths root
    if normalise targetFile /= normalise (householdEntitlementJournalPath paths)
      then die "Entitlement transfer command only accepts canonical entitlement.journal"
      else do
        snapshotResult <- loadCanonicalHouseholdWriteSnapshot root
        snapshot <- case snapshotResult of
          Left errors -> validationFailed errors
          Right value -> pure value
        let state = householdWriteSnapshotState snapshot
            envelopePolicy = householdStateEnvelopePolicy state
            registry = householdEnvelopeRegistry (householdStateEnvelopeHistory state)
            existingSource = householdWriteSnapshotEntitlementSource snapshot
        case EntitlementTransferAppend.prepareCurrentEntitlementTransferAppend
            envelopePolicy registry existingSource transfer of
          Left errors -> validationFailed errors
          Right preview ->
            executePreview
              (publishWithPathAdmission (\_ -> loadCanonicalHousehold root))
              targetFile
              existingSource
              (EntitlementTransferAppend.entitlementCandidateBlock preview)
              (EntitlementTransferAppend.entitlementCandidateCompleteSource preview)
              commitMode

  IssueCmd tsvFile intent -> do
    root <- case resolveHouseholdRoot tsvFile of
      Left err -> die ("Invalid Household root: " <> show err)
      Right r -> pure r
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

  IssueRealizeCmd rootPath intent -> do
    root <- case mkHouseholdRoot rootPath of
      Left err -> die ("Invalid Household root: " <> show err)
      Right value -> pure value
    snapshotResult <- loadCanonicalHouseholdWriteSnapshot root
    snapshot <- case snapshotResult of
      Left errors -> validationFailed errors
      Right value -> pure value
    let state = householdWriteSnapshotState snapshot
        paths = householdStatePaths state
        actualSource = householdWriteSnapshotActualSource snapshot
        issuesSource = householdWriteSnapshotIssuesSource snapshot
        relationPath = householdIssueRelationsPath paths
    (relationExists, relationSource) <- readOptionalTextSource relationPath
    case HouseholdWorkspace.prepareIssueRealize
        (householdStateActualJournal state)
        (householdStatePlanJournal state)
        actualSource
        relationSource
        issuesSource
        intent of
      Left errors -> validationFailed errors
      Right preview -> executeIssueRealizePreview
        root paths snapshot relationExists relationSource intent preview commitMode

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

  PlanFinishCmd planFile actualFile planIdText actualDate actualAmount -> do
    planSource <- TIO.readFile planFile
    actualSource <- TIO.readFile actualFile
    resolvedPlan <- loadResolvedPlanJournal planFile planSource
    resolvedActual <- loadResolvedActualJournal actualFile
    planJournal <- case admitPlanJournalFromResolvedJournal resolvedPlan planSource of
      Left errors -> validationFailed errors
      Right value -> pure value
    actualJournal <- case admitActualJournalFromResolvedJournal resolvedActual actualSource of
      Left errors -> validationFailed errors
      Right value -> pure value
    planId <- case mkPlanId planIdText of
      Left planIdError -> validationFailed (pure planIdError)
      Right value -> pure value
    let completeIntent = PlanCompleteAdvance.PlanCompleteAdvanceIntent
          { PlanCompleteAdvance.completeAdvancePlanId = planId
          , PlanCompleteAdvance.completeAdvanceActualDate = actualDate
          , PlanCompleteAdvance.completeAdvanceActualAmount = actualAmount
          , PlanCompleteAdvance.completeAdvanceSuccessorDate = Nothing
          , PlanCompleteAdvance.completeAdvanceSuccessorAmount = Nothing
          }
    case PlanCompleteAdvance.preparePlanCompleteAdvance
        planJournal actualJournal planSource actualSource completeIntent of
      Left errors -> validationFailed errors
      Right preview -> executePlanFinishPreview
        planFile actualFile planSource actualSource preview commitMode

readOptionalTextSource :: FilePath -> IO (Bool, Text)
readOptionalTextSource path = do
  result <- tryIOError (TIO.readFile path)
  case result of
    Right source -> pure (True, source)
    Left errorValue
      | isDoesNotExistError errorValue -> pure (False, "")
      | otherwise -> die ("Source read failed: " <> show errorValue)

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

executeIssueRealizePreview
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> HouseholdWriteSnapshot
  -> Bool
  -> Text
  -> HouseholdWorkspace.IssueRealizeIntent
  -> HouseholdWorkspace.IssueRealizePreview
  -> CommitMode
  -> IO ()
executeIssueRealizePreview root paths snapshot relationExists relationSource intent preview commitMode = do
  TIO.putStrLn "--- Actual ---"
  putPreviewBlock (HouseholdWorkspace.realizedActualBlock preview)
  TIO.putStrLn "--- Relation --"
  putPreviewBlock (HouseholdWorkspace.realizedRelationBlock preview)
  TIO.putStrLn "--- Issue -----"
  putPreviewBlock (HouseholdWorkspace.realizedIssueBlock preview)
  TIO.putStrLn "---------------"
  case commitMode of
    PreviewOnly ->
      TIO.putStrLn
        "Run with --commit immediately after 'realize' to apply all three changes."
    CommitRequested -> do
      let state = householdWriteSnapshotState snapshot
          observed = HouseholdWorkspace.IssueRealizeObservedSources
            { HouseholdWorkspace.issueRealizeObservedActualPath =
                householdActualJournalPath paths
            , HouseholdWorkspace.issueRealizeObservedActualJournal =
                householdStateActualJournal state
            , HouseholdWorkspace.issueRealizeObservedActualSource =
                householdWriteSnapshotActualSource snapshot
            , HouseholdWorkspace.issueRealizeObservedPlanJournal =
                householdStatePlanJournal state
            , HouseholdWorkspace.issueRealizeObservedRelationPath =
                householdIssueRelationsPath paths
            , HouseholdWorkspace.issueRealizeObservedRelationExists = relationExists
            , HouseholdWorkspace.issueRealizeObservedRelationSource = relationSource
            , HouseholdWorkspace.issueRealizeObservedIssuesPath =
                householdIssuesPath paths
            , HouseholdWorkspace.issueRealizeObservedIssuesSource =
                householdWriteSnapshotIssuesSource snapshot
            }
      writeResult <- HouseholdWorkspace.publishIssueRealizeFromObservedSources
        (admitIssueRealizeAfterWrite root (householdIssueRelationsPath paths))
        observed
        intent
      case writeResult of
        Right () -> TIO.putStrLn "Successfully realized Issue as Actual."
        Left writeError -> die ("Write failed: " <> show writeError)

admitIssueRealizeAfterWrite
  :: HouseholdRoot
  -> FilePath
  -> IO (Either String ())
admitIssueRealizeAfterWrite root relationPath = do
  householdResult <- loadCanonicalHousehold root
  case householdResult of
    Left errors -> pure
      (Left ("Household post-admission failed: " <> show errors))
    Right state -> do
      relationRead <- tryIOError (TIO.readFile relationPath)
      case relationRead of
        Left errorValue -> pure
          (Left ("Relation post-admission read failed: " <> show errorValue))
        Right relationSource -> pure $ case HouseholdWorkspace.admitIssueRelationSource
            (householdStateActualJournal state)
            (householdStatePlanJournal state)
            (householdStateIssues state)
            relationSource of
          Left errors -> Left ("Relation post-admission failed: " <> show errors)
          Right _ -> Right ()

executePlanFinishPreview
  :: FilePath
  -> FilePath
  -> Text
  -> Text
  -> PlanCompleteAdvance.PlanCompleteAdvancePreview
  -> CommitMode
  -> IO ()
executePlanFinishPreview planFile actualFile planSource actualSource preview commitMode = do
  TIO.putStrLn "--- Preview ---"
  putPreviewBlock (PlanCompleteAdvance.completeAdvanceActualBlock preview)
  TIO.putStrLn "---------------"
  case commitMode of
    PreviewOnly ->
      TIO.putStrLn
        "Run with --commit immediately after the command name to apply changes."
    CommitRequested -> do
      let writeIntent = PlanCompleteAdvance.PlanCompleteAdvanceWriteIntent
            { PlanCompleteAdvance.writeActualPath = actualFile
            , PlanCompleteAdvance.writeExpectedActual = actualSource
            , PlanCompleteAdvance.writeCandidateActual =
                PlanCompleteAdvance.completeAdvanceActualSource preview
            , PlanCompleteAdvance.writePlanPath = planFile
            , PlanCompleteAdvance.writeExpectedPlan = planSource
            , PlanCompleteAdvance.writeCandidatePlan =
                PlanCompleteAdvance.completeAdvancePlanSource preview
            }
      writeResult <- PlanCompleteAdvance.publishPlanCompleteAdvance
        (admitPlanFinishPaths planFile actualFile)
        writeIntent
      case writeResult of
        Right () -> TIO.putStrLn "Successfully updated source."
        Left writeError -> die ("Write failed: " <> show writeError)

-- | Re-admit the two explicit Journal paths accepted by the CLI after the
-- coordinated writer installs both candidates. This deliberately does not
-- require a canonical Household root: the retained CLI grammar accepts explicit
-- Plan and Actual paths, while each Journal remains path-aware for includes.
admitPlanFinishPaths :: FilePath -> FilePath -> IO (Either String ())
admitPlanFinishPaths planFile actualFile = do
  actualResult <- admitActualJournalPath actualFile
  case actualResult of
    Left errors -> pure
      (Left ("Actual post-admission failed: " <> show errors))
    Right _ -> do
      planResult <- admitPlanJournalPath planFile
      pure $ case planResult of
        Left errors -> Left ("Plan post-admission failed: " <> show errors)
        Right _ -> Right ()

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
