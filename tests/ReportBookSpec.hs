{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Engine (DateRange, mkDateRange)
import HKernel.Journal (Journal, parseJournal)
import HKernel.Render
  ( renderBalanceSheetWithPresentation
  , renderDailyFlowWithPresentation
  , renderMonthlyAccountsWithPresentation
  , renderProfitAndLossWithPresentation
  , renderRecentTransactionsWithPresentation
  , renderReportBook
  , renderReportBookWithPresentation
  , renderTrialBalanceWithPresentation
  )
import HKernel.Report
import HKernel.Report.Plan
import HKernel.Report.Presentation
import System.Exit (exitFailure)

main :: IO ()
main = do
  let journal = mustRight (parseJournal journalInput)
      start = fromGregorian 2026 8 1
      end = fromGregorian 2026 8 31
      dateRange = mustRight (mkDateRange start end)
      book@(ReportBook trialBalance balanceSheet profitAndLossReport dailyFlowReport recentTransactionsReport monthlyAccountsReport) =
        reportBook dateRange journal

  assertEqual
    "report book uses the range end for the trial balance"
    (trialBalanceAsOf end journal)
    trialBalance
  assertEqual
    "report book uses the range end for the balance sheet"
    (balanceSheetAsOf end journal)
    balanceSheet
  assertEqual
    "report book retains the complete range for profit and loss"
    (profitAndLoss dateRange journal)
    profitAndLossReport
  assertEqual
    "report book retains the complete range for daily flow"
    (dailyFlow dateRange journal)
    dailyFlowReport
  assertEqual
    "report book uses the range end for recent transactions"
    (recentTransactions defaultRecentCount end journal)
    recentTransactionsReport
  assertEqual
    "report book retains the complete range for monthly accounts"
    (monthlyAccounts dateRange journal)
    monthlyAccountsReport

  let ReportBook _ _ defaultProfitAndLoss defaultDailyFlow _ defaultMonthly =
        reportBookAsOf end journal
  assertEqual
    "default report book keeps period statements month-to-date"
    (profitAndLoss dateRange journal)
    defaultProfitAndLoss
  assertEqual
    "default report book gives Daily Flow all history through its as-of day"
    (dailyFlowThrough end journal)
    defaultDailyFlow
  assertEqual
    "default report book keeps Monthly Accounts month-to-date"
    (monthlyAccounts dateRange journal)
    defaultMonthly

  configuredPeriodTests journal

  let headings = filter ("\ESC[1;36m==" `T.isPrefixOf`)
        (T.lines (renderReportBook book))
  assertEqual
    "report book renders terminal-coloured headings in the established report order"
    expectedHeadings
    headings

  let presentation = PresentationConfig
        { presentationNegativeStyle = LeadingMinus
        , presentationHeadingColor = BlueColor
        , presentationSectionColor = CyanColor
        , presentationPositiveAmountColor = YellowColor
        , presentationNegativeAmountColor = MagentaColor
        , presentationDailyFlowDateColumns =
            mustRight (mkDateColumnCount 5)
        }
      standalonePayloads =
        [ renderTrialBalanceWithPresentation presentation trialBalance
        , renderBalanceSheetWithPresentation presentation balanceSheet
        , renderProfitAndLossWithPresentation presentation profitAndLossReport
        , renderDailyFlowWithPresentation presentation dailyFlowReport
        , renderRecentTransactionsWithPresentation
            presentation recentTransactionsReport
        , renderMonthlyAccountsWithPresentation
            presentation monthlyAccountsReport
        ]
      renderedWithPresentation =
        renderReportBookWithPresentation presentation book
  assertEqual
    "all contains the same configured payloads as standalone renderers"
    True
    (all (`T.isInfixOf` renderedWithPresentation) standalonePayloads)
  assertEqual
    "the shared presentation selects minus notation in all"
    True
    ("-1,000 JPY" `T.isInfixOf` renderedWithPresentation
      && not ("(1,000 JPY)" `T.isInfixOf` renderedWithPresentation))
  assertEqual
    "configured heading color reaches combined Journal report headings"
    True
    ("\ESC[1;34m== Account Balances (h-kernel Engine) ==\ESC[0m"
      `T.isInfixOf` renderedWithPresentation
      && "\ESC[1;34m== Monthly Accounts (Account × Month) ==\ESC[0m"
        `T.isInfixOf` renderedWithPresentation)
  assertEqual
    "configured section color reaches report hierarchy"
    True
    ("\ESC[36mIncome\ESC[0m" `T.isInfixOf` renderedWithPresentation
      && "\ESC[36mExpenses\ESC[0m" `T.isInfixOf` renderedWithPresentation)
  let configuredPositiveTotals =
        [ line
        | line <- T.lines renderedWithPresentation
        , "Total Income" `T.isInfixOf` line
            || "Total assets" `T.isInfixOf` line
        ]
  assertEqual
    "configured positive amount color reaches positive totals"
    True
    (not (null configuredPositiveTotals)
      && all (T.isInfixOf "\ESC[33m") configuredPositiveTotals
      && all (not . T.isInfixOf "\ESC[32m") configuredPositiveTotals)
  let configuredAmountTotals =
        [ line
        | line <- T.lines renderedWithPresentation
        , "Total Expenses" `T.isInfixOf` line
            || "Total liabilities" `T.isInfixOf` line
        ]
  assertEqual
    "configured report exposes every negative amount-tone total"
    3
    (length configuredAmountTotals)
  assertEqual
    "configured negative amount color reaches every negative amount-tone total"
    True
    (all (T.isInfixOf "\ESC[35m") configuredAmountTotals
      && all (not . T.isInfixOf "\ESC[31m") configuredAmountTotals)
  assertEqual
    "status success stays green instead of inheriting positive amount color"
    True
    ("Balanced: \ESC[32mYES\ESC[0m" `T.isInfixOf` renderedWithPresentation)
  assertEqual
    "Journal-only ReportBook does not manufacture Household sections"
    False
    (any (`T.isInfixOf` renderedWithPresentation)
      [ "== Cycle Accounts & Comparison Matrix =="
      , "== Daily Target =="
      , "== Planned Transactions =="
      , "== Household Issues =="
      , "== Envelope & Backing =="
      ])

  budgetAccountTests dateRange

configuredPeriodTests :: Journal -> IO ()
configuredPeriodTests journal = do
  let trialDay = fromGregorian 2026 8 10
      balanceDay = fromGregorian 2026 8 15
      recentDay = fromGregorian 2026 8 10
      profitRange = mustRight (mkDateRange
        (fromGregorian 2026 7 20)
        (fromGregorian 2026 8 10))
      dailyRange = mustRight (mkDateRange
        (fromGregorian 2026 8 1)
        (fromGregorian 2026 8 15))
      monthlyRange = mustRight (mkDateRange
        (fromGregorian 2026 7 1)
        (fromGregorian 2026 8 10))
      recentCount = mustRight (mkRecentCount 2)
      plan = ResolvedReportPlan
        { resolvedTrialBalanceAsOf = trialDay
        , resolvedBalanceSheetAsOf = balanceDay
        , resolvedProfitAndLossRange = profitRange
        , resolvedDailyFlowSpec = ResolvedDailyFlowInRange dailyRange
        , resolvedMonthlyAccountsRange = monthlyRange
        , resolvedRecentTransactionsAsOf = recentDay
        , resolvedRecentTransactionsCount = recentCount
        }
      ReportBook trial balance profit daily recent monthly =
        reportBookWithPlan plan journal

  assertEqual
    "configured report book preserves the Trial Balance as-of coordinate"
    (trialBalanceAsOf trialDay journal)
    trial
  assertEqual
    "configured report book preserves the Balance Sheet as-of coordinate"
    (balanceSheetAsOf balanceDay journal)
    balance
  assertEqual
    "configured report book preserves the P&L range"
    (profitAndLoss profitRange journal)
    profit
  assertEqual
    "configured report book preserves the Daily Flow range"
    (dailyFlow dailyRange journal)
    daily
  assertEqual
    "configured report book preserves the Recent Transactions coordinate"
    (recentTransactions recentCount recentDay journal)
    recent
  assertEqual
    "configured report book preserves the Monthly Accounts range"
    (monthlyAccounts monthlyRange journal)
    monthly

budgetAccountTests :: DateRange -> IO ()
budgetAccountTests dateRange = do
  let journal = mustRight (parseJournal budgetJournalInput)
      budgetFood = mustRight (mkAccount "budget:food")
      budgetOffset = mustRight (mkAccount "budget:offset")
      ReportBook trialBalance balanceSheet profitAndLossReport dailyFlowReport _ monthlyAccountsReport =
        reportBook dateRange journal

  assertEqual
    "budget accounts remain visible in the trial balance"
    [budgetFood, budgetOffset]
    (map lineAccount (trialBalanceLines trialBalance))
  assertEqual
    "budget accounts are not treated as unclassified balance-sheet evidence"
    []
    (balanceSheetUnclassified balanceSheet)
  assertEqual
    "budget accounts are not treated as unclassified profit-and-loss evidence"
    []
    (profitAndLossUnclassified profitAndLossReport)
  assertEqual
    "budget accounts do not become daily flow"
    []
    (dailyFlowLines dailyFlowReport)
  assertEqual
    "budget accounts do not become daily expense rows"
    []
    (dailyFlowExpenseRows dailyFlowReport)
  assertEqual
    "budget accounts are not treated as unclassified daily-flow evidence"
    []
    (dailyFlowUnclassified dailyFlowReport)
  assertEqual
    "budget accounts do not become monthly income rows"
    []
    (monthlyAccountsIncomeRows monthlyAccountsReport)
  assertEqual
    "budget accounts do not become monthly expense rows"
    []
    (monthlyAccountsExpenseRows monthlyAccountsReport)
  assertEqual
    "budget accounts are not treated as unclassified monthly evidence"
    []
    (monthlyAccountsUnclassified monthlyAccountsReport)

expectedHeadings :: [T.Text]
expectedHeadings =
  [ "\ESC[1;36m== Account Balances (h-kernel Engine) ==\ESC[0m"
  , "\ESC[1;36m== Balance Sheet (h-kernel Engine) ==\ESC[0m"
  , "\ESC[1;36m== Profit & Loss Statement (h-kernel Engine) ==\ESC[0m"
  , "\ESC[1;36m== Daily Flow (Category × Date) ==\ESC[0m"
  , "\ESC[1;36m== Recent Transactions (Last 5 Transactions) ==\ESC[0m"
  , "\ESC[1;36m== Monthly Accounts (Account × Month) ==\ESC[0m"
  ]

journalInput :: T.Text
journalInput = T.unlines
  [ "account assets:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account equity:opening"
  , "    type: equity"
  , "    commodity: JPY"
  , ""
  , "account expenses:food"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account income:salary"
  , "    type: income"
  , "    commodity: JPY"
  , ""
  , "2026-07-20 Earlier food"
  , "    expenses:food  50 JPY"
  , "    assets:cash"
  , ""
  , "2026-08-01 Opening balance"
  , "    assets:cash  1000 JPY"
  , "    equity:opening"
  , ""
  , "2026-08-10 Buy food"
  , "    expenses:food  100 JPY"
  , "    assets:cash"
  , ""
  , "2026-08-15 Salary"
  , "    assets:cash  500 JPY"
  , "    income:salary"
  ]

budgetJournalInput :: T.Text
budgetJournalInput = T.unlines
  [ "account budget:food"
  , "    type: budget"
  , "    commodity: JPY"
  , ""
  , "account budget:offset"
  , "    type: budget"
  , "    commodity: JPY"
  , ""
  , "2026-08-01 Budget coordinates"
  , "    budget:food  1000 JPY"
  , "    budget:offset"
  ]



