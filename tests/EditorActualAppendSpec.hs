{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (Account, accountName, mkAccount)
import HKernel.Editor.ActualAppend
  ( ActualEditError(..)
  , ActualAppendPreview(..)
  , ActualEditIntent(..)
  , ActualExpenseInput(..)
  , ActualExpenseInputError(..)
  , ActualExpenseItemInput(..)
  , buildActualExpenseIntentWithRegistry
  , prepareActualAppend
  , prepareActualAppendFromResolvedJournal
  )
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Journal (Journal, journalAccountRegistry, parseJournal)
import HKernel.Money
  ( Commodity
  , Quantity
  , commodityCode
  , mkCommodity
  , parseQuantity
  , renderQuantity
  )

main :: IO ()
main = do
  let results = [ ("testOrdinaryTwoPosting", testOrdinaryTwoPosting)
                , ("testUndeclaredAccount", testUndeclaredAccount)
                , ("testZeroAmount", testZeroAmount)
                , ("testMultiplePostingErrors", testMultiplePostingErrors)
                , ("testUnbalanced", testUnbalanced)
                , ("testResolvedDeclarations", testResolvedDeclarations)
                , ("testResolvedUnknownAccount", testResolvedUnknownAccount)
                , ("testResolvedDuplicateEventId", testResolvedDuplicateEventId)
                , ("testSplitExpenseDerivesPayment", testSplitExpenseDerivesPayment)
                , ("testSplitExpenseAddsMixedScalesExactly", testSplitExpenseAddsMixedScalesExactly)
                , ("testSplitExpenseRequiresExpenseItems", testSplitExpenseRequiresExpenseItems)
                , ("testSplitExpenseRequiresSpendablePayment", testSplitExpenseRequiresSpendablePayment)
                , ("testSplitExpenseBalancesEachCommodity", testSplitExpenseBalancesEachCommodity)
                ]
  mapM_ print results
  if all snd results
    then exitSuccess
    else exitFailure

fixtureSource :: Text
fixtureSource = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account equity:opening"
  , "  type: Equity"
  , "  commodity: JPY"
  , ""
  , "2023-01-01 opening"
  , "  assets:bank  100 JPY"
  , "  equity:opening  -100 JPY"
  ]

accBank :: Account
accBank = either (error "bad account") id (mkAccount "assets:bank")

accOpening :: Account
accOpening = either (error "bad account") id (mkAccount "equity:opening")

accUnknown :: Account
accUnknown = either (error "bad account") id (mkAccount "assets:unknown")

qty :: Text -> Quantity
qty = either (error "bad qty") id . parseQuantity

comm :: Text -> Commodity
comm = either (error "bad comm") id . mkCommodity

testOrdinaryTwoPosting :: Bool
testOrdinaryTwoPosting =
  let intent = ActualEditIntent
        { intentDate = fromGregorian 2023 1 2
        , intentDescription = "test"
        , intentPostings = IntentPosting accBank (qty "50") (Just (comm "JPY"))
                        :| [IntentPosting accOpening (qty "-50") (Just (comm "JPY"))]
        , intentMetadata = []
        }
      result = prepareActualAppend fixtureSource intent
  in case result of
       Right _ -> True
       Left err -> error (show err)

testUndeclaredAccount :: Bool
testUndeclaredAccount =
  let intent = ActualEditIntent
        { intentDate = fromGregorian 2023 1 2
        , intentDescription = "test"
        , intentPostings = IntentPosting accUnknown (qty "50") (Just (comm "JPY"))
                        :| [IntentPosting accOpening (qty "-50") (Just (comm "JPY"))]
        , intentMetadata = []
        }
      result = prepareActualAppend fixtureSource intent
  in case result of
       Left (UndeclaredAccount _ :| _) -> True
       _ -> False

testZeroAmount :: Bool
testZeroAmount =
  let intent = ActualEditIntent
        { intentDate = fromGregorian 2023 1 2
        , intentDescription = "test"
        , intentPostings = IntentPosting accBank (qty "0") (Just (comm "JPY"))
                        :| [IntentPosting accOpening (qty "0") (Just (comm "JPY"))]
        , intentMetadata = []
        }
      result = prepareActualAppend fixtureSource intent
  in case result of
       Left (ZeroAmount _ :| _) -> True
       _ -> False

testMultiplePostingErrors :: Bool
testMultiplePostingErrors =
  let intent = ActualEditIntent
        { intentDate = fromGregorian 2023 1 2
        , intentDescription = "test"
        , intentPostings = IntentPosting accBank (qty "0") (Just (comm "JPY"))
                        :| [IntentPosting accOpening (qty "0") (Just (comm "JPY"))]
        , intentMetadata = []
        }
      result = prepareActualAppend fixtureSource intent
  in case result of
       Left (ZeroAmount first :| [ZeroAmount second]) ->
         first == accBank && second == accOpening
       _ -> False

testResolvedDeclarations :: Bool
testResolvedDeclarations =
  case prepareActualAppendFromResolvedJournal
      resolvedJournal actualRoot resolvedIntent of
    Right preview ->
      "assets:bank  50 JPY" `T.isInfixOf` candidateBlock preview
        && "equity:opening  -50 JPY" `T.isInfixOf` candidateBlock preview
    Left err -> error (show err)

testResolvedUnknownAccount :: Bool
testResolvedUnknownAccount =
  case prepareActualAppendFromResolvedJournal
      resolvedJournal actualRoot unknownResolvedIntent of
    Left (UndeclaredAccount account :| []) -> account == accUnknown
    _ -> False

testResolvedDuplicateEventId :: Bool
testResolvedDuplicateEventId =
  case prepareActualAppendFromResolvedJournal
      resolvedJournal actualRoot duplicateIdentityIntent of
    Left (CandidateSourceParseError _ :| []) -> True
    _ -> False

