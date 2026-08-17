-- | Pure accounting report models.
--
-- Reports preserve commodities all the way to their result. Rendering concerns
-- such as colors, column widths, and number formatting belong elsewhere.
module HKernel.Report
  ( classifyAccount
  , AccountLine(..)
  , TrialBalance(..)
  , trialBalanceAsOf
  , ProfitAndLoss(..)
  , profitAndLoss
  , BalanceSheet(..)
  , balanceSheetAsOf
  , DailyFlowLine(..)
  , dailyFlowNet
  , DailyFlowExpenseRow(..)
  , dailyFlowExpenseTotal
  , DailyFlowPeriod(..)
  , DailyFlow(..)
  , dailyFlow
  , dailyFlowThrough
  , dailyFlowTotalIncome
  , dailyFlowTotalExpenses
  , dailyFlowTotalNet
  , YearMonth
  , yearMonthYear
  , yearMonthNumber
  , yearMonthOf
  , MonthlyAccountRow(..)
  , monthlyAccountRowBalance
  , monthlyAccountRowTotal
  , MonthlyAccountsLine(..)
  , monthlyAccountsNet
  , MonthlyAccounts(..)
  , monthlyAccountsLines
  , monthlyAccounts
  , RecentCount
  , RecentCountError(..)
  , mkRecentCount
  , recentCountValue
  , defaultRecentCount
  , RecentTransactions
  , recentTransactionsAsOf
  , recentTransactionsCount
  , recentTransactionItems
  , recentTransactions
  , ReportBook(..)
  , reportBook
  , reportBookAsOf
  , reportBookWithPlan
  ) where

import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day, fromGregorian, toGregorian)
import HKernel.Account
import HKernel.Engine
import HKernel.Engine.Facts
  ( AccountingFacts
  , accountingFactsRegistry
  , accountBalancesInRangeFacts
  , accountBalancesThroughFacts
  , prepareAccountingFacts
  )
import HKernel.Journal (Journal, journalAccountRegistry)
import HKernel.Money
import HKernel.Report.Flow
import HKernel.Report.Matrix
import HKernel.Report.Plan
import HKernel.Report.RecentTransactions

-- | Look up the accounting meaning explicitly declared for an account.
--
-- Returning 'Nothing' is intentional: report code must keep undeclared
-- accounts visible instead of guessing from their names.
classifyAccount :: Journal -> Account -> Maybe AccountType
classifyAccount journal account =
  accountTypeFor account (journalAccountRegistry journal)

data AccountLine = AccountLine
  { lineAccount :: Account
  , lineBalance :: Balance
  } deriving (Eq, Show)

-- | Raw account lines partitioned once by declared accounting meaning.
data ClassifiedAccountLines = ClassifiedAccountLines
  { classifiedAssetLines        :: [AccountLine]
  , classifiedLiabilityLines    :: [AccountLine]
  , classifiedEquityLines       :: [AccountLine]
  , classifiedIncomeLines       :: [AccountLine]
  , classifiedExpenseLines      :: [AccountLine]
  , classifiedUnclassifiedLines :: [AccountLine]
  }

-- | Point-in-time account facts shared by reports with one as-of date.
data PointBalanceBasis = PointBalanceBasis
  { pointBasisDate       :: Day
  , pointBasisLines      :: [AccountLine]
  , pointBasisClassified :: ClassifiedAccountLines
  }

-- | Period account facts shared by reports over one explicit date range.
data PeriodBalanceBasis = PeriodBalanceBasis
  { periodBasisRange      :: DateRange
  , periodBasisRegistry   :: AccountRegistry
  , periodBasisClassified :: ClassifiedAccountLines
  }

preparePointBalanceBasis :: Day -> Journal -> PointBalanceBasis
preparePointBalanceBasis day =
  preparePointBalanceBasisFromFacts day . prepareAccountingFacts

