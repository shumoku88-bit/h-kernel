{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.HouseholdIssue (mkIssueId, IssueStatus(..))
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)
import HKernel.Editor.IssueAppend (prepareIssueAppend, candidateBlock, IssueAppendIntent(..), IssueAppendPreview)

main :: IO ()
main = do
  let results = [ ("testValidIssueAppend", testValidIssueAppend) ]
  mapM_ print results
  if all snd results
    then exitSuccess
    else exitFailure

fixtureSource :: Text
fixtureSource = T.unlines
  [ "issue_id\tstatus\tdate\tcategory\ttitle\tamount\tcurrency\tdetails"
  , "ISSUE-1\topen\t2026-08-01\tmisc\tSome title\t1000\tJPY\tsome details"
  ]

testIntent :: IssueAppendIntent
testIntent = IssueAppendIntent
  { intentIssueId       = either (error "bad id") id (mkIssueId "ISSUE-2")
  , intentStatus        = Open
  , intentDate          = fromGregorian 2026 8 4
  , intentCategory      = "groceries"
  , intentTitle         = "Buy milk"
  , intentAmount        = Just (mkAmount (either (error "bad comm") id (mkCommodity "JPY")) (quantityFromInteger 500))
  , intentDetails       = "need it for breakfast"
  }

testValidIssueAppend :: Bool
testValidIssueAppend =
  let result = prepareIssueAppend fixtureSource testIntent
  in case result of
       Right preview ->
         let block = candidateBlock preview
         in "ISSUE-2\topen\t2026-08-04\tgroceries\tBuy milk\t500\tJPY\tneed it for breakfast" == block
       Left err -> error (show err)
