{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Time.Calendar (Day)
import HKernel.Editor.TUI.Actual (State(..), startIssueRealize, startRecord)
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueDue(..)
  , IssueStatus(..)
  , mkHouseholdIssue
  , mkIssueId
  )
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  let results =
        [ ("ordinary Record and Issue realization enter the shared Record flow", testSharedRecordFlow)
        , ("closed Issue cannot start realization", testClosedIssueCannotStart)
        ]
  mapM_ print results
  if all snd results then exitSuccess else exitFailure

testSharedRecordFlow :: Bool
testSharedRecordFlow =
  isRecordInput (startRecord entryDay :: State ())
    && case openIssue of
      Nothing -> False
      Just issue -> maybe False isRecordInput
        (startIssueRealize entryDay issue :: Maybe (State ()))
  where
    isRecordInput state = case state of
      RecordInput _ -> True
      _ -> False

testClosedIssueCannotStart :: Bool
testClosedIssueCannotStart =
  case closedIssue of
    Nothing -> False
    Just issue -> case startIssueRealize entryDay issue of
      Nothing -> True
      Just _ -> False

entryDay :: Day
entryDay = read "2026-08-08"

openIssue, closedIssue :: Maybe HouseholdIssue
openIssue = mkIssue Open
closedIssue = mkIssue Resolved

mkIssue :: IssueStatus -> Maybe HouseholdIssue
mkIssue status = do
  issueId <- either (const Nothing) Just (mkIssueId "ISSUE-TUI")
  either (const Nothing) Just
    (mkHouseholdIssue
      issueId
      (read "2026-08-01")
      status
      DueUndetermined
      Nothing
      "Issue title"
      "")
