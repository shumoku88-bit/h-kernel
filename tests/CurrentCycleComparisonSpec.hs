{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Account (Account, mkAccount)
import HKernel.Journal (parseJournal)
import HKernel.Money
import HKernel.Period (Period, mkPeriod)
import HKernel.Report.CycleAccounts
import System.Exit (exitFailure)

main :: IO ()
main = do
  let journal = mustRight (parseJournal journalText)
      baselinePeriod = mustPeriod
        (fromGregorian 2026 4 1)
        (fromGregorian 2026 5 1)
      currentPeriod = mustPeriod
        (fromGregorian 2026 5 1)
        (fromGregorian 2026 6 1)
      baselineComplete = mustRight
        (currentCycleAccounts (fromGregorian 2026 4 30) baselinePeriod journal)
      currentComplete = mustRight
        (currentCycleAccounts (fromGregorian 2026 5 31) currentPeriod journal)
      currentAligned = mustRight
        (currentCycleAccounts (fromGregorian 2026 5 30) currentPeriod journal)
      comparisonComplete = mustRight
        (cycleComparison CompleteCycles currentComplete baselineComplete)
      comparisonAligned = mustRight
        (cycleComparison AlignedElapsed currentAligned baselineComplete)
      cash = mustAccount "assets:cash"
      food = mustAccount "expenses:food"
      income = mustAccount "income:salary"
      equity = mustAccount "equity:opening"
      jpy = mustRight (mkCommodity "JPY")
      cashRow = currentRow cash currentComplete
      foodRow = currentRow food currentComplete
      incomeRow = currentRow income currentComplete
      equityRow = currentRow equity currentComplete

  assertEqual "current cycle publishes the complete canonical Account axis"
    [cash, equity, food, income]
    (map currentCycleAccount (currentCycleAccountsRows currentComplete))

  assertEqual "opening is the exact Account balance before cycle start"
    (one jpy 130)
    (currentCycleAccountOpening cashRow)
  assertEqual "positive postings form the debit lane"
    (one jpy 70)
    (currentCycleAccountDebit cashRow)
  assertEqual "negative postings retain their sign in the credit lane"
    (one jpy (-30))
    (currentCycleAccountCredit cashRow)
  assertEqual "movement is debit plus signed credit"
    (one jpy 40)
    (currentCycleAccountRowMovement cashRow)
  assertEqual "closing is opening plus movement"
    (one jpy 170)
    (currentCycleAccountRowClosing cashRow)

  assertEqual "Expense debit movement remains exact"
    (emptyBalance, one jpy 30, emptyBalance, one jpy 30)
    ( currentCycleAccountOpening foodRow
    , currentCycleAccountDebit foodRow
    , currentCycleAccountCredit foodRow
    , currentCycleAccountRowMovement foodRow
    )
  assertEqual "Income credit movement remains signed"
    (one jpy (-50), emptyBalance, one jpy (-70), one jpy (-120))
    ( currentCycleAccountOpening incomeRow
    , currentCycleAccountDebit incomeRow
    , currentCycleAccountCredit incomeRow
    , currentCycleAccountRowClosing incomeRow
    )
  assertEqual "Account with no current movement remains on the canonical axis"
    (one jpy (-100), emptyBalance, emptyBalance, one jpy (-100))
    ( currentCycleAccountOpening equityRow
    , currentCycleAccountDebit equityRow
    , currentCycleAccountCredit equityRow
    , currentCycleAccountRowClosing equityRow
    )

  assertEqual "opening/debit+credit/closing totals obey double entry"
    True
    (currentCycleAccountsBalanced currentComplete)
  assertEqual "debit and signed credit totals cancel"
    emptyBalance
    (sumBalances
      [ currentCycleAccountsDebitTotal currentComplete
      , currentCycleAccountsCreditTotal currentComplete
      ])

  assertEqual "complete cycle comparison keeps its explicit policy"
    CompleteCycles
    (cycleComparisonPolicy comparisonComplete)
  assertEqual "complete cycles may have different calendar day counts"
    (one jpy 10, one jpy (-20), one jpy 10)
    ( differenceFor cash comparisonComplete
    , differenceFor income comparisonComplete
    , differenceFor food comparisonComplete
    )
  assertEqual "comparison differences remain double-entry balanced"
    True
    (cycleComparisonBalanced comparisonComplete)
  assertEqual "aligned elapsed accepts equal observed day counts"
    AlignedElapsed
    (cycleComparisonPolicy comparisonAligned)

  assertEqual "aligned elapsed rejects unequal day counts"
    (Left (CycleComparisonElapsedDayCountMismatch 31 30))
    (cycleComparison AlignedElapsed currentComplete baselineComplete)

  let incompleteCurrent = mustRight
        (currentCycleAccounts (fromGregorian 2026 5 30) currentPeriod journal)
  assertEqual "complete cycle policy rejects partial observation"
    (Left CycleComparisonRequiresCompleteCycles)
    (cycleComparison CompleteCycles incompleteCurrent baselineComplete)

  assertEqual "observation must occur inside the resolved period"
    (Left (CurrentCycleObservationOutsidePeriod (fromGregorian 2026 6 1)))
    (currentCycleAccounts (fromGregorian 2026 6 1) currentPeriod journal)

  let smallerJournal = mustRight (parseJournal journalWithoutEquity)
      smallerCurrent = mustRight
        (currentCycleAccounts (fromGregorian 2026 5 31) currentPeriod smallerJournal)
  assertEqual "comparison rejects different canonical Account axes"
    (Left CycleComparisonAccountAxisMismatch)
    (cycleComparison CompleteCycles currentComplete smallerCurrent)

currentRow :: Account -> CurrentCycleAccounts -> CurrentCycleAccountRow
currentRow account report = case filter ((== account) . currentCycleAccount)
    (currentCycleAccountsRows report) of
  [row] -> row
  rows -> error ("expected one current-cycle row, got " <> show rows)

differenceFor :: Account -> CycleComparison -> Balance
differenceFor account report = case filter ((== account) . cycleComparisonAccount)
    (cycleComparisonRows report) of
  [row] -> cycleComparisonRowDifference row
  rows -> error ("expected one comparison row, got " <> show rows)

one :: Commodity -> Integer -> Balance
one commodity value =
  singletonBalance (mkAmount commodity (quantityFromInteger value))

mustAccount :: Text -> Account
mustAccount = mustRight . mkAccount

mustPeriod :: Day -> Day -> Period
mustPeriod start endExclusive = mustRight (mkPeriod start endExclusive)

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid fixture: " <> show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " <> label)
  | otherwise = do
      putStrLn ("  [FAIL] " <> label)
      putStrLn ("    expected: " <> show expected)
      putStrLn ("    but got:  " <> show actual)
      exitFailure

