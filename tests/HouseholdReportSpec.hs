{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Application.Config (mkHouseholdRoot)
import HKernel.Backing
  ( backingPoolAvailableSurplus
  , backingPoolFundingCommitment
  , backingPoolGrossSurplus
  )
import HKernel.Household.Application
  ( admitCanonicalHousehold
  , buildHouseholdReportSurfaceFromHousehold
  )
import HKernel.Household.Report
import HKernel.Household.Report.Render
import HKernel.HouseholdIssue
import HKernel.Money
import HKernel.Period
import HKernel.Plan
import HKernel.Report.CycleAccounts
import HKernel.Report.Presentation (defaultPresentationConfig)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let observation = fromGregorian 2026 7 31
      surface = mustRightText
        (buildSurfaceAt observation actualJournal planJournalText householdTOML issuesTSV)
      currentCycle = householdCurrentCycleAccounts surface
      currentPeriod = currentCycleAccountsPeriod currentCycle
      backing = householdEnvelopeBacking surface
      pool = exactlyOne (envelopeBackingPools backing)
      target = householdDailyTarget surface
      foodLine = exactlyOne (envelopeBackingLines backing)
      openPlans = householdPlannedTransactions surface
      classifiedPlans = classifyPlannedTransactions currentPeriod openPlans
      issue = exactlyOne
        (filter ((== Open) . householdIssueStatus) (householdIssues surface))
      jpy = mustRight (mkCommodity "JPY")

  assertEqual "current income-anchor cycle is resolved from Actual and Plan Journal"
    (fromGregorian 2026 6 15, fromGregorian 2026 8 14)
    (periodStart currentPeriod, periodEndExclusive currentPeriod)
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
    unavailable -> failWith "aligned Household Cycle Comparison should be available" unavailable

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
    [BeforeCurrentCycle, InCurrentCycle, InCurrentCycle, AfterCurrentCycle]
    (map classifiedPlanHorizon classifiedPlans)

  let cancelledOutgoingPlanSource = T.replace
        "    ; plan-id: plan-wifi\n"
        (T.unlines
          [ "    ; plan-id: plan-wifi"
          , "    ; cancelled-on: 2026-07-30"
          ])
        planJournalText
      beforeCancellation = mustRightText
        (buildSurfaceAt
          (fromGregorian 2026 7 29)
          actualJournal cancelledOutgoingPlanSource householdTOML issuesTSV)
      afterCancellation = mustRightText
        (buildSurfaceAt
          observation
          actualJournal cancelledOutgoingPlanSource householdTOML issuesTSV)
  assertEqual "Plan cancellation does not retire the commitment before its effective day"
    True
    ("plan-wifi" `elem`
      map (planIdText . committedPlanId)
        (householdPlannedTransactions beforeCancellation))
  assertEqual "Plan cancellation removes the commitment on and after its effective day"
    False
    ("plan-wifi" `elem`
      map (planIdText . committedPlanId)
        (householdPlannedTransactions afterCancellation))

  let supersededOutgoingPlanSource =
        T.replace
          "    ; plan-id: plan-wifi\n"
          (T.unlines
            [ "    ; plan-id: plan-wifi"
            , "    ; superseded-on: 2026-07-30"
            , "    ; superseded-by: plan-wifi-replacement"
            ])
          planJournalText
        <> T.unlines
          [ ""
          , "2026-08-08 replacement service"
          , "    ; plan-id: plan-wifi-replacement"
          , "    expenses:food   150 JPY"
          , "    assets:cash    -150 JPY"
          ]
      supersededSurface = mustRightText
        (buildSurfaceAt
          observation
          actualJournal supersededOutgoingPlanSource householdTOML issuesTSV)
      supersededOpenIds = map (planIdText . committedPlanId)
        (householdPlannedTransactions supersededSurface)
  assertEqual "supersession preserves the replacement while retiring the old Plan"
    (False, True)
    ( "plan-wifi" `elem` supersededOpenIds
    , "plan-wifi-replacement" `elem` supersededOpenIds
    )

  let cancelledIncomeAnchorSource = T.replace
        "    ; plan-id: plan-pension\n"
        (T.unlines
          [ "    ; plan-id: plan-pension"
          , "    ; cancelled-on: 2026-07-30"
          ])
        planJournalText
  assertLeftContaining
    "cancelled incoming Plan is not reused as a future cycle anchor"
    "income-anchor cycle requires two observed Actual anchors and one future Plan anchor"
    (buildSurfaceAt
      observation actualJournal cancelledIncomeAnchorSource householdTOML issuesTSV)

  assertEqual "issue category evidence remains visible without affecting balances"
    "[planning] decide funding"
    (householdIssueDetails issue)
  assertEqual "native Budget movement becomes exact envelope entitlement"
    (one jpy 1000)
    (envelopeEntitlement foodLine)
  assertEqual "Actual Expense movement becomes exact consumption"
    (one jpy 100)
    (envelopeActualConsumption foodLine)
  assertEqual "overdue and current open Plans remain reserved until the next cycle boundary"
    (one jpy 550)
    (envelopePostPlanHeadroom foodLine)
  assertEqual "liquid Asset backing is selected by explicit Budget policy"
    (one jpy 1900)
    (envelopeFundingBalance backing)
  assertEqual "Plan source Asset reserves the same BackingPool funding horizon"
    (one jpy 350)
    (backingPoolFundingCommitment pool)
  assertEqual "matching funding and Envelope commitments are not double-counted in pool surplus"
    (one jpy 1000, one jpy 1000)
    (backingPoolGrossSurplus pool, backingPoolAvailableSurplus pool)
  assertEqual "Daily Target Asset selection is owned by household.toml"
    (one jpy 1900)
    (dailyTargetEligibleAssets target)
  assertEqual "Daily Target retains native Plan reservation evidence"
    (one jpy 50)
    (dailyTargetAlreadyExcluded target)
  assertEqual "Daily Target keeps capacity net of bounded reservation evidence"
    (one jpy 1750)
    (dailyTargetCapacity target)
  assertEqual "Daily Target publishes an exact rational rate"
    [(jpy, 125)]
    (dailyTargetRate target)

  let renderedSurface = renderHouseholdReportSections
        defaultPresentationConfig surface
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
    ("Source: plan.journal" `T.isInfixOf` renderedSurface)
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

  let shortPreviousActual =
        T.replace "2026-04-15 Pension" "2026-05-15 Pension" actualJournal
      shortPreviousSurface = mustRightText
        (buildSurfaceAt observation shortPreviousActual planJournalText householdTOML issuesTSV)
      shortPreviousRendered = renderHouseholdReportSections
        defaultPresentationConfig shortPreviousSurface
  case householdCycleComparison shortPreviousSurface of
    HouseholdCycleComparisonUnavailable _ ->
      assertEqual "unavailable aligned comparison does not fail the Household surface"
        True
        ("Status: NOT AVAILABLE" `T.isInfixOf` shortPreviousRendered
          && "Daily Target" `T.isInfixOf` shortPreviousRendered
          && "Envelope & Backing" `T.isInfixOf` shortPreviousRendered)
    available -> failWith "short previous cycle should make aligned comparison unavailable" available

  let defaultIssues = renderHouseholdIssues OpenIssuesOnly (householdIssues surface)
      allIssues = renderHouseholdIssues AllIssues (householdIssues surface)
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

  assertLeftContaining "Household cycle Account must be declared Income"
    "HouseholdCycleIncomeAccountNotIncome"
    (buildSurfaceAt observation actualJournal planJournalText cycleRoleMismatchTOML issuesTSV)
  assertLeftContaining "Household allocation Account must be declared Budget"
    "HouseholdAllocationAccountNotBudget"
    (buildSurfaceAt observation actualJournal planJournalText allocationRoleMismatchTOML issuesTSV)
  assertLeftContaining "unsupported Plan Journal directions fail at admission"
    "UnsupportedPlanRoleFlow"
    (buildSurfaceAt observation actualJournal unsupportedPlanJournalText householdTOML issuesTSV)
  assertLeftContaining "unknown completion Plan references fail closed"
    "unknown PlanId"
    (buildSurfaceAt observation unknownPlanActualJournal planJournalText householdTOML issuesTSV)
  assertLeftContaining "Daily Target rejects reservation above the Plan amount"
    "ReservationExceedsPlanAmount"
    (buildSurfaceAt observation actualJournal overReservedPlanJournalText householdTOML issuesTSV)
  assertLeftContaining "Daily Target rejects cross-Commodity reservation"
    "ReservationCommodityMismatch"
    (buildSurfaceAt observation actualJournal crossCommodityPlanJournalText householdTOML issuesTSV)
  assertLeftContaining "Daily Target rejects duplicate reservation identity"
    "DuplicateReservationId"
    (buildSurfaceAt observation actualJournal duplicateReservationPlanJournalText householdTOML issuesTSV)

one :: Commodity -> Integer -> Balance
one commodity value = singletonBalance
  (mkAmount commodity (quantityFromInteger value))

buildSurfaceAt
  :: Day
  -> Text
  -> Text
  -> Text
  -> Text
  -> Either Text HouseholdReportSurface
buildSurfaceAt observation actual plan household issues = do
  state <- leftShow
    (admitCanonicalHousehold householdRoot accountsJournal actual plan budgetJournal
      budgetPolicyTOML household reportTOML issues)
  leftShow (buildHouseholdReportSurfaceFromHousehold observation state)

householdRoot = case mkHouseholdRoot "." of
  Right value -> value
  Left err -> error ("invalid Household root fixture: " ++ show err)

leftShow :: Show error => Either error value -> Either Text value
leftShow result = case result of
  Left err -> Left (T.pack (show err))
  Right value -> Right value

accountsJournal :: Text
accountsJournal = declarations

actualJournal :: Text
actualJournal = "include accounts.journal\n\n" <> T.unlines
  [ "2026-04-15 Pension"
  , "    assets:cash  1000 JPY"
  , "    income:pension"
  , ""
  , "2026-06-15 Pension"
  , "    assets:cash  1000 JPY"
  , "    income:pension"
  , ""
  , "2026-07-20 Food"
  , "    expenses:food  100 JPY"
  , "    assets:cash"
  , ""
  , "2026-07-25 Card settlement"
  , "    ; event-id: actual-card"
  , "    ; plan-id: plan-card"
  , "    liabilities:card  400 JPY"
  , "    assets:savings"
  ]

unknownPlanActualJournal :: Text
unknownPlanActualJournal = actualJournal <> T.unlines
  [ ""
  , "2026-07-26 Unknown completion"
  , "    ; event-id: actual-unknown"
  , "    ; plan-id: plan-missing"
  , "    liabilities:card  1 JPY"
  , "    assets:savings"
  ]

declarations :: Text
declarations = T.unlines
  [ "account assets:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account assets:savings"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account liabilities:card"
  , "    type: liability"
  , "    commodity: JPY"
  , ""
  , "account income:pension"
  , "    type: income"
  , "    commodity: JPY"
  , ""
  , "account expenses:food"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account budget:opening"
  , "    type: budget"
  , "    commodity: JPY"
  , ""
  , "account budget:unassigned"
  , "    type: budget"
  , "    commodity: JPY"
  , ""
  , "account budget:food"
  , "    type: budget"
  , "    commodity: JPY"
  ]

budgetJournal :: Text
budgetJournal = "include accounts.journal\n\n" <> T.unlines
  [ "2026-06-15 allocate"
  , "    budget:opening  -1000 JPY"
  , "    budget:food      1000 JPY"
  , ""
  , "2026-06-15 unassigned"
  , "    budget:opening     -50 JPY"
  , "    budget:unassigned   50 JPY"
  ]

budgetPolicyTOML :: Text
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

householdTOML :: Text
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
  , ""
  , "[daily-target]"
  , ""
  , "[[daily-target.assets]]"
  , "id = \"cash\""
  , "account = \"assets:cash\""
  ]

