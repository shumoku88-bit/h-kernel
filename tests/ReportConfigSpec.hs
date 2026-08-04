{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Engine (rangeEnd, rangeStart)
import HKernel.Journal (parseJournal)
import HKernel.Report (recentCountValue)
import HKernel.Report.Config
import HKernel.Report.Plan
import HKernel.Report.Presentation
import System.Exit (exitFailure)

main :: IO ()
main = do
  let configuration = mustRight (parseReportConfiguration validConfig)
      plan = reportConfigurationPlan configuration
      presentation = reportConfigurationPresentation configuration
      journal = mustRight (parseJournal journalInput)
      latest = fromGregorian 2026 8 1
      resolved = mustRight (resolveReportPlan latest journal plan)

  assertEqual "trial balance resolves latest once"
    latest
    (resolvedTrialBalanceAsOf resolved)
  assertEqual "balance sheet accepts an exact as-of date"
    (fromGregorian 2026 7 31)
    (resolvedBalanceSheetAsOf resolved)
  assertEqual "profit and loss keeps its configured start"
    (fromGregorian 2026 6 15)
    (rangeStart (resolvedProfitAndLossRange resolved))
  assertEqual "profit and loss resolves latest as its end"
    latest
    (rangeEnd (resolvedProfitAndLossRange resolved))
  assertEqual "beginning resolves to the first eligible journal date"
    (fromGregorian 2026 4 15)
    (rangeStart (resolvedMonthlyAccountsRange resolved))
  assertEqual "recent count is validated and retained"
    7
    (recentCountValue (resolvedRecentTransactionsCount resolved))
  assertEqual "negative amount style is validated and retained"
    LeadingMinus
    (presentationNegativeStyle presentation)
  assertEqual "negative amount color is validated and retained"
    MagentaColor
    (presentationNegativeColor presentation)
  assertEqual "daily flow date columns are validated and retained"
    10
    (dateColumnCountValue
      (presentationDailyFlowDateColumns presentation))

  let defaultColumnsConfiguration = mustRight
        (parseReportConfiguration
          (T.replace "max-date-columns = 10\n" "" validConfig))
  assertEqual "daily flow date columns default to fourteen"
    14
    (dateColumnCountValue
      (presentationDailyFlowDateColumns
        (reportConfigurationPresentation defaultColumnsConfiguration)))

  let defaultPresentationConfiguration = mustRight
        (parseReportConfiguration
          (T.replace presentationTable "" validConfig))
  assertEqual "negative amount style defaults to accounting parentheses"
    AccountingParentheses
    (presentationNegativeStyle
      (reportConfigurationPresentation defaultPresentationConfiguration))
  assertEqual "negative amount color defaults to red"
    RedColor
    (presentationNegativeColor
      (reportConfigurationPresentation defaultPresentationConfiguration))

  assertLeft "unknown TOML keys are not silently ignored"
    (parseReportConfiguration
      (validConfig <> "\n[reports.daily-flow.extra]\nvalue = 1\n"))
  assertLeft "invalid dates are rejected with domain context"
    (parseReportConfiguration
      (T.replace "2026-06-15" "not-a-date" validConfig))
  assertLeft "unknown negative amount styles are rejected"
    (parseReportConfiguration
      (T.replace "negative-style = \"minus\""
        "negative-style = \"absolute\"" validConfig))
  assertLeft "unknown negative amount colors are rejected"
    (parseReportConfiguration
      (T.replace "negative-color = \"magenta\""
        "negative-color = \"invalid-color\"" validConfig))
  assertLeft "non-positive recent counts are rejected"
    (parseReportConfiguration
      (T.replace "count = 7" "count = 0" validConfig))
  assertLeft "non-positive daily flow date columns are rejected"
    (parseReportConfiguration
      (T.replace "max-date-columns = 10" "max-date-columns = 0" validConfig))

presentationTable :: T.Text
presentationTable = T.unlines
  [ "[presentation.amounts]"
  , "negative-style = \"minus\""
  , "negative-color = \"magenta\""
  , ""
  ]

validConfig :: T.Text
validConfig = presentationTable <> T.unlines
  [ "[reports.trial-balance]"
  , "as-of = \"latest\""
  , ""
  , "[reports.balance-sheet]"
  , "as-of = \"2026-07-31\""
  , ""
  , "[reports.profit-and-loss]"
  , "from = \"2026-06-15\""
  , "through = \"latest\""
  , ""
  , "[reports.daily-flow]"
  , "from = \"2026-07-18\""
  , "through = \"latest\""
  , "max-date-columns = 10"
  , ""
  , "[reports.monthly-accounts]"
  , "from = \"beginning\""
  , "through = \"latest\""
  , ""
  , "[reports.recent-transactions]"
  , "through = \"latest\""
  , "count = 7"
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
  , "2026-04-15 Opening"
  , "    assets:cash  100 JPY"
  , "    equity:opening"
  ]

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly decoded: " ++ show value)
    exitFailure

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
