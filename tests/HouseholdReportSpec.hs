{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.HouseholdIssue
import HKernel.Money
import HKernel.Period
import HKernel.Plan
import HKernel.Plan.Journal
import HKernel.Report.CycleAccounts
import HKernel.Report.Presentation (defaultPresentationConfig)
import HKernel.Spike.HouseholdReport
import HKernel.Spike.HouseholdReport.Render
import System.Exit (exitFailure)

main :: IO ()
main = do
  let actual = mustRight (parseActualJournal actualJournal)
      observation = fromGregorian 2026 7 31
      planJournal = mustRight (parsePlanJournal planJournalText)
      surface = mustRight
        (buildHouseholdReportSurfaceFromPlanJournal observation actual
          accountsTSV budgetTSV budgetPolicyTOML householdTOML planJournal
          issuesTSV dailyScopeTSV)
      currentCycle = householdCurrentCycleAccounts surface
      currentPeriod = currentCycleAccountsPeriod currentCycle
      backing = householdEnvelopeBacking surface
      target = householdDailyTarget surface
      foodLine = exactlyOne (envelopeBackingLines backing)
      openPlans = householdPlannedTransactions surface
      classifiedPlans = classifyPlannedTransactions currentPeriod openPlans
      issue = exactlyOne
        (filter ((== Open) . householdIssueStatus) (householdIssues surface))
      jpy = mustRight (mkCommodity "JPY")

  assertEqual "current income-anchor cycle is resolved from Actual and Plan Journal"
    (fromGregorian 2026 6 15, fromGregorian 2026 8 14)
    ( periodStart currentPeriod
    , periodEndExclusive currentPeriod
    )
  assertEqual "precise current-cycle report observes through the Household observation day"
    observation
    (currentCycleAccountsObservation currentCycle)
  assertEqual "precise current-cycle report publishes the complete declared Account axis"
    8
    (length (currentCycleAccountsRows currentCycle))
  case householdCycleComparison surface of
    HouseholdCycleComparisonAvailable comparison -> do
      let baseline = cycleComparisonBaseline comparison
      assertEqual "previous cycle is resolved from the two latest Actual anchors"
        (fromGregorian 2026 4 15, fromGregorian 2026 6 15)
        ( periodStart (currentCycleAccountsPeriod baseline)
        , periodEndExclusive (currentCycleAccountsPeriod baseline)
        )
      assertEqual "Household daily comparison uses aligned elapsed policy"
        AlignedElapsed
        (cycleComparisonPolicy comparison)
      assertEqual "Household daily comparison observes the previous cycle at the same elapsed day"
        (fromGregorian 2026 5 31)
        (currentCycleAccountsObservation baseline)
    unavailable -> do
      putStrLn "  [FAIL] aligned Household Cycle Comparison should be available"
      putStrLn ("    actual: " ++ show unavailable)
      exitFailure
  assertEqual "explicit completion removes the completed outgoing Plan without hiding other horizons"
    ["plan-prior", "plan-overdue", "plan-wifi", "plan-next-cycle"]
    (map (planIdText . committedPlanId) openPlans)
  assertEqual "open outgoing Plans remain date ordered across the current cycle boundary"
    [ fromGregorian 2026 6 10
    , fromGregorian 2026 7 25
    , fromGregorian 2026 8 8
    , fromGregorian 2026 8 20
    ]
    (map committedPlanDate openPlans)
  assertEqual "Plan horizon classification keeps before current and after current visible"
    [ BeforeCurrentCycle
    , InCurrentCycle
    , InCurrentCycle
    , AfterCurrentCycle
    ]
    (map classifiedPlanHorizon classifiedPlans)
  assertEqual "issue category evidence remains visible without affecting balances"
    "[planning] decide funding"
    (householdIssueDetails issue)
  assertEqual "budget movement becomes exact envelope entitlement"
    (one jpy 1000)
    (envelopeEntitlement foodLine)
  assertEqual "Actual Expense movement becomes exact consumption"
    (one jpy 100)
    (envelopeActualConsumption foodLine)
  assertEqual "only current-cycle open mapped Plans become reserve and derived headroom"
    (one jpy 600)
    (envelopePostPlanHeadroom foodLine)
  assertEqual "liquid Asset backing is selected by explicit Budget policy"
    (one jpy 1900)
    (envelopeFundingBalance backing)
  assertEqual "Daily Target Asset selection is owned by its explicit scope"
    (one jpy 1900)
    (dailyTargetEligibleAssets target)
  assertEqual "Daily Target retains bounded reservation evidence"
    (one jpy 50)
    (dailyTargetAlreadyExcluded target)
  assertEqual "Daily Target keeps capacity net of bounded reservation evidence"
    (one jpy 1750)
    (dailyTargetCapacity target)
  assertEqual "Daily Target publishes an exact rational rate"
    [(jpy, 125)]
    (dailyTargetRate target)

  let renderedSurface = renderHouseholdReportSections
        defaultPresentationConfig
        surface
  assertEqual "Household cycle delivery publishes the precise current-cycle report"
    True
    ("Current Cycle Accounts" `T.isInfixOf` renderedSurface
      && "Opening" `T.isInfixOf` renderedSurface
      && "Closing" `T.isInfixOf` renderedSurface)
  assertEqual "Household cycle delivery publishes the aligned previous-cycle comparison"
    True
    ("Cycle Comparison" `T.isInfixOf` renderedSurface
      && "Policy: aligned_elapsed" `T.isInfixOf` renderedSurface
      && "2026-05-31" `T.isInfixOf` renderedSurface)
  assertEqual "legacy Expense-only matrix no longer owns visible Household cycle output"
    False
    ("Cycle Accounts & Comparison Matrix" `T.isInfixOf` renderedSurface)
  assertEqual "Planned Transactions identifies the native Plan Journal source"
    True
    ("Source: plan.journal" `T.isInfixOf` renderedSurface
      && not ("Source: plan.tsv" `T.isInfixOf` renderedSurface))
  assertEqual "Planned Transactions exposes still-open commitments before the current cycle"
    True
    ("Open before current cycle" `T.isInfixOf` renderedSurface
      && "2026-06-10 | plan-prior" `T.isInfixOf` renderedSurface)
  assertEqual "Planned Transactions marks the resolved current-cycle boundary"
    True
    ("current cycle ends before 2026-08-14" `T.isInfixOf` renderedSurface)
  assertEqual "Planned Transactions keeps the next-cycle payment visible before cycle rollover"
    True
    ("2026-08-20 | plan-next-cycle" `T.isInfixOf` renderedSurface)

  let defaultIssues = renderHouseholdIssues OpenIssuesOnly
        (householdIssues surface)
      allIssues = renderHouseholdIssues AllIssues
        (householdIssues surface)
  assertEqual "default Issue report uses vertical cards"
    True
    ("┌─ OPEN " `T.isInfixOf` defaultIssues
      && "│ Title" `T.isInfixOf` defaultIssues
      && not ("Issue ID" `T.isInfixOf` defaultIssues))
  assertEqual "resolved Issues are hidden by default"
    False
    ("issue-resolved" `T.isInfixOf` defaultIssues)
  assertEqual "the explicit all-Issues option retains resolved cards"
    True
    ("issue-resolved" `T.isInfixOf` allIssues
      && "┌─ RESOLVED " `T.isInfixOf` allIssues)

  let actualWithExtraAccount =
        mustRight (parseActualJournal actualJournalWithExtraAccount)
      bidirectionalRegistryFailure =
        buildHouseholdReportSurfaceFromPlanJournal observation
          actualWithExtraAccount accountsWithExtraAccountTSV budgetTSV
          budgetPolicyTOML householdTOML planJournal issuesTSV dailyScopeTSV
  assertLeftContaining
    "Account reconciliation rejects source-only Accounts"
    "accounts.tsv Account is not declared in actual.journal: assets:source-only"
    bidirectionalRegistryFailure
  assertLeftContaining
    "Account reconciliation rejects Journal-only Accounts in the same gate"
    "actual.journal Account is missing from accounts.tsv: assets:journal-only"
    bidirectionalRegistryFailure
  assertLeftContaining
    "Account reconciliation diagnoses declared role disagreement"
    "Account type disagrees between accounts.tsv and actual.journal for assets:cash: accounts.tsv=Liability, actual.journal=Asset"
    (buildHouseholdReportSurfaceFromPlanJournal observation actual
      roleMismatchAccountsTSV budgetTSV budgetPolicyTOML householdTOML
      planJournal issuesTSV dailyScopeTSV)
  assertLeftContaining
    "Account metadata rejects fields without key=value syntax"
    "malformed metadata field broken; expected non-empty key=value"
    (buildHouseholdReportSurfaceFromPlanJournal observation actual
      malformedAccountsTSV budgetTSV budgetPolicyTOML householdTOML
      planJournal issuesTSV dailyScopeTSV)
  assertLeftContaining
    "Account metadata rejects empty values"
    "malformed metadata field type=; expected non-empty key=value"
    (buildHouseholdReportSurfaceFromPlanJournal observation actual
      emptyValueAccountsTSV budgetTSV budgetPolicyTOML householdTOML
      planJournal issuesTSV dailyScopeTSV)
  assertLeftContaining
    "Account metadata rejects duplicate keys before overwrite"
    "duplicate metadata key role"
    (buildHouseholdReportSurfaceFromPlanJournal observation actual
      duplicateRoleAccountsTSV budgetTSV budgetPolicyTOML householdTOML
      planJournal issuesTSV dailyScopeTSV)
  assertLeftContaining
    "Household cycle Account must be declared Income"
    "HouseholdCycleIncomeAccountNotIncome"
    (buildHouseholdReportSurfaceFromPlanJournal observation actual
      accountsTSV budgetTSV budgetPolicyTOML cycleRoleMismatchTOML
      planJournal issuesTSV dailyScopeTSV)
  assertLeftContaining
    "Household allocation Account must be declared Budget"
    "HouseholdAllocationAccountNotBudget"
    (buildHouseholdReportSurfaceFromPlanJournal observation actual
      accountsTSV budgetTSV budgetPolicyTOML allocationRoleMismatchTOML
      planJournal issuesTSV dailyScopeTSV)

  let unsupportedPlanJournal =
        mustRight (parsePlanJournal unsupportedPlanJournalText)
  assertLeftContaining "unsupported Plan Journal directions fail at admission"
    "UnsupportedPlanRoleFlow"
    (buildHouseholdReportSurfaceFromPlanJournal observation actual
      accountsTSV budgetTSV budgetPolicyTOML householdTOML
      unsupportedPlanJournal issuesTSV dailyScopeTSV)

  let unknownActual = mustRight (parseActualJournal unknownPlanActualJournal)
  assertLeftContaining "unknown completion Plan references fail closed"
    "unknown PlanId"
    (buildHouseholdReportSurfaceFromPlanJournal observation unknownActual
      accountsTSV budgetTSV budgetPolicyTOML householdTOML planJournal
      issuesTSV dailyScopeTSV)

  assertLeftContaining "Daily Target rejects reservation above the Plan amount"
    "ReservationExceedsPlanAmount"
    (buildHouseholdReportSurfaceFromPlanJournal observation actual
      accountsTSV budgetTSV budgetPolicyTOML householdTOML planJournal
      issuesTSV overReservedDailyScopeTSV)

  assertLeftContaining "Daily Target rejects cross-Commodity reservation"
    "ReservationCommodityMismatch"
    (buildHouseholdReportSurfaceFromPlanJournal observation actual
      accountsTSV budgetTSV budgetPolicyTOML householdTOML planJournal
      issuesTSV crossCommodityDailyScopeTSV)

  assertLeftContaining "Daily Target rejects duplicate reservation identity"
    "DuplicateReservationId"
    (buildHouseholdReportSurfaceFromPlanJournal observation actual
      accountsTSV budgetTSV budgetPolicyTOML householdTOML planJournal
      issuesTSV duplicateReservationDailyScopeTSV)

one :: Commodity -> Integer -> Balance
one commodity value =
  singletonBalance (mkAmount commodity (quantityFromInteger value))

actualJournal :: T.Text
actualJournal = declarations <> T.unlines
  [ "2026-04-15 Pension"
  , "    assets:cash  1000 JPY"
  , "    income:pension"
  , "2026-06-15 Pension"
  , "    assets:cash  1000 JPY"
  , "    income:pension"
  , "2026-07-20 Food"
  , "    expenses:food  100 JPY"
  , "    assets:cash"
  , "2026-07-25 Card settlement"
  , "    ; event-id: actual-card"
  , "    ; plan-id: plan-card"
  , "    liabilities:card  400 JPY"
  , "    assets:savings"
  ]

actualJournalWithExtraAccount :: T.Text
actualJournalWithExtraAccount = T.unlines
  [ "account assets:journal-only"
  , "    type: asset"
  , "    commodity: JPY"
  ] <> actualJournal

unknownPlanActualJournal :: T.Text
unknownPlanActualJournal = actualJournal <> T.unlines
  [ "2026-07-26 Unknown completion"
  , "    ; event-id: actual-unknown"
  , "    ; plan-id: plan-missing"
  , "    liabilities:card  1 JPY"
  , "    assets:savings"
  ]

declarations :: T.Text
declarations = T.unlines
  [ "account assets:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , "account assets:savings"
  , "    type: asset"
  , "    commodity: JPY"
  , "account liabilities:card"
  , "    type: liability"
  , "    commodity: JPY"
  , "account income:pension"
  , "    type: income"
  , "    commodity: JPY"
  , "account expenses:food"
  , "    type: expense"
  , "    commodity: JPY"
  , "account budget:opening"
  , "    type: budget"
  , "    commodity: JPY"
  , "account budget:unassigned"
  , "    type: budget"
  , "    commodity: JPY"
  , "account budget:food"
  , "    type: budget"
  , "    commodity: JPY"
  ]

accountsTSV :: T.Text
accountsTSV = T.unlines
  [ "assets:cash\trole=asset\ttype=liquid\tcurrency=JPY"
  , "assets:savings\trole=asset\ttype=savings\tcurrency=JPY"
  , "liabilities:card\trole=liability\tcurrency=JPY"
  , "income:pension\trole=income\tcurrency=JPY"
  , "expenses:food\trole=expense\tbudget=Food\tcurrency=JPY"
  , "budget:opening\trole=budget\tkind=opening\tcurrency=JPY"
  , "budget:unassigned\trole=budget\tkind=unassigned\tcurrency=JPY"
  , "budget:food\trole=budget\tkind=envelope\tbudget=Food\tcurrency=JPY"
  ]

accountsWithExtraAccountTSV :: T.Text
accountsWithExtraAccountTSV = accountsTSV <>
  "assets:source-only\trole=asset\ttype=liquid\tcurrency=JPY\n"

roleMismatchAccountsTSV :: T.Text
roleMismatchAccountsTSV = T.replace
  "assets:cash\trole=asset\ttype=liquid\tcurrency=JPY"
  "assets:cash\trole=liability\ttype=liquid\tcurrency=JPY"
  accountsTSV

malformedAccountsTSV :: T.Text
malformedAccountsTSV = T.replace
  "assets:cash\trole=asset\ttype=liquid\tcurrency=JPY"
  "assets:cash\trole=asset\ttype=liquid\tcurrency=JPY\tbroken"
  accountsTSV

emptyValueAccountsTSV :: T.Text
emptyValueAccountsTSV = T.replace
  "assets:cash\trole=asset\ttype=liquid\tcurrency=JPY"
  "assets:cash\trole=asset\ttype=\tcurrency=JPY"
  accountsTSV

duplicateRoleAccountsTSV :: T.Text
duplicateRoleAccountsTSV = T.replace
  "assets:cash\trole=asset\ttype=liquid\tcurrency=JPY"
  "assets:cash\trole=asset\ttype=liquid\tcurrency=JPY\trole=liability"
  accountsTSV

budgetTSV :: T.Text
budgetTSV = T.unlines
  [ "2026-06-15\tallocate\tbudget:opening\tbudget:food\t1000\tcurrency=JPY"
  , "2026-06-15\tunassigned\tbudget:opening\tbudget:unassigned\t50\tcurrency=JPY"
  ]

budgetPolicyTOML :: T.Text
budgetPolicyTOML = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"assets:cash\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"Food\""
  , "label = \"Food\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"expenses:food\"]"
  ]