preparePointBalanceBasisFromFacts
  :: Day
  -> AccountingFacts
  -> PointBalanceBasis
preparePointBalanceBasisFromFacts day facts = PointBalanceBasis
  { pointBasisDate = day
  , pointBasisLines = lines'
  , pointBasisClassified = classifyAccountLines registry lines'
  }
  where
    registry = accountingFactsRegistry facts
    lines' = accountLines (accountBalancesThroughFacts day facts)

preparePeriodBalanceBasis :: DateRange -> Journal -> PeriodBalanceBasis
preparePeriodBalanceBasis dateRange =
  preparePeriodBalanceBasisFromFacts dateRange . prepareAccountingFacts

preparePeriodBalanceBasisFromFacts
  :: DateRange
  -> AccountingFacts
  -> PeriodBalanceBasis
preparePeriodBalanceBasisFromFacts dateRange facts = PeriodBalanceBasis
  { periodBasisRange = dateRange
  , periodBasisRegistry = registry
  , periodBasisClassified = classifyAccountLines registry lines'
  }
  where
    registry = accountingFactsRegistry facts
    lines' = accountLines (accountBalancesInRangeFacts dateRange facts)

data TrialBalance = TrialBalance
  { trialBalanceDate  :: Day
  , trialBalanceLines :: [AccountLine]
  , trialBalanceTotal :: Balance
  } deriving (Eq, Show)

trialBalanceAsOf :: Day -> Journal -> TrialBalance
trialBalanceAsOf day journal =
  trialBalanceFromBasis (preparePointBalanceBasis day journal)

trialBalanceFromBasis :: PointBalanceBasis -> TrialBalance
trialBalanceFromBasis basis = TrialBalance
  { trialBalanceDate = pointBasisDate basis
  , trialBalanceLines = lines'
  , trialBalanceTotal = sumLineBalances lines'
  }
  where
    lines' = pointBasisLines basis

data ProfitAndLoss = ProfitAndLoss
  { profitAndLossRange        :: DateRange
  , incomeLines               :: [AccountLine]
  , expenseLines              :: [AccountLine]
  , totalIncome               :: Balance
  , totalExpenses             :: Balance
  , netIncome                 :: Balance
  , profitAndLossUnclassified :: [AccountLine]
  } deriving (Eq, Show)

-- | Build a period report. Income balances are sign-normalized for display:
-- credits become positive income. Expense balances retain their ledger sign.
profitAndLoss :: DateRange -> Journal -> ProfitAndLoss
profitAndLoss dateRange journal =
  profitAndLossFromBasis (preparePeriodBalanceBasis dateRange journal)

profitAndLossFromBasis :: PeriodBalanceBasis -> ProfitAndLoss
profitAndLossFromBasis basis = ProfitAndLoss
  { profitAndLossRange = periodBasisRange basis
  , incomeLines = normalizedIncome
  , expenseLines = expenses
  , totalIncome = incomeTotal
  , totalExpenses = expenseTotal
  , netIncome = subtractBalance incomeTotal expenseTotal
  , profitAndLossUnclassified =
      classifiedUnclassifiedLines classified
  }
  where
    classified = periodBasisClassified basis
    normalizedIncome = map negateLine (classifiedIncomeLines classified)
    expenses = classifiedExpenseLines classified
    incomeTotal = sumLineBalances normalizedIncome
    expenseTotal = sumLineBalances expenses

data BalanceSheet = BalanceSheet
  { balanceSheetDate         :: Day
  , assetLines               :: [AccountLine]
  , liabilityLines           :: [AccountLine]
  , equityLines              :: [AccountLine]
  , totalAssets              :: Balance
  , totalLiabilities         :: Balance
  , postedEquity             :: Balance
  , currentEarnings          :: Balance
  , totalEquity              :: Balance
  , balanceSheetUnclassified :: [AccountLine]
  , accountingEquationDelta  :: Balance
  } deriving (Eq, Show)

