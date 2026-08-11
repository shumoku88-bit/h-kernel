{-# LANGUAGE OverloadedStrings #-}

-- | Pure terminal rendering for h-kernel reports.
--
-- Report values come from the typed kernel. Their terminal presentation follows
-- the h-kernel terminal output contract: ANSI colours, dynamic CJK-aware widths,
-- and the original report headings and section structure.
module HKernel.Render
  ( renderReportBook
  , renderReportBookWithDailyFlowDateColumns
  , renderReportBookWithPresentation
  , renderReportBookCoreWithPresentation
  , renderTrialBalance
  , renderTrialBalanceWithPresentation
  , renderProfitAndLoss
  , renderProfitAndLossWithPresentation
  , renderBalanceSheet
  , renderBalanceSheetWithPresentation
  , renderDailyFlow
  , renderDailyFlowWithDateColumns
  , renderDailyFlowWithPresentation
  , renderMonthlyAccounts
  , renderMonthlyAccountsWithPresentation
  , renderRecentTransactions
  , renderRecentTransactionsWithPresentation
  , renderCycleAccounts
  , renderCycleAccountsWithPresentation
  , renderJournalErrors
  , renderLoadError
  ) where

import Data.List (intersperse)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)
import HKernel.Account
import HKernel.Engine (rangeEnd, rangeStart)
import HKernel.Journal
import HKernel.Ledger
import HKernel.Loader
import HKernel.Money hiding (lookupBalance)
import HKernel.Period (Period, periodEndExclusive, periodStart)
import HKernel.Render.TerminalStyle
import HKernel.Report
import HKernel.Report.CycleAccounts
import HKernel.Report.Presentation

renderReportBook :: ReportBook -> Text
renderReportBook = renderReportBookWithPresentation defaultPresentationConfig

renderReportBookWithDailyFlowDateColumns
  :: DateColumnCount
  -> ReportBook
  -> Text
renderReportBookWithDailyFlowDateColumns dateColumns =
  renderReportBookWithPresentation
    (defaultPresentationConfig
      { presentationDailyFlowDateColumns = dateColumns })

renderReportBookWithPresentation
  :: PresentationConfig
  -> ReportBook
  -> Text
renderReportBookWithPresentation = renderReportBookCoreWithPresentation

renderReportBookCoreWithPresentation
  :: PresentationConfig
  -> ReportBook
  -> Text
renderReportBookCoreWithPresentation presentation
  (ReportBook trialBalance balanceSheet profitAndLossReport dailyFlowReport recentTransactionsReport monthlyAccountsReport) =
    T.intercalate "\n"
      [ renderTrialBalanceWithPresentation presentation trialBalance
      , renderBalanceSheetWithPresentation presentation balanceSheet
      , renderProfitAndLossWithPresentation presentation profitAndLossReport
      , renderDailyFlowWithPresentation presentation dailyFlowReport
      , renderRecentTransactionsWithPresentation
          presentation recentTransactionsReport
      , renderMonthlyAccountsWithPresentation presentation monthlyAccountsReport
      ]

renderTrialBalance :: TrialBalance -> Text
renderTrialBalance = renderTrialBalanceWithPresentation defaultPresentationConfig

renderTrialBalanceWithPresentation :: PresentationConfig -> TrialBalance -> Text
renderTrialBalanceWithPresentation presentation report = T.intercalate "\n"
  [ terminalHeaderWith presentation "Account Balances (h-kernel Engine)"
  , terminalMeta ("As of: " <> renderDay (trialBalanceDate report))
  , ""
  , renderTerminalTable accountColumns rows Nothing
  , "Balanced: " <> renderYesNo (isZeroBalance (trialBalanceTotal report))
  , ""
  ]
  where
    rows =
      [ [ plainCell (accountName (lineAccount line))
        , signedBalanceCellWith presentation (lineBalance line)
        ]
      | line <- trialBalanceLines report
      ]

renderProfitAndLoss :: ProfitAndLoss -> Text
renderProfitAndLoss =
  renderProfitAndLossWithPresentation defaultPresentationConfig

renderProfitAndLossWithPresentation
  :: PresentationConfig
  -> ProfitAndLoss
  -> Text
