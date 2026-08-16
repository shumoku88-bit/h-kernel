{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Engine (rangeEnd, rangeStart)
import HKernel.Journal (Journal, parseJournal)
import HKernel.Period (mkPeriod)
import HKernel.Report (recentCountValue)
import HKernel.Report.Config
import HKernel.Report.Plan
import HKernel.Report.Presentation
import System.Exit (exitFailure)

main :: IO ()
main = do
  let configuration = mustRight (parseReportConfiguration validConfig)
      rendered = renderReportConfiguration configuration
      reparsed = mustRight (parseReportConfiguration rendered)
      plan = reportConfigurationPlan configuration
      presentation = reportConfigurationPresentation configuration
      calendarMarkers = presentationCalendarMarkers presentation
      journal = mustRight (parseJournal journalInput)
      latest = fromGregorian 2026 8 1
      resolved = mustRight (resolveReportPlan latest journal plan)

  assertEqual "canonical report TOML re-admits the exact same configuration"
    configuration
    reparsed
  assertEqual "canonical report TOML is idempotent after re-admission"
    rendered
    (renderReportConfiguration reparsed)
  assertEqual "canonical rendering uses the shared direct calendar table"
    True
    ("[presentation.calendar]\n" `T.isInfixOf` rendered)
  assertEqual "canonical rendering retires the nested calendar markers table"
    False
    ("[presentation.calendar.markers]\n" `T.isInfixOf` rendered)
  assertEqual "trial balance resolves latest once"
    latest
    (resolvedTrialBalanceAsOf resolved)
  assertEqual "balance sheet accepts an exact as-of date"
    (fromGregorian 2026 7 31)
    (resolvedBalanceSheetAsOf resolved)
  assertEqual "profit and loss keeps its configured start"
    (fromGregorian 2026 6 15)
    (rangeStart (resolvedProfitAndLossRange resolved))
  assertEqual "profit and loss resolves latest as its end"
    latest
    (rangeEnd (resolvedProfitAndLossRange resolved))
  assertEqual "beginning resolves to the first eligible journal date"
    (fromGregorian 2026 4 15)
    (rangeStart (resolvedMonthlyAccountsRange resolved))
  assertEqual "recent count is validated and retained"
    7
    (recentCountValue (resolvedRecentTransactionsCount resolved))
  assertEqual "negative amount style is validated and retained"
    LeadingMinus
    (presentationNegativeStyle presentation)
  assertEqual "heading color is validated and retained"
    BlueColor
    (presentationHeadingColor presentation)
  assertEqual "section color is validated and retained"
    CyanColor
    (presentationSectionColor presentation)
  assertEqual "positive amount color is validated and retained"
    YellowColor
    (presentationPositiveAmountColor presentation)
  assertEqual "negative amount color is validated and retained"
    MagentaColor
    (presentationNegativeAmountColor presentation)
  assertEqual "plan due calendar marker is validated and retained"
    '^'
    (calendarMarkerValue (calendarPlanDueMarker calendarMarkers))
  assertEqual "issue due calendar marker is validated and retained"
    '!'
    (calendarMarkerValue (calendarIssueDueMarker calendarMarkers))
  assertEqual "cycle end calendar marker is validated and retained"
    '|'
    (calendarMarkerValue (calendarCycleEndMarker calendarMarkers))
  assertEqual "multiple calendar marker is validated and retained"
    ':'
    (calendarMarkerValue (calendarMultipleMarker calendarMarkers))
  assertEqual "daily flow date columns are validated and retained"
    10
    (dateColumnCountValue
      (presentationDailyFlowDateColumns presentation))

  characterizeCurrentCycleRange journal latest
  characterizeCalendarSelection calendarMarkers

  let defaultColumnsConfiguration = mustRight
        (parseReportConfiguration
          (T.replace "max-date-columns = 10\n" "" validConfig))
  assertEqual "daily flow date columns default to fourteen"
    14
    (dateColumnCountValue
      (presentationDailyFlowDateColumns
        (reportConfigurationPresentation defaultColumnsConfiguration)))

  let defaultHierarchyConfiguration = mustRight
        (parseReportConfiguration
          (T.replace hierarchyTable "" validConfig))
      defaultHierarchyPresentation =
        reportConfigurationPresentation defaultHierarchyConfiguration
  assertEqual "heading color defaults to cyan"
    CyanColor
    (presentationHeadingColor defaultHierarchyPresentation)
  assertEqual "section color defaults to yellow"
    YellowColor
    (presentationSectionColor defaultHierarchyPresentation)

  let hierarchyOnlyConfiguration = mustRight
        (parseReportConfiguration
          (T.replace calendarMarkersTable ""
            (T.replace amountsTable "" validConfig)))
      hierarchyOnlyPresentation =
        reportConfigurationPresentation hierarchyOnlyConfiguration
  assertEqual "hierarchy remains configurable without other presentation tables"
    (BlueColor, CyanColor)
    ( presentationHeadingColor hierarchyOnlyPresentation
    , presentationSectionColor hierarchyOnlyPresentation
    )
  assertEqual "amount presentation defaults when only hierarchy is configured"
    (AccountingParentheses, GreenColor, RedColor)
    ( presentationNegativeStyle hierarchyOnlyPresentation
    , presentationPositiveAmountColor hierarchyOnlyPresentation
    , presentationNegativeAmountColor hierarchyOnlyPresentation
    )
  assertCalendarDefaults "calendar markers default when only hierarchy is configured"
    (presentationCalendarMarkers hierarchyOnlyPresentation)

  let defaultCalendarConfiguration = mustRight
        (parseReportConfiguration
          (T.replace calendarMarkersTable "" validConfig))
  assertCalendarDefaults "calendar markers default when the calendar table is absent"
    (presentationCalendarMarkers
      (reportConfigurationPresentation defaultCalendarConfiguration))

  let partialCalendarConfiguration = mustRight
        (parseReportConfiguration
          (T.replace calendarMarkersTable partialCalendarMarkersTable validConfig))
      partialCalendarMarkers = presentationCalendarMarkers
        (reportConfigurationPresentation partialCalendarConfiguration)
  assertEqual "a configured calendar marker overrides only its own role"
    '?'
    (calendarMarkerValue (calendarIssueDueMarker partialCalendarMarkers))
  assertEqual "unconfigured calendar roles retain defaults"
    ('$', '|', '+')
    ( calendarMarkerValue (calendarPlanDueMarker partialCalendarMarkers)
    , calendarMarkerValue (calendarCycleEndMarker partialCalendarMarkers)
    , calendarMarkerValue (calendarMultipleMarker partialCalendarMarkers)
    )

  let legacyConfiguration = mustRight
        (parseReportConfiguration
          (T.replace calendarMarkersTable legacyCalendarMarkersTable validConfig))
      legacyMarkers = presentationCalendarMarkers
        (reportConfigurationPresentation legacyConfiguration)
      legacyRendered = renderReportConfiguration legacyConfiguration
  assertEqual "legacy nested calendar markers remain readable during migration"
    ('^', '!', '|', '+')
    ( calendarMarkerValue (calendarPlanDueMarker legacyMarkers)
    , calendarMarkerValue (calendarIssueDueMarker legacyMarkers)
    , calendarMarkerValue (calendarCycleEndMarker legacyMarkers)
    , calendarMarkerValue (calendarMultipleMarker legacyMarkers)
    )
  assertEqual "legacy input is canonically rendered into the shared direct shape"
    True
    ("multiple-marker = \"+\"" `T.isInfixOf` legacyRendered)
  assertLeft "legacy and direct calendar shapes cannot be mixed"
    (parseReportConfiguration
      (T.replace calendarMarkersTable mixedCalendarMarkersTable validConfig))

  let defaultPresentationConfiguration = mustRight
        (parseReportConfiguration
          (T.replace presentationTable "" validConfig))
      defaultPresentation =
        reportConfigurationPresentation defaultPresentationConfiguration
  assertEqual "negative amount style defaults to accounting parentheses"
    AccountingParentheses
    (presentationNegativeStyle defaultPresentation)
  assertEqual "heading color defaults to cyan without presentation config"
    CyanColor
    (presentationHeadingColor defaultPresentation)
  assertEqual "section color defaults to yellow without presentation config"
    YellowColor
    (presentationSectionColor defaultPresentation)
  assertEqual "positive amount color defaults to green"
    GreenColor
    (presentationPositiveAmountColor defaultPresentation)
  assertEqual "negative amount color defaults to red"
    RedColor
    (presentationNegativeAmountColor defaultPresentation)
  assertCalendarDefaults "calendar markers default without presentation config"
    (presentationCalendarMarkers defaultPresentation)

  assertLeft "unknown TOML keys are not silently ignored"
    (parseReportConfiguration
      (validConfig <> "\n[reports.daily-flow.extra]\nvalue = 1\n"))
  assertLeft "invalid dates are rejected with domain context"
    (parseReportConfiguration
      (T.replace "2026-06-15" "not-a-date" validConfig))
  assertLeft "range and explicit boundaries cannot be combined"
    (parseReportConfiguration mixedCurrentCycleConfig)
  assertLeft "explicit ranges require both from and through"
    (parseReportConfiguration incompleteExplicitRangeConfig)
  assertLeft "unknown symbolic ranges are rejected"
    (parseReportConfiguration unknownSymbolicRangeConfig)
  assertLeft "monthly accounts does not silently inherit current-cycle semantics"
    (parseReportConfiguration monthlyCurrentCycleConfig)
  assertLeft "unknown negative amount styles are rejected"
    (parseReportConfiguration
      (T.replace "negative-style = \"minus\""
        "negative-style = \"absolute\"" validConfig))
  assertLeft "unknown heading colors are rejected"
    (parseReportConfiguration
      (T.replace "heading-color = \"blue\""
        "heading-color = \"invalid-color\"" validConfig))
  assertLeft "unknown section colors are rejected"
    (parseReportConfiguration
      (T.replace "section-color = \"cyan\""
        "section-color = \"invalid-color\"" validConfig))
  assertLeft "unknown positive amount colors are rejected"
    (parseReportConfiguration
      (T.replace "positive-color = \"yellow\""
        "positive-color = \"invalid-color\"" validConfig))
  assertLeft "unknown negative amount colors are rejected"
    (parseReportConfiguration
      (T.replace "negative-color = \"magenta\""
        "negative-color = \"invalid-color\"" validConfig))
  assertLeft "empty calendar markers are rejected"
    (parseReportConfiguration
      (T.replace "multiple-marker = \":\"" "multiple-marker = \"\"" validConfig))
  assertLeft "multi-character calendar markers are rejected"
    (parseReportConfiguration
      (T.replace "multiple-marker = \":\"" "multiple-marker = \"..\"" validConfig))
  assertLeft "Unicode calendar markers are rejected until terminal width is explicit"
    (parseReportConfiguration
      (T.replace "multiple-marker = \":\"" "multiple-marker = \"●\"" validConfig))
  assertLeft "whitespace calendar markers are rejected"
    (parseReportConfiguration
      (T.replace "multiple-marker = \":\"" "multiple-marker = \" \"" validConfig))
  assertLeft "retired Actual glyph remains validated in legacy input"
    (parseReportConfiguration
      (T.replace calendarMarkersTable invalidLegacyActualTable validConfig))
  assertLeft "non-positive recent counts are rejected"
    (parseReportConfiguration
      (T.replace "count = 7" "count = 0" validConfig))
  assertLeft "non-positive daily flow date columns are rejected"
    (parseReportConfiguration
      (T.replace "max-date-columns = 10" "max-date-columns = 0" validConfig))

characterizeCurrentCycleRange :: Journal -> Day -> IO ()
characterizeCurrentCycleRange journal latest = do
  let configuration = mustRight (parseReportConfiguration currentCycleConfig)
      plan = reportConfigurationPlan configuration
      period = mustRight
        (mkPeriod (fromGregorian 2026 7 15) (fromGregorian 2026 8 15))
      resolved = mustRight
        (resolveReportPlanWithCurrentCycle latest journal (Just period) plan)
      dailyRange = case resolvedDailyFlowSpec resolved of
        ResolvedDailyFlowInRange value -> value
        ResolvedDailyFlowThrough _ -> error "configured daily range was not resolved"
      rendered = renderReportConfiguration configuration
  assertEqual "current-cycle query is retained as a typed symbolic range"
    True
    (reportPlanNeedsCurrentCycle plan)
  assertEqual "profit and loss current cycle starts at the resolved Period start"
    (fromGregorian 2026 7 15)
    (rangeStart (resolvedProfitAndLossRange resolved))
  assertEqual "profit and loss current cycle ends on the observation day"
    latest
    (rangeEnd (resolvedProfitAndLossRange resolved))
  assertEqual "daily flow uses the same current cycle start"
    (fromGregorian 2026 7 15)
    (rangeStart dailyRange)
  assertEqual "daily flow uses the same observation day"
    latest
    (rangeEnd dailyRange)
  assertEqual "canonical rendering preserves both symbolic current-cycle queries"
    2
    (T.count "range = \"current-cycle-to-date\"" rendered)
  assertLeft "pure Journal resolution fails closed without current cycle context"
    (resolveReportPlan latest journal plan)
  let stalePeriod = mustRight
        (mkPeriod (fromGregorian 2026 6 15) (fromGregorian 2026 7 15))
  assertLeft "current-cycle query rejects an observation outside the supplied Period"
    (resolveReportPlanWithCurrentCycle latest journal (Just stalePeriod) plan)

characterizeCalendarSelection :: CalendarMarkers -> IO ()
characterizeCalendarSelection markers = do
  let selected planDue issueDue cycleEnd =
        fmap calendarMarkerValue
          (selectCalendarMarker markers planDue issueDue cycleEnd)
  assertEqual "a day with no attention facts has no marker"
    Nothing
    (selected False False False)
  assertEqual "Plan due alone keeps its marker"
    (Just '^')
    (selected True False False)
  assertEqual "Issue due alone keeps its marker"
    (Just '!')
    (selected False True False)
  assertEqual "cycle end alone keeps its marker"
    (Just '|')
    (selected False False True)
  assertEqual "two independent facts use the multiple marker"
    [Just ':', Just ':', Just ':']
    [ selected True True False
    , selected True False True
    , selected False True True
    ]
  assertEqual "three independent facts also use the multiple marker"
    (Just ':')
    (selected True True True)

hierarchyTable :: T.Text
hierarchyTable = T.unlines
  [ "[presentation.hierarchy]"
  , "heading-color = \"blue\""
  , "section-color = \"cyan\""
  , ""
  ]

amountsTable :: T.Text
amountsTable = T.unlines
  [ "[presentation.amounts]"
  , "negative-style = \"minus\""
  , "positive-color = \"yellow\""
  , "negative-color = \"magenta\""
  , ""
  ]

calendarMarkersTable :: T.Text
calendarMarkersTable = T.unlines
  [ "[presentation.calendar]"
  , "cycle-end-marker = \"|\""
  , "plan-due-marker = \"^\""
  , "issue-due-marker = \"!\""
  , "multiple-marker = \":\""
  , ""
  ]

partialCalendarMarkersTable :: T.Text
partialCalendarMarkersTable = T.unlines
  [ "[presentation.calendar]"
  , "issue-due-marker = \"?\""
  , ""
  ]

legacyCalendarMarkersTable :: T.Text
legacyCalendarMarkersTable = T.unlines
  [ "[presentation.calendar.markers]"
  , "actual = \".\""
  , "plan = \"^\""
  , "issue-due = \"!\""
  , "cycle-end = \"|\""
  , ""
  ]

mixedCalendarMarkersTable :: T.Text
mixedCalendarMarkersTable = T.unlines
  [ "[presentation.calendar]"
  , "plan-due-marker = \"^\""
  , ""
  , "[presentation.calendar.markers]"
  , "actual = \".\""
  , "plan = \"^\""
  , "issue-due = \"!\""
  , "cycle-end = \"|\""
  , ""
  ]

invalidLegacyActualTable :: T.Text
invalidLegacyActualTable = T.unlines
  [ "[presentation.calendar.markers]"
  , "actual = \"●\""
  , "plan = \"^\""
  , "issue-due = \"!\""
  , "cycle-end = \"|\""
  , ""
  ]

presentationTable :: T.Text
presentationTable = hierarchyTable <> amountsTable <> calendarMarkersTable

validConfig :: T.Text
validConfig = presentationTable <> T.unlines
  [ "[reports.trial-balance]"
  , "as-of = \"latest\""
  , ""
  , "[reports.balance-sheet]"
  , "as-of = \"2026-07-31\""
  , ""
  , "[reports.profit-and-loss]"
  , "from = \"2026-06-15\""
  , "through = \"latest\""
  , ""
  , "[reports.daily-flow]"
  , "from = \"2026-07-18\""
  , "through = \"latest\""
  , "max-date-columns = 10"
  , ""
  , "[reports.monthly-accounts]"
  , "from = \"beginning\""
  , "through = \"latest\""
  , ""
  , "[reports.recent-transactions]"
  , "through = \"latest\""
  , "count = 7"
  ]

currentCycleConfig :: T.Text
currentCycleConfig = presentationTable <> T.unlines
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
  , "max-date-columns = 10"
  , ""
  , "[reports.monthly-accounts]"
  , "from = \"beginning\""
  , "through = \"latest\""
  , ""
  , "[reports.recent-transactions]"
  , "through = \"latest\""
  , "count = 7"
  ]