-- | Build an as-of balance sheet. Liability and equity credits are normalized
-- to positive presentation values. Current earnings are derived from unclosed
-- income and expense accounts, and total equity includes both posted equity and
-- those current earnings.
balanceSheetAsOf :: Day -> Journal -> BalanceSheet
balanceSheetAsOf day journal =
  balanceSheetFromBasis (preparePointBalanceBasis day journal)

balanceSheetFromBasis :: PointBalanceBasis -> BalanceSheet
balanceSheetFromBasis basis = BalanceSheet
  { balanceSheetDate = pointBasisDate basis
  , assetLines = assets
  , liabilityLines = normalizedLiabilities
  , equityLines = normalizedEquity
  , totalAssets = assetTotal
  , totalLiabilities = liabilityTotal
  , postedEquity = postedEquityTotal
  , currentEarnings = earnings
  , totalEquity = equityTotal
  , balanceSheetUnclassified =
      classifiedUnclassifiedLines classified
  , accountingEquationDelta = equationDelta
  }
  where
    classified = pointBasisClassified basis
    assets = classifiedAssetLines classified
    normalizedLiabilities =
      map negateLine (classifiedLiabilityLines classified)
    normalizedEquity = map negateLine (classifiedEquityLines classified)
    normalizedIncome = map negateLine (classifiedIncomeLines classified)
    expenses = classifiedExpenseLines classified

    assetTotal = sumLineBalances assets
    liabilityTotal = sumLineBalances normalizedLiabilities
    postedEquityTotal = sumLineBalances normalizedEquity
    earnings = subtractBalance
      (sumLineBalances normalizedIncome)
      (sumLineBalances expenses)
    equityTotal = addBalance postedEquityTotal earnings
    equationDelta =
      assetTotal
        `subtractBalance` liabilityTotal
        `subtractBalance` equityTotal

-- | The irreducible facts for one day's flow. Net flow is deliberately derived.
data DailyFlowLine = DailyFlowLine
  { dailyFlowDate     :: Day
  , dailyFlowIncome   :: Balance
  , dailyFlowExpenses :: Balance
  } deriving (Eq, Show)

dailyFlowNet :: DailyFlowLine -> Balance
dailyFlowNet line =
  subtractBalance (dailyFlowIncome line) (dailyFlowExpenses line)

-- | One expense account indexed explicitly by day.
data DailyFlowExpenseRow = DailyFlowExpenseRow
  { dailyFlowExpenseAccount :: Account
  , dailyFlowExpenseByDate  :: Map.Map Day Balance
  } deriving (Eq, Show)

dailyFlowExpenseTotal :: DailyFlowExpenseRow -> Balance
dailyFlowExpenseTotal = balanceRowTotal . dailyExpenseBalanceRow

dailyExpenseBalanceRow :: DailyFlowExpenseRow -> BalanceRow Account Day
dailyExpenseBalanceRow row = BalanceRow
  (dailyFlowExpenseAccount row)
  (dailyFlowExpenseByDate row)

data DailyFlow = DailyFlow
  { dailyFlowPeriod       :: DailyFlowPeriod
  , dailyFlowLines        :: [DailyFlowLine]
  , dailyFlowExpenseRows  :: [DailyFlowExpenseRow]
  , dailyFlowUnclassified :: [AccountLine]
  } deriving (Eq, Show)

dailyFlow :: DateRange -> Journal -> DailyFlow
dailyFlow dateRange journal =
  dailyFlowFromBasis (prepareFlowBasis dateRange journal)

dailyFlowThrough :: Day -> Journal -> DailyFlow
dailyFlowThrough day journal =
  dailyFlowFromBasis (prepareDailyFlowBasisThrough day journal)

