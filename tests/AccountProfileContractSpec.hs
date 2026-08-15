{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account (Account, mkAccount)
import HKernel.Backing.Identity (mkBackingPoolId)
import HKernel.Backing.Policy
  ( assignEnvelopeBackingPool
  , defineBackingPool
  , mkBackingPolicy
  )
import HKernel.Envelope
  ( Pacing(..)
  , defineEnvelope
  , mkCurrentEnvelopePolicy
  , mkCurrentExpenseAssignments
  , mkEnvelopeLabel
  )
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Household.AccountProfile
import HKernel.Household.Config
  ( householdConfigurationAccountPolicy
  , parseHouseholdConfiguration
  )
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
  assertEqual "native Envelope role remains a separate direct-constructor axis"
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

  let foodId = mustRight (mkEnvelopeId "food")
      poolId = mustRight (mkBackingPoolId "cash")
      envelopePolicy = mustRight (mkCurrentEnvelopePolicy
        [defineEnvelope foodId (mustRight (mkEnvelopeLabel "Food")) Daily])
      backingPolicy = mustRight (mkBackingPolicy
        [defineBackingPool poolId [liquid]]
        [assignEnvelopeBackingPool foodId poolId])
      currentExpenses = mustRight (mkCurrentExpenseAssignments [(expense, foodId)])
      noLegacyRoleSource = T.unlines
        [ "[cycle]"
        , "mode = \"income-anchor\""
        , "income-account = \"income:pension\""
        , ""
        , "[budget]"
        , "unassigned-accounts = [\"budget:unassigned\"]"
        , ""
        , "[[budget.envelopes]]"
        , "id = \"food\""
        , "allocation-account = \"budget:daily\""
        , "plan-destination-accounts = 42"
        , ""
        , "[account-policy.assets]"
        , "liquid = [\"assets:cash\"]"
        , "savings = []"
        , "investment = []"
        , ""
        , "[account-policy.budget.kind]"
        , "opening = [\"budget:opening\"]"
        , "unassigned = [\"budget:unassigned\"]"
        , "spent = [\"budget:spent\"]"
        , "envelope = [\"budget:daily\"]"
        , ""
        , "[account-policy.budget.group]"
        , "daily = [\"budget:daily\"]"
        , "flex = []"
        , "reserve = [\"budget:opening\", \"budget:unassigned\", \"budget:spent\"]"
        , ""
        , "[account-policy.expenses]"
        , "fixed = []"
        , "variable = [\"expenses:food\"]"
        ]
      admitted = mustRight
        (parseHouseholdConfiguration
          envelopePolicy backingPolicy currentExpenses noLegacyRoleSource)
      admittedAccountPolicy = case householdConfigurationAccountPolicy admitted of
        Just value -> value
        Nothing -> error "account-policy unexpectedly absent"

  assertEqual "household.toml no longer requires the legacy Envelope role section"
    True
    (Map.null (householdEnvelopeRoleByAccount admittedAccountPolicy))
  assertEqual "retiring compatibility coordinates preserves structural Budget kind"
    (Just RetainedEnvelopeBudgetAccount)
    (Map.lookup envelope (householdBudgetKindByAccount admittedAccountPolicy))

account :: Text -> Account
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
