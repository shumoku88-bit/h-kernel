{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import HKernel.Account (Account, mkAccount)
import HKernel.Household.AccountProfile
import System.Exit (exitFailure)

main :: IO ()
main = do
  let liquid = account "assets:cash"
      savings = account "assets:savings"
      opening = account "budget:opening"
      unassigned = account "budget:unassigned"
      envelope = account "budget:daily"
      expense = account "expenses:food"
      policy = mustRight (mkHouseholdAccountPolicy
        [ (liquid, RetainedLiquidAsset)
        , (savings, RetainedSavingsAsset)
        ]
        [ (opening, RetainedOpeningBudgetAccount)
        , (unassigned, RetainedUnassignedBudgetAccount)
        , (envelope, RetainedEnvelopeBudgetAccount)
        ]
        [ (unassigned, RetainedUnassignedEnvelopeRole)
        , (envelope, RetainedDynamicEnvelopeRole)
        ]
        [ (opening, RetainedReserveBudgetGroup)
        , (unassigned, RetainedReserveBudgetGroup)
        , (envelope, RetainedDailyBudgetGroup)
        ]
        [(expense, RetainedFixedSpend)])

  assertEqual "native Asset policy keeps explicit coordinates"
    (Just RetainedSavingsAsset)
    (Map.lookup savings (householdAssetClassByAccount policy))
  assertEqual "native Budget kind remains available to entitlement adapter"
    (Just RetainedEnvelopeBudgetAccount)
    (Map.lookup envelope (householdBudgetKindByAccount policy))
  assertEqual "native Envelope role remains a separate current axis"
    (Just RetainedDynamicEnvelopeRole)
    (Map.lookup envelope (householdEnvelopeRoleByAccount policy))
  assertEqual "native Budget group remains a separate current axis"
    (Just RetainedDailyBudgetGroup)
    (Map.lookup envelope (householdBudgetGroupByAccount policy))
  assertEqual "native Expense spend class remains explicit"
    (Just RetainedFixedSpend)
    (Map.lookup expense (householdSpendClassByAccount policy))

  assertLeftEqual "duplicate Budget kind coordinates fail closed"
    [DuplicateHouseholdBudgetKindCoordinate]
    (mkHouseholdAccountPolicy
      []
      [ (envelope, RetainedEnvelopeBudgetAccount)
      , (envelope, RetainedSpentBudgetAccount)
      ]
      [] [] [])

  assertLeftEqual "duplicate current axes accumulate independently"
    [ DuplicateHouseholdAssetClassCoordinate
    , DuplicateHouseholdSpendClassCoordinate
    ]
    (mkHouseholdAccountPolicy
      [ (liquid, RetainedLiquidAsset)
      , (liquid, RetainedSavingsAsset)
      ]
      [] [] []
      [ (expense, RetainedFixedSpend)
      , (expense, RetainedVariableSpend)
      ])

account :: String -> Account
account value = mustRight (mkAccount value)

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

assertLeftEqual
  :: (Eq error, Show error)
  => String
  -> [error]
  -> Either (NonEmpty.NonEmpty error) value
  -> IO ()
assertLeftEqual label expected result = case result of
  Left errors -> assertEqual label expected (NonEmpty.toList errors)
  Right _ -> failTest label "unexpectedly accepted duplicate coordinates"

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = failTest label
      ("expected: " ++ show expected ++ ", but got: " ++ show actual)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
