{-# LANGUAGE OverloadedStrings #-}

-- | Pure CLI argument parsing and command specifications.
module HKernel.CLI
  ( Command(..)
  , JournalCommand(..)
  , DateOrigin(..)
  , parseArguments
  , defaultDateRange
  , defaultJournalCandidates
  , usage
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian, toGregorian)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.Engine (DateRange, mkDateRange)
import HKernel.Period (Period, mkPeriod)

-- | Indicates whether a report date/range was explicitly supplied on the CLI
-- or derived from the current calendar day default.
data DateOrigin
  = DefaultedDate
  | ExplicitDate
  deriving (Eq, Show)

-- | Every CLI request, including extensions that need an additional input.
data Command
  = RunJournal JournalCommand
  | RunEnvelopeBudget FilePath DateRange
  deriving (Eq, Show)

-- | Commands whose complete input is one validated Journal.
data JournalCommand
  = Check
  | RunDefaultReportBook Day
  | RunReportBook DateRange
  | RunTrialBalance DateOrigin Day
  | RunBalanceSheet DateOrigin Day
  | RunProfitAndLoss DateOrigin DateRange
  | RunDailyFlow DateOrigin DateRange
  | RunMonthlyAccounts DateOrigin DateRange
  | RunRecentTransactions DateOrigin Day
  | RunCycleAccounts Period Period
  deriving (Eq, Show)

defaultJournalPath :: FilePath
defaultJournalPath = "journal.journal"

defaultJournalCandidates :: [FilePath]
defaultJournalCandidates =
  [ "journal.journal"
  , "examples/sample.journal"
  ]

-- | Derive a default date range ending on the given day.
-- The range starts at the 1st of the month of the target day.
defaultDateRange :: Day -> DateRange
defaultDateRange day =
  let (year, month, _) = toGregorian day
      start = fromGregorian year month 1
      start' = if start <= day then start else day
  in case mkDateRange start' day of
       Right dateRange -> dateRange
       Left _ -> case mkDateRange day day of
         Right dateRange -> dateRange
         Left _ -> error "invalid date range fallback"

isJournalMode :: String -> Bool
isJournalMode mode = mode `elem`
  [ "check"
  , "all-reports", "all"
  , "trial-balance", "tb"
  , "balance-sheet", "bs"
  , "profit-and-loss", "pl"
  , "daily-flow", "daily"
  , "monthly-accounts", "monthly"
  , "recent-transactions", "recent"
  , "cycle-accounts", "cycle"
  ]

parseJournalCommandWithDate :: String -> DateOrigin -> Day -> Either Text JournalCommand
parseJournalCommandWithDate mode origin day
  | mode `elem` ["all-reports", "all"] =
      Right (RunDefaultReportBook day)
  | mode `elem` ["trial-balance", "tb"] =
      Right (RunTrialBalance origin day)
  | mode `elem` ["balance-sheet", "bs"] =
      Right (RunBalanceSheet origin day)
  | mode `elem` ["profit-and-loss", "pl"] =
      Right (RunProfitAndLoss origin (defaultDateRange day))
  | mode `elem` ["daily-flow", "daily"] =
      Right (RunDailyFlow origin (defaultDateRange day))
  | mode `elem` ["monthly-accounts", "monthly"] =
      Right (RunMonthlyAccounts origin (defaultDateRange day))
  | mode `elem` ["recent-transactions", "recent"] =
      Right (RunRecentTransactions origin day)
  | mode `elem` ["cycle-accounts", "cycle"] =
      Left "cycle-accounts requires PREVIOUS_START PREVIOUS_END_EXCLUSIVE CURRENT_START CURRENT_END_EXCLUSIVE"
  | mode == "check" = Right Check
  | otherwise = Left ("unknown command: " <> T.pack mode)

parseArguments :: Day -> [String] -> Either Text (FilePath, Command)
parseArguments today arguments = case arguments of
  [] ->
    journal defaultJournalPath (RunDefaultReportBook today)

  [arg1]
    | isJournalMode arg1 ->
        journalWithDate defaultJournalPath arg1 DefaultedDate today
    | Right day <- parseDay arg1 ->
        journal defaultJournalPath (RunDefaultReportBook day)
    | otherwise ->
        journal arg1 (RunDefaultReportBook today)

  [arg1, arg2]
    | isJournalMode arg2 ->
        journalWithDate arg1 arg2 DefaultedDate today
    | isJournalMode arg1, Right day <- parseDay arg2 ->
        journalWithDate defaultJournalPath arg1 ExplicitDate day
    | isJournalMode arg1 ->
        journalWithDate arg2 arg1 DefaultedDate today
    | Right day <- parseDay arg2 ->
        journal arg1 (RunDefaultReportBook day)
    | Right dateRange <- parseDateRange arg1 arg2 ->
        journal defaultJournalPath (RunReportBook dateRange)

  [arg1, arg2, arg3]
    | isJournalMode arg2, Right day <- parseDay arg3 ->
        journalWithDate arg1 arg2 ExplicitDate day
    | isJournalMode arg1, Right day <- parseDay arg3 ->
        journalWithDate arg2 arg1 ExplicitDate day
    | Right dateRange <- parseDateRange arg2 arg3 ->
        journal arg1 (RunReportBook dateRange)

  [arg1, arg2, arg3, arg4]
    | mode `elem` ["all-reports", "all"] ->
        journalRange journalPath RunReportBook startText endText
    | mode `elem` ["profit-and-loss", "pl"] ->
        journalRange journalPath (RunProfitAndLoss ExplicitDate) startText endText
    | mode `elem` ["daily-flow", "daily"] ->
        journalRange journalPath (RunDailyFlow ExplicitDate) startText endText
    | mode `elem` ["monthly-accounts", "monthly"] ->
        journalRange journalPath (RunMonthlyAccounts ExplicitDate) startText endText
    | mode' `elem` ["all-reports", "all"] ->
        journalRange journalPath' RunReportBook startText endText
    | mode' `elem` ["profit-and-loss", "pl"] ->
        journalRange journalPath' (RunProfitAndLoss ExplicitDate) startText endText
    | mode' `elem` ["daily-flow", "daily"] ->
        journalRange journalPath' (RunDailyFlow ExplicitDate) startText endText
    | mode' `elem` ["monthly-accounts", "monthly"] ->
        journalRange journalPath' (RunMonthlyAccounts ExplicitDate) startText endText
    where
      (journalPath, mode, startText, endText) = (arg1, arg2, arg3, arg4)
      (mode', journalPath', _, _) = (arg1, arg2, arg3, arg4)

  [mode, previousStart, previousEnd, currentStart, currentEnd]
    | mode `elem` ["cycle-accounts", "cycle"] ->
        journalCycle defaultJournalPath
          previousStart previousEnd currentStart currentEnd

  [journalPath, mode, policyPath, startText, endText]
    | mode `elem` ["envelope-budget", "envelopes"] -> do
        dateRange <- parseDateRange startText endText
        Right (journalPath, RunEnvelopeBudget policyPath dateRange)

  [journalPath, mode, previousStart, previousEnd, currentStart, currentEnd]
    | mode `elem` ["cycle-accounts", "cycle"] ->
        journalCycle journalPath previousStart previousEnd currentStart currentEnd

  _ -> Left "invalid arguments"
  where
    journal journalPath command = Right (journalPath, RunJournal command)

    journalWithDate journalPath mode origin day = do
      command <- parseJournalCommandWithDate mode origin day
      journal journalPath command

    journalRange journalPath constructor startText endText = do
      dateRange <- parseDateRange startText endText
      journal journalPath (constructor dateRange)

    journalCycle journalPath previousStart previousEnd currentStart currentEnd = do
      previous <- parsePeriod previousStart previousEnd
      current <- parsePeriod currentStart currentEnd
      journal journalPath (RunCycleAccounts current previous)

parseDateRange :: String -> String -> Either Text DateRange
parseDateRange startText endText = do
  start <- parseDay startText
  end <- parseDay endText
  case mkDateRange start end of
    Left _ -> Left "the report start date must not be after its end date"
    Right dateRange -> Right dateRange

parsePeriod :: String -> String -> Either Text Period
parsePeriod startText endText = do
  start <- parseDay startText
  endExclusive <- parseDay endText
  case mkPeriod start endExclusive of
    Left _ -> Left "a cycle start must be before its exclusive end"
    Right period -> Right period

parseDay :: String -> Either Text Day
parseDay input = case parseTimeM True defaultTimeLocale "%Y-%m-%d" input of
  Just day -> Right day
  Nothing -> Left ("invalid date ‘" <> T.pack input <> "’; expected YYYY-MM-DD")

usage :: Text
usage = T.unlines
  [ "Usage:"
  , "  h-kernel [JOURNAL] [COMMAND] [ARGS...]"
  , ""
  , "Commands:"
  , "  all-reports, all [DATE | START END]   Render all Journal-only reports (default)"
  , "  trial-balance, tb [DATE]              Render trial balance as of date"
  , "  balance-sheet, bs [DATE]              Render balance sheet as of date"
  , "  profit-and-loss, pl [START END | DATE] Render profit and loss for period"
  , "  daily-flow, daily [START END | DATE]  Render daily income and expenses"
  , "  monthly-accounts, monthly [START END | DATE] Render monthly income and expenses"
  , "  recent-transactions, recent [DATE]    Render the latest five transactions"
  , "  cycle-accounts, cycle PREV_START PREV_END_EXCL CURRENT_START CURRENT_END_EXCL"
  , "                                        Compare two explicit half-open cycles"
  , "  envelope-budget, envelopes POLICY START END Render an external envelope policy"
  , "  check                                 Validate journal syntax and includes"
  , ""
  , "Defaults:"
  , "  JOURNAL : HKERNEL_LEDGER_DATA_DIR/actual.journal when configured; otherwise"
  , "            journal.journal or the sample Journal"
  , "  COMMAND : all-reports"
  , "  DATE    : Today's date (YYYY-MM-DD)"
  , "  START   : First day of the month for DATE (YYYY-MM-01)"
  ]
