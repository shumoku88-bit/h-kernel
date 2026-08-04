{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List (foldl')
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import HKernel.Account
import HKernel.Budget
import HKernel.Budget.Config
import HKernel.Budget.Distribution
import HKernel.Budget.Policy
import HKernel.Budget.Routing
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeWholeExpenseDistribution
  characterizeUnassignedExpense

characterizeWholeExpenseDistribution :: IO ()
characterizeWholeExpenseDistribution = do
  let policy = mustRight (parseBudgetPolicy validConfig)
      validated = mustRight
        (validateBudgetPolicyAccounts accountRegistry policy)
      food = mustRight (mkEnvelopeId "food")
      foodAccount = mustRight (mkAccount "expenses:food")

  case expenseDistributionFor foodAccount validated of
    Nothing -> failTest
      "whole Expense distribution"
      "expected an assigned Expense distribution"
    Just distribution -> case NonEmpty.toList
      (expenseDistributionShares distribution) of
        [share] -> do
          assertEqual
            "the current assignment retains its envelope coordinate"
            food
            (envelopeShareEnvelope share)
          assertEqual
            "the current whole assignment has unit relative weight"
            1
            (distributionWeightValue (envelopeShareWeight share))
        shares -> failTest
          "whole Expense distribution"
          ("expected one share, but got " ++ show shares)

characterizeUnassignedExpense :: IO ()
characterizeUnassignedExpense = do
  let policy = mustRight (parseBudgetPolicy validConfig)
      validated = mustRight
        (validateBudgetPolicyAccounts accountRegistry policy)
      unassigned = mustRight (mkAccount "expenses:unassigned")

  assertEqual
    "a declared but unassigned Expense account has no invented distribution"
    Nothing
    (expenseDistributionFor unassigned validated)

validConfig :: T.Text
validConfig = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"assets:smbc\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"food\""
  , "label = \"食費\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"expenses:food\"]"
  ]

accountRegistry :: AccountRegistry
accountRegistry = registryFrom
  [ ("assets:smbc", Asset)
  , ("expenses:food", Expense)
  , ("expenses:unassigned", Expense)
  ]

registryFrom :: [(T.Text, AccountType)] -> AccountRegistry
registryFrom = foldl' addDeclaration emptyAccountRegistry
  where
    addDeclaration registry (name, accountType) =
      mustRight
        (registerAccount
          (declareAccount (mustRight (mkAccount name)) accountType)
          registry)

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

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
