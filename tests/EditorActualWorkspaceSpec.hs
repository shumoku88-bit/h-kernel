{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List (find)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account
  ( Account
  , accountDeclarations
  , accountName
  , declaredAccount
  )
import HKernel.Actual.Journal
  ( ActualTransactionEntry
  , actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntryIdentity
  , parseActualJournal
  )
import HKernel.Editor.ActualWorkspace
  ( newestTransactionEntriesForAccount
  , transactionEntriesForAccount
  )
import HKernel.Journal (journalAccountRegistry)
import HKernel.Plan.Completion (actualTransactionIdText)

main :: IO ()
main = do
  source <- TIO.readFile "tests/fixtures/editor/actual-add.journal"
  fixtureResults <- case parseActualJournal source of
    Left errors -> do
      mapM_ print (NonEmpty.toList errors)
      exitFailure
    Right actualJournal -> do
      let journal = actualJournalValue actualJournal
          transactions = actualJournalTransactionEntries actualJournal
          accounts =
            map declaredAccount
              (accountDeclarations (journalAccountRegistry journal))
      pure
        [ ("no Account filter preserves all Actual transactions"
          , length (transactionEntriesForAccount Nothing transactions)
              == length transactions)
        , ("selected Account retains matching Actual transactions"
          , matchesAllFor "assets:cash" accounts transactions)
        , ("selected Account excludes non-matching Actual transactions"
          , matchesNoneFor "expenses:food" accounts transactions)
        ]

  let alignedJournal = mustRight (parseActualJournal duplicateShapeSource)
      alignedEntries = actualJournalTransactionEntries alignedJournal
      alignmentResult =
        ( "source-position identity survives duplicate Transaction values"
        , map (fmap actualTransactionIdText . actualTransactionEntryIdentity)
            alignedEntries
            == [Nothing, Just "actual-second"]
        )
      newestFirstResult =
        ( "newest-first projection reverses display without changing source entries"
        , map (fmap actualTransactionIdText . actualTransactionEntryIdentity)
            (newestTransactionEntriesForAccount Nothing alignedEntries)
            == [Just "actual-second", Nothing]
            && map (fmap actualTransactionIdText . actualTransactionEntryIdentity)
                alignedEntries
              == [Nothing, Just "actual-second"]
        )
      results = fixtureResults ++ [alignmentResult, newestFirstResult]

  mapM_ print results
  if all snd results then exitSuccess else exitFailure

matchesAllFor
  :: Text
  -> [Account]
  -> [ActualTransactionEntry]
  -> Bool
matchesAllFor expectedName accounts transactions =
  case accountNamed expectedName accounts of
    Nothing -> False
    Just account ->
      length (transactionEntriesForAccount (Just account) transactions)
        == length transactions

matchesNoneFor
  :: Text
  -> [Account]
  -> [ActualTransactionEntry]
  -> Bool
matchesNoneFor expectedName accounts transactions =
  case accountNamed expectedName accounts of
    Nothing -> False
    Just account -> null (transactionEntriesForAccount (Just account) transactions)

accountNamed :: Text -> [Account] -> Maybe Account
accountNamed expectedName =
  find ((== expectedName) . accountName)

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Left err -> error ("invalid test setup: " ++ show err)
  Right value -> value

duplicateShapeSource :: Text
duplicateShapeSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2026-08-08 Same transaction"
  , "  assets:cash  -100 JPY"
  , "  expenses:food  100 JPY"
  , ""
  , "2026-08-08 Same transaction"
  , "  ; event-id: actual-second"
  , "  assets:cash  -100 JPY"
  , "  expenses:food  100 JPY"
  ]