mixedCurrentCycleConfig :: T.Text
mixedCurrentCycleConfig = T.replace
  "range = \"current-cycle-to-date\""
  "range = \"current-cycle-to-date\"\nfrom = \"2026-07-15\"\nthrough = \"latest\""
  currentCycleConfig

incompleteExplicitRangeConfig :: T.Text
incompleteExplicitRangeConfig = T.replace
  "from = \"2026-06-15\"\nthrough = \"latest\""
  "from = \"2026-06-15\""
  validConfig

unknownSymbolicRangeConfig :: T.Text
unknownSymbolicRangeConfig = T.replace
  "current-cycle-to-date"
  "current-month-to-date"
  currentCycleConfig

monthlyCurrentCycleConfig :: T.Text
monthlyCurrentCycleConfig = T.replace
  "from = \"beginning\"\nthrough = \"latest\""
  "range = \"current-cycle-to-date\""
  validConfig

journalInput :: T.Text
journalInput = T.unlines
  [ "account assets:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account equity:opening"
  , "    type: equity"
  , "    commodity: JPY"
  , ""
  , "2026-04-15 Opening"
  , "    assets:cash  100 JPY"
  , "    equity:opening"
  ]

assertCalendarDefaults :: String -> CalendarMarkers -> IO ()
assertCalendarDefaults label markers =
  assertEqual label
    ('$', '!', '|', '+')
    ( calendarMarkerValue (calendarPlanDueMarker markers)
    , calendarMarkerValue (calendarIssueDueMarker markers)
    , calendarMarkerValue (calendarCycleEndMarker markers)
    , calendarMarkerValue (calendarMultipleMarker markers)
    )

assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly decoded: " ++ show value)
    exitFailure
