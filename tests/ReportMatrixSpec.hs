{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import HKernel.Money
import HKernel.Report.Matrix
import System.Exit (exitFailure)

main :: IO ()
main = do
  let jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      matrix = balanceMatrixFromCoordinates
        [ ("income", 1 :: Int, one jpy 500)
        , ("income", 1, one usd 10)
        , ("expense", 1, one jpy 100)
        , ("expense", 2, one jpy 40)
        , ("expense", 3, one jpy (-40))
        ]
      rows = balanceMatrixRows matrix
      expenseRow = rowFor "expense" rows
      incomeRow = rowFor "income" rows

  assertEqual
    "rows are projected in typed key order"
    ["expense", "income"]
    (map balanceRowKey rows)
  assertEqual
    "equal coordinates aggregate without mixing commodities"
    (balanceFromAmounts
      [ mkAmount jpy (quantityFromInteger 500)
      , mkAmount usd (quantityFromInteger 10)
      ])
    (balanceRowAt 1 incomeRow)
  assertEqual
    "a missing sparse cell reads as the canonical empty balance"
    emptyBalance
    (balanceRowAt 2 incomeRow)
  assertEqual
    "row totals are derived from cells"
    (one jpy 100)
    (balanceRowTotal expenseRow)
  assertEqual
    "column totals are derived across rows"
    (balanceFromAmounts
      [ mkAmount jpy (quantityFromInteger 600)
      , mkAmount usd (quantityFromInteger 10)
      ])
    (balanceMatrixColumnTotal 1 matrix)
  assertEqual
    "activity in different columns remains visible when the row total cancels"
    False
    (balanceRowIsZero expenseRow)

  let zeroRow = rowFor "temporary" (balanceMatrixRows
        (balanceMatrixFromCoordinates
          [ ("temporary", 1 :: Int, one jpy 20)
          , ("temporary", 1, one jpy (-20))
          ]))
  assertEqual
    "same-cell cancellation retains a zero coordinate for report policy"
    True
    (balanceRowIsZero zeroRow)

one :: Commodity -> Integer -> Balance
one commodity quantity = balanceFromAmounts
  [mkAmount commodity (quantityFromInteger quantity)]

rowFor
  :: Eq row
  => row
  -> [BalanceRow row column]
  -> BalanceRow row column
rowFor key rows = case filter ((== key) . balanceRowKey) rows of
  [row] -> row
  unexpected -> error ("expected one matrix row, got " ++ show (length unexpected))

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
