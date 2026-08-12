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
  characterizeCompatibility
  characterizeSourceFailures

characterizeAcceptedIssues :: IO ()
characterizeAcceptedIssues = do
  let issues = mustRight (parseHouseholdIssues validIssues)
      knownDueIssue = exactlyOne
        (filter ((== "issue-one") . issueIdText . householdIssueId) issues)
      noDueIssue = exactlyOne
        (filter ((== "issue-no-due") . issueIdText . householdIssueId) issues)
      closedIssue = exactlyOne
        (filter ((== "issue-closed") . issueIdText . householdIssueId) issues)
      issueWithoutAmount = exactlyOne
        (mustRight (parseHouseholdIssues optionalAmountIssue))
      jpy = mustRight (mkCommodity "JPY")

  assertEqual "one physical row becomes one typed HouseholdIssue"
    3
    (length issues)
  assertEqual "recorded date remains independent from due and closed"
    (fromGregorian 2026 7 20)
    (householdIssueRecordedOn knownDueIssue)
  assertEqual "known due is admitted from the due coordinate"
    (DueOn (fromGregorian 2026 8 15))
    (householdIssueDue knownDueIssue)
  assertEqual "open Issue has explicit not-closed meaning"
    NotClosed
    (householdIssueClosed knownDueIssue)
  assertEqual "explicit no-due remains typed"
    NoDueDate
    (householdIssueDue noDueIssue)
  assertEqual "closed date is independent from due"
    (ClosedOn (fromGregorian 2026 8 8))
    (householdIssueClosed closedIssue)
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

characterizeCompatibility :: IO ()
characterizeCompatibility = do
  let dueAwareOpen = exactlyOne (mustRight (parseHouseholdIssues dueAwareOpenSource))
      dueAwareClosed = exactlyOne (mustRight (parseHouseholdIssues dueAwareClosedSource))
      legacyClosed = exactlyOne (mustRight (parseHouseholdIssues legacyClosedSource))
  assertEqual "current source owns both due and closed columns"
    True
    (householdIssueSourceUsesDueColumn validIssues
      && householdIssueSourceUsesClosedColumn validIssues)
  assertEqual "nine-column source retains due but not closed coordinate"
    True
    (householdIssueSourceUsesDueColumn dueAwareOpenSource
      && not (householdIssueSourceUsesClosedColumn dueAwareOpenSource))
  assertEqual "nine-column open Issue is known not closed"
    NotClosed
    (householdIssueClosed dueAwareOpen)
  assertEqual "nine-column historical closed Issue keeps missing closure evidence"
    ClosedUndetermined
    (householdIssueClosed dueAwareClosed)
  assertEqual "legacy source owns neither due nor closed coordinate"
    True
    (not (householdIssueSourceUsesDueColumn legacyClosedSource)
      && not (householdIssueSourceUsesClosedColumn legacyClosedSource))
  assertEqual "legacy missing due evidence becomes undetermined"
    DueUndetermined
    (householdIssueDue legacyClosed)
  assertEqual "legacy historical closed Issue keeps closure undetermined"
    ClosedUndetermined
    (householdIssueClosed legacyClosed)

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
  assertLeftAt "invalid explicit closed date fails closed"
    2
    "invalid issue closed date"
    (parseHouseholdIssues (T.replace "\tnone\tplanning\t" "\t2026-02-30\tplanning\t" oneIssue))
  assertLeftAtMessageContains "open status cannot carry closure evidence"
    2
    "OpenHouseholdIssueHasClosureEvidence"
    (parseHouseholdIssues (T.replace "\tnone\tplanning\t" "\t2026-08-08\tplanning\t" oneIssue))
  assertLeftAtMessageContains "closed date cannot precede recorded date"
    2
    "HouseholdIssueClosedBeforeRecorded"
    (parseHouseholdIssues closedBeforeRecorded)
  assertLeftAt "current row width remains exact"
    2
    "expected ten issue columns"
    (parseHouseholdIssues (header <> "\nissue-one\topen\n"))
  assertLeftAt "nine-column row width remains exact"
    2
    "expected nine due-aware issue columns"
    (parseHouseholdIssues (dueAwareHeader <> "\nissue-one\topen\n"))
  assertLeftAt "legacy row width remains exact"
    2
    "expected eight legacy issue columns"
    (parseHouseholdIssues (legacyHeader <> "\nissue-one\topen\n"))
  assertLeftAt "blank amount cannot discard a present currency"
    2
    "amount and currency must both be blank or both be present"
    (parseHouseholdIssues amountBlankOnly)
  assertLeftAt "IssueId is unique across the admitted collection"
    0
    "duplicate identity"
    (parseHouseholdIssues duplicateIssues)