cycleRoleMismatchTOML :: Text
cycleRoleMismatchTOML = T.replace
  "income-account = \"income:pension\""
  "income-account = \"assets:cash\""
  householdTOML

allocationRoleMismatchTOML :: Text
allocationRoleMismatchTOML = T.replace
  "allocation-account = \"budget:food\""
  "allocation-account = \"expenses:food\""
  householdTOML

planJournalText :: Text
planJournalText = "include accounts.journal\n\n" <> T.unlines
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
  , "    ; daily-target-id: wifi"
  , "    ; reservation-id: reservation:wifi"
  , "    ; reservation-amount: 50"
  , "    ; reservation-commodity: JPY"
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

unsupportedPlanJournalText :: Text
unsupportedPlanJournalText = planJournalText <> T.unlines
  [ ""
  , "2026-08-10 transfer"
  , "    ; plan-id: plan-transfer"
  , "    assets:savings   10 JPY"
  , "    assets:cash     -10 JPY"
  ]

overReservedPlanJournalText :: Text
overReservedPlanJournalText = T.replace
  "; reservation-amount: 50"
  "; reservation-amount: 300"
  planJournalText

crossCommodityPlanJournalText :: Text
crossCommodityPlanJournalText = T.replace
  "; reservation-commodity: JPY"
  "; reservation-commodity: USD"
  planJournalText

