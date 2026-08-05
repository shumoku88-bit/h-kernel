{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Editor.ActualWriter
  ( WriteIntent(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithAdmission
  )
import HKernel.Editor.IssueAppend
  ( IssueAppendIntent(..)
  , IssueAppendPreview(..)
  , prepareIssueAppend
  )
import HKernel.Household.Issue.TSV
  ( householdIssuesHeader
  , parseHouseholdIssues
  )
import HKernel.HouseholdIssue
  ( IssueStatus(..)
  , householdIssueAmount
  , householdIssueId
  , mkIssueId
  )
import HKernel.Money
  ( mkAmount
  , mkCommodity
  , quantityFromInteger
  )

main :: IO ()
main = do
  let tests =
        [ ("testValidIssueAppend", pure testValidIssueAppend)
        , ("testOptionalAmountAppend", pure testOptionalAmountAppend)
        , ("testEmptySourceAddsHeader", pure testEmptySourceAddsHeader)
        , ("testCommentOnlySourceAddsHeader", pure testCommentOnlySourceAddsHeader)
        , ("testOneSidedBlankAmountRejected", pure testOneSidedBlankAmountRejected)
        , ("testIssueCommit", testIssueCommit)
        , ("testEmptyIssueCommit", testEmptyIssueCommit)
        ]
  results <- sequence [action | (_, action) <- tests]
  let namedResults = zip (map fst tests) results
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

fixtureSource :: Text
fixtureSource = T.unlines
  [ householdIssuesHeader
  , "ISSUE-1\topen\t2026-08-01\tmisc\tSome title\t1000\tJPY\tsome details"
  ]

testIntent :: IssueAppendIntent
testIntent = IssueAppendIntent
  { intentIssueId = mustIssueId "ISSUE-2"
  , intentStatus = Open
  , intentDate = fromGregorian 2026 8 4
  , intentCategory = "groceries"
  , intentTitle = "Buy milk"
  , intentAmount = Just
      (mkAmount
        (mustCommodity "JPY")
        (quantityFromInteger 500))
  , intentDetails = "need it for breakfast"
  }

optionalAmountIntent :: IssueAppendIntent
optionalAmountIntent = IssueAppendIntent
  { intentIssueId = mustIssueId "ISSUE-3"
  , intentStatus = Open
  , intentDate = fromGregorian 2026 8 5
  , intentCategory = "home"
  , intentTitle = "Check the boiler"
  , intentAmount = Nothing
  , intentDetails = "cost is not known yet"
  }

testValidIssueAppend :: Bool
testValidIssueAppend =
  case prepareIssueAppend fixtureSource testIntent of
    Right preview ->
      candidateBlock preview
        == "ISSUE-2\topen\t2026-08-04\tgroceries\tBuy milk\t500\tJPY\tneed it for breakfast"
    Left err -> error (show err)

testOptionalAmountAppend :: Bool
testOptionalAmountAppend =
  case prepareIssueAppend fixtureSource optionalAmountIntent of
    Left err -> error (show err)
    Right preview ->
      candidateBlock preview
        == "ISSUE-3\topen\t2026-08-05\thome\tCheck the boiler\t\tcost is not known yet"
      && parsedOptionalIssueMatches preview

testEmptySourceAddsHeader :: Bool
testEmptySourceAddsHeader =
  case prepareIssueAppend "" optionalAmountIntent of
    Left err -> error (show err)
    Right preview ->
      candidateCompleteSource preview
        == householdIssuesHeader <> "\n" <> candidateBlock preview
      && parsedOptionalIssueMatches preview

testCommentOnlySourceAddsHeader :: Bool
testCommentOnlySourceAddsHeader =
  case prepareIssueAppend "# retained notebook note\n" optionalAmountIntent of
    Left err -> error (show err)
    Right preview ->
      householdIssuesHeader `T.isInfixOf` candidateCompleteSource preview
      && parsedOptionalIssueMatches preview

testOneSidedBlankAmountRejected :: Bool
testOneSidedBlankAmountRejected =
  case parseHouseholdIssues oneSidedBlankSource of
    Left _ -> True
    Right _ -> False
  where
    oneSidedBlankSource = T.unlines
      [ householdIssuesHeader
      , "ISSUE-4\topen\t2026-08-05\thome\tBroken latch\t\tJPY\tinspect first"
      ]

parsedOptionalIssueMatches :: IssueAppendPreview -> Bool
parsedOptionalIssueMatches preview =
  case parseHouseholdIssues (candidateCompleteSource preview) of
    Right issues -> case reverse issues of
      issue : _ ->
        householdIssueId issue == intentIssueId optionalAmountIntent
          && householdIssueAmount issue == Nothing
      [] -> False
    Left _ -> False

testIssueCommit :: IO Bool
testIssueCommit =
  commitAndVerify
    "tests/fixtures/test_editor_issue_commit.tsv"
    fixtureSource
    testIntent
    (const True)

testEmptyIssueCommit :: IO Bool
testEmptyIssueCommit =
  commitAndVerify
    "tests/fixtures/test_editor_empty_issue_commit.tsv"
    ""
    optionalAmountIntent
    (\written -> case parseHouseholdIssues written of
      Right [issue] ->
        householdIssueId issue == intentIssueId optionalAmountIntent
          && householdIssueAmount issue == Nothing
      _ -> False)

commitAndVerify
  :: FilePath
  -> Text
  -> IssueAppendIntent
  -> (Text -> Bool)
  -> IO Bool
commitAndVerify path source intent verify = do
  cleanup path
  TIO.writeFile path source
  result <- case prepareIssueAppend source intent of
    Left err -> print err >> pure False
    Right preview -> do
      writeResult <- publishWithAdmission
        parseHouseholdIssues
        WriteIntent
          { targetFilePath = path
          , expectedOldBytes = source
          , candidateNewBytes = candidateCompleteSource preview
          }
      case writeResult of
        Left err -> print err >> pure False
        Right () -> do
          written <- TIO.readFile path
          pure
            (written == candidateCompleteSource preview
              && verify written)
  cleanup path
  pure result

cleanup :: FilePath -> IO ()
cleanup path = do
  removeIfPresent path
  removeIfPresent (path <> ".backup.tmp")
  removeIfPresent (path <> ".new.tmp")

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  catch
    (removeTextFile defaultWriterFileSystem path)
    (\(_ :: IOException) -> pure ())

mustIssueId :: Text -> HKernel.HouseholdIssue.IssueId
mustIssueId value = either (error "bad IssueId") id (mkIssueId value)

mustCommodity :: Text -> HKernel.Money.Commodity
mustCommodity value = either (error "bad Commodity") id (mkCommodity value)
