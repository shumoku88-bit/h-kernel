{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Applicative ((<|>))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import HKernel.Account.Journal (parseAccountJournal)
import HKernel.Actual.Journal
  ( actualJournalValue
  , parseActualJournal
  )
import HKernel.CLI
import HKernel.Engine (DateRange, rangeEnd)
import HKernel.Envelope
import HKernel.Envelope.Render
import HKernel.Spike.HouseholdReport
import HKernel.Spike.HouseholdReport.Render
  ( renderHouseholdSourceErrors
  , renderReportBookWithHouseholdPresentation
  )
import HKernel.Journal
import HKernel.Loader (loadJournal)
import HKernel.Plan.Journal (parsePlanJournal)
import HKernel.Render
import HKernel.Report
import HKernel.Report.Config
import HKernel.Report.CycleAccounts (cycleAccounts)
import HKernel.Report.Plan
import HKernel.Report.Presentation
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (stderr)
import System.IO.Error (tryIOError)

main :: IO ()
main = do
  today <- localDay . zonedTimeToLocalTime <$> getZonedTime
  arguments <- getArgs
  case parseArguments today arguments of
    Left message -> dieWithUsage message
    Right (journalPath, command) -> do
      (resolvedPath, householdDirectory) <- resolveJournalInput journalPath
      run today resolvedPath householdDirectory command

resolveJournalInput :: FilePath -> IO (FilePath, Maybe FilePath)
resolveJournalInput requestedPath = do
  configuredDirectory <- resolveConfiguredLedgerDataDirectory
  case configuredDirectory of
    Just directory -> householdInput directory
    Nothing
      | requestedPath /= "journal.journal" -> pure (requestedPath, Nothing)
      | otherwise -> do
          hKernelJournal <- lookupEnv "HKERNEL_JOURNAL"
          ledgerFile <- lookupEnv "LEDGER_FILE"
          case hKernelJournal <|> ledgerFile of
            Just envPath -> pure (envPath, Nothing)
            Nothing -> do
              path <- findFirst defaultJournalCandidates
              pure (path, Nothing)
  where
    householdInput directory
      | requestedPath == "journal.journal" || requestedPath == actualPath =
          pure (actualPath, Just directory)
      | otherwise = dieText
          "HKERNEL_LEDGER_DATA_DIR cannot be combined with another Journal path"
      where
        actualPath = directory </> "actual.journal"

    findFirst [] = pure requestedPath
    findFirst (candidate : candidates) = do
      exists <- doesFileExist candidate
      if exists then pure candidate else findFirst candidates

run :: Day -> FilePath -> Maybe FilePath -> Command -> IO ()
run today journalPath householdDirectory command = do
  loadResult <- loadJournal journalPath
  journal <- case loadResult of
    Left err -> dieText (renderLoadError err)
    Right value -> pure value
  case command of
    RunJournal Check ->
      TIO.putStr (executeWithPresentation defaultPresentationConfig Check journal)
    RunJournal (RunDefaultReportBook day) -> do
      configuration <- loadReportConfiguration
      runDefaultReportBook day journal householdDirectory configuration
    RunJournal journalCommand -> do
      configuration <- loadReportConfiguration
      let presentation = maybe defaultPresentationConfig
            reportConfigurationPresentation configuration
      resolvedCommand <- case configuration of
        Nothing -> pure journalCommand
        Just configured -> case resolveReportPlan today journal (reportConfigurationPlan configured) of
          Left err -> dieText (renderReportPlanError err)
          Right resolvedPlan -> pure (applyReportPlanResolved resolvedPlan journalCommand)
      case resolvedCommand of
        RunReportBook dateRange -> runCombinedReport
          presentation (rangeEnd dateRange) (reportBook dateRange journal) journal
          householdDirectory
        _ -> TIO.putStr
          (executeWithPresentation presentation resolvedCommand journal)
    RunEnvelopeBudget policyPath dateRange ->
      runEnvelopeBudget policyPath dateRange journal

applyReportPlanResolved :: ResolvedReportPlan -> JournalCommand -> JournalCommand
applyReportPlanResolved plan command = case command of
  RunTrialBalance DefaultedDate _ ->
    RunTrialBalance DefaultedDate (resolvedTrialBalanceAsOf plan)
  RunBalanceSheet DefaultedDate _ ->
    RunBalanceSheet DefaultedDate (resolvedBalanceSheetAsOf plan)
  RunProfitAndLoss DefaultedDate _ ->
    RunProfitAndLoss DefaultedDate (resolvedProfitAndLossRange plan)
  RunDailyFlow DefaultedDate _ ->
    case resolvedDailyFlowSpec plan of
      ResolvedDailyFlowInRange range -> RunDailyFlow DefaultedDate range
      ResolvedDailyFlowThrough day -> RunDailyFlow DefaultedDate (defaultDateRange day)
  RunMonthlyAccounts DefaultedDate _ ->
    RunMonthlyAccounts DefaultedDate (resolvedMonthlyAccountsRange plan)
  RunRecentTransactions DefaultedDate _ ->
    RunRecentTransactions DefaultedDate (resolvedRecentTransactionsAsOf plan)
  other -> other

loadReportConfiguration :: IO (Maybe ReportConfiguration)
loadReportConfiguration = do
  configPath <- resolveReportConfigPath
  case configPath of
    Nothing -> pure Nothing
    Just path -> do
      readResult <- tryIOError (TIO.readFile path)
      configText <- case readResult of
        Left err -> dieText
          ("cannot read report configuration ‘" <> T.pack path <> "’: "
            <> tshow err)
        Right value -> pure value
      configuration <- case parseReportConfiguration configText of
        Left errors -> dieText
          ("report configuration failed in ‘" <> T.pack path <> "’:\n"
            <> renderReportConfigErrors errors)
        Right value -> pure value
      pure (Just configuration)

runDefaultReportBook
  :: Day
  -> Journal
  -> Maybe FilePath
  -> Maybe ReportConfiguration
  -> IO ()
runDefaultReportBook latest journal householdDirectory configuration = do
  resolvedPlan <- case configuration of
    Nothing -> pure (defaultResolvedReportPlan latest)
    Just configured -> case resolveReportPlan
        latest journal (reportConfigurationPlan configured) of
      Left err -> dieText (renderReportPlanError err)
      Right value -> pure value
  let presentation = maybe defaultPresentationConfig
        reportConfigurationPresentation configuration
  runCombinedReport
    presentation
    (resolvedTrialBalanceAsOf resolvedPlan)
    (reportBookWithPlan resolvedPlan journal)
    journal
    householdDirectory

runCombinedReport
  :: PresentationConfig
  -> Day
  -> ReportBook
  -> Journal
  -> Maybe FilePath
  -> IO ()
runCombinedReport presentation observation book journal householdDirectory =
  case householdDirectory of
    Nothing -> TIO.putStr (renderReportBookWithPresentation presentation book)
    Just directory -> do
      household <- loadHouseholdReportSurface directory observation journal
      TIO.putStr
        (renderReportBookWithHouseholdPresentation presentation book household)

loadHouseholdReportSurface
  :: FilePath
  -> Day
  -> Journal
  -> IO HouseholdReportSurface
loadHouseholdReportSurface directory observation journal = do
  actualText <- readHouseholdSource directory "actual.journal"
  actual <- case parseActualJournal actualText of
    Left errors -> dieText
      ("actual.journal completion admission failed:\n"
        <> renderAdmissionErrors errors)
    Right value -> pure value
  if actualJournalValue actual == journal
    then pure ()
    else dieText
      "actual.journal changed between accounting load and completion admission"
  accountText <- readHouseholdSource directory "accounts.journal"
  accountRegistry <- case parseAccountJournal accountText of
    Left errors -> dieText
      ("accounts.journal admission failed:\n"
        <> renderAdmissionErrors errors)
    Right value -> pure value
  budgetText <- readHouseholdSource directory "budget_alloc.tsv"
  budgetPolicyText <- readHouseholdSource directory "budget.toml"
  householdPolicyText <- readHouseholdSource directory "household.toml"
  planText <- readHouseholdSource directory "plan.journal"
  planJournal <- case parsePlanJournal planText of
    Left errors -> dieText
      ("plan.journal admission failed:\n"
        <> renderAdmissionErrors errors)
    Right value -> pure value
  issuesText <- readHouseholdSource directory "issues.tsv"
  case buildHouseholdReportSurfaceFromNativeHouseholdSources observation actual
      accountRegistry budgetText budgetPolicyText householdPolicyText planText
      planJournal issuesText of
    Left errors -> dieText
      ("household source admission failed:\n"
        <> renderHouseholdSourceErrors errors)
    Right surface -> pure surface

renderAdmissionErrors :: Show error => NonEmpty.NonEmpty error -> Text
renderAdmissionErrors =
  T.unlines . map (("  - " <>) . tshow) . NonEmpty.toList

readHouseholdSource :: FilePath -> FilePath -> IO Text
readHouseholdSource directory name = do
  let path = directory </> name
  result <- tryIOError (TIO.readFile path)
  case result of
    Left err -> dieText
      ("cannot read household source ‘" <> T.pack name <> "’: " <> tshow err)
    Right value -> pure value

resolveReportConfigPath :: IO (Maybe FilePath)
resolveReportConfigPath = do
  configured <- lookupEnv "HKERNEL_REPORT_CONFIG"
  case configured of
    Just path -> pure (Just path)
    Nothing -> do
      exists <- doesFileExist defaultReportConfigPath
      pure (if exists then Just defaultReportConfigPath else Nothing)

defaultReportConfigPath :: FilePath
defaultReportConfigPath = "report.toml"

resolveConfiguredLedgerDataDirectory :: IO (Maybe FilePath)
resolveConfiguredLedgerDataDirectory = do
  configured <- lookupEnv "HKERNEL_LEDGER_DATA_DIR"
  case configured of
    Just path -> pure (Just path)
    Nothing -> do
      exists <- doesFileExist ledgerDataLocalPath
      if not exists
        then pure Nothing
        else do
          result <- tryIOError (TIO.readFile ledgerDataLocalPath)
          case result of
            Left err -> dieText
              ("cannot read local ledger-data configuration: " <> tshow err)
            Right value
              | T.null (T.strip value) -> dieText
                  "ledger-data.local must contain a ledger data directory path"
              | otherwise -> pure (Just (T.unpack (T.strip value)))

ledgerDataLocalPath :: FilePath
ledgerDataLocalPath = "ledger-data.local"

renderReportPlanError :: ReportPlanError -> Text
renderReportPlanError (InvalidReportRange reportName start end) =
  "invalid " <> reportName <> " range: start " <> tshow start
    <> " is after end " <> tshow end

runEnvelopeBudget :: FilePath -> DateRange -> Journal -> IO ()
runEnvelopeBudget policyPath dateRange journal = do
  readResult <- tryIOError (TIO.readFile policyPath)
  policyText <- case readResult of
    Left err -> dieText
      ("cannot read envelope policy ‘" <> T.pack policyPath <> "’: " <> tshow err)
    Right value -> pure value
  policy <- case parseEnvelopePolicy policyText of
    Left errors -> dieText
      ("envelope policy parsing failed in ‘" <> T.pack policyPath <> "’:\n"
        <> renderEnvelopePolicyErrors errors)
    Right value -> pure value
  report <- case envelopeBudget dateRange policy journal of
    Left errors -> dieText
      ("envelope policy validation failed:\n"
        <> renderEnvelopeBudgetErrors errors)
    Right value -> pure value
  TIO.putStr (renderEnvelopeBudget report)

executeWithPresentation
  :: PresentationConfig
  -> JournalCommand
  -> Journal
  -> Text
executeWithPresentation presentation command journal = case command of
  Check ->
    "Journal is valid: "
      <> tshow (length (journalTransactions journal))
      <> " transactions\n"
  RunDefaultReportBook day ->
    renderReportBookWithPresentation
      presentation (reportBookAsOf day journal)
  RunReportBook dateRange ->
    renderReportBookWithPresentation
      presentation (reportBook dateRange journal)
  RunTrialBalance _ day ->
    renderTrialBalanceWithPresentation
      presentation (trialBalanceAsOf day journal)
  RunBalanceSheet _ day ->
    renderBalanceSheetWithPresentation
      presentation (balanceSheetAsOf day journal)
  RunProfitAndLoss _ dateRange ->
    renderProfitAndLossWithPresentation
      presentation (profitAndLoss dateRange journal)
  RunDailyFlow _ dateRange ->
    renderDailyFlowWithPresentation
      presentation (dailyFlow dateRange journal)
  RunMonthlyAccounts _ dateRange ->
    renderMonthlyAccountsWithPresentation
      presentation (monthlyAccounts dateRange journal)
  RunRecentTransactions _ day ->
    renderRecentTransactionsWithPresentation presentation
      (recentTransactions defaultRecentCount day journal)
  RunCycleAccounts current previous ->
    renderCycleAccountsWithPresentation presentation
      (cycleAccounts current previous journal)

dieWithUsage :: Text -> IO value
dieWithUsage message = dieText (message <> "\n\n" <> usage)

dieText :: Text -> IO value
dieText message = do
  TIO.hPutStrLn stderr message
  exitFailure

tshow :: Show value => value -> Text
tshow = T.pack . show
