{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
import HKernel.Actual.Journal
import HKernel.Budget (envelopeIdText)
import HKernel.Household.AccountProfile
import HKernel.Household.AccountProfile.TSV
import HKernel.Journal (journalAccountRegistry)
import HKernel.Money (mkCommodity)
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeSyntaxAndClassification
  characterizeActualRegistryParity
  characterizeSourceDiagnostics

characterizeSyntaxAndClassification :: IO ()
characterizeSyntaxAndClassification = do
  let profiles = mustRight (parseRetainedAccountProfiles validAccountsTSV)
      cash = mustRight (mkAccount "assets:cash")
      food = mustRight (mkAccount "expenses:food")
      budgetFood = mustRight (mkAccount "budget:food")
      jpy = mustRight (mkCommodity "JPY")
      cashProfile = mustJust (Map.lookup cash profiles)
      foodProfile = mustJust (Map.lookup food profiles)
      budgetProfile = mustJust (Map.lookup budgetFood profiles)
      cashDeclaration = retainedAccountDeclaration cashProfile
      cashHousehold = retainedAccountHouseholdEvidence cashProfile
      foodBudget = retainedAccountBudgetEvidence foodProfile
      foodHousehold = retainedAccountHouseholdEvidence foodProfile
      budgetHousehold = retainedAccountHouseholdEvidence budgetProfile

  assertEqual "every meaningful row becomes one Account profile"
    3
    (Map.size profiles)
  assertEqual "role becomes the canonical Account type"
    Asset
    (declaredAccountType cashDeclaration)
  assertEqual "currency becomes Account default Commodity evidence"
    (Just jpy)
    (declaredAccountDefaultCommodity cashDeclaration)
  assertEqual "role and currency are not retained as policy metadata"
    (Map.fromList [("future-key", "kept")])
    (retainedAccountUnclassifiedMetadata cashProfile)
  assertEqual "Asset type metadata becomes household class evidence"
    (Just RetainedLiquidAsset)
    (accountAssetClassEvidence cashHousehold)
  assertEqual "Asset budget metadata becomes Plan destination evidence"
    (Just "Cash")
    (fmap envelopeIdText
      (accountPlanDestinationEnvelopeEvidence cashHousehold))
  assertEqual "Expense budget metadata becomes BudgetPolicy evidence"
    (Just "Food")
    (fmap envelopeIdText (accountExpenseEnvelopeEvidence foodBudget))
  assertEqual "Expense fixed marker remains separate household evidence"
    (Just False)
    (accountFixedExpenseEvidence foodHousehold)
  assertEqual "Expense spend class remains a distinct coordinate"
    (Just RetainedVariableSpend)
    (accountSpendClassEvidence foodHousehold)
  assertEqual "Budget Account kind is classified without prefix inference"
    (Just RetainedEnvelopeBudgetAccount)
    (accountBudgetAccountKindEvidence budgetHousehold)
  assertEqual "Budget Account allocation reference remains explicit"
    (Just "Food")
    (fmap envelopeIdText
      (accountAllocationEnvelopeEvidence budgetHousehold))
  assertEqual "Daily group remains retained group evidence"
    (Just RetainedDailyBudgetGroup)
    (accountBudgetGroupEvidence budgetHousehold)

characterizeActualRegistryParity :: IO ()
characterizeActualRegistryParity = do
  let registry = actualRegistry matchingActualJournal

  assertRight "matching type and default Commodity pass bidirectional parity"
    (admitRetainedAccountProfiles registry validAccountsTSV)

  assertRight
    "omitted Actual per-Account Commodity does not contradict retained evidence"
    (admitRetainedAccountProfiles
      (actualRegistry actualWithoutPerAccountCommodities)
      validAccountsTSV)

  assertErrors "Account type mismatch is diagnosed independently"
    [ AccountProfileTSVError
        "accounts.tsv"
        0
        "Account type disagrees between accounts.tsv and actual.journal for expenses:food: accounts.tsv=Expense, actual.journal=Asset"
    ]
    (admitRetainedAccountProfiles
      (actualRegistry typeMismatchActualJournal)
      validAccountsTSV)

  assertErrors "default Commodity mismatch is not hidden behind type parity"
    [ AccountProfileTSVError
        "accounts.tsv"
        0
        "default Commodity disagrees between accounts.tsv and actual.journal for assets:cash: accounts.tsv=Just (Commodity {commodityCode = \"JPY\"}), actual.journal=Just (Commodity {commodityCode = \"USD\"})"
    ]
    (admitRetainedAccountProfiles
      (actualRegistry commodityMismatchActualJournal)
      validAccountsTSV)

  assertErrors "an Account present only in accounts.tsv is rejected"
    [ AccountProfileTSVError
        "accounts.tsv"
        0
        "accounts.tsv Account is not declared in actual.journal: budget:food"
    ]
    (admitRetainedAccountProfiles
      (actualRegistry actualWithoutBudgetAccount)
      validAccountsTSV)

  assertErrors "an Actual declaration absent from accounts.tsv is rejected"
    [ AccountProfileTSVError
        "actual.journal"
        0
        "actual.journal Account is missing from accounts.tsv: liabilities:card"
    ]
    (admitRetainedAccountProfiles
      (actualRegistry actualWithAdditionalAccount)
      validAccountsTSV)

characterizeSourceDiagnostics :: IO ()
characterizeSourceDiagnostics = do
  assertErrors "duplicate Account identity reports the repeated physical line"
    [ AccountProfileTSVError
        "accounts.tsv"
        2
        "duplicate Account assets:cash"
    ]
    (parseRetainedAccountProfiles duplicateAccountTSV)

  assertErrors "duplicate metadata key is rejected before classification"
    [ AccountProfileTSVError
        "accounts.tsv"
        1
        "duplicate metadata key role"
    ]
    (parseRetainedAccountProfiles duplicateMetadataTSV)

  assertErrors "malformed metadata does not disappear into an empty value"
    [ AccountProfileTSVError
        "accounts.tsv"
        1
        "malformed metadata field currency=; expected non-empty key=value"
    ]
    (parseRetainedAccountProfiles malformedMetadataTSV)

  assertErrors "unsupported role remains a source-local admission failure"
    [ AccountProfileTSVError
        "accounts.tsv"
        1
        "unsupported role CashLike"
    ]
    (parseRetainedAccountProfiles unsupportedRoleTSV)

  assertLeft "invalid Commodity is rejected by the existing smart constructor"
    (parseRetainedAccountProfiles invalidCommodityTSV)

  assertErrors "independent retained metadata failures accumulate on one row"
    [ AccountProfileTSVError
        "accounts.tsv"
        1
        "UnsupportedRetainedAssetClass \"cashlike\""
    , AccountProfileTSVError
        "accounts.tsv"
        1
        "InvalidRetainedEnvelopeReference \"Bad Envelope\" (EnvelopeIdContainsWhitespace \"Bad Envelope\")"
    ]
    (parseRetainedAccountProfiles invalidProfileCoordinatesTSV)

validAccountsTSV :: Text
validAccountsTSV = T.unlines
  [ "# synthetic retained Account source"
  , T.intercalate "\t"
      [ "assets:cash"
      , "role=Asset"
      , "currency=JPY"
      , "type=liquid"
      , "budget=Cash"
      , "future-key=kept"
      ]
  , T.intercalate "\t"
      [ "expenses:food"
      , "role=Expense"
      , "currency=JPY"
      , "budget=Food"
      , "fixed=0"
      , "spend_class=variable"
      ]
  , T.intercalate "\t"
      [ "budget:food"
      , "role=Budget"
      , "currency=JPY"
      , "kind=envelope"
      , "budget=Food"
      , "envelope_role=dynamic"
      , "budget_group=daily"
      ]
  ]

matchingActualJournal :: Text
matchingActualJournal = declarationJournal
  [ ("assets:cash", "Asset", "JPY")
  , ("expenses:food", "Expense", "JPY")
  , ("budget:food", "Budget", "JPY")
  ]

actualWithoutPerAccountCommodities :: Text
actualWithoutPerAccountCommodities = declarationJournalWithoutCommodities
  [ ("assets:cash", "Asset")
  , ("expenses:food", "Expense")
  , ("budget:food", "Budget")
  ]

typeMismatchActualJournal :: Text
typeMismatchActualJournal = declarationJournal
  [ ("assets:cash", "Asset", "JPY")
  , ("expenses:food", "Asset", "JPY")
  , ("budget:food", "Budget", "JPY")
  ]

commodityMismatchActualJournal :: Text
commodityMismatchActualJournal = declarationJournal
  [ ("assets:cash", "Asset", "USD")
  , ("expenses:food", "Expense", "JPY")
  , ("budget:food", "Budget", "JPY")
  ]

actualWithoutBudgetAccount :: Text
actualWithoutBudgetAccount = declarationJournal
  [ ("assets:cash", "Asset", "JPY")
  , ("expenses:food", "Expense", "JPY")
  ]

actualWithAdditionalAccount :: Text
actualWithAdditionalAccount = declarationJournal
  [ ("assets:cash", "Asset", "JPY")
  , ("expenses:food", "Expense", "JPY")
  , ("budget:food", "Budget", "JPY")
  , ("liabilities:card", "Liability", "JPY")
  ]

declarationJournal :: [(Text, Text, Text)] -> Text
declarationJournal declarations = T.unlines
  (concatMap declarationBlock declarations)
  where
    declarationBlock (account, accountType, commodity) =
      [ "account " <> account
      , "  ; type: " <> accountType
      , "  ; commodity: " <> commodity
      , ""
      ]

declarationJournalWithoutCommodities :: [(Text, Text)] -> Text
declarationJournalWithoutCommodities declarations = T.unlines
  (["commodity JPY", ""] ++ concatMap declarationBlock declarations)
  where
    declarationBlock (account, accountType) =
      [ "account " <> account
      , "  ; type: " <> accountType
      , ""
      ]

duplicateAccountTSV :: Text
duplicateAccountTSV = T.unlines
  [ "assets:cash\trole=Asset\tcurrency=JPY"
  , "assets:cash\trole=Asset\tcurrency=JPY"
  ]

duplicateMetadataTSV :: Text
duplicateMetadataTSV =
  "assets:cash\trole=Asset\trole=Expense\tcurrency=JPY\n"

malformedMetadataTSV :: Text
malformedMetadataTSV =
  "assets:cash\trole=Asset\tcurrency=\n"

unsupportedRoleTSV :: Text
unsupportedRoleTSV =
  "assets:cash\trole=CashLike\tcurrency=JPY\n"

invalidCommodityTSV :: Text
invalidCommodityTSV =
  "assets:cash\trole=Asset\tcurrency=bad currency\n"

invalidProfileCoordinatesTSV :: Text
invalidProfileCoordinatesTSV =
  "assets:cash\trole=Asset\tcurrency=JPY\ttype=cashlike\tbudget=Bad Envelope\n"

actualRegistry :: Text -> AccountRegistry
actualRegistry input =
  journalAccountRegistry
    (actualJournalValue (mustRight (parseActualJournal input)))

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Left err -> error ("invalid test fixture: " ++ show err)
  Right value -> value

mustJust :: Maybe value -> value
mustJust value = case value of
  Just result -> result
  Nothing -> error "invalid test fixture: missing expected value"

assertRight :: Show error => String -> Either error value -> IO ()
assertRight label result = case result of
  Right _ -> putStrLn ("  [PASS] " ++ label)
  Left err -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly rejected: " ++ show err)
    exitFailure

assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure

assertErrors
  :: String
  -> [AccountProfileTSVError]
  -> Either (NonEmpty.NonEmpty AccountProfileTSVError) value
  -> IO ()
assertErrors label expected result = case result of
  Left errors -> assertEqual label expected (NonEmpty.toList errors)
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    source was unexpectedly accepted"
    exitFailure

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
