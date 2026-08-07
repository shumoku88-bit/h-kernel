{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Account (Account, mkAccount)
import HKernel.Journal (journalFromTransactions, parseJournal)
import HKernel.Ledger (mkPosting, mkTransaction)
import HKernel.Money
import HKernel.Period (Period, mkPeriod)
import HKernel.Render (renderCycleAccounts)
import HKernel.Report.CycleAccounts
import System.Exit (exitFailure)

main :: IO ()
main = do
  let journal = mustRight (parseJournal journalInput)
      previousPeriod = mustPeriod
        (fromGregorian 2026 4 15)
        (fromGregorian 2026 6 15)
      currentPeriod = mustPeriod
        (fromGregorian 2026 6 15)
        (fromGregorian 2026 8 15)
      report = cycleAccounts currentPeriod previousPeriod journal
      currentCycle = mustRight
        (currentCycleAccounts (fromGregorian 2026 8 14) currentPeriod journal)
      previousCycle = mustRight
        (currentCycleAccounts (fromGregorian 2026 6 14) previousPeriod journal)
      completeComparison = mustRight
        (cycleComparison CompleteCycles currentCycle previousCycle)
      alignedComparison = mustRight
        (cycleComparison AlignedElapsed currentCycle previousCycle)
      jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      food = mustRight (mkAccount "cost:food")
      medical = mustRight (mkAccount "cost:medical")
      oldExpense = mustRight (mkAccount "cost:old")
      travel = mustRight (mkAccount "cost:travel")
      foodRow = rowFor food report
      medicalRow = rowFor medical report
      oldRow = rowFor oldExpense report
      travelRow = rowFor travel report
      currentFood = currentRowFor food currentCycle

  assertEqual
    "current-cycle report retains the explicit cycle"
    currentPeriod
    (currentCycleAccountsPeriod currentCycle)
  assertEqual
    "current-cycle report retains the inclusive observation"
    (fromGregorian 2026 8 14)
    (currentCycleAccountsObservation currentCycle)
  assertEqual
    "current-cycle report publishes every declared Account in canonical order"
    8
    (length (currentCycleAccountsRows currentCycle))
  assertEqual
    "current-cycle opening is the exact balance before cycle start"
    (jpyBalance 100 jpy)
    (currentCycleAccountOpening currentFood)
  assertEqual
    "current-cycle debit lane keeps positive movement"
    (jpyBalance 150 jpy)
    (currentCycleAccountDebit currentFood)
  assertEqual
    "current-cycle credit lane keeps signed negative movement"
    (jpyBalance (-20) jpy)
    (currentCycleAccountCredit currentFood)
  assertEqual
    "current-cycle movement is debit plus signed credit"
    (jpyBalance 130 jpy)
    (currentCycleAccountRowMovement currentFood)
  assertEqual
    "current-cycle closing is opening plus movement"
    (jpyBalance 230 jpy)
    (currentCycleAccountRowClosing currentFood)
  assertEqual
    "current-cycle opening, movement, and closing remain double-entry balanced"
    True
    (currentCycleAccountsBalanced currentCycle)
  assertEqual
    "current-cycle debit and signed credit totals cancel exactly"
    emptyBalance
    (sumBalances
      [ currentCycleAccountsDebitTotal currentCycle
      , currentCycleAccountsCreditTotal currentCycle
      ])

  assertEqual
    "complete cycle comparison retains its policy"
    CompleteCycles
    (cycleComparisonPolicy completeComparison)
  assertEqual
    "aligned elapsed accepts equal observed day counts"
    AlignedElapsed
    (cycleComparisonPolicy alignedComparison)
  assertEqual
    "cycle comparison publishes current minus baseline movement"
    (jpyBalance 30 jpy)
    (comparisonDifferenceFor food completeComparison)
  assertEqual
    "cycle comparison remains balanced by Commodity"
    True
    (cycleComparisonBalanced completeComparison)

  let partialCurrent = mustRight
        (currentCycleAccounts (fromGregorian 2026 8 13) currentPeriod journal)
  assertEqual
    "aligned elapsed rejects different observed day counts"
    (Left (CycleComparisonElapsedDayCountMismatch 60 61))
    (cycleComparison AlignedElapsed partialCurrent previousCycle)
  assertEqual
    "complete comparison rejects a partial current cycle"
    (Left CycleComparisonRequiresCompleteCycles)
    (cycleComparison CompleteCycles partialCurrent previousCycle)
  assertEqual
    "current-cycle observation must occur inside the resolved period"
    (Left (CurrentCycleObservationOutsidePeriod (fromGregorian 2026 8 15)))
    (currentCycleAccounts (fromGregorian 2026 8 15) currentPeriod journal)

  assertEqual
    "cycle accounts retain the explicit current observation period"
    currentPeriod
    (cycleAccountsCurrentPeriod report)
  assertEqual
    "cycle accounts retain the explicit previous observation period"
    previousPeriod
    (cycleAccountsPreviousPeriod report)
  assertEqual
    "Expense rows align in canonical full Account order"
    [food, medical, oldExpense, travel]
    (map cycleAccountRowAccount (cycleAccountsRows report))

  assertEqual
    "an account present in both periods publishes exact current, previous, and delta"
    ( jpyBalance 130 jpy
    , jpyBalance 100 jpy
    , jpyBalance 30 jpy
    )
    ( cycleAccountRowCurrent foodRow
    , cycleAccountRowPrevious foodRow
    , cycleAccountRowDelta foodRow
    )
  assertEqual
    "an account present only in the current period retains canonical previous zero"
    (jpyBalance 30 jpy, emptyBalance, jpyBalance 30 jpy)
    ( cycleAccountRowCurrent medicalRow
    , cycleAccountRowPrevious medicalRow
    , cycleAccountRowDelta medicalRow
    )
  assertEqual
    "an account present only in the previous period retains canonical current zero"
    (emptyBalance, jpyBalance 40 jpy, jpyBalance (-40) jpy)
    ( cycleAccountRowCurrent oldRow
    , cycleAccountRowPrevious oldRow
    , cycleAccountRowDelta oldRow
    )
  assertEqual
    "cycle comparison preserves a second commodity without conversion"
    (usdBalance 2 usd, usdBalance 5 usd, usdBalance (-3) usd)
    ( cycleAccountRowCurrent travelRow
    , cycleAccountRowPrevious travelRow
    , cycleAccountRowDelta travelRow
    )

  assertEqual
    "declared Income and Asset movement do not enter Cycle Accounts"
    False
    (any ((== mustRight (mkAccount "revenue:salary"))
      . cycleAccountRowAccount) (cycleAccountsRows report))
  assertEqual
    "the exclusive current-period end is excluded"
    (jpyBalance 130 jpy)
    (cycleAccountRowCurrent foodRow)
  assertEqual
    "period starts and final included days belong to their selected observations"
    (jpyBalance 40 jpy, usdBalance 2 usd)
    ( cycleAccountRowPrevious oldRow
    , cycleAccountRowCurrent travelRow
    )

  let expectedCurrentTotal = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 160)
        , mkAmount usd (quantityFromInteger 2)
        ]
      expectedPreviousTotal = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 140)
        , mkAmount usd (quantityFromInteger 5)
        ]
      expectedDeltaTotal = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 20)
        , mkAmount usd (quantityFromInteger (-3))
        ]
  assertEqual
    "current total is derived across aligned Expense rows"
    expectedCurrentTotal
    (cycleAccountsCurrentTotal report)
  assertEqual
    "previous total is derived across aligned Expense rows"
    expectedPreviousTotal
    (cycleAccountsPreviousTotal report)
  assertEqual
    "total delta is exact current minus previous by commodity"
    expectedDeltaTotal
    (cycleAccountsDeltaTotal report)
  assertEqual
    "validated Journal input has no unclassified cycle rows"
    []
    (cycleAccountsUnclassifiedRows report)

  let rendered = renderCycleAccounts report
  assertEqual
    "cycle renderer publishes the explicit half-open coordinates"
    True
    ("Current: [2026-06-15, 2026-08-15)" `T.isInfixOf` rendered
      && "Previous: [2026-04-15, 2026-06-15)" `T.isInfixOf` rendered)
  assertEqual
    "cycle renderer preserves commodity-separated totals"
    True
    ("160 JPY, 2 USD" `T.isInfixOf` rendered
      && "140 JPY, 5 USD" `T.isInfixOf` rendered)

  let unknownLeft = mustRight (mkAccount "unknown:left")
      unknownRight = mustRight (mkAccount "unknown:right")
      unknownTransaction = mustRight (mkTransaction
        (fromGregorian 2026 7 1)
        "Programmatic unknown accounts"
        ( mkPosting unknownLeft
            (mkAmount jpy (quantityFromInteger 7))
        :| [ mkPosting unknownRight
              (mkAmount jpy (quantityFromInteger (-7)))
           ]
        ))
      unknownReport = cycleAccounts currentPeriod previousPeriod
        (journalFromTransactions [unknownTransaction])
  assertEqual
    "undeclared programmatic accounts are not invented as Expense rows"
    []
    (cycleAccountsRows unknownReport)
  assertEqual
    "undeclared programmatic accounts remain visible as separate evidence"
    [unknownLeft, unknownRight]
    (map cycleAccountRowAccount
      (cycleAccountsUnclassifiedRows unknownReport))

