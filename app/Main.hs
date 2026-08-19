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
import System.FilePath ((</>), normalise, takeFileName)
import System.IO (stderr)
import System.IO.Error (isDoesNotExistError, tryIOError)

main :: IO ()
main = do
  today <- localDay . zonedTimeToLocalTime <$> getZonedTime
  arguments <- getArgs
  case arguments of
    "concierge" : conciergeArguments ->
      runConcierge today conciergeArguments
    _ -> case parseArguments today arguments of
      Left message -> dieWithUsage message
      Right (journalPath, command) -> do
        (resolvedPath, householdDirectory) <- resolveJournalInput journalPath
        run today resolvedPath householdDirectory command

-- Read-only AI consultation ---------------------------------------------------

data ConciergeSnapshot = ConciergeSnapshot
  { conciergeCanonicalSources :: [(FilePath, Text)]
  , conciergeRelationSidecar  :: (FilePath, Maybe Text)
  } deriving (Eq, Show)

data ConciergeObservation = ConciergeObservation
  { conciergeObservationSnapshot :: ConciergeSnapshot
  , conciergeObservationReport   :: Text
  }

conciergeProtocol :: Text
conciergeProtocol = T.unlines
  [ "HKERNEL_CONCIERGE_PROTOCOL v1"
  , "mode: read-only"
  , "authority: canonical Household admission and explicit source evidence"
  , "write_capability: none"
  , "writer_commands: forbidden during consultation"
  , "relationship_policy: use explicit relation rows and source-durable identities only"
  , "inference_policy: never infer identity or relation from date, memo, amount, Account shape, or source position"
  , "epistemic_policy: distinguish observed fact, plan, configuration, relation/history, report projection, and recommendation"
  , "recommendation_policy: recommendations are advisory and never become Household facts"
  , "staleness_policy: if the observation fence fails, discard the packet and request a fresh observation"
  , "source_scope: eight canonical root coordinates plus the explicit issue-relations provenance sidecar"
  , "sidecar_status: issue-relations.tsv is explicit provenance evidence but is not a ninth canonical Household source"
  , "sidecar_admission: concierge-v1 fences sidecar source text but does not independently re-admit relation references; do not invent or repair relations from similarity"
  ]

conciergeUsage :: Text
conciergeUsage = T.unlines
  [ "Usage:"
  , "  h-kernel concierge protocol"
  , "  h-kernel concierge overview"
  , "  h-kernel concierge export"
  , "  h-kernel concierge packet"
  ]

runConcierge :: Day -> [String] -> IO ()
runConcierge today arguments = case arguments of
  ["protocol"] -> TIO.putStr conciergeProtocol
  ["self-check"] -> conciergeSelfCheck
  [command]
    | command `elem` ["overview", "export", "packet"] -> do
        directory <- requireConciergeHouseholdDirectory
        observation <- stableConciergeObservation today directory
        rendered <- renderConciergeObservation command observation
        TIO.putStr rendered
  _ -> dieText conciergeUsage

conciergeSelfCheck :: IO ()
conciergeSelfCheck = do
  let requiredClauses =
        [ "mode: read-only"
        , "write_capability: none"
        , "writer_commands: forbidden during consultation"
        , "relationship_policy:"
        , "recommendation_policy:"
        , "sidecar_admission:"
        ]
      missing = filter (not . (`T.isInfixOf` conciergeProtocol)) requiredClauses
  if null missing
    then TIO.putStrLn "concierge Haskell observation self-check passed"
    else dieText
      ("concierge protocol missing required clauses: " <> T.intercalate ", " missing)

requireConciergeHouseholdDirectory :: IO FilePath
requireConciergeHouseholdDirectory = do
  configured <- resolveConfiguredLedgerDataDirectory
  case configured of
    Just directory -> pure directory
    Nothing -> dieText
      "concierge Household root is not configured; use tools/hk --base DIR, HKERNEL_LEDGER_DATA_DIR, or ledger-data.local"

stableConciergeObservation :: Day -> FilePath -> IO ConciergeObservation
stableConciergeObservation today directory = do
  before <- readConciergeSnapshot directory
  firstState <- loadCanonicalReportState directory
  firstReport <- canonicalDefaultReportText
    today firstState (householdStateReportConfig firstState)
  middle <- readConciergeSnapshot directory
  secondState <- loadCanonicalReportState directory
  secondReport <- canonicalDefaultReportText
    today secondState (householdStateReportConfig secondState)
  after <- readConciergeSnapshot directory

  if before /= middle
      || middle /= after
      || firstState /= secondState
      || firstReport /= secondReport
    then dieText
      "Household changed during concierge observation; discard this observation and retry"
    else pure ConciergeObservation
      { conciergeObservationSnapshot = before
      , conciergeObservationReport = firstReport
      }