householdTOML :: T.Text
householdTOML = T.unlines
  [ "[cycle]"
  , "mode = \"income-anchor\""
  , "income-account = \"income:pension\""
  , ""
  , "[budget]"
  , "unassigned-accounts = [\"budget:unassigned\"]"
  , ""
  , "[[budget.envelopes]]"
  , "id = \"Food\""
  , "allocation-account = \"budget:food\""
  ]

cycleRoleMismatchTOML :: T.Text
cycleRoleMismatchTOML = T.replace
  "income-account = \"income:pension\""
  "income-account = \"assets:cash\""
  householdTOML

allocationRoleMismatchTOML :: T.Text
allocationRoleMismatchTOML = T.replace
  "allocation-account = \"budget:food\""
  "allocation-account = \"expenses:food\""
  householdTOML

planJournalText :: T.Text
planJournalText = declarations <> T.unlines
  [ "2026-06-10 prior cycle"
  , "    ; plan-id: plan-prior"
  , "    expenses:food    50 JPY"
  , "    assets:cash     -50 JPY"
  , ""
  , "2026-07-25 overdue"
  , "    ; plan-id: plan-overdue"
  , "    expenses:food   100 JPY"
  , "    assets:cash    -100 JPY"
  , ""
  , "2026-08-08 wifi"
  , "    ; plan-id: plan-wifi"
  , "    expenses:food   200 JPY"
  , "    assets:cash    -200 JPY"
  , ""
  , "2026-08-10 card"
  , "    ; plan-id: plan-card"
  , "    liabilities:card   400 JPY"
  , "    assets:cash       -400 JPY"
  , ""
  , "2026-08-14 pension"
  , "    ; plan-id: plan-pension"
  , "    income:pension  -1000 JPY"
  , "    assets:cash      1000 JPY"
  , ""
  , "2026-08-20 next cycle"
  , "    ; plan-id: plan-next-cycle"
  , "    expenses:food   300 JPY"
  , "    assets:cash    -300 JPY"
  ]

