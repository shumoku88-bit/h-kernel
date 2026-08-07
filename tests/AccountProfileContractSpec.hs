{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
import HKernel.Budget
  ( EnvelopeIdError(..)
  , envelopeIdText
  )
import HKernel.Budget.Config (parseBudgetPolicy)
import HKernel.Household.AccountProfile
import HKernel.Household.Config
  ( householdConfigurationAccountPolicy
  , parseHouseholdConfiguration
  )
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

  characterizeNativeAccountPolicy jpy assetProfile

characterizeNativeAccountPolicy :: Commodity -> RetainedAccountProfile -> IO ()
characterizeNativeAccountPolicy jpy profileWithUnknownMetadata = do
  let asset = migrationProfile "assets:cash" Asset
        [("type", "liquid")]
      opening = migrationProfile "budget:opening" Budget
        [("kind", "opening"), ("budget_group", "reserve")]
      unassigned = migrationProfile "budget:unassigned" Budget
        [ ("kind", "unassigned")
        , ("envelope_role", "unassigned")
        , ("budget_group", "reserve")
        ]
      envelope = migrationProfile "budget:daily" Budget
        [ ("kind", "envelope")
        , ("budget", "Daily")
        , ("envelope_role", "dynamic")
        , ("budget_group", "daily")
        ]
      expense = migrationProfile "expenses:food" Expense
        [ ("budget", "Daily")
        , ("fixed", "1")
        , ("spend_class", "fixed")
        ]
      retained = Map.fromList
        [ (declaredAccount (retainedAccountDeclaration value), value)
        | value <- [asset, opening, unassigned, envelope, expense]
        ]
      projected = mustRight (projectRetainedHouseholdAccountPolicy retained)
      budgetPolicy = mustRight (parseBudgetPolicy nativeBudgetConfig)
      nativeConfiguration = mustRight
        (parseHouseholdConfiguration budgetPolicy nativeHouseholdConfig)

  assertEqual
    "semantic TOML axes reproduce retained Account household policy"
    (Just projected)
    (householdConfigurationAccountPolicy nativeConfiguration)

  case projectRetainedHouseholdAccountPolicy
      (Map.singleton
        (declaredAccount (retainedAccountDeclaration profileWithUnknownMetadata))
        profileWithUnknownMetadata) of
    Left errors
      | RetainedAccountMetadataRemainsUnclassified `elem` NonEmpty.toList errors ->
          putStrLn "  [PASS] native migration refuses unclassified retained metadata"
      | otherwise -> failTest
          "native migration refuses unclassified retained metadata"
          ("unexpected errors: " ++ show errors)
    Right value -> failTest
      "native migration refuses unclassified retained metadata"
      ("unexpectedly projected: " ++ show value)

  let conflictingFixed = migrationProfile "expenses:conflict" Expense
        [("fixed", "1"), ("spend_class", "variable")]
  case projectRetainedHouseholdAccountPolicy
      (Map.singleton
        (declaredAccount (retainedAccountDeclaration conflictingFixed))
        conflictingFixed) of
    Left errors
      | RetainedFixedMarkerConflictsWithSpendClass `elem` NonEmpty.toList errors ->
          putStrLn "  [PASS] duplicate fixed marker may be retired only after parity"
      | otherwise -> failTest
          "duplicate fixed marker may be retired only after parity"
          ("unexpected errors: " ++ show errors)
    Right value -> failTest
      "duplicate fixed marker may be retired only after parity"
      ("unexpectedly projected: " ++ show value)
  where
    migrationProfile name role metadata = mustRight
      (classifyRetainedAccountProfile
        (declaration name role jpy)
        (Map.fromList metadata))

nativeBudgetConfig :: T.Text
nativeBudgetConfig = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"assets:cash\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"Daily\""
  , "label = \"Daily\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"expenses:food\"]"
  ]

nativeHouseholdConfig :: T.Text
nativeHouseholdConfig = T.unlines
  [ "[cycle]"
  , "mode = \"income-anchor\""
  , "income-account = \"income:benefit\""
  , ""
  , "[budget]"
  , "unassigned-accounts = [\"budget:unassigned\"]"
  , ""
  , "[[budget.envelopes]]"
  , "id = \"Daily\""
  , "allocation-account = \"budget:daily\""
  , ""
  , "[account-policy.assets]"
  , "liquid = [\"assets:cash\"]"
  , "savings = []"
  , "investment = []"
  , ""
  , "[account-policy.budget.kind]"
  , "opening = [\"budget:opening\"]"
  , "unassigned = [\"budget:unassigned\"]"
  , "spent = []"
  , "envelope = [\"budget:daily\"]"
  , ""
  , "[account-policy.budget.envelope-role]"
  , "unassigned = [\"budget:unassigned\"]"
  , "dynamic = [\"budget:daily\"]"
  , "execution = []"
  , ""
  , "[account-policy.budget.group]"
  , "daily = [\"budget:daily\"]"
  , "flex = []"
  , "reserve = [\"budget:opening\", \"budget:unassigned\"]"
  , ""
  , "[account-policy.expenses]"
  , "fixed = [\"expenses:food\"]"
  , "variable = []"
  ]

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
  | otherwise -> failTest label
      ("expected: " ++ show expected ++ ", but got: " ++ show actual)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