currentRowFor :: Account -> CurrentCycleAccounts -> CurrentCycleAccountRow
currentRowFor account report = case filter ((== account) . currentCycleAccount)
    (currentCycleAccountsRows report) of
  [row] -> row
  unexpected -> error ("expected one current-cycle row, got " ++ show unexpected)

comparisonDifferenceFor :: Account -> CycleComparison -> Balance
comparisonDifferenceFor account report = case filter
    ((== account) . cycleComparisonAccount) (cycleComparisonRows report) of
  [row] -> cycleComparisonRowDifference row
  unexpected -> error ("expected one comparison row, got " ++ show unexpected)

rowFor :: Account -> CycleAccounts -> CycleAccountRow
rowFor account report = case filter ((== account) . cycleAccountRowAccount)
    (cycleAccountsRows report) of
  [row] -> row
  unexpected -> error ("expected one cycle account row, got " ++ show unexpected)

mustPeriod :: Day -> Day -> Period
mustPeriod start endExclusive =
  mustRight (mkPeriod start endExclusive)

jpyBalance :: Integer -> Commodity -> Balance
jpyBalance value commodity =
  singletonBalance (mkAmount commodity (quantityFromInteger value))

usdBalance :: Integer -> Commodity -> Balance
usdBalance = jpyBalance

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
  , "account revenue:salary"
  , "    type: income"
  , "    commodity: JPY"
  , ""
  , "account cost:food"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account cost:medical"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account cost:old"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account cost:travel"
  , "    type: expense"
  , "    commodity: USD"
  , ""
  , "2026-04-15 Previous food boundary"
  , "    cost:food  100 JPY"
  , "    wallet:cash"
  , ""
  , "2026-05-20 Previous travel"
  , "    cost:travel  5 USD"
  , "    wallet:dollars"
  , ""
  , "2026-06-14 Previous-only boundary"
  , "    cost:old  40 JPY"
  , "    wallet:cash"
  , ""
  , "2026-06-15 Current food boundary"
  , "    cost:food  150 JPY"
  , "    wallet:cash"
  , ""
  , "2026-07-01 Food refund"
  , "    wallet:cash  20 JPY"
  , "    cost:food"
  , ""
  , "2026-07-10 Current-only medical"
  , "    cost:medical  30 JPY"
  , "    wallet:cash"
  , ""
  , "2026-07-20 Salary excluded from Expense comparison"
  , "    wallet:cash  500 JPY"
  , "    revenue:salary"
  , ""
  , "2026-08-14 Current travel boundary"
  , "    cost:travel  2 USD"
  , "    wallet:dollars"
  , ""
  , "2026-08-15 Food at exclusive current-period end"
  , "    cost:food  999 JPY"
  , "    wallet:cash"
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