unsupportedPlanJournalText :: T.Text
unsupportedPlanJournalText = planJournalText <> T.unlines
  [ ""
  , "2026-08-10 transfer"
  , "    ; plan-id: plan-transfer"
  , "    assets:savings   10 JPY"
  , "    assets:cash     -10 JPY"
  ]

issuesTSV :: T.Text
issuesTSV = T.unlines
  [ "issue_id\tstatus\tdate\tcategory\ttitle\tamount\tcurrency\tdetails"
  , "issue-one\topen\t2026-07-20\tplanning\twifi\t200\tJPY\tdecide funding"
  , "issue-resolved\tresolved\t2026-07-01\tsubscription\tcancelled\t0\tJPY\tdone"
  ]

dailyScopeHeader :: T.Text
dailyScopeHeader =
  "kind\tscope_id\taccount_key\tplan_id\texcluded_amount\tcurrency\treservation_ref"

dailyScopeTSV :: T.Text
dailyScopeTSV = T.unlines
  [ dailyScopeHeader
  , "asset\tcash\tassets:cash\t\t\t\t"
  , "obligation\twifi\t\tplan-wifi\t50\tJPY\treservation:wifi"
  ]

overReservedDailyScopeTSV :: T.Text
overReservedDailyScopeTSV = T.unlines
  [ dailyScopeHeader
  , "asset\tcash\tassets:cash\t\t\t\t"
  , "obligation\twifi\t\tplan-wifi\t300\tJPY\treservation:wifi"
  ]

