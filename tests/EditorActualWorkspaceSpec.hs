{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List (find)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account
  ( Account
  , accountDeclarations
  , accountName
  , declaredAccount
  )
import HKernel.Actual.Journal
  ( actualJournalValue
  , parseActualJournal
  )
import HKernel.Editor.ActualWorkspace (transactionsForAccount)
import HKernel.Journal
  ( journalAccountRegistry
  , journalTransactions
  )
import HKernel.Ledger (Transaction)

main :: IO ()
main = do
  source <- TIO.readFile "tests/fixtures/editor/actual-add.journal"
  case parseActualJournal source of
    Left errors -> do
      mapM_ print (NonEmpty.toList errors)
      exitFailure
    Right actualJournal -> do
      let journal = actualJournalValue actualJournal
          transactions = journalTransactions journal
          accounts =
            map declaredAccount
              (accountDeclarations (journalAccountRegistry journal))
          results =
            [ ("no Account filter preserves all Actual transactions"
              , length (transactionsForAccount Nothing transactions)
                  == length transactions)
            , ("selected Account retains matching Actual transactions"
              , matchesAllFor "assets:cash" accounts transactions)
            , ("selected Account excludes non-matching Actual transactions"
              , matchesNoneFor "expenses:food" accounts transactions)
            ]
      mapM_ print results
      if all snd results then exitSuccess else exitFailure

matchesAllFor :: Text -> [Account] -> [Transaction] -> Bool
matchesAllFor expectedName accounts transactions =
  case accountNamed expectedName accounts of
    Nothing -> False
    Just account ->
      length (transactionsForAccount (Just account) transactions)
        == length transactions

matchesNoneFor :: Text -> [Account] -> [Transaction] -> Bool
matchesNoneFor expectedName accounts transactions =
  case accountNamed expectedName accounts of
    Nothing -> False
    Just account -> null (transactionsForAccount (Just account) transactions)

accountNamed :: Text -> [Account] -> Maybe Account
accountNamed expectedName =
  find ((== expectedName) . accountName)