dailyFlowFromBasis :: FlowBasis [AccountLine] -> DailyFlow
dailyFlowFromBasis basis = DailyFlow
  { dailyFlowPeriod = flowBasisDailyPeriod basis
  , dailyFlowLines = dailyLines
  , dailyFlowExpenseRows = map toExpenseRow
      (balanceMatrixRows (flowBasisDailyExpenses basis))
  , dailyFlowUnclassified = flowBasisDailyUnclassified basis
  }
  where
    dailyLines = map toDailyFlowLine (Map.toAscList (flowBasisDaily basis))
    toExpenseRow row = DailyFlowExpenseRow
      (balanceRowKey row)
      (balanceRowCells row)

dailyFlowTotalIncome :: DailyFlow -> Balance
dailyFlowTotalIncome = sumBalances . map dailyFlowIncome . dailyFlowLines

dailyFlowTotalExpenses :: DailyFlow -> Balance
dailyFlowTotalExpenses = sumBalances . map dailyFlowExpenses . dailyFlowLines

dailyFlowTotalNet :: DailyFlow -> Balance
dailyFlowTotalNet report =
  subtractBalance
    (dailyFlowTotalIncome report)
    (dailyFlowTotalExpenses report)

-- | One typed account indexed explicitly by calendar month.
data MonthlyAccountRow = MonthlyAccountRow
  { monthlyAccountRowAccount :: Account
  , monthlyAccountRowByMonth :: Map.Map YearMonth Balance
  } deriving (Eq, Show)

monthlyAccountRowBalance :: YearMonth -> MonthlyAccountRow -> Balance
monthlyAccountRowBalance month =
  balanceRowAt month . monthlyAccountBalanceRow

monthlyAccountRowTotal :: MonthlyAccountRow -> Balance
monthlyAccountRowTotal = balanceRowTotal . monthlyAccountBalanceRow

monthlyAccountBalanceRow
  :: MonthlyAccountRow
  -> BalanceRow Account YearMonth
monthlyAccountBalanceRow row = BalanceRow
  (monthlyAccountRowAccount row)
  (monthlyAccountRowByMonth row)

-- | Derived totals for one displayed calendar month.
data MonthlyAccountsLine = MonthlyAccountsLine
  { monthlyAccountsMonth    :: YearMonth
  , monthlyAccountsIncome   :: Balance
  , monthlyAccountsExpenses :: Balance
  } deriving (Eq, Show)

monthlyAccountsNet :: MonthlyAccountsLine -> Balance
monthlyAccountsNet line =
  subtractBalance
    (monthlyAccountsIncome line)
    (monthlyAccountsExpenses line)

data MonthlyAccounts = MonthlyAccounts
  { monthlyAccountsRange        :: DateRange
  , monthlyAccountsMonths       :: [YearMonth]
  , monthlyAccountsIncomeRows   :: [MonthlyAccountRow]
  , monthlyAccountsExpenseRows  :: [MonthlyAccountRow]
  , monthlyAccountsUnclassified :: [AccountLine]
  } deriving (Eq, Show)

monthlyAccountsLines :: MonthlyAccounts -> [MonthlyAccountsLine]
monthlyAccountsLines report =
  [ MonthlyAccountsLine
      { monthlyAccountsMonth = month
      , monthlyAccountsIncome = totalFor monthlyAccountsIncomeRows month
      , monthlyAccountsExpenses = totalFor monthlyAccountsExpenseRows month
      }
  | month <- monthlyAccountsMonths report
  ]
  where
    totalFor selectRows month =
      sumBalances (map (monthlyAccountRowBalance month) (selectRows report))

monthlyAccounts :: DateRange -> Journal -> MonthlyAccounts
monthlyAccounts dateRange journal =
  monthlyAccountsFromBasis (prepareFlowBasis dateRange journal)

