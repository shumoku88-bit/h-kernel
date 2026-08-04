{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Engine (mkDateRange)
import HKernel.Journal (journalFromTransactions, parseJournal)
import HKernel.Ledger (mkPosting, mkTransaction)
import HKernel.Money
import HKernel.Render
  ( renderDailyFlow
  , renderDailyFlowWithDateColumns
  )
import HKernel.Report
import HKernel.Report.Presentation
import System.Exit (exitFailure)

main :: IO ()
main = do
  let journal = mustRight (parseJournal journalInput)
      start = fromGregorian 2026 8 1
      end = fromGregorian 2026 8 31
      dateRange = mustRight (mkDateRange start end)
      report = dailyFlow dateRange journal
      jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      expectedIncome = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 500)
        , mkAmount usd (quantityFromInteger 10)
        ]
      expectedExpenses = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 100)
        , mkAmount usd (quantityFromInteger 3)
        ]
      expectedNet = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 400)
        , mkAmount usd (quantityFromInteger 7)
        ]

  assertEqual
    "daily flow retains only days with typed income or expense activity"
    [ fromGregorian 2026 8 10
    , fromGregorian 2026 8 15
    , fromGregorian 2026 8 20
    , fromGregorian 2026 8 21
    ]
    (map dailyFlowDate (dailyFlowLines report))
  assertEqual
    "daily flow retains the requested display period"
    (DailyFlowInRange dateRange)
    (dailyFlowPeriod report)
  assertEqual
    "daily flow classifies unconventional account names by metadata"
    expectedIncome
    (dailyFlowTotalIncome report)
  assertEqual
    "daily flow excludes asset and equity counterpart postings"
    expectedExpenses
    (dailyFlowTotalExpenses report)
  assertEqual
    "daily flow subtracts expenses without mixing commodities"
    expectedNet
    (dailyFlowTotalNet report)
  assertEqual
    "daily flow keeps income and net values separate by date and commodity"
    [ (emptyBalance, balanceFromAmounts
        [mkAmount jpy (quantityFromInteger (-100))])
    , (balanceFromAmounts [mkAmount jpy (quantityFromInteger 500)]
      , balanceFromAmounts [mkAmount jpy (quantityFromInteger 500)])
    , (balanceFromAmounts [mkAmount usd (quantityFromInteger 10)]
      , balanceFromAmounts [mkAmount usd (quantityFromInteger 10)])
    , (emptyBalance, balanceFromAmounts
        [mkAmount usd (quantityFromInteger (-3))])
    ]
    [ (dailyFlowIncome line, dailyFlowNet line)
    | line <- dailyFlowLines report
    ]

  let food = mustRight (mkAccount "living:food")
      travel = mustRight (mkAccount "living:travel")
      expenseRows = dailyFlowExpenseRows report
  assertEqual
    "daily flow exposes Expense Account × Date values"
    [ DailyFlowExpenseRow food (Map.singleton
        (fromGregorian 2026 8 10)
        (balanceFromAmounts [mkAmount jpy (quantityFromInteger 100)]))
    , DailyFlowExpenseRow travel (Map.singleton
        (fromGregorian 2026 8 21)
        (balanceFromAmounts [mkAmount usd (quantityFromInteger 3)]))
    ]
    expenseRows
  assertEqual
    "daily flow expense rows derive Total column values without mixing commodities"
    [ balanceFromAmounts [mkAmount jpy (quantityFromInteger 100)]
    , balanceFromAmounts [mkAmount usd (quantityFromInteger 3)]
    ]
    (map dailyFlowExpenseTotal expenseRows)
  assertEqual
    "validated journals have no unclassified daily-flow accounts"
    []
    (dailyFlowUnclassified report)

  calendarBlockTests report

  let unknownLeft = mustRight (mkAccount "unknown:left")
      unknownRight = mustRight (mkAccount "unknown:right")
      unknownTransaction = mustRight (mkTransaction
        (fromGregorian 2026 8 25)
        "Programmatic unknown accounts"
        ( mkPosting unknownLeft
            (mkAmount jpy (quantityFromInteger 1))
        :| [ mkPosting unknownRight
              (mkAmount jpy (quantityFromInteger (-1)))
           ]
        ))
      unknownReport = dailyFlow dateRange
        (journalFromTransactions [unknownTransaction])
  assertEqual
    "unclassified programmatic accounts are not invented as flow"
    []
    (dailyFlowLines unknownReport)
  assertEqual
    "unclassified programmatic accounts remain visible"
    2
    (length (dailyFlowUnclassified unknownReport))
  assertEqual
    "the renderer names unclassified daily-flow evidence"
    True
    ("Unclassified accounts" `T.isInfixOf` renderDailyFlow unknownReport)

  presentationWindowTests jpy
  zeroTotalRowTests

calendarBlockTests :: DailyFlow -> IO ()
calendarBlockTests report = do
  let dateColumns = mustRight (mkDateColumnCount 10)
      rendered = renderDailyFlowWithDateColumns dateColumns report
      headerLines = filter ("\ESC[1mCategory" `T.isPrefixOf`) (T.lines rendered)
  assertEqual "a 31-day range is split into four date blocks"
    4
    (length headerLines)
  assertTrue "the renderer includes every calendar day, including quiet days"
    (all (`T.isInfixOf` rendered) ["08-01", "08-02", "08-31"])
  assertTrue "the renderer labels the complete configured range"
    (all (`T.isInfixOf` rendered)
      [ "Requested period: 2026-08-01 .. 2026-08-31"
      , "Displayed: 2026-08-01 .. 2026-08-31 (31 calendar days)"
      , "Max date columns: 10"
      ])
  assertTrue "the renderer publishes deterministic block coordinates"
    (all (`T.isInfixOf` rendered)
      [ "Dates: 2026-08-01 .. 2026-08-10 | Block 1/4"
      , "Dates: 2026-08-31 .. 2026-08-31 | Block 4/4"
      ])
  assertEqual "each block shows its block-total column"
    4
    (countOccurrences "Block total" rendered)
  assertEqual "each block repeats the configured-period total column"
    4
    (countOccurrences "Period total" rendered)
  assertTrue "period totals preserve every commodity"
    (all (`T.isInfixOf` rendered)
      ["500 JPY, 10 USD", "400 JPY, 7 USD"])

  let oneBlock = renderDailyFlowWithDateColumns
        (mustRight (mkDateColumnCount 31)) report
  assertEqual "a single block omits the duplicate block-total column"
    0
    (countOccurrences "Block total" oneBlock)
  assertEqual "a single block retains the period-total column"
    1
    (countOccurrences "Period total" oneBlock)

