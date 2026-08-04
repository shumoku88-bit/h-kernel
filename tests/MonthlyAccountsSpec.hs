{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (Account, mkAccount)
import HKernel.Engine (mkDateRange)
import HKernel.Journal (journalFromTransactions, parseJournal)
import HKernel.Ledger (mkPosting, mkTransaction)
import HKernel.Money
import HKernel.Render (renderMonthlyAccounts)
import HKernel.Report
import System.Exit (exitFailure)

main :: IO ()
main = do
  let journal = mustRight (parseJournal journalInput)
      start = fromGregorian 2026 6 15
      end = fromGregorian 2026 8 20
      dateRange = mustRight (mkDateRange start end)
      report = monthlyAccounts dateRange journal
      dailyReport = dailyFlow dateRange journal
      jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      june = yearMonthOf (fromGregorian 2026 6 1)
      july = yearMonthOf (fromGregorian 2026 7 1)
      august = yearMonthOf (fromGregorian 2026 8 1)
      bonus = mustRight (mkAccount "revenue:bonus")
      salary = mustRight (mkAccount "revenue:salary")
      food = mustRight (mkAccount "living:food")
      reversible = mustRight (mkAccount "living:reversible")
      travel = mustRight (mkAccount "living:travel")
      juneLine = lineFor june report
      julyLine = lineFor july report
      augustLine = lineFor august report
      julyIncome = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 500)
        , mkAmount usd (quantityFromInteger 10)
        ]
      julyExpenses = balanceFromAmounts
        [mkAmount jpy (quantityFromInteger 140)]
      julyNet = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 360)
        , mkAmount usd (quantityFromInteger 10)
        ]
      augustExpenses = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger (-40))
        , mkAmount usd (quantityFromInteger 3)
        ]
      augustNet = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 40)
        , mkAmount usd (quantityFromInteger (-3))
        ]

  assertEqual
    "monthly accounts publish every calendar month touched by the range"
    [(2026, 6), (2026, 7), (2026, 8)]
    (map yearMonthPair (monthlyAccountsMonths report))
  assertEqual
    "monthly income rows are grouped and ordered by full Account identity"
    [bonus, salary]
    (map monthlyAccountRowAccount (monthlyAccountsIncomeRows report))
  assertEqual
    "monthly expense rows are grouped and ordered by full Account identity"
    [food, reversible, travel]
    (map monthlyAccountRowAccount (monthlyAccountsExpenseRows report))
  assertEqual
    "an account whose cells are all zero is omitted"
    False
    (any ((== mustRight (mkAccount "living:cancelled"))
      . monthlyAccountRowAccount) (monthlyAccountsExpenseRows report))

  assertEqual
    "a calendar month without typed flow remains visible"
    (emptyBalance, emptyBalance, emptyBalance)
    ( monthlyAccountsIncome juneLine
    , monthlyAccountsExpenses juneLine
    , monthlyAccountsNet juneLine
    )
  assertEqual
    "monthly accounts classify unconventional income names by metadata"
    julyIncome
    (monthlyAccountsIncome julyLine)
  assertEqual
    "monthly accounts retain expense Account contributions"
    julyExpenses
    (monthlyAccountsExpenses julyLine)
  assertEqual
    "monthly accounts derive July net without mixing commodities"
    julyNet
    (monthlyAccountsNet julyLine)
  assertEqual
    "monthly accounts exclude asset transfers from August flow"
    emptyBalance
    (monthlyAccountsIncome augustLine)
  assertEqual
    "monthly accounts keep the partial ending month inside the explicit range"
    augustExpenses
    (monthlyAccountsExpenses augustLine)
  assertEqual
    "monthly accounts exclude transactions after the explicit range end"
    augustNet
    (monthlyAccountsNet augustLine)

  let reversibleRow = rowFor reversible (monthlyAccountsExpenseRows report)
  assertEqual
    "monthly cells preserve activity that cancels across different months"
    ( balanceFromAmounts [mkAmount jpy (quantityFromInteger 40)]
    , balanceFromAmounts [mkAmount jpy (quantityFromInteger (-40))]
    , emptyBalance
    )
    ( monthlyAccountRowBalance july reversibleRow
    , monthlyAccountRowBalance august reversibleRow
    , monthlyAccountRowTotal reversibleRow
    )

  assertEqual
    "validated journals have no unclassified monthly accounts"
    []
    (monthlyAccountsUnclassified report)
  assertEqual
    "grouping daily flow by month preserves total income"
    (dailyFlowTotalIncome dailyReport)
    (sumBalances (map monthlyAccountsIncome (monthlyAccountsLines report)))
  assertEqual
    "grouping daily flow by month preserves total expenses"
    (dailyFlowTotalExpenses dailyReport)
    (sumBalances (map monthlyAccountsExpenses (monthlyAccountsLines report)))
  assertEqual
    "grouping daily flow by month preserves total net"
    (dailyFlowTotalNet dailyReport)
    (sumBalances (map monthlyAccountsNet (monthlyAccountsLines report)))

  let rendered = renderMonthlyAccounts report
  assertEqual
    "monthly accounts renderer publishes the coloured Account by Month matrix"
    True
    ( all (`T.isInfixOf` rendered)
        [ "\ESC[1;36m== Monthly Accounts (Account × Month) ==\ESC[0m"
        , "Period: 2026-06-15 .. 2026-08-20 | Displayed months: 3"
        , "Account"
        , "2026-06"
        , "2026-07"
        , "2026-08"
        , "Period total"
        , "\ESC[1m\ESC[33mIncome\ESC[0m\ESC[0m"
        , "\ESC[1m\ESC[33mExpenses\ESC[0m\ESC[0m"
        , "revenue:bonus"
        , "revenue:salary"
        , "living:food"
        , "living:reversible"
        , "living:travel"
        , "\ESC[32m500 JPY\ESC[0m"
        , "\ESC[31m3 USD\ESC[0m"
        , "Net Profit"
        ]
    )
  assertEqual
    "monthly accounts renderer omits accounts with only zero month cells"
    False
    ("living:cancelled" `T.isInfixOf` rendered)
  assertEqual
    "monthly accounts renderer emits no trailing whitespace"
    True
    (all (\line -> T.stripEnd line == line) (T.lines rendered))

  let unknownLeft = mustRight (mkAccount "unknown:left")
      unknownRight = mustRight (mkAccount "unknown:right")
      unknownTransaction = mustRight (mkTransaction
        (fromGregorian 2026 8 15)
        "Programmatic unknown accounts"
        ( mkPosting unknownLeft
            (mkAmount jpy (quantityFromInteger 1))
        :| [ mkPosting unknownRight
              (mkAmount jpy (quantityFromInteger (-1)))
           ]
        ))
      unknownReport = monthlyAccounts dateRange
        (journalFromTransactions [unknownTransaction])
  assertEqual
    "unclassified programmatic accounts are not invented as monthly income"
    []
    (monthlyAccountsIncomeRows unknownReport)
  assertEqual
    "unclassified programmatic accounts are not invented as monthly expenses"
    []
    (monthlyAccountsExpenseRows unknownReport)
  assertEqual
    "unclassified programmatic accounts remain visible in monthly accounts"
    2
    (length (monthlyAccountsUnclassified unknownReport))
  assertEqual
    "the renderer names unclassified monthly evidence"
    True
    ("Unclassified accounts" `T.isInfixOf` renderMonthlyAccounts unknownReport)

