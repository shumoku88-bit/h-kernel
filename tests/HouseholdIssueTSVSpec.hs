{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
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
  characterizeLegacyCompatibility
  characterizeSourceFailures

characterizeAcceptedIssues :: IO ()
characterizeAcceptedIssues = do
  let issues = mustRight (parseHouseholdIssues validIssues)
      knownDueIssue = exactlyOne
        (filter ((== "issue-one") . issueIdText . householdIssueId) issues)
      noDueIssue = exactlyOne
        (filter ((== "issue-no-due") . issueIdText . householdIssueId) issues)
      undeterminedIssue = exactlyOne
        (filter ((== "issue-undetermined") . issueIdText . householdIssueId) issues)
      issueWithoutAmount = exactlyOne
        (mustRight (parseHouseholdIssues optionalAmountIssue))
      jpy = mustRight (mkCommodity "JPY")

  assertEqual "one physical row becomes one typed HouseholdIssue"
    3
    (length issues)
  assertEqual "open status remains typed"
    Open
    (householdIssueStatus knownDueIssue)
  assertEqual "recorded date remains independent from due"
    (fromGregorian 2026 7 20)
    (householdIssueRecordedOn knownDueIssue)
  assertEqual "known due is admitted from the due coordinate"
    (DueOn (fromGregorian 2026 8 15))
    (householdIssueDue knownDueIssue)
  assertEqual "explicit no-due remains typed"
    NoDueDate
    (householdIssueDue noDueIssue)
  assertEqual "undetermined due remains typed"
    DueUndetermined
    (householdIssueDue undeterminedIssue)
  assertEqual "amount and Commodity remain exact"
    (Just (mkAmount jpy (quantityFromInteger 200)))
    (householdIssueAmount knownDueIssue)
  assertEqual "category remains explicit context in details"
    "[planning] decide funding"
    (householdIssueDetails knownDueIssue)
  assertEqual "blank amount and currency retain no invented Amount"
    Nothing
    (householdIssueAmount issueWithoutAmount)
  assertEqual "blank and comment-only input admits no issues"
    []
    (mustRight (parseHouseholdIssues "\n# no current matters\n"))

characterizeLegacyCompatibility :: IO ()
characterizeLegacyCompatibility = do
  let legacyIssues = mustRight (parseHouseholdIssues legacySource)
      legacyIssue = exactlyOne legacyIssues
  assertEqual "legacy eight-column header remains admitted during migration"
    True
    (householdIssueSourceHasHeader legacySource)
  assertEqual "legacy source does not claim to own a due column"
    False
    (householdIssueSourceUsesDueColumn legacySource)
  assertEqual "legacy missing due evidence becomes undetermined, not no-due"
    DueUndetermined
    (householdIssueDue legacyIssue)
  assertEqual "current source advertises an explicit due column"
    True
    (householdIssueSourceUsesDueColumn validIssues)

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
  assertLeftAt "recorded date retains its physical line coordinate"
    2
    "invalid date"
    (parseHouseholdIssues (T.replace "2026-07-20" "2026-02-30" oneIssue))
  assertLeftAt "invalid explicit due fails closed"
    2
    "invalid issue due"
    (parseHouseholdIssues (T.replace "2026-08-15" "2026-02-30" oneIssue))
  assertLeftAt "current row width remains exact"
    2
    "expected nine issue columns"
    (parseHouseholdIssues (header <> "\nissue-one\topen\n"))
  assertLeftAt "legacy row width remains exact"
    2
    "expected eight legacy issue columns"
    (parseHouseholdIssues (legacyHeader <> "\nissue-one\topen\n"))
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

legacyHeader :: T.Text
legacyHeader = legacyHouseholdIssuesHeader

oneIssue :: T.Text
oneIssue = T.unlines
  [ header
  , "issue-one\topen\t2026-07-20\t2026-08-15\tplanning\twifi\t200\tJPY\tdecide funding"
  ]

optionalAmountIssue :: T.Text
optionalAmountIssue = T.unlines
  [ header
  , "issue-unknown-cost\topen\t2026-07-22\tundetermined\thome\tboiler\t\t\tinspect first"
  ]

amountBlankOnly :: T.Text
amountBlankOnly = T.unlines
  [ header
  , "issue-amount-blank\topen\t2026-07-22\tnone\thome\tboiler\t\tJPY\tinspect first"
  ]

currencyBlankOnly :: T.Text
currencyBlankOnly = T.unlines
  [ header
  , "issue-currency-blank\topen\t2026-07-22\tnone\thome\tboiler\t200\t\tinspect first"
  ]

validIssues :: T.Text
validIssues = T.unlines
  [ "# household notebook"
  , header
  , "issue-one\topen\t2026-07-20\t2026-08-15\tplanning\twifi\t200\tJPY\tdecide funding"
  , "issue-no-due\topen\t2026-07-01\tnone\twant\tbookshelf\t\t\tlook for a good one"
  , "issue-undetermined\tresolved\t2026-07-02\tundetermined\twaiting\trepair schedule\t\t\twaiting for reply"
  ]

legacySource :: T.Text
legacySource = T.unlines
  [ legacyHeader
  , "legacy-issue\topen\t2026-07-20\tplanning\twifi\t200\tJPY\tdecide funding"
  ]

duplicateIssues :: T.Text
duplicateIssues = T.unlines
  [ header
  , "issue-one\topen\t2026-07-20\tnone\tplanning\twifi\t200\tJPY\tdecide funding"
  , "issue-one\tresolved\t2026-07-21\tundetermined\tplanning\twifi\t0\tJPY\tdone"
  ]

exactlyOne :: Show value => [value] -> value
exactlyOne [value] = value
exactlyOne values = error ("expected exactly one value, got " ++ show values)

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
