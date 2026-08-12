{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account
  ( Account
  , AccountType(..)
  , declareAccount
  , declareAccountWithDefaultCommodity
  , lookupAccountDeclaration
  , mkAccount
  )
import HKernel.Account.Journal
  ( AccountDeclarationRenderError(..)
  , parseAccountJournal
  )
import HKernel.Actual.Journal
  ( actualJournalValue
  , parseActualJournal
  )
import HKernel.Editor.AccountAppend
import HKernel.Journal (journalAccountRegistry)
import HKernel.Money (Commodity, mkCommodity)

main :: IO ()
main = do
  let results =
        [ ("testCanonicalAccountJournalAppend", testCanonicalAccountJournalAppend)
        , ("testCanonicalAccountJournalDuplicate", testCanonicalAccountJournalDuplicate)
        , ("testCanonicalAccountJournalRejectsActualSource", testCanonicalAccountJournalRejectsActualSource)
        , ("testValidAccountNoCommodity", testValidAccountNoCommodity)
        , ("testValidAccountWithCommodity", testValidAccountWithCommodity)
        , ("testDuplicateAccount", testDuplicateAccount)
        , ("testAllAccountTypesRoundTrip", testAllAccountTypesRoundTrip)
        , ("testCommentDelimiterRejected", testCommentDelimiterRejected)
        ]
  mapM_ print results
  if all snd results
    then exitSuccess
    else exitFailure

accountJournalSource :: Text
accountJournalSource = T.unlines
  [ "account equity:opening"
  , "  type: Equity"
  , ""
  , "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  ]

fixtureSource :: Text
fixtureSource = accountJournalSource <> T.unlines
  [ ""
  , "2026-08-01 opening"
  , "  assets:cash     1000 JPY"
  , "  equity:opening  -1000 JPY"
  ]

accNew :: Account
accNew = mustAccount "expenses:food"

accExisting :: Account
accExisting = mustAccount "assets:cash"

commJPY :: Commodity
commJPY = either (error "bad comm") id (mkCommodity "JPY")

testCanonicalAccountJournalAppend :: Bool
testCanonicalAccountJournalAppend =
  let declaration =
        declareAccountWithDefaultCommodity accNew Expense commJPY
  in case prepareAccountJournalAppend accountJournalSource declaration of
       Left _ -> False
       Right preview ->
         accountCandidateBlock preview
           == "account expenses:food\n  type: Expense\n  commodity: JPY\n"
         && case parseAccountJournal (accountCandidateCompleteSource preview) of
              Left _ -> False
              Right registry ->
                lookupAccountDeclaration accNew registry == Just declaration

testCanonicalAccountJournalDuplicate :: Bool
testCanonicalAccountJournalDuplicate =
  let declaration = declareAccount accExisting Asset
  in case prepareAccountJournalAppend accountJournalSource declaration of
       Left (AccountJournalDuplicateDeclaration account :| []) ->
         account == accExisting
       _ -> False

testCanonicalAccountJournalRejectsActualSource :: Bool
testCanonicalAccountJournalRejectsActualSource =
  let declaration = declareAccount accNew Expense
  in case prepareAccountJournalAppend fixtureSource declaration of
       Left (AccountJournalSourceParseError _ :| []) -> True
       _ -> False

testValidAccountNoCommodity :: Bool
testValidAccountNoCommodity =
  let declaration = declareAccount accNew Expense
      result = prepareActualAccountAppend fixtureSource declaration
  in case result of
       Right preview ->
         "account expenses:food\n  type: Expense\n"
           == candidateBlock preview
       Left err -> error (show err)

testValidAccountWithCommodity :: Bool
testValidAccountWithCommodity =
  let declaration = declareAccountWithDefaultCommodity accNew Expense commJPY
      result = prepareActualAccountAppend fixtureSource declaration
  in case result of
       Right preview ->
         "account expenses:food\n  type: Expense\n  commodity: JPY\n"
           == candidateBlock preview
       Left err -> error (show err)

testDuplicateAccount :: Bool
testDuplicateAccount =
  let declaration = declareAccount accExisting Asset
      result = prepareActualAccountAppend fixtureSource declaration
  in case result of
       Left (DuplicateDeclaration account :| []) -> account == accExisting
       _ -> False

testAllAccountTypesRoundTrip :: Bool
testAllAccountTypesRoundTrip =
  all declarationRoundTrips
    [ Asset
    , Liability
    , Equity
    , Income
    , Expense
    , Budget
    ]
  where
    declarationRoundTrips accountType =
      let account = mustAccount
            ("roundtrip:" <> T.toCaseFold (T.pack (show accountType)))
          declaration =
            declareAccountWithDefaultCommodity account accountType commJPY
      in case prepareActualAccountAppend fixtureSource declaration of
           Left _ -> False
           Right preview ->
             case parseActualJournal (candidateCompleteSource preview) of
               Left _ -> False
               Right journal ->
                 lookupAccountDeclaration
                   account
                   (journalAccountRegistry (actualJournalValue journal))
                   == Just declaration

testCommentDelimiterRejected :: Bool
testCommentDelimiterRejected =
  let account = mustAccount "expenses:food;legacy"
      declaration = declareAccount account Expense
  in case prepareActualAccountAppend fixtureSource declaration of
       Left (DeclarationRenderError AccountDeclarationUnrepresentable :| []) ->
         True
       _ -> False

mustAccount :: Text -> Account
mustAccount value = either (error "bad account") id (mkAccount value)