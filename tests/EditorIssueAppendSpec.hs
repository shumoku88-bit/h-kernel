{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Directory (removeFile)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Editor.ActualWriter (WriteIntent(..), publishWithAdmission)
import HKernel.Editor.IssueAppend
  ( IssueAppendIntent(..)
  , IssueAppendPreview(..)
  , prepareIssueAppend
  )
import HKernel.Household.Issue.TSV (parseHouseholdIssues)
import HKernel.HouseholdIssue (IssueStatus(..), mkIssueId)
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)

main :: IO ()
main = do
  let tests =
        [ ("testValidIssueAppend", pure testValidIssueAppend)
        , ("testIssueCommit", testIssueCommit)
        ]
  results <- sequence [action | (_, action) <- tests]
  let namedResults = zip (map fst tests) results
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

fixtureSource :: Text
fixtureSource = T.unlines
  [ "issue_id\tstatus\tdate\tcategory\ttitle\tamount\tcurrency\tdetails"
  , "ISSUE-1\topen\t2026-08-01\tmisc\tSome title\t1000\tJPY\tsome details"
  ]

testIntent :: IssueAppendIntent
testIntent = IssueAppendIntent
  { intentIssueId = either (error "bad id") id (mkIssueId "ISSUE-2")
  , intentStatus = Open
  , intentDate = fromGregorian 2026 8 4
  , intentCategory = "groceries"
  , intentTitle = "Buy milk"
  , intentAmount = Just
      (mkAmount
        (either (error "bad comm") id (mkCommodity "JPY"))
        (quantityFromInteger 500))
  , intentDetails = "need it for breakfast"
  }

testValidIssueAppend :: Bool
testValidIssueAppend =
  case prepareIssueAppend fixtureSource testIntent of
    Right preview ->
      candidateBlock preview
        == "ISSUE-2\topen\t2026-08-04\tgroceries\tBuy milk\t500\tJPY\tneed it for breakfast"
    Left err -> error (show err)

testIssueCommit :: IO Bool
testIssueCommit = do
  let path = "tests/fixtures/test_editor_issue_commit.tsv"
  cleanup path
  TIO.writeFile path fixtureSource
  result <- case prepareIssueAppend fixtureSource testIntent of
    Left err -> print err >> pure False
    Right preview -> do
      writeResult <- publishWithAdmission
        parseHouseholdIssues
        WriteIntent
          { targetFilePath = path
          , expectedOldBytes = fixtureSource
          , candidateNewBytes = candidateCompleteSource preview
          }
      case writeResult of
        Left err -> print err >> pure False
        Right () ->
          (== candidateCompleteSource preview) <$> TIO.readFile path
  cleanup path
  pure result

cleanup :: FilePath -> IO ()
cleanup path = do
  removeIfPresent path
  removeIfPresent (path <> ".backup.tmp")
  removeIfPresent (path <> ".new.tmp")

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  catch (removeFile path) (\(_ :: IOException) -> pure ())
