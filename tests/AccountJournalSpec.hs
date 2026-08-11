{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, mustJust, assertEqual)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
import HKernel.Account.Journal
import HKernel.Journal
  ( JournalError(..)
  , JournalErrorReason(..)
  , parseJournal
  )
import HKernel.Money (mkCommodity)
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeRegistryPublication
  characterizeStrictSourceShape
  characterizeDeclarationDiagnostics
  characterizeActualJournalCompatibility

characterizeRegistryPublication :: IO ()
characterizeRegistryPublication = do
  let registry = mustRight (parseAccountJournal validAccountJournal)
      checking = mustRight (mkAccount "assets:checking")
      food = mustRight (mkAccount "expenses:food")
      card = mustRight (mkAccount "liabilities:card")
      jpy = mustRight (mkCommodity "JPY")
      checkingDeclaration = mustJust
        (lookupAccountDeclaration checking registry)
      foodDeclaration = mustJust
        (lookupAccountDeclaration food registry)
      cardDeclaration = mustJust
        (lookupAccountDeclaration card registry)

  assertEqual "account Journal publishes every declaration"
    3
    (length (accountDeclarations registry))
  assertEqual "type metadata becomes accounting meaning"
    Asset
    (declaredAccountType checkingDeclaration)
  assertEqual "role remains an accepted accounting-type synonym"
    Expense
    (declaredAccountType foodDeclaration)
  assertEqual "per-account default commodity is retained explicitly"
    (Just jpy)
    (declaredAccountDefaultCommodity checkingDeclaration)
  assertEqual "an omitted default commodity remains absent"
    Nothing
    (declaredAccountDefaultCommodity foodDeclaration)
  assertEqual "other accounting categories remain distinct"
    Liability
    (declaredAccountType cardDeclaration)

characterizeStrictSourceShape :: IO ()
characterizeStrictSourceShape = do
  assertErrors "transaction blocks cannot enter a declaration source"
    [ UnsupportedAccountJournalBlock 1 "2026-08-02 * Lunch"
    ]
    (parseAccountJournal transactionInput)
  assertErrors "include expansion is a later loader boundary"
    [ UnsupportedAccountJournalBlock 1 "include shared-accounts.journal"
    ]
    (parseAccountJournal includeInput)
  assertErrors "unknown account metadata is diagnosed"
    [ UnknownAccountJournalMetadata 3 "liquidity"
    ]
    (parseAccountJournal unknownMetadataInput)
  assertErrors "non-comment metadata must retain key-value shape"
    [ MalformedAccountJournalMetadata 2 "type Asset"
    ]
    (parseAccountJournal malformedMetadataInput)

characterizeDeclarationDiagnostics :: IO ()
characterizeDeclarationDiagnostics = do
  let cash = mustRight (mkAccount "assets:cash")

  assertErrors "duplicate account identity is rejected at its second declaration"
    [ AccountJournalSyntaxError
        (JournalError 4 (DuplicateAccountDirective cash))
    ]
    (parseAccountJournal duplicateAccountInput)
  assertLeft "missing accounting type remains a typed Journal error"
    (parseAccountJournal missingTypeInput)
  assertLeft "duplicate type metadata remains a typed Journal error"
    (parseAccountJournal duplicateTypeInput)
  assertLeft "invalid commodity remains a typed Journal error"
    (parseAccountJournal invalidCommodityInput)

characterizeActualJournalCompatibility :: IO ()
characterizeActualJournalCompatibility =
  assertRight
    "ordinary Actual Journal admission still accepts historical policy comments"
    (parseJournal actualCompatibilityInput)

validAccountJournal :: Text
validAccountJournal = T.unlines
  [ "; synthetic declaration source"
  , "account assets:checking"
  , "  ; type: Asset"
  , "  ; commodity: JPY"
  , ""
  , "account expenses:food"
  , "  ; role: Expense"
  , ""
  , "account liabilities:card"
  , "  type: Liability"
  , "  commodity: JPY"
  ]

transactionInput :: Text
transactionInput = T.unlines
  [ "2026-08-02 * Lunch"
  , "  assets:checking  -800 JPY"
  , "  expenses:food     800 JPY"
  ]

includeInput :: Text
includeInput = "include shared-accounts.journal\n"

unknownMetadataInput :: Text
unknownMetadataInput = T.unlines
  [ "account assets:cash"
  , "  ; type: Asset"
  , "  ; liquidity: liquid"
  ]

malformedMetadataInput :: Text
malformedMetadataInput = T.unlines
  [ "account assets:cash"
  , "  type Asset"
  ]

duplicateAccountInput :: Text
duplicateAccountInput = T.unlines
  [ "account assets:cash"
  , "  ; type: Asset"
  , ""
  , "account assets:cash"
  , "  ; type: Asset"
  ]

missingTypeInput :: Text
missingTypeInput = "account assets:cash\n"

duplicateTypeInput :: Text
duplicateTypeInput = T.unlines
  [ "account assets:cash"
  , "  ; type: Asset"
  , "  ; role: Asset"
  ]

invalidCommodityInput :: Text
invalidCommodityInput = T.unlines
  [ "account assets:cash"
  , "  ; type: Asset"
  , "  ; commodity: bad currency"
  ]

actualCompatibilityInput :: Text
actualCompatibilityInput = T.unlines
  [ "account assets:cash"
  , "  ; type: Asset"
  , "  ; liquidity: liquid"
  , ""
  , "account expenses:food"
  , "  ; type: Expense"
  , "  ; default-envelope: everyday"
  , ""
  , "2026-08-02 * Lunch"
  , "  assets:cash    -800 JPY"
  , "  expenses:food   800 JPY"
  ]





assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure

assertRight :: Show error => String -> Either error value -> IO ()
assertRight label result = case result of
  Right _ -> putStrLn ("  [PASS] " ++ label)
  Left err -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly rejected: " ++ show err)
    exitFailure

assertErrors
  :: String
  -> [AccountJournalError]
  -> Either (NonEmpty.NonEmpty AccountJournalError) value
  -> IO ()
assertErrors label expected result = case result of
  Left errors -> assertEqual label expected (NonEmpty.toList errors)
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    source was unexpectedly accepted"
    exitFailure