renderProfitAndLossWithPresentation presentation report = T.intercalate "\n"
  [ terminalHeaderWith presentation "Profit & Loss Statement (h-kernel Engine)"
  , terminalMeta ("Period: " <> renderDay (rangeStart dateRange)
      <> ".." <> renderDay (rangeEnd dateRange))
  , ""
  , terminalSectionWith presentation "Income"
  , renderTerminalTable accountAmountColumns incomeRows Nothing
  , terminalSectionWith presentation "Expenses"
  , renderTerminalTable accountAmountColumns expenseRows (Just netRow)
  , renderUnclassifiedWith presentation
      (profitAndLossUnclassified report)
  , ""
  ]
  where
    dateRange = profitAndLossRange report
    incomeRows =
      [ [ plainCell (accountName (lineAccount line))
        , positiveBalanceCellWith presentation (lineBalance line)
        ]
      | line <- incomeLines report
      ] ++
      [ [ styledCell terminalBold "Total Income"
        , styledCell (terminalBold . terminalPositiveAmountWith presentation)
            (renderBalancePlainWith presentation (totalIncome report))
        ]
      ]
    expenseRows =
      [ [ plainCell (accountName (lineAccount line))
        , negativeBalanceCellWith presentation (lineBalance line)
        ]
      | line <- expenseLines report
      ] ++
      [ [ styledCell terminalBold "Total Expenses"
        , styledCell
            (terminalBold . terminalNegativeAmountWith presentation)
            (renderBalancePlainWith presentation (totalExpenses report))
        ]
      ]
    netRow =
      [ styledCell terminalBold "Net Profit (Income - Expenses)"
      , signedBalanceCellWith presentation (netIncome report)
      ]

renderBalanceSheet :: BalanceSheet -> Text
renderBalanceSheet =
  renderBalanceSheetWithPresentation defaultPresentationConfig

renderBalanceSheetWithPresentation
  :: PresentationConfig
  -> BalanceSheet
  -> Text
renderBalanceSheetWithPresentation presentation report = T.intercalate "\n"
  [ terminalHeaderWith presentation "Balance Sheet (h-kernel Engine)"
  , terminalMeta ("As of: " <> renderDay (balanceSheetDate report))
  , ""
  , terminalSectionWith presentation "Assets"
  , renderTerminalTable accountColumns assetRows Nothing
  , terminalSectionWith presentation "Liabilities"
  , renderTerminalTable accountColumns liabilityRows Nothing
  , terminalSectionWith presentation "Equity"
  , renderTerminalTable accountColumns equityRows Nothing
  , renderUnclassifiedWith presentation (balanceSheetUnclassified report)
  , terminalBoldThen "Balanced: " (renderYesNo balanced)
      <> " (Net Check: "
      <> renderBalanceSignedWith presentation delta <> ")"
  , ""
  ]
  where
    assetRows =
      [ [ plainCell (accountName (lineAccount line))
        , positiveBalanceCellWith presentation (lineBalance line)
        ]
      | line <- assetLines report
      ] ++
      [ [ styledCell terminalBold "Total assets"
        , styledCell (terminalBold . terminalPositiveAmountWith presentation)
            (renderBalancePlainWith presentation (totalAssets report))
        ]
      ]
    liabilityRows =
      [ [ plainCell (accountName (lineAccount line))
        , negativeBalanceCellWith presentation (lineBalance line)
        ]
      | line <- liabilityLines report
      ] ++
      [ [ styledCell terminalBold "Total liabilities"
        , styledCell
            (terminalBold . terminalNegativeAmountWith presentation)
            (renderBalancePlainWith presentation (totalLiabilities report))
        ]
      ]
    equityRows =
      [ [ plainCell (accountName (lineAccount line))
        , plainBalanceCellWith presentation (lineBalance line)
        ]
      | line <- equityLines report
      ] ++
      [ [ plainCell "Current earnings"
        , signedBalanceCellWith presentation (currentEarnings report)
        ]
      , [ styledCell terminalBold "Total equity"
        , styledCell terminalBold
            (renderBalancePlainWith presentation (totalEquity report))
        ]
      ]
    delta = accountingEquationDelta report
    balanced = isZeroBalance delta && null (balanceSheetUnclassified report)

data DailyFlowView = DailyFlowView
  { dailyFlowViewRequestedPeriod :: Text
  , dailyFlowViewDisplayedPeriod :: Text
  , dailyFlowViewDates           :: [Day]
  , dailyFlowViewIncomeByDate    :: Map.Map Day Balance
  , dailyFlowViewIncomeTotal     :: Balance
  , dailyFlowViewExpenses        :: [DailyFlowExpenseView]
  , dailyFlowViewNetByDate       :: Map.Map Day Balance
  , dailyFlowViewNetTotal        :: Balance
  , dailyFlowViewTotalLabel      :: Text
  }