journalText :: Text
journalText = T.unlines
  [ "account assets:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , "account equity:opening"
  , "    type: equity"
  , "    commodity: JPY"
  , "account expenses:food"
  , "    type: expense"
  , "    commodity: JPY"
  , "account income:salary"
  , "    type: income"
  , "    commodity: JPY"
  , ""
  , "2026-03-31 opening"
  , "    assets:cash       100 JPY"
  , "    equity:opening   -100 JPY"
  , ""
  , "2026-04-10 baseline food"
  , "    expenses:food      20 JPY"
  , "    assets:cash        -20 JPY"
  , ""
  , "2026-04-20 baseline salary"
  , "    assets:cash         50 JPY"
  , "    income:salary      -50 JPY"
  , ""
  , "2026-05-10 current food"
  , "    expenses:food      30 JPY"
  , "    assets:cash        -30 JPY"
  , ""
  , "2026-05-20 current salary"
  , "    assets:cash         70 JPY"
  , "    income:salary      -70 JPY"
  ]

journalWithoutEquity :: Text
journalWithoutEquity = T.unlines
  [ "account assets:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , "account expenses:food"
  , "    type: expense"
  , "    commodity: JPY"
  , "account income:salary"
  , "    type: income"
  , "    commodity: JPY"
  , ""
  , "2026-04-10 baseline food"
  , "    expenses:food      20 JPY"
  , "    assets:cash        -20 JPY"
  , ""
  , "2026-04-20 baseline salary"
  , "    assets:cash         50 JPY"
  , "    income:salary      -50 JPY"
  , ""
  , "2026-05-10 current food"
  , "    expenses:food      30 JPY"
  , "    assets:cash        -30 JPY"
  , ""
  , "2026-05-20 current salary"
  , "    assets:cash         70 JPY"
  , "    income:salary      -70 JPY"
  ]