resolvedIntent :: ActualEditIntent
resolvedIntent = ActualEditIntent
  { intentDate = fromGregorian 2023 1 2
  , intentDescription = "resolved add"
  , intentPostings = IntentPosting accBank (qty "50") Nothing
      :| [IntentPosting accOpening (qty "-50") Nothing]
  , intentMetadata = [("event-id", "event-new")]
  }

unknownResolvedIntent :: ActualEditIntent
unknownResolvedIntent = resolvedIntent
  { intentPostings = IntentPosting accUnknown (qty "50") Nothing
      :| [IntentPosting accOpening (qty "-50") Nothing]
  }

duplicateIdentityIntent :: ActualEditIntent
duplicateIdentityIntent = resolvedIntent
  { intentMetadata = [("event-id", "event-opening")]
  }

actualRoot :: Text
actualRoot = T.unlines
  [ "include accounts.journal"
  , ""
  , "2023-01-01 opening"
  , "  ; event-id: event-opening"
  , "  assets:bank  100 JPY"
  , "  equity:opening  -100 JPY"
  ]

resolvedJournal :: Journal
resolvedJournal = either (error . show) id (parseJournal resolvedSource)

resolvedSource :: Text
resolvedSource = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account equity:opening"
  , "  type: Equity"
  , "  commodity: JPY"
  , ""
  , "2023-01-01 opening"
  , "  assets:bank  100 JPY"
  , "  equity:opening  -100 JPY"
  ]

testUnbalanced :: Bool
testUnbalanced =
  let intent = ActualEditIntent
        { intentDate = fromGregorian 2023 1 2
        , intentDescription = "test"
        , intentPostings = IntentPosting accBank (qty "50") (Just (comm "JPY"))
                        :| [IntentPosting accOpening (qty "-40") (Just (comm "JPY"))]
        , intentMetadata = []
        }
      result = prepareActualAppend fixtureSource intent
  in case result of
       Left (ValidationError _ :| _) -> True
       _ -> False

expenseJournal :: Journal
expenseJournal = either (error . show) id (parseJournal expenseSource)

expenseSource :: Text
expenseSource = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account liabilities:card"
  , "  type: Liability"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , "account expenses:food:stock"
  , "  type: Expense"
  , "  commodity: JPY"
  , "account income:pension"
  , "  type: Income"
  , "  commodity: JPY"
  ]

splitExpenseInput :: ActualExpenseInput
splitExpenseInput = ActualExpenseInput
  { expenseDateText = "2026-08-17"
  , expenseDescriptionText = "業務スーパー"
  , expensePaymentAccountText = "assets:bank"
  , expenseItems =
      ActualExpenseItemInput "expenses:food" "1897"
        :| [ActualExpenseItemInput "expenses:food:stock" "2822"]
  }

testSplitExpenseDerivesPayment :: Bool
testSplitExpenseDerivesPayment =
  case buildActualExpenseIntentWithRegistry
      (journalAccountRegistry expenseJournal) splitExpenseInput of
    Left _ -> False
    Right intent -> case NonEmpty.toList (intentPostings intent) of
      [food, stock, payment] ->
        posting food == ("expenses:food", "1897", "JPY")
          && posting stock == ("expenses:food:stock", "2822", "JPY")
          && posting payment == ("assets:bank", "-4719", "JPY")
      _ -> False

testSplitExpenseAddsMixedScalesExactly :: Bool
testSplitExpenseAddsMixedScalesExactly =
  case buildActualExpenseIntentWithRegistry
      (journalAccountRegistry expenseJournal)
      (splitExpenseInput
        { expenseItems =
            ActualExpenseItemInput "expenses:food" "100.5"
              :| [ActualExpenseItemInput "expenses:food:stock" "20.05"]
        }) of
    Right intent -> case reverse (NonEmpty.toList (intentPostings intent)) of
      payment : _ -> renderQuantity (intentQuantity payment) == "-120.55"
      _ -> False
    Left _ -> False

testSplitExpenseRequiresExpenseItems :: Bool
testSplitExpenseRequiresExpenseItems =
  buildActualExpenseIntentWithRegistry
    (journalAccountRegistry expenseJournal)
    (splitExpenseInput
      { expenseItems = ActualExpenseItemInput "income:pension" "100" :| [] })
    == Left (ActualExpenseItemAccountMustBeExpense 1)

testSplitExpenseRequiresSpendablePayment :: Bool
testSplitExpenseRequiresSpendablePayment =
  buildActualExpenseIntentWithRegistry
    (journalAccountRegistry expenseJournal)
    (splitExpenseInput { expensePaymentAccountText = "expenses:food" })
    == Left ActualExpensePaymentAccountMustBeAssetOrLiability

testSplitExpenseBalancesEachCommodity :: Bool
testSplitExpenseBalancesEachCommodity =
  case buildActualExpenseIntentWithRegistry
      (journalAccountRegistry expenseJournal)
      (splitExpenseInput
        { expenseItems =
            ActualExpenseItemInput "expenses:food" "10 USD"
              :| [ActualExpenseItemInput "expenses:food:stock" "500 JPY"]
        }) of
    Left _ -> False
    Right intent ->
      map posting (NonEmpty.toList (intentPostings intent))
        == [ ("expenses:food", "10", "USD")
           , ("expenses:food:stock", "500", "JPY")
           , ("assets:bank", "-500", "JPY")
           , ("assets:bank", "-10", "USD")
           ]

posting :: IntentPosting -> (Text, Text, Text)
posting value =
  ( accountName (intentAccount value)
  , renderQuantity (intentQuantity value)
  , maybe "" commodityCode (intentCommodity value)
  )
