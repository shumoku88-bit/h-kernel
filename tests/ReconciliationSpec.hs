{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List (find)
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account
  ( Account
  , accountDeclarations
  , accountName
  , declaredAccount
  )
import HKernel.Account.Reconciliation
  ( externalBalanceValue
  , observeExternalBalance
  , reconcileAccountBalance
  , reconciliationDifference
  , reconciliationExternalObservation
  , reconciliationLedgerBalance
  , reconciliationMatches
  )
import HKernel.Actual.Journal
  ( actualJournalValue
  , parseActualJournal
  )
import HKernel.Journal (journalAccountRegistry)
import HKernel.Money
  ( balanceEntries
  , mkAmount
  , mkCommodity
  , parseQuantity
  , singletonBalance
  )

main :: IO ()
main = do
  let actual = mustRight (parseActualJournal source)
      journal = actualJournalValue actual
      registry = journalAccountRegistry journal
      paypay = mustJust (find
        ((== "assets:paypay") . accountName)
        (map declaredAccount (accountDeclarations registry)))
      jpy = mustRight (mkCommodity "JPY")
      external710 = singletonBalance (mkAmount jpy (mustRight (parseQuantity "710")))
      external700 = singletonBalance (mkAmount jpy (mustRight (parseQuantity "700")))
      external1000 = singletonBalance (mkAmount jpy (mustRight (parseQuantity "1000")))
      observedToday = observeExternalBalance paypay (fromGregorian 2026 8 18) external710
      differenceResult = reconcileAccountBalance journal observedToday
      matchedResult = reconcileAccountBalance journal
        (observeExternalBalance paypay (fromGregorian 2026 8 18) external700)
      historicalResult = reconcileAccountBalance journal
        (observeExternalBalance paypay (fromGregorian 2026 8 10) external1000)
      results =
        [ ( "difference is exact external minus ledger"
          , balanceEntries (reconciliationLedgerBalance differenceResult)
              == [(jpy, mustRight (parseQuantity "700"))]
            && balanceEntries (reconciliationDifference differenceResult)
              == [(jpy, mustRight (parseQuantity "10"))]
          )
        , ( "matching observation is represented by the unique zero Balance"
          , reconciliationMatches matchedResult
            && null (balanceEntries (reconciliationDifference matchedResult))
          )
        , ( "reconciliation uses the external observation day"
          , reconciliationMatches historicalResult
            && externalBalanceValue
                (reconciliationExternalObservation historicalResult)
              == external1000
          )
        ]
  mapM_ print results
  if all snd results then exitSuccess else exitFailure

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Left err -> error ("invalid test setup: " ++ show err)
  Right value -> value

mustJust :: Maybe value -> value
mustJust value = case value of
  Nothing -> error "invalid test setup: expected value"
  Just found -> found

source :: Text
source = "account assets:paypay\n\
\  type: Asset\n\
\  commodity: JPY\n\
\\n\
\account income:rewards\n\
\  type: Income\n\
\  commodity: JPY\n\
\\n\
\account expenses:food\n\
\  type: Expense\n\
\  commodity: JPY\n\
\\n\
\2026-08-10 Reward\n\
\  assets:paypay  1000 JPY\n\
\  income:rewards  -1000 JPY\n\
\\n\
\2026-08-15 Purchase\n\
\  assets:paypay  -300 JPY\n\
\  expenses:food  300 JPY\n"