readConciergeSnapshot :: FilePath -> IO ConciergeSnapshot
readConciergeSnapshot directory = do
  root <- case mkHouseholdRoot directory of
    Left _ -> dieText "invalid Household root directory"
    Right value -> pure value
  let paths = householdSourcePaths root
      canonicalPaths =
        [ householdAccountsJournalPath paths
        , householdActualJournalPath paths
        , householdPlanJournalPath paths
        , householdEntitlementJournalPath paths
        , householdEnvelopeConfigPath paths
        , householdPolicyConfigPath paths
        , householdReportConfigPath paths
        , householdIssuesPath paths
        ]
      relationPath = householdIssueRelationsPath paths
  canonicalSources <- traverse readCanonicalSource canonicalPaths
  relationSource <- readOptionalConciergeSource relationPath
  pure ConciergeSnapshot
    { conciergeCanonicalSources = canonicalSources
    , conciergeRelationSidecar = (relationPath, relationSource)
    }
  where
    readCanonicalSource path = do
      source <- readRequiredConciergeSource path
      pure (path, source)

readRequiredConciergeSource :: FilePath -> IO Text
readRequiredConciergeSource path = do
  result <- tryIOError (TIO.readFile path)
  case result of
    Left err -> dieText
      ("cannot read concierge source ‘" <> T.pack path <> "’: " <> tshow err)
    Right value -> pure value

readOptionalConciergeSource :: FilePath -> IO (Maybe Text)
readOptionalConciergeSource path = do
  result <- tryIOError (TIO.readFile path)
  case result of
    Left err
      | isDoesNotExistError err -> pure Nothing
      | otherwise -> dieText
          ("cannot read concierge provenance source ‘" <> T.pack path <> "’: "
            <> tshow err)
    Right value -> pure (Just value)

renderConciergeObservation
  :: String
  -> ConciergeObservation
  -> IO Text
renderConciergeObservation command observation = do
  generatedAt <- T.pack . show <$> getZonedTime
  let header kind = T.unlines
        [ "HKERNEL_CONCIERGE_" <> kind <> " v1"
        , "generated_at: " <> generatedAt
        , "mode: read-only"
        , "canonical_household_admission: passed"
        , "observation_fence: passed"
        ]
      reportBlock =
        "\n@@CANONICAL_REPORT\n"
          <> ensureTrailingNewline (conciergeObservationReport observation)
          <> "@@END_CANONICAL_REPORT\n"
      sourceBlock = renderConciergeSources
        (conciergeObservationSnapshot observation)
  pure $ conciergeProtocol <> "\n" <> case command of
    "overview" ->
      header "OVERVIEW"
        <> "evidence_level: canonical-report\n"
        <> "next: use `tools/hk concierge export` only when exact root-source evidence is needed\n"
        <> reportBlock
    "export" ->
      header "EVIDENCE"
        <> "evidence_level: exact-root-source-text\n"
        <> "canonical_sources: 8\n"
        <> "provenance_sidecars: 1\n"
        <> sourceBlock
    "packet" ->
      header "PACKET"
        <> "evidence_level: canonical-report-plus-exact-root-source-text\n"
        <> reportBlock
        <> sourceBlock
    _ -> conciergeUsage

renderConciergeSources :: ConciergeSnapshot -> Text
renderConciergeSources snapshot =
  T.concat
    [ renderConciergeSource "canonical" path True source
    | (path, source) <- conciergeCanonicalSources snapshot
    ]
  <> case conciergeRelationSidecar snapshot of
    (path, Nothing) -> renderConciergeSource "provenance-sidecar" path False ""
    (path, Just source) -> renderConciergeSource
      "provenance-sidecar" path True source

renderConciergeSource
  :: Text
  -> FilePath
  -> Bool
  -> Text
  -> Text
renderConciergeSource sourceClass path present source =
  let presentText = if present then "true" else "false"
  in "\n@@SOURCE name=" <> T.pack (takeFileName path)
      <> " class=" <> sourceClass
      <> " present=" <> presentText
      <> " characters=" <> tshow (T.length source) <> "\n"
      <> ensureTrailingNewline source
      <> "@@END_SOURCE\n"

ensureTrailingNewline :: Text -> Text
ensureTrailingNewline value
  | T.null value = value
  | "\n" `T.isSuffixOf` value = value
  | otherwise = value <> "\n"

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
  TIO.putStr =<< canonicalDefaultReportText latest state configuration

canonicalDefaultReportText
  :: Day
  -> HouseholdState
  -> ReportConfiguration
  -> IO Text
canonicalDefaultReportText latest state configuration = do
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
  pure
    (renderReportBookWithHouseholdPresentation
      (reportConfigurationPresentation configuration)
      (reportBookWithPlan resolvedPlan journal)
      reportSurface)

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