data DailyFlowExpenseView = DailyFlowExpenseView
  { dailyFlowExpenseViewAccount :: Account
  , dailyFlowExpenseViewByDate  :: Map.Map Day Balance
  , dailyFlowExpenseViewTotal   :: Balance
  }

projectDailyFlow :: DateColumnCount -> DailyFlow -> DailyFlowView
projectDailyFlow dateColumns report = DailyFlowView
  { dailyFlowViewRequestedPeriod = renderDailyFlowPeriod period
  , dailyFlowViewDisplayedPeriod = renderDisplayedPeriod period selectedDates
  , dailyFlowViewDates = selectedDates
  , dailyFlowViewIncomeByDate = Map.fromList
      [ (day, dailyFlowIncome line)
      | line <- selectedLines
      , let day = dailyFlowDate line
      ]
  , dailyFlowViewIncomeTotal = sumBalances
      (map dailyFlowIncome selectedLines)
  , dailyFlowViewExpenses = filter
      (not . isZeroBalance . dailyFlowExpenseViewTotal)
      (map projectExpense (dailyFlowExpenseRows report))
  , dailyFlowViewNetByDate = Map.fromList
      [ (day, dailyFlowNet line)
      | line <- selectedLines
      , let day = dailyFlowDate line
      ]
  , dailyFlowViewNetTotal = sumBalances
      (map dailyFlowNet selectedLines)
  , dailyFlowViewTotalLabel = case period of
      DailyFlowInRange _ -> "Period total"
      DailyFlowThrough _ -> "Window total"
  }
  where
    period = dailyFlowPeriod report
    allLines = dailyFlowLines report
    selectedDates = case period of
      DailyFlowInRange dateRange ->
        [rangeStart dateRange .. rangeEnd dateRange]
      DailyFlowThrough _ -> map dailyFlowDate selectedLines
    selectedLines = case period of
      DailyFlowInRange _ -> allLines
      DailyFlowThrough _ ->
        takeLast (dateColumnCountValue dateColumns) allLines
    selectedDateSet = Map.fromList [(day, ()) | day <- selectedDates]
    projectExpense row = DailyFlowExpenseView
      { dailyFlowExpenseViewAccount = dailyFlowExpenseAccount row
      , dailyFlowExpenseViewByDate = amounts
      , dailyFlowExpenseViewTotal = sumBalances (Map.elems amounts)
      }
      where
        amounts = Map.filterWithKey
          (\day _ -> Map.member day selectedDateSet)
          (dailyFlowExpenseByDate row)

renderDailyFlowPeriod :: DailyFlowPeriod -> Text
renderDailyFlowPeriod period = case period of
  DailyFlowInRange dateRange ->
    renderDay (rangeStart dateRange) <> " .. " <> renderDay (rangeEnd dateRange)
  DailyFlowThrough day -> "through " <> renderDay day

renderDisplayedPeriod :: DailyFlowPeriod -> [Day] -> Text
renderDisplayedPeriod _ [] = "(none)"
renderDisplayedPeriod period dates =
  renderDay (head dates)
    <> " .. " <> renderDay (last dates)
    <> " (" <> tshow (length dates) <> " " <> unit <> ")"
  where
    unit = case period of
      DailyFlowInRange _ -> "calendar days"
      DailyFlowThrough _ -> "flow days"

renderDailyFlow :: DailyFlow -> Text
renderDailyFlow = renderDailyFlowWithPresentation defaultPresentationConfig

renderDailyFlowWithDateColumns :: DateColumnCount -> DailyFlow -> Text
renderDailyFlowWithDateColumns dateColumns =
  renderDailyFlowWithPresentation
    (defaultPresentationConfig
      { presentationDailyFlowDateColumns = dateColumns })