monthlyAccountsFromBasis :: FlowBasis [AccountLine] -> MonthlyAccounts
monthlyAccountsFromBasis basis = MonthlyAccounts
  { monthlyAccountsRange = dateRange
  , monthlyAccountsMonths = yearMonthsInRange dateRange
  , monthlyAccountsIncomeRows =
      monthlyAccountRows (flowBasisMonthlyIncome basis)
  , monthlyAccountsExpenseRows =
      monthlyAccountRows (flowBasisMonthlyExpenses basis)
  , monthlyAccountsUnclassified = flowBasisMonthlyUnclassified basis
  }
  where
    dateRange = flowBasisMonthlyRange basis

monthlyAccountRows
  :: BalanceMatrix Account YearMonth
  -> [MonthlyAccountRow]
monthlyAccountRows =
  map toMonthlyAccountRow
    . filter (not . balanceRowIsZero)
    . balanceMatrixRows
  where
    toMonthlyAccountRow row = MonthlyAccountRow
      (balanceRowKey row)
      (balanceRowCells row)

yearMonthsInRange :: DateRange -> [YearMonth]
yearMonthsInRange dateRange =
  takeWhile (<= lastMonth) (iterate nextYearMonth firstMonth)
  where
    firstMonth = yearMonthOf (rangeStart dateRange)
    lastMonth = yearMonthOf (rangeEnd dateRange)

nextYearMonth :: YearMonth -> YearMonth
nextYearMonth month
  | yearMonthNumber month == 12 =
      yearMonthOf (fromGregorian (yearMonthYear month + 1) 1 1)
  | otherwise =
      yearMonthOf
        (fromGregorian (yearMonthYear month) (yearMonthNumber month + 1) 1)

-- | Every report currently available through the combined CLI command.
data ReportBook = ReportBook
  TrialBalance
  BalanceSheet
  ProfitAndLoss
  DailyFlow
  RecentTransactions
  MonthlyAccounts
  deriving (Eq, Show)

-- | Shared coordinates for a report book whose reports may have distinct dates.
-- Equal point or period coordinates are prepared once and shared lazily.
data ReportBasis = ReportBasis
  { reportBasisTrialBalance       :: PointBalanceBasis
  , reportBasisBalanceSheet       :: PointBalanceBasis
  , reportBasisProfitAndLoss      :: PeriodBalanceBasis
  , reportBasisFlows              :: FlowBasis [AccountLine]
  , reportBasisRecentTransactions :: RecentTransactionBasis
  , reportBasisRecentCount        :: RecentCount
  }

prepareReportBasisForPlan
  :: ResolvedReportPlan
  -> Journal
  -> ReportBasis
prepareReportBasisForPlan plan =
  prepareReportBasisForFacts plan . prepareAccountingFacts

prepareReportBasisForFacts
  :: ResolvedReportPlan
  -> AccountingFacts
  -> ReportBasis
prepareReportBasisForFacts plan facts = ReportBasis
  { reportBasisTrialBalance = trialBasis
  , reportBasisBalanceSheet = balanceBasis
  , reportBasisProfitAndLoss = profitBasis
  , reportBasisFlows = flowBasis
  , reportBasisRecentTransactions = prepareRecentTransactionBasis
      (resolvedRecentTransactionsAsOf plan)
      facts
  , reportBasisRecentCount = resolvedRecentTransactionsCount plan
  }
  where
    trialDay = resolvedTrialBalanceAsOf plan
    balanceDay = resolvedBalanceSheetAsOf plan
    (trialBasis, balanceBasis) = preparePointPair
      trialDay balanceDay facts

    profitRange = resolvedProfitAndLossRange plan
    monthlyRange = resolvedMonthlyAccountsRange plan
    profitBasis = preparePeriodBalanceBasisFromFacts profitRange facts
    monthlyBasis
      | monthlyRange == profitRange = profitBasis
      | otherwise = preparePeriodBalanceBasisFromFacts monthlyRange facts

    dailyPeriod = case resolvedDailyFlowSpec plan of
      ResolvedDailyFlowInRange dateRange -> DailyFlowInRange dateRange
      ResolvedDailyFlowThrough day -> DailyFlowThrough day

    dailyUnclassified = case resolvedDailyFlowSpec plan of
      ResolvedDailyFlowThrough day
        | day == trialDay -> pointUnclassified trialBasis
        | day == balanceDay -> pointUnclassified balanceBasis
        | otherwise -> pointUnclassified
            (preparePointBalanceBasisFromFacts day facts)
      ResolvedDailyFlowInRange dateRange
        | dateRange == profitRange -> periodUnclassified profitBasis
        | dateRange == monthlyRange -> periodUnclassified monthlyBasis
        | otherwise -> periodUnclassified
            (preparePeriodBalanceBasisFromFacts dateRange facts)

    flowBasis = prepareFlowBasisFor
      dailyPeriod
      monthlyRange
      dailyUnclassified
      (periodUnclassified monthlyBasis)
      (accountingFactsRegistry facts)
      facts

