{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text qualified as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Application.Config (mkHouseholdRoot)
import HKernel.Editor.TUI.Actual (State(..), startIssueRealize, startRecord)
import HKernel.Editor.TUI.Home
  ( CalendarMarkerObservation(..)
  , calendarMarkerObservation
  , homeUsesStackedLayout
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , WorkspaceReloadFailure(..)
  , contextHouseholdCycleObservation
  , contextOpenPlanObservation
  , makeWorkspaceContext
  , workspaceReloadFailureText
  )
import HKernel.Editor.TUI.Shell (shellUsesStackedLayout)
import HKernel.Editor.TUI.SourcePreview (sourcePreviewText)
import HKernel.Household.Application
  ( HouseholdWriteSnapshot(..)
  , admitCanonicalHousehold
  )
import HKernel.Household.Report
  ( HouseholdPlannedTransactions(..)
  , householdPlannedTransactionsAvailability
  )
import HKernel.Household.Report.Render
  ( renderHouseholdReportSections
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
import HKernel.Report.Presentation
  ( defaultPresentationConfig
  , presentationCalendarMarkers
  )
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  let results =
        [ ("ordinary Record and Issue realization enter the shared Record flow", testSharedRecordFlow)
        , ("closed Issue cannot start realization", testClosedIssueCannotStart)
        , ("source preview removes terminal tabs", not (T.any (== '\t') previewText))
        , ("source preview preserves Issue comments", "枠内に折り返すコメント" `T.isInfixOf` previewText)
        , ("Home stacks observations at 60 columns", homeUsesStackedLayout 60)
        , ("Home stacks roomier calendar at 80 columns", homeUsesStackedLayout 80)
        , ("Home becomes side-by-side at 87 columns", not (homeUsesStackedLayout 87))
        , ("Home remains side-by-side at 120 columns", not (homeUsesStackedLayout 120))
        , ("production shell stacks at 60 columns", shellUsesStackedLayout 60)
        , ("production shell stacks at 80 columns", shellUsesStackedLayout 80)
        , ("production shell becomes side-by-side at 87 columns", not (shellUsesStackedLayout 87))
        , ("production shell remains side-by-side at 120 columns", not (shellUsesStackedLayout 120))
        , ("calendar marker keeps unavailable distinct from observed-empty", calendarUnavailableDistinct)
        , ("reload failure keeps diagnostic detail", reloadDiagnosticDetailRetained)
        , ("Household surface survives narrow Planned Transactions failure", availabilitySurfaceAvailable)
        , ("Planned Transactions alone records local unavailability", availabilityPlannedUnavailable)
        , ("full renderer keeps Daily Target and Envelope beside unavailable Plans", availabilityRendererKeepsIndependentSections)
        , ("Cycle observation remains available beside unavailable Planned Transactions", availabilityCycleAvailable)
        , ("current-cycle ReportBook remains available beside unavailable Planned Transactions", availabilityReportBookAvailable)
        , ("role-neutral open Plan observation retains unsupported payment shape", availabilityOpenPlanAvailable)
        ]
  mapM_ print results
  if all snd results then exitSuccess else exitFailure

previewText :: T.Text
previewText = sourcePreviewText
  "ISSUE-1\topen\t2026-08-20\tgeneral\tTitle\tnone\tnone\t枠内に折り返すコメント"

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

calendarUnavailableDistinct :: Bool
calendarUnavailableDistinct =
  case
      ( calendarMarkerObservation markers (Left ()) (Right False) (Right False)
      , calendarMarkerObservation markers (Right False) (Right False) (Right False)
      ) of
    (CalendarMarkerUnavailable, CalendarMarkerAvailable Nothing) -> True
    _ -> False
  where
    markers = presentationCalendarMarkers defaultPresentationConfig

reloadDiagnosticDetailRetained :: Bool
reloadDiagnosticDetailRetained =
  workspaceReloadFailureText (PostReloadValidationFailed "reload-detail")
    == "reload-detail"

availabilityContext :: Maybe AppContext
availabilityContext = do
  root <- either (const Nothing) Just (mkHouseholdRoot ".")
  household <- either (const Nothing) Just
    (admitCanonicalHousehold
      root
      availabilityAccounts
      availabilityActual
      availabilityPlan
      availabilityEntitlement
      availabilityEnvelope
      availabilityHousehold
      availabilityReport
      availabilityIssues)
  let snapshot = HouseholdWriteSnapshot
        { householdWriteSnapshotState = household
        , householdWriteSnapshotAccountsSource = availabilityAccounts
        , householdWriteSnapshotActualSource = availabilityActual
        , householdWriteSnapshotPlanSource = availabilityPlan
        , householdWriteSnapshotEntitlementSource = availabilityEntitlement
        , householdWriteSnapshotIssuesSource = availabilityIssues
        }
  pure (makeWorkspaceContext availabilityObservation snapshot)

availabilitySurfaceAvailable :: Bool
availabilitySurfaceAvailable = case availabilityContext of
  Nothing -> False
  Just context -> case contextHouseholdReportSurface context of
    Left _ -> False
    Right _ -> True

availabilityPlannedUnavailable :: Bool
availabilityPlannedUnavailable = case availabilityContext of
  Nothing -> False
  Just context -> case contextHouseholdReportSurface context of
    Left _ -> False
    Right surface -> case householdPlannedTransactionsAvailability surface of
      HouseholdPlannedTransactionsUnavailable _ -> True
      HouseholdPlannedTransactionsAvailable _ -> False

availabilityRendererKeepsIndependentSections :: Bool
availabilityRendererKeepsIndependentSections = case availabilityContext of
  Nothing -> False
  Just context -> case contextHouseholdReportSurface context of
    Left _ -> False
    Right surface ->
      let rendered = renderHouseholdReportSections defaultPresentationConfig surface
      in "Planned Transactions" `T.isInfixOf` rendered
          && "Status: NOT AVAILABLE" `T.isInfixOf` rendered
          && "Daily Target" `T.isInfixOf` rendered
          && "Envelope & Backing" `T.isInfixOf` rendered

availabilityCycleAvailable :: Bool
availabilityCycleAvailable = case availabilityContext of
  Nothing -> False
  Just context -> case contextHouseholdCycleObservation context of
    Left _ -> False
    Right _ -> True

availabilityReportBookAvailable :: Bool
availabilityReportBookAvailable = case availabilityContext of
  Nothing -> False
  Just context -> case contextResolvedReportBook context of
    Left _ -> False
    Right _ -> True

availabilityOpenPlanAvailable :: Bool
availabilityOpenPlanAvailable = case availabilityContext of
  Nothing -> False
  Just context -> case contextOpenPlanObservation context of
    Left _ -> False
    Right plans ->
      "P200" `elem` map (planIdText . identifiedPlanId) plans

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
  , "range = \"current-cycle-to-date\""
  , ""
  , "[reports.daily-flow]"
  , "range = \"current-cycle-to-date\""
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