lineFor :: YearMonth -> MonthlyAccounts -> MonthlyAccountsLine
lineFor month report = case filter ((== month) . monthlyAccountsMonth)
    (monthlyAccountsLines report) of
  [line] -> line
  unexpected -> error ("expected one monthly line, got " ++ show unexpected)

rowFor :: Account -> [MonthlyAccountRow] -> MonthlyAccountRow
rowFor account rows = case filter ((== account) . monthlyAccountRowAccount) rows of
  [row] -> row
  unexpected -> error ("expected one monthly account row, got " ++ show unexpected)

yearMonthPair :: YearMonth -> (Integer, Int)
yearMonthPair month = (yearMonthYear month, yearMonthNumber month)

journalInput :: T.Text
journalInput = T.unlines
  [ "account wallet:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account wallet:savings"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account wallet:dollars"
  , "    type: asset"
  , "    commodity: USD"
  , ""
  , "account capital:opening"
  , "    type: equity"
  , "    commodity: JPY"
  , ""
  , "account revenue:salary"
  , "    type: income"
  , "    commodity: JPY"
  , ""
  , "account revenue:bonus"
  , "    type: income"
  , "    commodity: USD"
  , ""
  , "account living:cancelled"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account living:food"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account living:reversible"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account living:travel"
  , "    type: expense"
  , "    commodity: USD"
  , ""
  , "2026-06-20 Opening balance"
  , "    wallet:cash  1000 JPY"
  , "    capital:opening"
  , ""
  , "2026-07-10 Salary"
  , "    wallet:cash  500 JPY"
  , "    revenue:salary"
  , ""
  , "2026-07-12 Buy food"
  , "    living:food  100 JPY"
  , "    wallet:cash"
  , ""
  , "2026-07-14 Cancelled charge"
  , "    living:cancelled  20 JPY"
  , "    wallet:cash"
  , ""
  , "2026-07-15 Cancelled refund"
  , "    wallet:cash  20 JPY"
  , "    living:cancelled"
  , ""
  , "2026-07-18 Reversible charge"
  , "    living:reversible  40 JPY"
  , "    wallet:cash"
  , ""
  , "2026-07-20 Bonus"
  , "    wallet:dollars  10 USD"
  , "    revenue:bonus"
  , ""
  , "2026-08-02 Travel"
  , "    living:travel  3 USD"
  , "    wallet:dollars"
  , ""
  , "2026-08-04 Reversible refund"
  , "    wallet:cash  40 JPY"
  , "    living:reversible"
  , ""
  , "2026-08-05 Move savings"
  , "    wallet:savings  50 JPY"
  , "    wallet:cash"
  , ""
  , "2026-08-25 Salary after range"
  , "    wallet:cash  1000 JPY"
  , "    revenue:salary"
  ]

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