preparePointPair
  :: Day
  -> Day
  -> AccountingFacts
  -> (PointBalanceBasis, PointBalanceBasis)
preparePointPair firstDay secondDay facts
  | firstDay == secondDay =
      let basis = preparePointBalanceBasisFromFacts firstDay facts
      in (basis, basis)
  | otherwise =
      ( preparePointBalanceBasisFromFacts firstDay facts
      , preparePointBalanceBasisFromFacts secondDay facts
      )

pointUnclassified :: PointBalanceBasis -> [AccountLine]
pointUnclassified = classifiedUnclassifiedLines . pointBasisClassified

periodUnclassified :: PeriodBalanceBasis -> [AccountLine]
periodUnclassified = classifiedUnclassifiedLines . periodBasisClassified

reportBookFromBasis :: ReportBasis -> ReportBook
reportBookFromBasis basis = ReportBook
  (trialBalanceFromBasis (reportBasisTrialBalance basis))
  (balanceSheetFromBasis (reportBasisBalanceSheet basis))
  (profitAndLossFromBasis (reportBasisProfitAndLoss basis))
  (dailyFlowFromBasis (reportBasisFlows basis))
  (recentTransactionsFromBasis
      (reportBasisRecentCount basis)
      (reportBasisRecentTransactions basis))
  (monthlyAccountsFromBasis (reportBasisFlows basis))

-- | Build a report book from one concrete, validated period plan.
reportBookWithPlan :: ResolvedReportPlan -> Journal -> ReportBook
reportBookWithPlan plan journal =
  reportBookFromBasis (prepareReportBasisForPlan plan journal)

-- | Build all reports for one explicit range, preserving the existing CLI API.
reportBook :: DateRange -> Journal -> ReportBook
reportBook dateRange journal = reportBookWithPlan plan journal
  where
    end = rangeEnd dateRange
    plan = ResolvedReportPlan
      { resolvedTrialBalanceAsOf = end
      , resolvedBalanceSheetAsOf = end
      , resolvedProfitAndLossRange = dateRange
      , resolvedDailyFlowSpec = ResolvedDailyFlowInRange dateRange
      , resolvedMonthlyAccountsRange = dateRange
      , resolvedRecentTransactionsAsOf = end
      , resolvedRecentTransactionsCount = defaultRecentCount
      }

-- | Build the terminal-oriented default combined report.
reportBookAsOf :: Day -> Journal -> ReportBook
reportBookAsOf day = reportBookWithPlan (defaultResolvedReportPlan day)

monthToDate :: Day -> DateRange
monthToDate day = case mkDateRange firstOfMonth day of
  Right dateRange -> dateRange
  Left _ -> error "invalid month-to-date range"
  where
    (year, month, _) = toGregorian day
    firstOfMonth = fromGregorian year month 1

prepareFlowBasis :: DateRange -> Journal -> FlowBasis [AccountLine]
prepareFlowBasis dateRange =
  prepareFlowBasisFromFacts dateRange . prepareAccountingFacts

