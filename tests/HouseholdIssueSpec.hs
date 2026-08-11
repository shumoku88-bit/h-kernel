{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import Data.Time.Calendar (fromGregorian)
import HKernel.HouseholdIssue
import HKernel.HouseholdIssue.Render
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeIssueIdentity
  characterizeHouseholdIssue
  characterizeCompleteLineRendering

characterizeIssueIdentity :: IO ()
characterizeIssueIdentity = do
  let issueId = mustRight (mkIssueId "issue-2026-001")

  assertEqual "issue identity retains its stable text"
    "issue-2026-001"
    (issueIdText issueId)
  assertLeft "empty issue identity is rejected"
    (mkIssueId "")
  assertLeft "issue identity with surrounding whitespace is rejected"
    (mkIssueId " issue-2026-001")
  assertLeft "issue identity with embedded whitespace is rejected"
    (mkIssueId "issue 2026 001")
  assertLeft "issue identity with a control character is rejected"
    (mkIssueId "issue\t2026")

characterizeHouseholdIssue :: IO ()
characterizeHouseholdIssue = do
  let issueId = mustRight (mkIssueId "issue-2026-001")
      recordedOn = fromGregorian 2026 8 1
      dueOn = fromGregorian 2026 8 8
      jpy = mustRight (mkCommodity "JPY")
      amount = mkAmount jpy (quantityFromInteger 4810)
      issue = mustRight (mkHouseholdIssue
        issueId
        recordedOn
        Open
        (DueOn dueOn)
        (Just amount)
        "Wi-Fi支払いをゆうちょで埋めるか"
        "節約中")

  assertEqual "issue retains its stable identity"
    issueId
    (householdIssueId issue)
  assertEqual "issue retains its recorded date"
    recordedOn
    (householdIssueRecordedOn issue)
  assertEqual "open and resolved remain distinct states"
    False
    (householdIssueStatus issue == Resolved)
  assertEqual "a known due date remains explicit"
    (DueOn dueOn)
    (householdIssueDue issue)
  assertEqual "an optional amount remains exact"
    (Just amount)
    (householdIssueAmount issue)
  assertEqual "issue text remains complete"
    "Wi-Fi支払いをゆうちょで埋めるか"
    (householdIssueText issue)
  assertEqual "issue details remain complete"
    "節約中"
    (householdIssueDetails issue)

  let undetermined = mustRight (mkHouseholdIssue
        issueId
        recordedOn
        Resolved
        DueUndetermined
        Nothing
        "契約を続けるか確認する"
        "")
  assertEqual "due-undetermined is distinct from a known date"
    DueUndetermined
    (householdIssueDue undetermined)
  assertEqual "non-monetary issues retain no amount"
    Nothing
    (householdIssueAmount undetermined)
  assertEqual "empty details are admitted without inventing content"
    ""
    (householdIssueDetails undetermined)

  assertLeft "empty issue text is rejected"
    (mkHouseholdIssue issueId recordedOn Open DueUndetermined Nothing "" "")
  assertLeft "issue text with surrounding whitespace is rejected"
    (mkHouseholdIssue issueId recordedOn Open DueUndetermined Nothing
      " 支払いを確認する" "")
  assertLeft "issue text cannot contain a hidden second line"
    (mkHouseholdIssue issueId recordedOn Open DueUndetermined Nothing
      "支払いを確認する\n来週" "")
  assertLeft "details with surrounding whitespace are rejected"
    (mkHouseholdIssue issueId recordedOn Open DueUndetermined Nothing
      "支払いを確認する" " 節約中")
  assertLeft "details cannot contain a hidden second line"
    (mkHouseholdIssue issueId recordedOn Open DueUndetermined Nothing
      "支払いを確認する" "節約中\n要相談")

characterizeCompleteLineRendering :: IO ()
characterizeCompleteLineRendering = do
  let issueId = mustRight (mkIssueId "issue-2026-001")
      jpy = mustRight (mkCommodity "JPY")
      issue = mustRight (mkHouseholdIssue
        issueId
        (fromGregorian 2026 8 1)
        Open
        (DueOn (fromGregorian 2026 8 8))
        (Just (mkAmount jpy (quantityFromInteger 4810)))
        "Wi-Fi支払いをゆうちょで埋めるか"
        "節約中")

  assertEqual "one-line rendering publishes every household-facing field"
    "2026-08-01 | open | due 2026-08-08 | 4810 JPY | Wi-Fi支払いをゆうちょで埋めるか | 節約中"
    (renderHouseholdIssueLine issue)

  let noDateOrAmount = mustRight (mkHouseholdIssue
        issueId
        (fromGregorian 2026 8 2)
        Resolved
        DueUndetermined
        Nothing
        "契約を続けるか確認する"
        "確認済み")
  assertEqual "undetermined due date and absent amount remain visible"
    "2026-08-02 | resolved | due undetermined | no amount | 契約を続けるか確認する | 確認済み"
    (renderHouseholdIssueLine noDateOrAmount)



assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure


