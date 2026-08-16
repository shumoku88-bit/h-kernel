{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Applicative ((<|>))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import HKernel.Actual.Journal (actualJournalValue)
import HKernel.Application.Config
  ( HouseholdSourcePaths(..)
  , householdSourcePaths
  , mkHouseholdRoot
  )
import HKernel.CLI
import HKernel.Engine (DateRange, rangeEnd)
import HKernel.Household.Application
  ( HouseholdState(..)
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHousehold
  )
import HKernel.Household.Report (HouseholdReportSurface(..))
import HKernel.Household.Report.Render
  ( renderReportBookWithHouseholdPresentation
  )
import HKernel.Journal
import HKernel.Loader (loadJournal)
import HKernel.Period (Period)
import HKernel.Render
import HKernel.Report
import HKernel.Report.Config
import HKernel.Report.CycleAccounts
  ( currentCycleAccountsPeriod
  , cycleAccounts
  )
import HKernel.Report.Plan
import HKernel.Report.Presentation
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>), normalise)
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
run today journalPath householdDirectory command =
  case (householdDirectory, command) of
    (Just directory, RunJournal (RunDefaultReportBook day)) ->
      runCanonicalDefaultReportBook directory day
    (Just directory, RunJournal (RunReportBook dateRange)) ->
      runCanonicalReportBook directory dateRange
    _ -> runJournalSourceCommand today journalPath householdDirectory command

runJournalSourceCommand
  :: Day
  -> FilePath
  -> Maybe FilePath
  -> Command
  -> IO ()
runJournalSourceCommand today journalPath householdDirectory command = do
  loadResult <- loadJournal journalPath
  journal <- case loadResult of
    Left err -> dieText (renderLoadError err)
    Right value -> pure value
  case command of
    RunJournal Check ->
      TIO.putStr (executeWithPresentation defaultPresentationConfig Check journal)
    RunJournal (RunDefaultReportBook day) -> do
      configuration <- loadReportConfiguration householdDirectory
      runDefaultJournalReportBook day journal configuration
    RunJournal journalCommand -> do
      configuration <- loadReportConfiguration householdDirectory
      let presentation = maybe defaultPresentationConfig
            reportConfigurationPresentation configuration
      resolvedCommand <- case configuration of
        Nothing -> pure journalCommand
        Just configured
          | not (journalCommandUsesConfiguredPeriod journalCommand) ->
              pure journalCommand
          | otherwise -> do
              currentCycle <- loadCurrentCycleContextIfNeeded
                today householdDirectory (reportConfigurationPlan configured)
              case resolveReportPlanWithCurrentCycle
                  today journal currentCycle (reportConfigurationPlan configured) of
                Left err -> dieText (renderReportPlanError err)
                Right resolvedPlan ->
                  pure (applyReportPlanResolved resolvedPlan journalCommand)
      TIO.putStr (executeWithPresentation presentation resolvedCommand journal)

runCanonicalDefaultReportBook :: FilePath -> Day -> IO ()
runCanonicalDefaultReportBook directory latest = do
  state <- loadCanonicalReportState directory
  configuration <- loadCanonicalReportConfiguration state
  let journal = actualJournalValue (householdStateActualJournal state)
      plan = reportConfigurationPlan configuration
  (currentCycle, latestSurface) <-
    if reportPlanNeedsCurrentCycle plan
      then do
        surface <- buildCanonicalHouseholdSurface latest state
        pure (Just (currentCyclePeriodFromSurface surface), Just surface)
      else pure (Nothing, Nothing)
  resolvedPlan <- case resolveReportPlanWithCurrentCycle
      latest journal currentCycle plan of
    Left err -> dieText (renderReportPlanError err)
    Right value -> pure value
  reportSurface <- case latestSurface of
    Just surface
      | resolvedTrialBalanceAsOf resolvedPlan == latest -> pure surface
    _ -> buildCanonicalHouseholdSurface
      (resolvedTrialBalanceAsOf resolvedPlan) state
  renderCanonicalReportBook
    (reportConfigurationPresentation configuration)
    (reportBookWithPlan resolvedPlan journal)
    reportSurface

runCanonicalReportBook :: FilePath -> DateRange -> IO ()
runCanonicalReportBook directory dateRange = do
  state <- loadCanonicalReportState directory
  configuration <- loadCanonicalReportConfiguration state
  reportSurface <- buildCanonicalHouseholdSurface (rangeEnd dateRange) state
  let journal = actualJournalValue (householdStateActualJournal state)
  renderCanonicalReportBook
    (reportConfigurationPresentation configuration)
    (reportBook dateRange journal)
    reportSurface

loadCanonicalReportState :: FilePath -> IO HouseholdState
loadCanonicalReportState directory = do
  root <- case mkHouseholdRoot directory of
    Left _ -> dieText "invalid Household root directory"
    Right value -> pure value
  result <- loadCanonicalHousehold root
  case result of
    Left errors -> dieText
      ("canonical household loading failed:\n"
        <> T.unlines (map (("  - " <>) . tshow) (NonEmpty.toList errors)))
    Right state -> pure state