renderDailyFlowWithPresentation :: PresentationConfig -> DailyFlow -> Text
renderDailyFlowWithPresentation presentation report = T.intercalate "\n"
  ( [ terminalHeaderWith presentation "Daily Flow (Category × Date)"
    , terminalMeta ("Requested period: "
        <> dailyFlowViewRequestedPeriod view
        <> " | Displayed: " <> dailyFlowViewDisplayedPeriod view
        <> " | Max date columns: "
        <> tshow (dateColumnCountValue dateColumns))
    , ""
    ]
    ++ intersperse "" renderedBlocks
    ++ [ renderUnclassifiedWith presentation (dailyFlowUnclassified report)
       , ""
       ]
  )
  where
    dateColumns = presentationDailyFlowDateColumns presentation
    view = projectDailyFlow dateColumns report
    dateBlocks = case chunksOf
        (dateColumnCountValue dateColumns)
        (dailyFlowViewDates view) of
      [] -> [[]]
      blocks -> blocks
    blockCount = length dateBlocks
    renderedBlocks =
      [ renderDailyFlowBlock presentation view blockCount blockIndex dates
      | (blockIndex, dates) <- zip [1 :: Int ..] dateBlocks
      ]

renderDailyFlowBlock
  :: PresentationConfig
  -> DailyFlowView
  -> Int
  -> Int
  -> [Day]
  -> Text
renderDailyFlowBlock presentation view blockCount blockIndex dates =
  T.intercalate "\n"
  [ terminalMeta (renderBlockPeriod dates
      <> " | Block " <> tshow blockIndex <> "/" <> tshow blockCount)
  , renderTerminalTable columns rows (Just netRow)
  ]
  where
    columns =
      ("Category", AlignLeft)
        : [ (renderShortDay day, AlignRight) | day <- dates ]
       ++ [("Block total", AlignRight) | blockCount > 1]
       ++ [(dailyFlowViewTotalLabel view, AlignRight)]
    incomeValues = map (lookupBalance (dailyFlowViewIncomeByDate view)) dates
    incomeRows
      | isZeroBalance (dailyFlowViewIncomeTotal view) = []
      | otherwise =
          [ plainCell "Income"
              : renderValues
                  (positiveBalanceCellWith presentation)
                  incomeValues
                  (dailyFlowViewIncomeTotal view)
          ]
    expenseRows =
      [ plainCell (accountName (dailyFlowExpenseViewAccount row))
          : renderValues
              (negativeBalanceCellWith presentation)
              values
              (dailyFlowExpenseViewTotal row)
      | row <- dailyFlowViewExpenses view
      , let values =
              map (lookupBalance (dailyFlowExpenseViewByDate row)) dates
      ]
    rows = incomeRows ++ expenseRows
    netRow =
      styledCell terminalBold "Net Flow"
        : renderValues
            (signedBalanceCellWith presentation)
            (map (lookupBalance (dailyFlowViewNetByDate view)) dates)
            (dailyFlowViewNetTotal view)
    renderValues renderBalance values periodTotal =
      map renderBalance values
        ++ [renderBalance (sumBalances values) | blockCount > 1]
        ++ [renderBalance periodTotal]

renderBlockPeriod :: [Day] -> Text
renderBlockPeriod [] = "Dates: (none)"
renderBlockPeriod dates =
  "Dates: " <> renderDay (head dates) <> " .. " <> renderDay (last dates)

lookupBalance :: Map.Map Day Balance -> Day -> Balance
lookupBalance values day = Map.findWithDefault emptyBalance day values

chunksOf :: Int -> [value] -> [[value]]
chunksOf _ [] = []
chunksOf count values = first : chunksOf count rest
  where
    (first, rest) = splitAt count values

renderMonthlyAccounts :: MonthlyAccounts -> Text
renderMonthlyAccounts =
  renderMonthlyAccountsWithPresentation defaultPresentationConfig

renderMonthlyAccountsWithPresentation
  :: PresentationConfig
  -> MonthlyAccounts
  -> Text
