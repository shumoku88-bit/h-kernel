{-# LANGUAGE OverloadedStrings #-}

-- | Symbolic and resolved period plans for the combined report book.
--
-- Configuration syntax stays outside this module. The report engine consumes
-- only validated, concrete dates and ranges.
module HKernel.Report.Plan
  ( DateReference(..)
  , AsOfSpec(..)
  , StartBoundary(..)
  , EndBoundary(..)
  , RangeSpec(..)
  , RecentSpec(..)
  , ReportPlan(..)
  , ResolvedDailyFlowSpec(..)
  , ResolvedReportPlan(..)
  , ReportPlanError(..)
  , defaultResolvedReportPlan
  , reportPlanNeedsCurrentCycle
  , resolveReportPlan
  , resolveReportPlanWithCurrentCycle
  ) where

import Data.List (minimumBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Time.Calendar (Day, fromGregorian, toGregorian)
import HKernel.Engine (DateRange, mkDateRange)
import HKernel.Journal (Journal, journalTransactions)
import HKernel.Ledger (transactionDate)
import HKernel.Period (Period, periodContains, periodStart)
import HKernel.Report.RecentTransactions (RecentCount, defaultRecentCount)

data DateReference
  = ExactDate Day
  | Latest
  deriving (Eq, Show)

newtype AsOfSpec = AsOf DateReference
  deriving (Eq, Show)

data StartBoundary
  = FromBeginning
  | FromDate Day
  deriving (Eq, Show)

data EndBoundary
  = ThroughDate Day
  | ThroughLatest
  deriving (Eq, Show)

data RangeSpec
  = RangeSpec StartBoundary EndBoundary
  | CurrentCycleToDate
  deriving (Eq, Show)

data RecentSpec = RecentSpec
  { recentSpecThrough :: EndBoundary
  , recentSpecCount   :: RecentCount
  } deriving (Eq, Show)

data ReportPlan = ReportPlan
  { trialBalanceSpec       :: AsOfSpec
  , balanceSheetSpec       :: AsOfSpec
  , profitAndLossSpec      :: RangeSpec
  , dailyFlowSpec          :: RangeSpec
  , monthlyAccountsSpec    :: RangeSpec
  , recentTransactionsSpec :: RecentSpec
  } deriving (Eq, Show)

data ResolvedDailyFlowSpec
  = ResolvedDailyFlowInRange DateRange
  | ResolvedDailyFlowThrough Day
  deriving (Eq, Show)

data ResolvedReportPlan = ResolvedReportPlan
  { resolvedTrialBalanceAsOf       :: Day
  , resolvedBalanceSheetAsOf       :: Day
  , resolvedProfitAndLossRange     :: DateRange
  , resolvedDailyFlowSpec          :: ResolvedDailyFlowSpec
  , resolvedMonthlyAccountsRange   :: DateRange
  , resolvedRecentTransactionsAsOf :: Day
  , resolvedRecentTransactionsCount :: RecentCount
  } deriving (Eq, Show)

data ReportPlanError
  = InvalidReportRange
      { invalidReportName  :: Text
      , invalidReportStart :: Day
      , invalidReportEnd   :: Day
      }
  | CurrentCycleContextRequired Text
  | CurrentCycleObservationOutsidePeriod Text Day
  deriving (Eq, Show)

defaultResolvedReportPlan :: Day -> ResolvedReportPlan
defaultResolvedReportPlan latest = ResolvedReportPlan
  { resolvedTrialBalanceAsOf = latest
  , resolvedBalanceSheetAsOf = latest
  , resolvedProfitAndLossRange = monthToDate latest
  , resolvedDailyFlowSpec = ResolvedDailyFlowThrough latest
  , resolvedMonthlyAccountsRange = monthToDate latest
  , resolvedRecentTransactionsAsOf = latest
  , resolvedRecentTransactionsCount = defaultRecentCount
  }

reportPlanNeedsCurrentCycle :: ReportPlan -> Bool
reportPlanNeedsCurrentCycle plan = any rangeNeedsCurrentCycle
  [ profitAndLossSpec plan
  , dailyFlowSpec plan
  , monthlyAccountsSpec plan
  ]
  where
    rangeNeedsCurrentCycle CurrentCycleToDate = True
    rangeNeedsCurrentCycle (RangeSpec _ _) = False

resolveReportPlan
  :: Day
  -> Journal
  -> ReportPlan
  -> Either ReportPlanError ResolvedReportPlan
resolveReportPlan latest journal =
  resolveReportPlanWithCurrentCycle latest journal Nothing

resolveReportPlanWithCurrentCycle
  :: Day
  -> Journal
  -> Maybe Period
  -> ReportPlan
  -> Either ReportPlanError ResolvedReportPlan
resolveReportPlanWithCurrentCycle latest journal currentCycle plan = do
  profitAndLossRange <- resolveRange
    "profit-and-loss" latest journal currentCycle (profitAndLossSpec plan)
  dailyRange <- resolveRange
    "daily-flow" latest journal currentCycle (dailyFlowSpec plan)
  monthlyRange <- resolveRange
    "monthly-accounts" latest journal currentCycle (monthlyAccountsSpec plan)
  pure ResolvedReportPlan
    { resolvedTrialBalanceAsOf = resolveAsOf latest (trialBalanceSpec plan)
    , resolvedBalanceSheetAsOf = resolveAsOf latest (balanceSheetSpec plan)
    , resolvedProfitAndLossRange = profitAndLossRange
    , resolvedDailyFlowSpec = ResolvedDailyFlowInRange dailyRange
    , resolvedMonthlyAccountsRange = monthlyRange
    , resolvedRecentTransactionsAsOf = resolveEnd
        latest (recentSpecThrough (recentTransactionsSpec plan))
    , resolvedRecentTransactionsCount =
        recentSpecCount (recentTransactionsSpec plan)
    }

resolveAsOf :: Day -> AsOfSpec -> Day
resolveAsOf latest (AsOf reference) = case reference of
  ExactDate day -> day
  Latest -> latest

resolveEnd :: Day -> EndBoundary -> Day
resolveEnd latest boundary = case boundary of
  ThroughDate day -> day
  ThroughLatest -> latest

resolveRange
  :: Text
  -> Day
  -> Journal
  -> Maybe Period
  -> RangeSpec
  -> Either ReportPlanError DateRange
resolveRange reportName latest journal currentCycle rangeSpec =
  case rangeSpec of
    RangeSpec startBoundary endBoundary ->
      case mkDateRange start end of
        Right dateRange -> Right dateRange
        Left _ -> Left (InvalidReportRange reportName start end)
      where
        end = resolveEnd latest endBoundary
        start = case startBoundary of
          FromDate day -> day
          FromBeginning -> journalBeginningThrough end journal
    CurrentCycleToDate -> case currentCycle of
      Nothing -> Left (CurrentCycleContextRequired reportName)
      Just period
        | not (periodContains period latest) ->
            Left (CurrentCycleObservationOutsidePeriod reportName latest)
        | otherwise -> case mkDateRange (periodStart period) latest of
            Right dateRange -> Right dateRange
            Left _ -> Left
              (InvalidReportRange reportName (periodStart period) latest)

journalBeginningThrough :: Day -> Journal -> Day
journalBeginningThrough end journal = case eligible of
  [] -> end
  transactions -> transactionDate
    (minimumBy (comparing transactionDate) transactions)
  where
    eligible = filter ((<= end) . transactionDate) (journalTransactions journal)

monthToDate :: Day -> DateRange
monthToDate day = case mkDateRange firstOfMonth day of
  Right dateRange -> dateRange
  Left _ -> error "invalid month-to-date range"
  where
    (year, month, _) = toGregorian day
    firstOfMonth = fromGregorian year month 1
