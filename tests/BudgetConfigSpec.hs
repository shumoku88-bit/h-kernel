{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight)
import Data.List (foldl')
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import HKernel.Account
import HKernel.Budget
import HKernel.Budget.Config
import HKernel.Budget.Policy
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeValidPolicy
  characterizeTomlAdmission
  characterizePolicyConflicts
  characterizeCoordinateConflictOrder
  characterizeAccountRegistryValidation

characterizeValidPolicy :: IO ()
characterizeValidPolicy = do
  let policy = mustRight (parseBudgetPolicy validConfig)
      rendered = renderBudgetPolicy policy
      reparsed = mustRight (parseBudgetPolicy rendered)
      food = mustRight (mkEnvelopeId "food")
      operating = mustRight (mkBackingPoolId "operating")
      foodExpense = mustRight (mkAccount "expenses:food")
      smbc = mustRight (mkAccount "assets:smbc")
      foodDefinition = mustJust
        "food definition"
        (budgetPolicyEnvelopeDefinition food policy)

  assertEqual "the initial policy retains four spendable envelopes"
    4
    (length (budgetPolicyEnvelopeDefinitions policy))
  assertEqual "the initial policy retains one backing pool"
    1
    (length (budgetPolicyBackingPoolDefinitions policy))
  assertEqual "Food keeps its human-facing Japanese label"
    "食費"
    (envelopeLabelText (envelopeDefinitionLabel foodDefinition))
  assertEqual "Food participates in daily pacing"
    Daily
    (envelopeDefinitionPacing foodDefinition)
  assertEqual "Food is backed by the operating pool"
    operating
    (envelopeDefinitionBackingPool foodDefinition)
  assertEqual "an Expense account resolves to exactly one envelope"
    (Just food)
    (budgetPolicyEnvelopeForExpense foodExpense policy)
  assertEqual "an Asset account resolves to exactly one backing pool"
    (Just operating)
    (budgetPolicyBackingPoolForAsset smbc policy)
  assertEqual "canonical Budget TOML re-admits the exact same policy"
    policy
    reparsed
  assertEqual "canonical Budget TOML is idempotent after re-admission"
    rendered
    (renderBudgetPolicy reparsed)

characterizeTomlAdmission :: IO ()
characterizeTomlAdmission = do
  assertLeft "unknown TOML keys are not silently ignored"
    (parseBudgetPolicy (validConfig <> "unknown = true\n"))
  assertLeft "unknown pacing modes are rejected"
    (parseBudgetPolicy
      (T.replace "pacing = \"daily\"" "pacing = \"weekly\"" validConfig))
  assertLeft "Unallocated cannot be declared as a spendable envelope"
    (parseBudgetPolicy
      (T.replace "id = \"other\"" "id = \"unallocated\"" validConfig))
  assertLeft "invalid Account identities are rejected before policy construction"
    (parseBudgetPolicy
      (T.replace "expenses:food" " expenses:food" validConfig))
  assertLeft "a backing pool must contain an Asset account identity"
    (parseBudgetPolicy
      (T.replace
        "asset-accounts = [\"assets:smbc\", \"assets:cash\"]"
        "asset-accounts = []"
        validConfig))

characterizePolicyConflicts :: IO ()
characterizePolicyConflicts = do
  assertLeft "duplicate envelope identities are rejected"
    (parseBudgetPolicy
      (T.replace "id = \"other\"" "id = \"food\"" validConfig))
  assertLeft "duplicate human labels are rejected"
    (parseBudgetPolicy
      (T.replace "label = \"その他\"" "label = \"食費\"" validConfig))
  assertLeft "one Expense account cannot feed two envelopes"
    (parseBudgetPolicy
      (T.replace "expenses:other" "expenses:food" validConfig))
  assertLeft "an envelope cannot reference a missing backing pool"
    (parseBudgetPolicy
      (T.replace
        "backing-pool = \"operating\""
        "backing-pool = \"missing\""
        validConfig))
  assertLeft "one Asset account cannot belong to two backing pools"
    (parseBudgetPolicy duplicateAssetConfig)

characterizeCoordinateConflictOrder :: IO ()
characterizeCoordinateConflictOrder = do
  let food = mustRight (mkEnvelopeId "food")
      other = mustRight (mkEnvelopeId "other")
      foodLabel = mustRight (mkEnvelopeLabel "食費")
      repeatedFoodLabel = mustRight (mkEnvelopeLabel "食費・再定義")
      operating = mustRight (mkBackingPoolId "operating")
      reserve = mustRight (mkBackingPoolId "reserve")
      sharedExpenseA = mustRight (mkAccount "expenses:a")
      sharedExpenseB = mustRight (mkAccount "expenses:b")
      smbc = mustRight (mkAccount "assets:smbc")
      envelopeDefinitions =
        [ defineEnvelope food foodLabel Daily operating
            [sharedExpenseA, sharedExpenseB]
        , defineEnvelope other foodLabel Flex operating
            [sharedExpenseB, sharedExpenseA]
        , defineEnvelope food repeatedFoodLabel Flex operating []
        ]
      backingPoolDefinitions =
        [ defineBackingPool operating [smbc]
        , defineBackingPool reserve [smbc]
        ]
      expectedErrors =
        [ DuplicateEnvelopeDefinition food
        , DuplicateEnvelopeLabel foodLabel food other
        , DuplicateExpenseAccountAssignment sharedExpenseB food other
        , DuplicateExpenseAccountAssignment sharedExpenseA food other
        , DuplicateAssetAccountMembership smbc operating reserve
        ]

  case mkBudgetPolicy envelopeDefinitions backingPoolDefinitions of
    Left errors -> assertEqual
      "coordinate conflicts retain domain order and first-owner evidence"
      expectedErrors
      (NonEmpty.toList errors)
    Right value -> failTest
      "coordinate conflict observation"
      ("unexpectedly accepted: " ++ show value)

characterizeAccountRegistryValidation :: IO ()
characterizeAccountRegistryValidation = do
  let policy = mustRight (parseBudgetPolicy validConfig)
      validRegistry = registryFrom
        [ ("assets:smbc", Asset)
        , ("assets:cash", Asset)
        , ("expenses:tobacco", Expense)
        , ("expenses:food", Expense)
        , ("expenses:stock-food", Expense)
        , ("expenses:other", Expense)
        ]
      invalidRegistry = registryFrom
        [ ("assets:smbc", Expense)
        , ("expenses:food", Asset)
        , ("expenses:stock-food", Expense)
        , ("expenses:other", Expense)
        ]
      food = mustRight (mkEnvelopeId "food")
      tobacco = mustRight (mkEnvelopeId "tobacco")
      operating = mustRight (mkBackingPoolId "operating")
      foodAccount = mustRight (mkAccount "expenses:food")
      tobaccoAccount = mustRight (mkAccount "expenses:tobacco")
      smbc = mustRight (mkAccount "assets:smbc")
      cash = mustRight (mkAccount "assets:cash")
      expectedErrors =
        [ BudgetPolicyExpenseAccountNotExpense food foodAccount Asset
        , BudgetPolicyExpenseAccountUndeclared tobacco tobaccoAccount
        , BudgetPolicyAssetAccountNotAsset operating smbc Expense
        , BudgetPolicyAssetAccountUndeclared operating cash
        ]

  case validateBudgetPolicyAccounts validRegistry policy of
    Left errors -> failTest
      "valid account registry"
      ("unexpected errors: " ++ show errors)
    Right validated -> assertEqual
      "account validation returns typed evidence for the unchanged policy"
      policy
      (accountValidatedBudgetPolicy validated)

  case validateBudgetPolicyAccounts invalidRegistry policy of
    Left errors -> assertEqual
      "all independent account-role conflicts are reported together"
      expectedErrors
      (NonEmpty.toList errors)
    Right value -> failTest
      "account registry conflicts"
      ("unexpectedly accepted: " ++ show value)

validConfig :: T.Text
validConfig = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"assets:smbc\", \"assets:cash\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"tobacco\""
  , "label = \"タバコ\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"expenses:tobacco\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"food\""
  , "label = \"食費\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"expenses:food\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"stock-food\""
  , "label = \"ストック食費\""
  , "pacing = \"flex\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"expenses:stock-food\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"other\""
  , "label = \"その他\""
  , "pacing = \"flex\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"expenses:other\"]"
  ]

duplicateAssetConfig :: T.Text
duplicateAssetConfig = validConfig <> T.unlines
  [ ""
  , "[[backing-pools]]"
  , "id = \"savings\""
  , "asset-accounts = [\"assets:smbc\"]"
  ]

registryFrom :: [(T.Text, AccountType)] -> AccountRegistry
registryFrom = foldl' addDeclaration emptyAccountRegistry
  where
    addDeclaration registry (name, accountType) =
      mustRight
        (registerAccount
          (declareAccount (mustRight (mkAccount name)) accountType)
          registry)



mustJust :: String -> Maybe value -> value
mustJust _ (Just value) = value
mustJust label Nothing = error ("missing test fixture: " ++ label)

assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> pass label
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