renderMonthlyAccountsWithPresentation presentation report = T.intercalate "\n"
  [ terminalHeaderWith presentation "Monthly Accounts (Account × Month)"
  , terminalMeta ("Period: " <> renderDay (rangeStart dateRange)
      <> " .. " <> renderDay (rangeEnd dateRange)
      <> " | Displayed months: " <> tshow (length months))
  , ""
  , renderTerminalTable columns rows (Just netRow)
  , renderUnclassifiedWith presentation
      (monthlyAccountsUnclassified report)
  , ""
  ]
  where
    dateRange = monthlyAccountsRange report
    months = monthlyAccountsMonths report
    lines' = monthlyAccountsLines report
    columns =
      ("Account", AlignLeft)
        : [ (renderYearMonth month, AlignRight) | month <- months ]
       ++ [("Period total", AlignRight)]
    rows =
      [sectionRow "Income"]
        ++ map (accountRow (positiveBalanceCellWith presentation))
          (monthlyAccountsIncomeRows report)
        ++ [totalRow
              (styledCell terminalBold "Total Income")
              (map monthlyAccountsIncome lines')
              monthlyIncomeTotal
              (terminalBold . terminalPositiveAmountWith presentation)]
        ++ [sectionRow "Expenses"]
        ++ map (accountRow (negativeBalanceCellWith presentation))
          (monthlyAccountsExpenseRows report)
        ++ [totalRow
              (styledCell terminalBold "Total Expenses")
              (map monthlyAccountsExpenses lines')
              monthlyExpenseTotal
              (terminalBold . terminalNegativeAmountWith presentation)]
    sectionRow label =
      styledCell (terminalBold . terminalSectionWith presentation) label
        : replicate (length months + 1) (plainCell "")
    accountRow balanceCell row =
      plainCell (accountName (monthlyAccountRowAccount row))
        : map balanceCell
            [ monthlyAccountRowBalance month row
            | month <- months
            ]
       ++ [balanceCell (monthlyAccountRowTotal row)]
    totalRow label values total style =
      label
        : map (styledCell style . renderBalancePlainWith presentation) values
       ++ [styledCell style (renderBalancePlainWith presentation total)]
    monthlyIncomeTotal = sumBalances (map monthlyAccountsIncome lines')
    monthlyExpenseTotal = sumBalances (map monthlyAccountsExpenses lines')
    netRow =
      styledCell terminalBold "Net Profit"
        : map
            (signedBalanceCellWith presentation . monthlyAccountsNet)
            lines'
       ++ [signedBalanceCellWith presentation
            (subtractBalance monthlyIncomeTotal monthlyExpenseTotal)]

renderCycleAccounts :: CycleAccounts -> Text
renderCycleAccounts =
  renderCycleAccountsWithPresentation defaultPresentationConfig

renderCycleAccountsWithPresentation
  :: PresentationConfig
  -> CycleAccounts
  -> Text
renderCycleAccountsWithPresentation presentation report = T.intercalate "\n"
  [ terminalHeaderWith presentation "Cycle Accounts & Comparison Matrix"
  , terminalMeta ("Current: " <> renderPeriod current
      <> " | Previous: " <> renderPeriod previous
      <> " | Periods are half-open")
  , ""
  , renderTerminalTable columns rows (Just totalRow)
  , renderCycleUnclassified presentation (cycleAccountsUnclassifiedRows report)
  , ""
  ]
  where
    current = cycleAccountsCurrentPeriod report
    previous = cycleAccountsPreviousPeriod report
    columns =
      [ ("Expense Account", AlignLeft)
      , ("Current", AlignRight)
      , ("Previous", AlignRight)
      , ("Delta", AlignRight)
      ]
    rows = map (cycleRow presentation) (cycleAccountsRows report)
    totalRow =
      [ styledCell terminalBold "Total Expenses"
      , styledCell terminalBold
          (renderBalancePlainWith presentation
            (cycleAccountsCurrentTotal report))
      , styledCell terminalBold
          (renderBalancePlainWith presentation
            (cycleAccountsPreviousTotal report))
      , signedBalanceCellWith presentation (cycleAccountsDeltaTotal report)
      ]

cycleRow :: PresentationConfig -> CycleAccountRow -> [Cell]
cycleRow presentation row =
  [ plainCell (accountName (cycleAccountRowAccount row))
  , plainBalanceCellWith presentation (cycleAccountRowCurrent row)
  , plainBalanceCellWith presentation (cycleAccountRowPrevious row)
  , signedBalanceCellWith presentation (cycleAccountRowDelta row)
  ]

renderCycleUnclassified :: PresentationConfig -> [CycleAccountRow] -> Text
renderCycleUnclassified _ [] = ""
renderCycleUnclassified presentation rows = T.intercalate "\n"
  [ terminalSectionWith presentation "Unclassified accounts"
  , renderTerminalTable columns
      (map (cycleRow presentation) rows)
      Nothing
  ]
  where
    columns =
      [ ("Account", AlignLeft)
      , ("Current", AlignRight)
      , ("Previous", AlignRight)
      , ("Delta", AlignRight)
      ]

renderPeriod :: Period -> Text
renderPeriod period =
  "[" <> renderDay (periodStart period)
    <> ", " <> renderDay (periodEndExclusive period) <> ")"


renderRecentTransactions :: RecentTransactions -> Text
renderRecentTransactions =
  renderRecentTransactionsWithPresentation defaultPresentationConfig

renderRecentTransactionsWithPresentation
  :: PresentationConfig
  -> RecentTransactions
  -> Text
renderRecentTransactionsWithPresentation presentation report = T.intercalate "\n"
  [ terminalHeaderWith presentation ("Recent Transactions (Last "
      <> tshow (recentCountValue (recentTransactionsCount report))
      <> " Transactions)")
  , terminalMeta ("As of: " <> renderDay (recentTransactionsAsOf report))
  , ""
  , renderRecentTransactionList
      presentation
      (recentTransactionItems report)
  , ""
  ]

renderRecentTransactionList :: PresentationConfig -> [Transaction] -> Text
renderRecentTransactionList _ [] = terminalDim "(none)"
renderRecentTransactionList presentation transactions =
  T.intercalate "\n"
    (map (renderRecentTransaction presentation) transactions)

renderRecentTransaction :: PresentationConfig -> Transaction -> Text
renderRecentTransaction presentation transaction = T.intercalate "\n"
  [ terminalSectionWith presentation
      (renderDay (transactionDate transaction)
        <> "  " <> transactionDescription transaction)
  , renderTerminalTable recentColumns rows Nothing
  ]
  where
    rows =
      [ [ plainCell (accountName (postingAccount posting))
        , signedAmountCellWith presentation (postingAmount posting)
        ]
      | posting <- NonEmpty.toList (transactionPostings transaction)
      ]

renderUnclassifiedWith :: PresentationConfig -> [AccountLine] -> Text
renderUnclassifiedWith _ [] = ""
renderUnclassifiedWith presentation lines' = T.intercalate "\n"
  [ terminalSectionWith presentation "Unclassified accounts"
  , renderTerminalTable accountColumns rows Nothing
  ]
  where
    rows =
      [ [ plainCell (accountName (lineAccount line))
        , signedBalanceCellWith presentation (lineBalance line)
        ]
      | line <- lines'
      ]

accountColumns :: [(Text, Alignment)]
accountColumns =
  [ ("Account", AlignLeft)
  , ("Balance", AlignRight)
  ]

accountAmountColumns :: [(Text, Alignment)]
accountAmountColumns =
  [ ("Account", AlignLeft)
  , ("Amount", AlignRight)
  ]

recentColumns :: [(Text, Alignment)]
recentColumns =
  [ ("Account", AlignLeft)
  , ("Amount", AlignRight)
  ]

takeLast :: Int -> [value] -> [value]
takeLast count values = drop (length values - min count (length values)) values

renderYesNo :: Bool -> Text
renderYesNo True  = terminalGreen "YES"
renderYesNo False = terminalRed "NO"

renderLoadError :: LoadError -> Text
renderLoadError loadError = case loadError of
  JournalReadFailed failure ->
    "cannot read journal " <> quoted (T.pack failedPath) <> ": "
      <> tshow (journalReadException failure)
      <> "\ninclude path: "
      <> T.intercalate " -> " (map T.pack (NonEmpty.toList paths))
    where
      paths = journalReadPath failure
      failedPath = NonEmpty.last paths
  JournalParseFailed path errors ->
    "journal parsing failed in " <> quoted (T.pack path) <> ":\n"
      <> renderJournalErrors errors
  JournalValidationFailed errors ->
    "journal validation failed:\n" <> renderJournalErrors errors
  IncludeAlreadyLoaded firstTrace repeatedTrace ->
    "journal file included more than once: "
      <> quoted (T.pack repeatedPath)
      <> "\nfirst include path: " <> renderIncludeTrace firstTrace
      <> "\nrepeated include path: " <> renderIncludeTrace repeatedTrace
    where
      repeatedPath = NonEmpty.last (includeTracePath repeatedTrace)
  IncludeCycle paths ->
    "include cycle: "
      <> T.intercalate " -> " (map T.pack (NonEmpty.toList paths))

renderIncludeTrace :: IncludeTrace -> Text
renderIncludeTrace =
  T.intercalate " -> "
    . map T.pack
    . NonEmpty.toList
    . includeTracePath

renderJournalErrors :: NonEmpty JournalError -> Text
renderJournalErrors = T.unlines . map renderError . NonEmpty.toList
  where
    renderError err =
      "line " <> tshow (journalErrorLine err) <> ": "
        <> renderReason (journalErrorReason err)

renderReason :: JournalErrorReason -> Text
renderReason reason = case reason of
  InvalidTransactionHeader line ->
    "invalid transaction header: " <> line
  UnexpectedIndentedLine line ->
    "indented line appears outside a directive or transaction: " <> T.strip line
  TransactionHasNoPostings ->
    "transaction has no postings"
  InvalidPostingAccount err ->
    "invalid account: " <> renderAccountError err
  UndeclaredPostingAccount account ->
    "posting uses undeclared account: " <> accountName account
  PostingCommodityMismatch account expected actual ->
    "posting commodity " <> commodityCode actual
      <> " conflicts with default " <> commodityCode expected
      <> " for account " <> accountName account
  InvalidPostingQuantity (InvalidQuantity value) ->
    "invalid quantity: " <> value
  InvalidPostingCommodity err ->
    "invalid commodity: " <> renderCommodityError err
  PostingAmountMissingCommodity value ->
    "quantity has no commodity: " <> value
  UnsupportedPostingSyntax value ->
    "unsupported posting syntax: " <> value
  MultipleElidedAmounts lineNumbers ->
    "more than one posting omits its amount (lines "
      <> T.intercalate ", " (map tshow lineNumbers) <> ")"
  CannotInferElidedAmount balance ->
    "cannot infer one amount from balance " <> renderBalancePlain balance
  InvalidTransaction err ->
    "invalid transaction: " <> renderTransactionError err
  InvalidAccountDirective line ->
    "invalid account directive: " <> T.strip line
  InvalidDeclaredAccount err ->
    "invalid declared account: " <> renderAccountError err
  InvalidAccountMetadata line ->
    "unsupported account metadata: " <> T.strip line
  InvalidAccountType value ->
    "unknown account type: " <> quoted value
  InvalidAccountCommodity err ->
    "invalid account default commodity: " <> renderCommodityError err
  AccountDirectiveHasNoType account ->
    "account directive has no type metadata: " <> accountName account
  DuplicateAccountType account ->
    "account has more than one type: " <> accountName account
  DuplicateAccountCommodity account ->
    "account has more than one default commodity: " <> accountName account
  DuplicateAccountDirective account ->
    "account is declared more than once: " <> accountName account
  InvalidIncludeDirective line ->
    "invalid include directive: " <> T.strip line
  InvalidIncludePath err ->
    "invalid include path: " <> renderIncludeError err
  UnresolvedInclude include ->
    "include has not been resolved: " <> includePath include

renderIncludeError :: IncludeError -> Text
renderIncludeError EmptyIncludePath = "path is empty"

renderAccountError :: AccountError -> Text
renderAccountError err = case err of
  EmptyAccount -> "account name is empty"
  AccountHasSurroundingWhitespace name ->
    "account has surrounding whitespace: " <> quoted name
  AccountContainsControlCharacter name ->
    "account contains a control character: " <> quoted name

renderCommodityError :: CommodityError -> Text
renderCommodityError err = case err of
  EmptyCommodity -> "commodity code is empty"
  CommodityContainsWhitespace code ->
    "commodity contains whitespace: " <> quoted code

renderTransactionError :: TransactionError -> Text
renderTransactionError err = case err of
  EmptyTransactionDescription -> "description is empty"
  TooFewPostings count ->
    "expected at least two postings, got " <> tshow count
  UnbalancedTransaction balance ->
    "unbalanced by " <> renderBalancePlain balance

renderDay :: Day -> Text
renderDay = T.pack . formatTime defaultTimeLocale "%Y-%m-%d"

renderShortDay :: Day -> Text
renderShortDay = T.pack . formatTime defaultTimeLocale "%m-%d"

renderYearMonth :: YearMonth -> Text
renderYearMonth month =
  tshow (yearMonthYear month)
    <> "-"
    <> T.justifyRight 2 '0' (tshow (yearMonthNumber month))

quoted :: Text -> Text
quoted value = "‘" <> value <> "’"

tshow :: Show value => value -> Text
tshow = T.pack . show
