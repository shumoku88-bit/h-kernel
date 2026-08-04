{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Journal (journalFromTransactions, parseJournal)
import HKernel.Ledger
import HKernel.Render (renderRecentTransactions)
import HKernel.Report
import System.Exit (exitFailure)

main :: IO ()
main = do
  assertEqual
    "recent count rejects zero"
    (Left (RecentCountMustBePositive 0))
    (mkRecentCount 0)
  assertEqual
    "recent count rejects negative values"
    (Left (RecentCountMustBePositive (-2)))
    (mkRecentCount (-2))
  assertEqual
    "the default report limit remains explicit"
    5
    (recentCountValue defaultRecentCount)

  let journal = mustRight (parseJournal journalInput)
      count = mustRight (mkRecentCount 3)
      asOf = fromGregorian 2026 8 20
      report = recentTransactions count asOf journal
      transactions = recentTransactionItems report

  assertEqual
    "recent transactions retain the explicit as-of date"
    asOf
    (recentTransactionsAsOf report)
  assertEqual
    "recent transactions retain the validated limit"
    count
    (recentTransactionsCount report)
  assertEqual
    "recent transactions select whole transactions newest first"
    [ "Split purchase"
    , "Same-day transfer"
    , "Salary"
    ]
    (map transactionDescription transactions)

  case transactions of
    splitPurchase : sameDayTransfer : salary : [] -> do
      assertEqual
        "a three-posting transaction is not flattened or truncated"
        3
        (NonEmpty.length (transactionPostings splitPurchase))
      assertEqual
        "same-date transactions retain journal order"
        (fromGregorian 2026 8 20)
        (transactionDate sameDayTransfer)
      assertEqual
        "the third selected transaction remains complete"
        2
        (NonEmpty.length (transactionPostings salary))
    _ -> failTest "expected exactly three recent transactions"

  assertEqual
    "transactions after the as-of date are excluded"
    False
    ("Future salary" `elem` map transactionDescription transactions)

  let rendered = renderRecentTransactions report
  assertEqual
    "the renderer preserves whole transactions in the terminal style"
    True
    ( all (`T.isInfixOf` rendered)
        [ "\ESC[1;36m== Recent Transactions (Last 3 Transactions) ==\ESC[0m"
        , "\ESC[2mAs of: 2026-08-20\ESC[0m"
        , "\ESC[33m2026-08-20  Split purchase\ESC[0m"
        , "living:food"
        , "living:household"
        , "wallet:cash"
        , "\ESC[31m(100 JPY)\ESC[0m"
        ]
    )

  let emptyReport = recentTransactions count asOf
        (journalFromTransactions ([] :: [Transaction]))
  assertEqual
    "an empty journal yields an empty recent report"
    []
    (recentTransactionItems emptyReport)
  assertEqual
    "the empty recent report renders explicitly"
    True
    ("(none)" `T.isInfixOf` renderRecentTransactions emptyReport)

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
  , "account capital:opening"
  , "    type: equity"
  , "    commodity: JPY"
  , ""
  , "account revenue:salary"
  , "    type: income"
  , "    commodity: JPY"
  , ""
  , "account living:food"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account living:household"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "2026-08-01 Opening balance"
  , "    wallet:cash  1000 JPY"
  , "    capital:opening"
  , ""
  , "2026-08-20 Split purchase"
  , "    living:food         60 JPY"
  , "    living:household    40 JPY"
  , "    wallet:cash       -100 JPY"
  , ""
  , "2026-08-15 Salary"
  , "    wallet:cash       500 JPY"
  , "    revenue:salary   -500 JPY"
  , ""
  , "2026-08-20 Same-day transfer"
  , "    wallet:savings     50 JPY"
  , "    wallet:cash       -50 JPY"
  , ""
  , "2026-08-25 Future salary"
  , "    wallet:cash       900 JPY"
  , "    revenue:salary   -900 JPY"
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

failTest :: String -> IO value
failTest message = do
  putStrLn ("  [FAIL] " ++ message)
  exitFailure