loadCanonicalReportConfiguration :: HouseholdState -> IO ReportConfiguration
loadCanonicalReportConfiguration state = do
  configured <- lookupEnv "HKERNEL_REPORT_CONFIG"
  case configured of
    Just path
      | normalise path /= normalise canonicalPath ->
          loadReportConfigurationAt path
    _ -> pure (householdStateReportConfig state)
  where
    canonicalPath = householdReportConfigPath (householdStatePaths state)

buildCanonicalHouseholdSurface
  :: Day
  -> HouseholdState
  -> IO HouseholdReportSurface
buildCanonicalHouseholdSurface observation state =
  case buildHouseholdReportSurfaceFromHousehold observation state of
    Left errors -> dieText
      ("household report surface calculation failed:\n"
        <> T.unlines (map (("  - " <>) . tshow) (NonEmpty.toList errors)))
    Right surface -> pure surface

currentCyclePeriodFromSurface :: HouseholdReportSurface -> Period
currentCyclePeriodFromSurface =
  currentCycleAccountsPeriod . householdCurrentCycleAccounts

loadCurrentCycleContextIfNeeded
  :: Day
  -> Maybe FilePath
  -> ReportPlan
  -> IO (Maybe Period)
loadCurrentCycleContextIfNeeded observation householdDirectory plan
  | not (reportPlanNeedsCurrentCycle plan) = pure Nothing
  | otherwise = case householdDirectory of
      Nothing -> pure Nothing
      Just directory -> do
        state <- loadCanonicalReportState directory
        surface <- buildCanonicalHouseholdSurface observation state
        pure (Just (currentCyclePeriodFromSurface surface))

renderCanonicalReportBook
  :: PresentationConfig
  -> ReportBook
  -> HouseholdReportSurface
  -> IO ()
renderCanonicalReportBook presentation book surface =
  TIO.putStr
    (renderReportBookWithHouseholdPresentation presentation book surface)

journalCommandUsesConfiguredPeriod :: JournalCommand -> Bool
journalCommandUsesConfiguredPeriod command = case command of
  RunTrialBalance DefaultedDate _ -> True
  RunBalanceSheet DefaultedDate _ -> True
  RunProfitAndLoss DefaultedDate _ -> True
  RunDailyFlow DefaultedDate _ -> True
  RunMonthlyAccounts DefaultedDate _ -> True
  RunRecentTransactions DefaultedDate _ -> True
  _ -> False

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

loadReportConfiguration :: Maybe FilePath -> IO (Maybe ReportConfiguration)
loadReportConfiguration householdDirectory = do
  configPath <- resolveReportConfigPath householdDirectory
  traverse loadReportConfigurationAt configPath

loadReportConfigurationAt :: FilePath -> IO ReportConfiguration
loadReportConfigurationAt path = do
  readResult <- tryIOError (TIO.readFile path)
  configText <- case readResult of
    Left err -> dieText
      ("cannot read report configuration ‘" <> T.pack path <> "’: "
        <> tshow err)
    Right value -> pure value
  case parseReportConfiguration configText of
    Left errors -> dieText
      ("report configuration failed in ‘" <> T.pack path <> "’:\n"
        <> renderReportConfigErrors errors)
    Right value -> pure value

runDefaultJournalReportBook
  :: Day
  -> Journal
  -> Maybe ReportConfiguration
  -> IO ()
runDefaultJournalReportBook latest journal configuration = do
  resolvedPlan <- case configuration of
    Nothing -> pure (defaultResolvedReportPlan latest)
    Just configured -> case resolveReportPlan
        latest journal (reportConfigurationPlan configured) of
      Left err -> dieText (renderReportPlanError err)
      Right value -> pure value
  let presentation = maybe defaultPresentationConfig
        reportConfigurationPresentation configuration
  TIO.putStr
    (renderReportBookWithPresentation
      presentation (reportBookWithPlan resolvedPlan journal))

resolveReportConfigPath :: Maybe FilePath -> IO (Maybe FilePath)
resolveReportConfigPath householdDirectory = do
  configured <- lookupEnv "HKERNEL_REPORT_CONFIG"
  case configured of
    Just path -> pure (Just path)
    Nothing -> do
      householdPath <- case householdDirectory of
        Nothing -> pure Nothing
        Just directory -> existingHouseholdReportConfigPath directory
      case householdPath of
        Just path -> pure (Just path)
        Nothing -> do
          exists <- doesFileExist defaultReportConfigPath
          pure (if exists then Just defaultReportConfigPath else Nothing)

existingHouseholdReportConfigPath :: FilePath -> IO (Maybe FilePath)
existingHouseholdReportConfigPath directory =
  case mkHouseholdRoot directory of
    Left _ -> pure Nothing
    Right root -> do
      let path = householdReportConfigPath (householdSourcePaths root)
      exists <- doesFileExist path
      pure (if exists then Just path else Nothing)

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
renderReportPlanError errorValue = case errorValue of
  InvalidReportRange reportName start end ->
    "invalid " <> reportName <> " range: start " <> tshow start
      <> " is after end " <> tshow end
  CurrentCycleContextRequired reportName ->
    reportName
      <> " range current-cycle-to-date requires canonical Household cycle context"
  CurrentCycleObservationOutsidePeriod reportName observation ->
    reportName <> " current-cycle-to-date observation " <> tshow observation
      <> " is outside the resolved current cycle"

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
