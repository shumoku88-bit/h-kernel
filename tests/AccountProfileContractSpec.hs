{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import HKernel.Account
import HKernel.Budget
  ( EnvelopeIdError(..)
  , envelopeIdText
  )
import HKernel.Household.AccountProfile
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  let jpy = mustRight (mkCommodity "JPY")
      assetDeclaration = declaration "assets:savings" Asset jpy
      expenseDeclaration = declaration "expenses:food" Expense jpy
      budgetDeclaration = declaration "budget:fixed" Budget jpy
      liabilityDeclaration = declaration "liabilities:card" Liability jpy

      assetProfile = mustRight
        (classifyRetainedAccountProfile assetDeclaration (Map.fromList
          [ ("type", "savings")
          , ("budget", "Savings")
          , ("future-key", "kept")
          ]))
      assetHousehold = retainedAccountHouseholdEvidence assetProfile
      assetBudget = retainedAccountBudgetEvidence assetProfile

  assertEqual "default Commodity remains Account declaration evidence"
    (Just jpy)
    (declaredAccountDefaultCommodity
      (retainedAccountDeclaration assetProfile))
  assertEqual "Asset class becomes household-only evidence"
    (Just RetainedSavingsAsset)
    (accountAssetClassEvidence assetHousehold)
  assertEqual "Asset budget reference becomes Plan-destination evidence"
    (Just "Savings")
    (fmap envelopeIdText
      (accountPlanDestinationEnvelopeEvidence assetHousehold))
  assertEqual "Asset budget reference is not an Expense assignment"
    Nothing
    (accountExpenseEnvelopeEvidence assetBudget)
  assertEqual "unknown metadata remains visible instead of being discarded"
    (Map.fromList [("future-key", "kept")])
    (retainedAccountUnclassifiedMetadata assetProfile)

  let expenseProfile = mustRight
        (classifyRetainedAccountProfile expenseDeclaration (Map.fromList
          [ ("budget", "Food")
          , ("fixed", "1")
          , ("spend_class", "fixed")
          ]))
      expenseBudget = retainedAccountBudgetEvidence expenseProfile
      expenseHousehold = retainedAccountHouseholdEvidence expenseProfile
  assertEqual "Expense budget reference becomes general BudgetPolicy evidence"
    (Just "Food")
    (fmap envelopeIdText
      (accountExpenseEnvelopeEvidence expenseBudget))
  assertEqual "fixed marker remains explicit household evidence"
    (Just True)
    (accountFixedExpenseEvidence expenseHousehold)
  assertEqual "spend class remains distinct from the fixed marker"
    (Just RetainedFixedSpend)
    (accountSpendClassEvidence expenseHousehold)
  assertEqual "classified Expense metadata leaves no residual coordinates"
    Map.empty
    (retainedAccountUnclassifiedMetadata expenseProfile)

  let budgetProfile = mustRight
        (classifyRetainedAccountProfile budgetDeclaration (Map.fromList
          [ ("kind", "envelope")
          , ("budget", "Fixed")
          , ("envelope_role", "execution")
          , ("budget_group", "reserve")
          ]))
      budgetHousehold = retainedAccountHouseholdEvidence budgetProfile
  assertEqual "Budget Account kind remains household structural evidence"
    (Just RetainedEnvelopeBudgetAccount)
    (accountBudgetAccountKindEvidence budgetHousehold)
  assertEqual "Budget Account reference becomes allocation evidence"
    (Just "Fixed")
    (fmap envelopeIdText
      (accountAllocationEnvelopeEvidence budgetHousehold))
  assertEqual "execution role is not collapsed into pacing"
    (Just RetainedExecutionEnvelopeRole)
    (accountEnvelopeRoleEvidence budgetHousehold)
  assertEqual "reserve group is preserved separately from daily/flex pacing"
    (Just RetainedReserveBudgetGroup)
    (accountBudgetGroupEvidence budgetHousehold)

  let liabilityProfile = mustRight
        (classifyRetainedAccountProfile liabilityDeclaration (Map.fromList
          [ ("type", "liquid")
          , ("future-key", "kept")
          ]))
  assertEqual "a familiar key on the wrong AccountType is not misclassified"
    (Map.fromList
      [ ("future-key", "kept")
      , ("type", "liquid")
      ])
    (retainedAccountUnclassifiedMetadata liabilityProfile)

  assertLeftEqual "independent invalid coordinates are accumulated"
    [ UnsupportedRetainedAssetClass "cashlike"
    , InvalidRetainedEnvelopeReference
        "Bad Envelope"
        (EnvelopeIdContainsWhitespace "Bad Envelope")
    ]
    (classifyRetainedAccountProfile assetDeclaration (Map.fromList
      [ ("type", "cashlike")
      , ("budget", "Bad Envelope")
      ]))

  assertLeftEqual "retained fixed marker rejects invented boolean syntax"
    [UnsupportedRetainedFixedMarker "yes"]
    (classifyRetainedAccountProfile expenseDeclaration
      (Map.fromList [("fixed", "yes")]))

declaration :: Text -> AccountType -> Commodity -> AccountDeclaration
declaration name accountType commodity =
  declareAccountWithDefaultCommodity
    (mustRight (mkAccount name))
    accountType
    commodity

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Left err -> error ("invalid test fixture: " ++ show err)
  Right value -> value

assertLeftEqual
  :: (Eq error, Show error)
  => String
  -> [error]
  -> Either (NonEmpty.NonEmpty error) value
  -> IO ()
assertLeftEqual label expected result = case result of
  Left errors -> assertEqual label expected (NonEmpty.toList errors)
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted evidence"
    exitFailure

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