prepareFlowBasisFromFacts
  :: DateRange
  -> AccountingFacts
  -> FlowBasis [AccountLine]
prepareFlowBasisFromFacts dateRange facts =
  prepareFlowBasisFromPeriod
    (preparePeriodBalanceBasisFromFacts dateRange facts)
    facts

prepareDailyFlowBasisThrough :: Day -> Journal -> FlowBasis [AccountLine]
prepareDailyFlowBasisThrough day =
  prepareDailyFlowBasisThroughFacts day . prepareAccountingFacts

prepareDailyFlowBasisThroughFacts
  :: Day
  -> AccountingFacts
  -> FlowBasis [AccountLine]
prepareDailyFlowBasisThroughFacts day facts =
  prepareFlowBasisFor
    (DailyFlowThrough day)
    statementRange
    unclassified
    unclassified
    (accountingFactsRegistry facts)
    facts
  where
    statementRange = monthToDate day
    pointBasis = preparePointBalanceBasisFromFacts day facts
    unclassified = pointUnclassified pointBasis

prepareFlowBasisFromPeriod
  :: PeriodBalanceBasis
  -> AccountingFacts
  -> FlowBasis [AccountLine]
prepareFlowBasisFromPeriod periodBasis facts =
  prepareFlowBasisFor
    (DailyFlowInRange dateRange)
    dateRange
    unclassified
    unclassified
    (periodBasisRegistry periodBasis)
    facts
  where
    dateRange = periodBasisRange periodBasis
    unclassified = periodUnclassified periodBasis

toDailyFlowLine :: (Day, FlowAmounts) -> DailyFlowLine
toDailyFlowLine (day, amounts) = DailyFlowLine
  { dailyFlowDate = day
  , dailyFlowIncome = flowIncome amounts
  , dailyFlowExpenses = flowExpenses amounts
  }

accountLines :: AccountBalances -> [AccountLine]
accountLines = map (uncurry AccountLine) . accountBalanceEntries

classifyAccountLines
  :: AccountRegistry
  -> [AccountLine]
  -> ClassifiedAccountLines
classifyAccountLines registry =
  foldr (addClassifiedAccountLine registry) emptyClassifiedAccountLines

addClassifiedAccountLine
  :: AccountRegistry
  -> AccountLine
  -> ClassifiedAccountLines
  -> ClassifiedAccountLines
addClassifiedAccountLine registry line classified =
  case classifyRegisteredAccount registry (lineAccount line) of
    Just Asset -> classified
      { classifiedAssetLines = line : classifiedAssetLines classified }
    Just Liability -> classified
      { classifiedLiabilityLines =
          line : classifiedLiabilityLines classified }
    Just Equity -> classified
      { classifiedEquityLines = line : classifiedEquityLines classified }
    Just Income -> classified
      { classifiedIncomeLines = line : classifiedIncomeLines classified }
    Just Expense -> classified
      { classifiedExpenseLines = line : classifiedExpenseLines classified }
    Nothing -> classified
      { classifiedUnclassifiedLines =
          line : classifiedUnclassifiedLines classified }

emptyClassifiedAccountLines :: ClassifiedAccountLines
emptyClassifiedAccountLines = ClassifiedAccountLines
  { classifiedAssetLines = []
  , classifiedLiabilityLines = []
  , classifiedEquityLines = []
  , classifiedIncomeLines = []
  , classifiedExpenseLines = []
  , classifiedUnclassifiedLines = []
  }

classifyRegisteredAccount :: AccountRegistry -> Account -> Maybe AccountType
classifyRegisteredAccount registry account =
  accountTypeFor account registry

negateLine :: AccountLine -> AccountLine
negateLine line = line { lineBalance = negateBalance (lineBalance line) }

sumLineBalances :: [AccountLine] -> Balance
sumLineBalances = sumBalances . map lineBalance