duplicateReservationPlanJournalText :: Text
duplicateReservationPlanJournalText = T.replace
  "; reservation-id: reservation:wifi"
  "; reservation-id: reservation:shared"
  (T.replace
    "    ; plan-id: plan-overdue\n"
    (T.unlines
      [ "    ; plan-id: plan-overdue"
      , "    ; daily-target-id: overdue"
      , "    ; reservation-id: reservation:shared"
      , "    ; reservation-amount: 25"
      , "    ; reservation-commodity: JPY"
      ])
    planJournalText)

issuesTSV :: Text
issuesTSV = T.unlines
  [ "issue_id\tstatus\tdate\tcategory\ttitle\tamount\tcurrency\tdetails"
  , "issue-one\topen\t2026-07-20\tplanning\twifi\t200\tJPY\tdecide funding"
  , "issue-resolved\tresolved\t2026-07-01\tsubscription\tcancelled\t0\tJPY\tdone"
  ]

reportTOML :: Text
reportTOML = T.unlines
  [ "[presentation.amounts]"
  , "negative-style = \"parentheses\""
  , ""
  , "[reports.trial-balance]"
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

exactlyOne :: Show value => [value] -> value
exactlyOne [value] = value
exactlyOne values = error ("expected exactly one value, got " ++ show values)

mustRightText :: Either Text value -> value
mustRightText (Right value) = value
mustRightText (Left err) = error ("invalid test fixture: " ++ T.unpack err)

assertLeftContaining :: String -> Text -> Either Text value -> IO ()
assertLeftContaining label expected result = case result of
  Left err
    | expected `T.isInfixOf` err -> putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    error did not contain: " ++ T.unpack expected)
        putStrLn ("    actual error: " ++ T.unpack err)
        exitFailure
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted source"
    exitFailure

failWith :: Show value => String -> value -> IO a
failWith label actual = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    actual: " ++ show actual)
  exitFailure
