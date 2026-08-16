{-# LANGUAGE OverloadedStrings #-}

module HouseholdWorkspaceProjectionSpec (main) where

import Data.Time.Calendar (fromGregorian)
import HKernel.Account
  ( AccountType(..)
  , declareAccount
  , emptyAccountRegistry
  , mkAccount
  , registerAccount
  )
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Editor.HouseholdWorkspace
  ( homeActualTransactionsOn
  , homeIssuesDueOn
  , workspaceAccounts
  , workspaceIssueCounts
  , workspaceTransactions
  )
import HKernel.HouseholdIssue
  ( IssueDue(..)
  , IssueStatus(..)
  , mkHouseholdIssue
  , mkIssueId
  )
import HKernel.Ledger (transactionDate)
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeWorkspaceLists
  characterizeIssueProjections

characterizeWorkspaceLists :: IO ()
characterizeWorkspaceLists = do
  let cash = mustRight (mkAccount "assets:cash")
      food = mustRight (mkAccount "expenses:food")
      registry = mustRight
        ( registerAccount (declareAccount food Expense)
        =<< registerAccount (declareAccount cash Asset) emptyAccountRegistry
        )
      journal = mustRight (parseActualJournal source)
      transactions = workspaceTransactions journal

  equal "workspace Account projection exposes every admitted declaration"
    2
    (length (workspaceAccounts registry))
  equal "workspace Actual projection is newest first without rewriting source"
    [fromGregorian 2026 8 2, fromGregorian 2026 8 1]
    (map transactionDate transactions)
  equal "Home day projection selects only the requested Actual facts"
    [fromGregorian 2026 8 1]
    (map transactionDate
      (homeActualTransactionsOn (fromGregorian 2026 8 1) journal))
  where
    source =
      "account assets:cash\n"
      <> "  type: Asset\n"
      <> "account expenses:food\n"
      <> "  type: Expense\n\n"
      <> "2026-08-01 first\n"
      <> "  expenses:food  10 JPY\n"
      <> "  assets:cash\n\n"
      <> "2026-08-02 second\n"
      <> "  expenses:food  20 JPY\n"
      <> "  assets:cash\n"

characterizeIssueProjections :: IO ()
characterizeIssueProjections = do
  let dueDay = fromGregorian 2026 8 10
      openDue = issue "open-due" Open (DueOn dueDay)
      openOther = issue "open-other" Open (DueOn (fromGregorian 2026 8 11))
      closedDue = issue "closed-due" Resolved (DueOn dueDay)
      issues = [openDue, openOther, closedDue]

  equal "workspace Issue counts keep open attention separate from closed history"
    (2, 1)
    (workspaceIssueCounts issues)
  equal "Home due projection includes only open Issues due on the selected day"
    [openDue]
    (homeIssuesDueOn dueDay issues)
  where
    issue identity status due = mustRight
      (mkHouseholdIssue
        (mustRight (mkIssueId identity))
        (fromGregorian 2026 8 1)
        status
        due
        Nothing
        identity
        "")

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

equal :: (Eq value, Show value) => String -> value -> value -> IO ()
equal label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    actual:   " ++ show actual)
      exitFailure
