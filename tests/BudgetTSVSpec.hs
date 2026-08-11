{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import HKernel.Budget
import HKernel.Budget.History (budgetHistoryChanges)
import HKernel.Budget.TSV
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeValidTable
  characterizeHeaderAdmission
  characterizeRowAdmission
  characterizeEntitlementHistory

characterizeValidTable :: IO ()
characterizeValidTable = do
  let history = mustRight (parseBudgetTSV validTable)
      changes = budgetHistoryChanges history
      food = mustRight (mkEnvelopeId "food")
      negativeFiveThousand = quantityFromInteger (-5000)

  assertEqual "valid table retains all six changes"
    6
    (length changes)
  case changes of
    [_, _, _, _, foodAdjustment, stockAdjustment] -> do
      assertEqual "negative adjustment retains its envelope"
        food
        (budgetChangeEnvelope foodAdjustment)
      assertEqual "negative adjustment remains exact"
        negativeFiveThousand
        (amountQuantity (budgetChangeAmount foodAdjustment))
      assertEqual "human note is retained"
        "move to stock food"
        (budgetChangeNote foodAdjustment)
      assertEqual "paired adjustment retains the same effective day"
        (budgetChangeDate foodAdjustment)
        (budgetChangeDate stockAdjustment)
    _ -> failTest "valid table shape" "unexpected parsed change count"

  assertEqual "a header-only table represents an empty admitted history"
    []
    (budgetHistoryChanges (mustRight (parseBudgetTSV budgetHeader)))

characterizeHeaderAdmission :: IO ()
characterizeHeaderAdmission = do
  assertSingleError "missing header is rejected at line one"
    isMissingHeader
    (parseBudgetTSV "# no table yet\n\n")
  assertSingleError "header text is exact and keeps its source line"
    isInvalidHeaderAtThree
    (parseBudgetTSV (T.unlines
      [ "# budget changes"
      , ""
      , "date\tcycle_start\tenvelope"
      ]))
  where
    isMissingHeader err =
      budgetTSVErrorLine err == 1
        && budgetTSVErrorReason err == MissingBudgetTSVHeader

    isInvalidHeaderAtThree err =
      budgetTSVErrorLine err == 3
        && case budgetTSVErrorReason err of
          InvalidBudgetTSVHeader _ -> True
          _                        -> False

characterizeRowAdmission :: IO ()
characterizeRowAdmission = do
  let invalidRows = budgetHeader <> T.unlines
        [ "not-a-date\t2026-08-15\t2026-10-15\tfood\t100\tJPY\tbad date"
        , "2026-08-15\t2026-08-15\t2026-10-15\tfood\tnot-a-number\tJPY\tbad quantity"
        , "2026-08-15\t2026-08-15\t2026-10-15\tunallocated\t100\tJPY\treserved"
        ]

  assertErrorLines "independent malformed rows are reported together"
    [2, 3, 4]
    (parseBudgetTSV invalidRows)
  assertSingleError "wrong column count is rejected"
    isInvalidRow
    (parseBudgetTSV
      (budgetHeader <> "2026-08-15\t2026-08-15\t2026-10-15\tfood\t100\tJPY\n"))
  assertSingleError "empty cycle is rejected"
    isInvalidCycle
    (parseBudgetTSV
      (budgetHeader <> validRow
        "2026-08-15" "2026-08-15" "2026-08-15" "food" "100" "JPY" "empty"))
  assertSingleError "change date at the exclusive end is rejected"
    isOutsideCycle
    (parseBudgetTSV
      (budgetHeader <> validRow
        "2026-10-15" "2026-08-15" "2026-10-15" "food" "100" "JPY" "late"))
  where
    isInvalidRow err = case budgetTSVErrorReason err of
      InvalidBudgetTSVRow _ -> True
      _                     -> False

    isInvalidCycle err = case budgetTSVErrorReason err of
      InvalidBudgetTSVCycle _ -> True
      _                       -> False

    isOutsideCycle err = case budgetTSVErrorReason err of
      InvalidBudgetTSVChange _ -> True
      _                        -> False

characterizeEntitlementHistory :: IO ()
characterizeEntitlementHistory = do
  let outOfFileOrder = budgetHeader <> T.unlines
        [ budgetRow "2026-09-01" "food" "-5000" "later reduction"
        , budgetRow "2026-08-15" "food" "10000" "initial"
        ]
      sameDayOffset = budgetHeader <> T.unlines
        [ budgetRow "2026-08-15" "food" "-5000" "same day reduction"
        , budgetRow "2026-08-15" "food" "5000" "same day allocation"
        ]
      temporarilyNegative = budgetHeader <> T.unlines
        [ budgetRow "2026-08-15" "food" "10000" "initial"
        , budgetRow "2026-09-01" "food" "-15000" "too much removed"
        , budgetRow "2026-09-02" "food" "10000" "later restoration"
        ]
      expectedNegative = quantityFromInteger (-5000)

  assertRight "effective dates, not file order, govern entitlement"
    (parseBudgetTSV outOfFileOrder)
  assertRight "same-day changes combine before negativity is tested"
    (parseBudgetTSV sameDayOffset)
  assertSingleError "a negative dated entitlement remains visible despite later restoration"
    (isNegativeAtLine 3 expectedNegative)
    (parseBudgetTSV temporarilyNegative)

validTable :: T.Text
validTable = T.unlines
  [ "# pension cycle budget"
  , ""
  , T.stripEnd budgetHeader
  , budgetRow "2026-08-15" "tobacco" "10000" "initial"
  , budgetRow "2026-08-15" "food" "50000" "initial"
  , budgetRow "2026-08-15" "stock-food" "15000" "initial"
  , budgetRow "2026-08-15" "other" "10000" "initial"
  , budgetRow "2026-09-01" "food" "-5000" "move to stock food"
  , budgetRow "2026-09-01" "stock-food" "5000" "move from food"
  ]

budgetHeader :: T.Text
budgetHeader =
  "date\tcycle_start\tcycle_end_exclusive\tenvelope\tquantity\tcommodity\tnote\n"

budgetRow :: T.Text -> T.Text -> T.Text -> T.Text -> T.Text
budgetRow day envelope quantity note =
  T.intercalate "\t"
    [ day
    , "2026-08-15"
    , "2026-10-15"
    , envelope
    , quantity
    , "JPY"
    , note
    ]

validRow
  :: T.Text
  -> T.Text
  -> T.Text
  -> T.Text
  -> T.Text
  -> T.Text
  -> T.Text
  -> T.Text
validRow day start endExclusive envelope quantity commodity note =
  T.intercalate "\t"
    [ day
    , start
    , endExclusive
    , envelope
    , quantity
    , commodity
    , note
    ] <> "\n"

isNegativeAtLine :: Int -> Quantity -> BudgetTSVError -> Bool
isNegativeAtLine expectedLine expectedQuantity err =
  budgetTSVErrorLine err == expectedLine
    && case budgetTSVErrorReason err of
      NegativeBudgetEntitlement _ _ _ quantity -> quantity == expectedQuantity
      _                                         -> False



assertRight :: Show error => String -> Either error value -> IO ()
assertRight label result = case result of
  Right _ -> pass label
  Left err -> failTest label ("unexpectedly rejected: " ++ show err)

assertSingleError
  :: Show value
  => String
  -> (BudgetTSVError -> Bool)
  -> Either (NonEmpty.NonEmpty BudgetTSVError) value
  -> IO ()
assertSingleError label predicate result = case result of
  Left errors -> case NonEmpty.toList errors of
    [err] | predicate err -> pass label
    unexpected -> failTest label ("unexpected errors: " ++ show unexpected)
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

assertErrorLines
  :: Show value
  => String
  -> [Int]
  -> Either (NonEmpty.NonEmpty BudgetTSVError) value
  -> IO ()
assertErrorLines label expected result = case result of
  Left errors -> assertEqual label expected
    (map budgetTSVErrorLine (NonEmpty.toList errors))
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pass label
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actual)

pass :: String -> IO ()
pass label = putStrLn ("  [PASS] " ++ label)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
