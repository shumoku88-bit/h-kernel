{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual, assertTrue)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Journal (parseJournal)
import HKernel.Money
import HKernel.Render (renderBalanceSheet)
import HKernel.Report
import System.Exit (exitFailure)

main :: IO ()
main = do
  let journal = mustRight (parseJournal journalInput)
      report = balanceSheetAsOf (fromGregorian 2026 1 3) journal
      expectedPostedEquity = integerBalance 10000
      expectedCurrentEarnings = integerBalance 3000
      expectedTotalEquity = integerBalance 13000
      rendered = renderBalanceSheet report

  assertEqual "posted equity retains only posted Equity accounts"
    expectedPostedEquity
    (postedEquity report)
  assertEqual "current earnings derive unclosed income minus expenses"
    expectedCurrentEarnings
    (currentEarnings report)
  assertEqual "total equity combines posted equity and current earnings"
    expectedTotalEquity
    (totalEquity report)
  assertEqual "balance sheet equation uses the composed total equity"
    emptyBalance
    (accountingEquationDelta report)
  assertTrue "renderer publishes current earnings separately"
    ("Current earnings" `T.isInfixOf` rendered
      && "3,000 JPY" `T.isInfixOf` rendered)
  assertTrue "renderer publishes the composed Total equity"
    ("Total equity" `T.isInfixOf` rendered
      && "13,000 JPY" `T.isInfixOf` rendered)

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
  , "account income:salary"
  , "    type: income"
  , "    commodity: JPY"
  , ""
  , "account expenses:food"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "2026-01-01 Opening balance"
  , "    assets:cash  10000 JPY"
  , "    equity:opening"
  , ""
  , "2026-01-02 Salary"
  , "    assets:cash  5000 JPY"
  , "    income:salary"
  , ""
  , "2026-01-03 Food"
  , "    expenses:food  2000 JPY"
  , "    assets:cash"
  ]

integerBalance :: Integer -> Balance
integerBalance value =
  singletonBalance
    (mkAmount commodity (quantityFromInteger value))
  where
    commodity = mustRight (mkCommodity "JPY")