crossCommodityDailyScopeTSV :: T.Text
crossCommodityDailyScopeTSV = T.unlines
  [ dailyScopeHeader
  , "asset\tcash\tassets:cash\t\t\t\t"
  , "obligation\twifi\t\tplan-wifi\t50\tUSD\treservation:wifi"
  ]

duplicateReservationDailyScopeTSV :: T.Text
duplicateReservationDailyScopeTSV = T.unlines
  [ dailyScopeHeader
  , "asset\tcash\tassets:cash\t\t\t\t"
  , "obligation\toverdue\t\tplan-overdue\t25\tJPY\treservation:shared"
  , "obligation\twifi\t\tplan-wifi\t50\tJPY\treservation:shared"
  ]

exactlyOne :: Show value => [value] -> value
exactlyOne [value] = value
exactlyOne values = error ("expected exactly one value, got " ++ show values)

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

assertLeftContaining
  :: String
  -> T.Text
  -> Either (NonEmpty.NonEmpty HouseholdSourceError) value
  -> IO ()
assertLeftContaining label expected result = case result of
  Left errors
    | any (T.isInfixOf expected . householdSourceMessage)
        (NonEmpty.toList errors) ->
        putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    errors did not contain: " ++ T.unpack expected)
        putStrLn ("    actual errors: " ++ show errors)
        exitFailure
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted source"
    exitFailure

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
