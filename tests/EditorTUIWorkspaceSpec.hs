{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)

import HKernel.Ledger
  ( Transaction
  , mkAccount
  , mkPosting
  , mkTransaction
  )
import HKernel.Money
  ( mkAmount
  , mkCommodity
  , quantityFromInteger
  )
import HKernel.Editor.TUI.Workspace
  ( ActualWorkspaceRow(..)
  , buildActualWorkspaceRows
  )

main :: IO ()
main = do
  first <- fixtureTransaction 7 "Coffee" (-138) 138
  second <- fixtureTransaction 8 "Groceries" (-1240) 1240
  let rows = buildActualWorkspaceRows [first, second]
  assertEqual "source order" ["2026-08-07  Coffee", "2026-08-08  Groceries"]
    (map workspaceRowSummary rows)
  case rows of
    firstRow : _ ->
      assertEqual "posting detail"
        [ "assets:cash  -138 JPY"
        , "expenses:food  138 JPY"
        ]
        (workspaceRowPostingLines firstRow)
    [] -> fail "expected workspace rows"

fixtureTransaction :: Int -> Text -> Integer -> Integer -> IO Transaction
fixtureTransaction day description cashQuantity expenseQuantity = do
  cash <- expectRight "cash account" (mkAccount "assets:cash")
  expense <- expectRight "expense account" (mkAccount "expenses:food")
  jpy <- expectRight "JPY commodity" (mkCommodity "JPY")
  expectRight "transaction"
    (mkTransaction
      (fromGregorian 2026 8 day)
      description
      ( mkPosting cash (mkAmount jpy (quantityFromInteger cashQuantity))
          :| [mkPosting expense (mkAmount jpy (quantityFromInteger expenseQuantity))]
      ))

expectRight :: Show e => String -> Either e a -> IO a
expectRight label value = case value of
  Left err -> fail (label <> ": " <> show err)
  Right result -> pure result

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label <> "\nexpected: " <> show expected <> "\n but got: " <> show actual)
