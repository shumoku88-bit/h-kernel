{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Household.Issue.TSV
import HKernel.HouseholdIssue
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeAcceptedIssues
  characterizeSourceFailures

characterizeAcceptedIssues :: IO ()
characterizeAcceptedIssues = do
  let issues = mustRight (parseHouseholdIssues validIssues)
      firstIssue = exactlyOne
        (filter ((== "issue-one") . issueIdText . householdIssueId) issues)
      secondIssue = exactlyOne
        (filter ((== "issue-resolved") . issueIdText . householdIssueId) issues)
      issueWithoutAmount = exactlyOne
        (mustRight (parseHouseholdIssues optionalAmountIssue))
      jpy = mustRight (mkCommodity "JPY")

  assertEqual "one physical row becomes one typed HouseholdIssue"
    2
    (length issues)
  assertEqual "open status remains typed"
    Open
    (householdIssueStatus firstIssue)
  assertEqual "recorded date remains exact"
    (fromGregorian 2026 7 20)
    (householdIssueRecordedOn firstIssue)
  assertEqual "retained source does not invent a due date"
    DueUndetermined
    (householdIssueDue firstIssue)
  assertEqual "amount and Commodity remain exact"
    (Just (mkAmount jpy (quantityFromInteger 200)))
    (householdIssueAmount firstIssue)
  assertEqual "category remains explicit context in details"
    "[planning] decide funding"
    (householdIssueDetails firstIssue)
  assertEqual "resolved remains distinct from open"
    Resolved
    (householdIssueStatus secondIssue)
  assertEqual "blank amount and currency retain no invented Amount"
    Nothing
    (householdIssueAmount issueWithoutAmount)
  assertEqual "blank and comment-only input admits no issues"
    []
    (mustRight (parseHouseholdIssues "\n# no current matters\n"))

characterizeSourceFailures :: IO ()
characterizeSourceFailures = do
  assertLeftAt "header is exact and retains its physical line"
    2
    "unexpected issues header"
    (parseHouseholdIssues (T.replace "issue_id" "id" validIssues))
  assertLeftAt "status vocabulary is closed"
    2
    "unknown issue status"
    (parseHouseholdIssues (T.replace "\topen\t" "\tpending\t" oneIssue))
  assertLeftAt "date retains its physical line coordinate"
    2
    "invalid date"
    (parseHouseholdIssues (T.replace "2026-07-20" "2026-02-30" oneIssue))
  assertLeftAt "row width remains exact"
    2
    "expected eight issue columns"
    (parseHouseholdIssues (header <> "\nissue-one\topen\n"))
  assertLeftAt "blank amount cannot discard a present currency"
    2
    "amount and currency must both be blank or both be present"
    (parseHouseholdIssues amountBlankOnly)
  assertLeftAt "blank currency cannot discard a present amount"
    2
    "amount and currency must both be blank or both be present"
    (parseHouseholdIssues currencyBlankOnly)
  assertLeftAt "IssueId is unique across the admitted collection"
    0
    "duplicate identity"
    (parseHouseholdIssues duplicateIssues)

header :: T.Text
header = householdIssuesHeader

oneIssue :: T.Text
oneIssue = T.unlines
  [ header
  , "issue-one\topen\t2026-07-20\tplanning\twifi\t200\tJPY\tdecide funding"
  ]

optionalAmountIssue :: T.Text
optionalAmountIssue = T.unlines
  [ header
  , "issue-unknown-cost\topen\t2026-07-22\thome\tboiler\t\t\tinspect first"
  ]

amountBlankOnly :: T.Text
amountBlankOnly = T.unlines
  [ header
  , "issue-amount-blank\topen\t2026-07-22\thome\tboiler\t\tJPY\tinspect first"
  ]

currencyBlankOnly :: T.Text
currencyBlankOnly = T.unlines
  [ header
  , "issue-currency-blank\topen\t2026-07-22\thome\tboiler\t200\t\tinspect first"
  ]

validIssues :: T.Text
validIssues = T.unlines
  [ "# household notebook"
  , header
  , "issue-one\topen\t2026-07-20\tplanning\twifi\t200\tJPY\tdecide funding"
  , "issue-resolved\tresolved\t2026-07-01\tsubscription\tcancelled\t0\tJPY\tdone"
  ]

duplicateIssues :: T.Text
duplicateIssues = T.unlines
  [ header
  , "issue-one\topen\t2026-07-20\tplanning\twifi\t200\tJPY\tdecide funding"
  , "issue-one\tresolved\t2026-07-21\tplanning\twifi\t0\tJPY\tdone"
  ]

exactlyOne :: Show value => [value] -> value
exactlyOne [value] = value
exactlyOne values = error ("expected exactly one value, got " ++ show values)

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

assertLeftAt
  :: String
  -> Int
  -> T.Text
  -> Either (NonEmpty.NonEmpty HouseholdIssueTSVError) value
  -> IO ()
assertLeftAt label expectedLine expectedMessage result = case result of
  Left errors
    | any matches (NonEmpty.toList errors) ->
        putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    expected line/message: "
          ++ show expectedLine ++ " / " ++ T.unpack expectedMessage)
        putStrLn ("    actual errors: " ++ show errors)
        exitFailure
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted source"
    exitFailure
  where
    matches err =
      householdIssueTSVErrorLine err == expectedLine
        && householdIssueTSVErrorMessage err == expectedMessage

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
