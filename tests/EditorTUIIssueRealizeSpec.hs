{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text qualified as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Application.Config (mkHouseholdRoot)
import HKernel.Editor.TUI.Actual (State(..), startIssueRealize, startRecord)
import HKernel.Editor.TUI.Home (homeUsesStackedLayout)
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , makeWorkspaceContext
  )
import HKernel.Household.Application
  ( HouseholdWriteSnapshot(..)
  , admitCanonicalHousehold
  )
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueDue(..)
  , IssueStatus(..)
  , mkHouseholdIssue
  , mkIssueId
  )
import HKernel.Plan (planIdText)
import HKernel.Plan.Journal (identifiedPlanId)
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  let results =
        [ ("ordinary Record and Issue realization enter the shared Record flow", testSharedRecordFlow)
        , ("closed Issue cannot start realization", testClosedIssueCannotStart)
        , ("Home stacks observations at 60 columns", homeUsesStackedLayout 60)
        , ("Home remains side-by-side at 80 columns", not (homeUsesStackedLayout 80))
        , ("Home remains side-by-side at 120 columns", not (homeUsesStackedLayout 120))
        , ("Home observers survive an unavailable narrow Household Report surface", testIndependentHomeObservations)
        ]
  mapM_ print results
  if all snd results then exitSuccess else exitFailure

testSharedRecordFlow :: Bool
testSharedRecordFlow =
  isRecordFlow (startRecord entryDay :: State ())
    && case openIssue of
      Nothing -> False
      Just issue -> maybe False isRecordFlow
        (startIssueRealize entryDay issue :: Maybe (State ()))
  where
    isRecordFlow state = case state of
      RecordFlow _ -> True
      _ -> False

testClosedIssueCannotStart :: Bool
testClosedIssueCannotStart =
  case closedIssue of
    Nothing -> False
    Just issue -> case startIssueRealize entryDay issue of
      Nothing -> True
      Just _ -> False

testIndependentHomeObservations :: Bool
testIndependentHomeObservations =
  case mkHouseholdRoot "." of
    Left _ -> False
    Right root -> case admitCanonicalHousehold
        root
        availabilityAccounts
        availabilityActual
        availabilityPlan
        availabilityEntitlement
        availabilityEnvelope
        availabilityHousehold
        availabilityReport
        availabilityIssues of
      Left _ -> False
      Right household ->
        let snapshot = HouseholdWriteSnapshot
              { householdWriteSnapshotState = household
              , householdWriteSnapshotAccountsSource = availabilityAccounts
              , householdWriteSnapshotActualSource = availabilityActual
              , householdWriteSnapshotPlanSource = availabilityPlan
              , householdWriteSnapshotEntitlementSource = availabilityEntitlement
              , householdWriteSnapshotIssuesSource = availabilityIssues
              }
            context = makeWorkspaceContext availabilityObservation snapshot
            reportUnavailable = case contextHouseholdReportSurface context of
              Left _ -> True
              Right _ -> False
            cycleAvailable = case contextHouseholdCycleObservation context of
              Left _ -> False
              Right _ -> True
            reportBookAvailable = case contextResolvedReportBook context of
              Left _ -> False
              Right _ -> True
            planAvailable = case contextOpenPlanObservation context of
              Left _ -> False
              Right plans ->
                "P200" `elem` map (planIdText . identifiedPlanId) plans
        in reportUnavailable
            && cycleAvailable
            && reportBookAvailable
            && planAvailable

entryDay :: Day
entryDay = read "2026-08-08"

availabilityObservation :: Day
availabilityObservation = fromGregorian 2026 7 20

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

availabilityAccounts :: T.Text
availabilityAccounts = T.unlines
  [ "account Assets:Bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account Income:Salary"
  , "  type: Income"
  , "  commodity: JPY"
  , ""
  , "account Expenses:Groceries"
  , "  type: Expense"
  , "  commodity: JPY"
  ]

availabilityActual :: T.Text
availabilityActual = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-06-01 * Income anchor"
  , "  Income:Salary  -300000 JPY"
  , "  Assets:Bank"
  , ""
  , "2026-07-01 * Income anchor"
  , "  Income:Salary  -300000 JPY"
  , "  Assets:Bank"
  ]

availabilityPlan :: T.Text
availabilityPlan = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-08-01 * Income anchor"
  , "  ; plan-id: P001"
  , "  Income:Salary  -300000 JPY"
  , "  Assets:Bank"
  , ""
  , "2026-07-26 * Split household costs"
  , "  ; plan-id: P200"
  , "  Assets:Bank            -3000 JPY"
  , "  Expenses:Groceries      1000 JPY"
  , "  Expenses:Groceries      2000 JPY"
  ]

availabilityEntitlement :: T.Text
availabilityEntitlement = T.unlines
  [ "2026-06-01 origin JPY"
  , "2026-07-01 transfer unallocated -> Daily 100000 JPY"
  ]

availabilityEnvelope :: T.Text
availabilityEnvelope = T.unlines
  [ "[[backing-pools]]"
  , "id = \"main\""
  , "asset-accounts = [\"Assets:Bank\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"Daily\""
  , "label = \"Daily\""
  , "pacing = \"daily\""
  , "backing-pool = \"main\""
  ]

availabilityHousehold :: T.Text
availabilityHousehold = T.unlines
  [ "[cycle]"
  , "mode = \"income-anchor\""
  , "income-account = \"Income:Salary\""
  , ""
  , "[daily-target]"
  , ""
  , "[[daily-target.assets]]"
  , "id = \"bank\""
  , "account = \"Assets:Bank\""
  , ""
  , "[envelope-history]"
  , "identities = [\"Daily\"]"
  , ""
  , "[[envelope-history.expense-routing]]"
  , "effective-from = \"initial\""
  , "expense-account = \"Expenses:Groceries\""
  , "route = \"managed\""
  , "target = \"Daily\""
  , "note = \"availability regression routing\""
  ]

availabilityReport :: T.Text
availabilityReport = T.unlines
  [ "[reports.trial-balance]"
  , "as-of = \"latest\""
  , ""
  , "[reports.balance-sheet]"
  , "as-of = \"latest\""
  , ""
  , "[reports.profit-and-loss]"
  , "from = \"2026-07-01\""
  , "through = \"latest\""
  , ""
  , "[reports.daily-flow]"
  , "from = \"2026-07-01\""
  , "through = \"latest\""
  , "max-date-columns = 5"
  , ""
  , "[reports.monthly-accounts]"
  , "from = \"2026-07-01\""
  , "through = \"latest\""
  , ""
  , "[reports.recent-transactions]"
  , "through = \"latest\""
  , "count = 5"
  ]

availabilityIssues :: T.Text
availabilityIssues = T.unlines
  [ "issue_id\tstatus\tdate\tcategory\ttitle\tamount\tcurrency\tdetails"
  ]