header :: T.Text
header = householdIssuesHeader

dueAwareHeader :: T.Text
dueAwareHeader = dueAwareHouseholdIssuesHeader

legacyHeader :: T.Text
legacyHeader = legacyHouseholdIssuesHeader

oneIssue :: T.Text
oneIssue = T.unlines
  [ header
  , "issue-one\topen\t2026-07-20\t2026-08-15\tnone\tplanning\twifi\t200\tJPY\tdecide funding"
  ]

optionalAmountIssue :: T.Text
optionalAmountIssue = T.unlines
  [ header
  , "issue-unknown-cost\topen\t2026-07-22\tundetermined\tnone\thome\tboiler\t\t\tinspect first"
  ]

amountBlankOnly :: T.Text
amountBlankOnly = T.unlines
  [ header
  , "issue-amount-blank\topen\t2026-07-22\tnone\tnone\thome\tboiler\t\tJPY\tinspect first"
  ]

validIssues :: T.Text
validIssues = T.unlines
  [ "# household notebook"
  , header
  , "issue-one\topen\t2026-07-20\t2026-08-15\tnone\tplanning\twifi\t200\tJPY\tdecide funding"
  , "issue-no-due\topen\t2026-07-01\tnone\tnone\twant\tbookshelf\t\t\tlook for a good one"
  , "issue-closed\tresolved\t2026-07-02\tundetermined\t2026-08-08\twaiting\trepair schedule\t\t\tprovider replied"
  ]

dueAwareOpenSource :: T.Text
dueAwareOpenSource = T.unlines
  [ dueAwareHeader
  , "due-open\topen\t2026-07-20\t2026-08-15\tplanning\twifi\t200\tJPY\tdecide funding"
  ]

dueAwareClosedSource :: T.Text
dueAwareClosedSource = T.unlines
  [ dueAwareHeader
  , "due-closed\tresolved\t2026-07-20\tundetermined\tplanning\twifi\t200\tJPY\tdone"
  ]

legacyClosedSource :: T.Text
legacyClosedSource = T.unlines
  [ legacyHeader
  , "legacy-closed\tdropped\t2026-07-20\tplanning\twifi\t200\tJPY\tstopped"
  ]

closedBeforeRecorded :: T.Text
closedBeforeRecorded = T.unlines
  [ header
  , "issue-old\tresolved\t2026-08-10\tnone\t2026-08-09\tplanning\twifi\t200\tJPY\tdone"
  ]

duplicateIssues :: T.Text
duplicateIssues = T.unlines
  [ header
  , "issue-one\topen\t2026-07-20\tnone\tnone\tplanning\twifi\t200\tJPY\tdecide funding"
  , "issue-one\tresolved\t2026-07-21\tundetermined\tundetermined\tplanning\twifi\t0\tJPY\tdone"
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
    | otherwise -> failWith errors
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted source"
    exitFailure
  where
    matches err =
      householdIssueTSVErrorLine err == expectedLine
        && householdIssueTSVErrorMessage err == expectedMessage
    failWith errors = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected line/message: "
        ++ show expectedLine ++ " / " ++ T.unpack expectedMessage)
      putStrLn ("    actual errors: " ++ show errors)
      exitFailure

assertLeftAtMessageContains
  :: String
  -> Int
  -> T.Text
  -> Either (NonEmpty.NonEmpty HouseholdIssueTSVError) value
  -> IO ()
assertLeftAtMessageContains label expectedLine fragment result = case result of
  Left errors
    | any matches (NonEmpty.toList errors) -> putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    actual errors: " ++ show errors)
        exitFailure
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted source"
    exitFailure
  where
    matches err =
      householdIssueTSVErrorLine err == expectedLine
        && fragment `T.isInfixOf` householdIssueTSVErrorMessage err