presentationWindowTests :: Commodity -> IO ()
presentationWindowTests jpy = do
  let start = fromGregorian 2026 9 1
      end = fromGregorian 2026 9 15
      dateRange = mustRight (mkDateRange start end)
      report = dailyFlow dateRange (mustRight (parseJournal windowJournalInput))
      dateColumns = mustRight (mkDateColumnCount 10)
      rendered = renderDailyFlowWithDateColumns dateColumns report
      expenseRow = case dailyFlowExpenseRows report of
        [row] -> row
        rows -> error ("expected one expense row, got " ++ show rows)
      headerLines = filter ("\ESC[1mCategory" `T.isPrefixOf`) (T.lines rendered)
  assertEqual
    "daily flow model retains every flow day"
    15
    (length (dailyFlowLines report))
  assertEqual
    "typed expense dates retain every Account × Day association"
    [fromGregorian 2026 9 day | day <- [1..15]]
    (Map.keys (dailyFlowExpenseByDate expenseRow))
  assertEqual
    "expense total remains the complete requested-period result"
    (balanceFromAmounts [mkAmount jpy (quantityFromInteger 15)])
    (dailyFlowExpenseTotal expenseRow)
  assertEqual "fifteen calendar days split into ten and five columns"
    2
    (length headerLines)
  assertTrue "both calendar block endpoints remain visible"
    (all (`T.isInfixOf` rendered) ["09-01", "09-10", "09-11", "09-15"])
  assertEqual "the block total is shown in both blocks"
    2
    (countOccurrences "Block total" rendered)
  assertEqual "the period total is repeated in both blocks"
    2
    (countOccurrences "Period total" rendered)
  assertTrue "block totals are distinct from the complete period total"
    (all (`T.isInfixOf` rendered) ["10 JPY", "5 JPY", "15 JPY"])

zeroTotalRowTests :: IO ()
zeroTotalRowTests = do
  let start = fromGregorian 2026 10 1
      end = fromGregorian 2026 10 2
      dateRange = mustRight (mkDateRange start end)
      report = dailyFlow dateRange (mustRight (parseJournal zeroRowJournalInput))
      rendered = renderDailyFlow report
  assertEqual "zero-net expense evidence remains in the typed report"
    1
    (length (dailyFlowExpenseRows report))
  assertTrue "an expense account whose period total is zero is not rendered"
    (not ("temporary-cost" `T.isInfixOf` rendered))

countOccurrences :: T.Text -> T.Text -> Int
countOccurrences needle haystack
  | T.null needle = 0
  | otherwise = go haystack
  where
    go remaining = case T.breakOn needle remaining of
      (_, suffix)
        | T.null suffix -> 0
        | otherwise -> 1 + go (T.drop (T.length needle) suffix)

windowJournalInput :: T.Text
windowJournalInput = T.unlines
  ( [ "account cash"
    , "    type: asset"
    , "    commodity: JPY"
    , ""
    , "account daily-cost"
    , "    type: expense"
    , "    commodity: JPY"
    , ""
    ]
    ++ concat
      [ [ "2026-09-" <> T.justifyRight 2 '0' (T.pack (show day))
            <> " Daily expense"
        , "    daily-cost  1 JPY"
        , "    cash"
        , ""
        ]
      | day <- [1 :: Int .. 15]
      ]
  )

zeroRowJournalInput :: T.Text
zeroRowJournalInput = T.unlines
  [ "account cash"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account temporary-cost"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "2026-10-01 Temporary expense"
  , "    temporary-cost  100 JPY"
  , "    cash"
  , ""
  , "2026-10-02 Full refund"
  , "    cash  100 JPY"
  , "    temporary-cost"
  ]

journalInput :: T.Text
journalInput = T.unlines
  [ "account wallet:cash"
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
  , "account living:food"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account earnings:salary"
  , "    type: income"
  , "    commodity: JPY"
  , ""
  , "account earnings:bonus"
  , "    type: income"
  , "    commodity: USD"
  , ""
  , "account living:travel"
  , "    type: expense"
  , "    commodity: USD"
  , ""
  , "2026-08-01 Opening balance"
  , "    wallet:cash  1000 JPY"
  , "    capital:opening"
  , ""
  , "2026-08-10 Buy food"
  , "    living:food  100 JPY"
  , "    wallet:cash"
  , ""
  , "2026-08-15 Salary"
  , "    wallet:cash  500 JPY"
  , "    earnings:salary"
  , ""
  , "2026-08-20 Bonus"
  , "    wallet:dollars  10 USD"
  , "    earnings:bonus"
  , ""
  , "2026-08-21 Travel"
  , "    living:travel  3 USD"
  , "    wallet:dollars"
  ]

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

assertTrue :: String -> Bool -> IO ()
assertTrue label actual = assertEqual label True actual

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
