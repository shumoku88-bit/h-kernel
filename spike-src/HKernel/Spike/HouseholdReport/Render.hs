{-# LANGUAGE OverloadedStrings #-}

-- | Terminal publication of the read-only real household report observation adapter.
--
-- Note: This module is a temporary observation adapter renderer for private source data.
-- It is not the canonical domain owner of Plan, cycle, budget, backing, allocation,
-- lifecycle, tax, or filing semantics.
module HKernel.Spike.HouseholdReport.Render
  ( IssueVisibility(..)
  , HouseholdReportSection(..)
  , renderHouseholdReportSection
  , renderHouseholdReportSections
  , renderHouseholdReportSectionsWithIssueVisibility
  , renderHouseholdIssues
  , renderHouseholdSourceErrors
  , renderReportBookWithHouseholdPresentation
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Ratio (denominator, numerator)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, diffDays)
import Data.Time.Format (defaultTimeLocale, formatTime)
import HKernel.Account (Account, accountName)
import HKernel.HouseholdIssue
import HKernel.Money
import HKernel.Period
import HKernel.Plan (CommittedOutgoingPlan)
import HKernel.Plan.Render (renderCommittedOutgoingPlanLine)
import HKernel.Render
  ( renderReportBookCoreWithPresentation
  )
import HKernel.Render.TerminalStyle
import HKernel.Report (ReportBook)
import HKernel.Report.CycleAccounts
import HKernel.Report.Presentation
import HKernel.Spike.HouseholdReport

data IssueVisibility
  = OpenIssuesOnly
  | AllIssues
  deriving (Eq, Show)

-- | One typed Household report section available to application adapters.
--
-- This is deliberately a report selection, not a CLI command name. TUI, CLI,
-- or another delivery adapter can select the same value and reuse the same pure
-- renderer without reconstructing Household report semantics.
data HouseholdReportSection
  = HouseholdCycleAccounts
  | HouseholdDailyTarget
  | HouseholdPlannedTransactions
  | HouseholdIssues IssueVisibility
  | HouseholdEnvelopeBacking
  deriving (Eq, Show)

-- | Render exactly one Household report section from an already typed surface.
renderHouseholdReportSection
  :: PresentationConfig
  -> HouseholdReportSection
  -> HouseholdReportSurface
  -> Text
renderHouseholdReportSection presentation section surface =
  case section of
    HouseholdCycleAccounts ->
      renderHouseholdCycleReports presentation surface
    HouseholdDailyTarget ->
      renderDailyTarget presentation (householdDailyTarget surface)
    HouseholdPlannedTransactions ->
      renderPlans
        (currentCycleAccountsPeriod (householdCurrentCycleAccounts surface))
        (householdPlannedTransactions surface)
    HouseholdIssues visibility ->
      renderHouseholdIssues visibility (householdIssues surface)
    HouseholdEnvelopeBacking ->
      renderEnvelope presentation (householdEnvelopeBacking surface)

renderHouseholdReportSections
  :: PresentationConfig
  -> HouseholdReportSurface
  -> Text
renderHouseholdReportSections =
  renderHouseholdReportSectionsWithIssueVisibility OpenIssuesOnly

renderHouseholdReportSectionsWithIssueVisibility
  :: IssueVisibility
  -> PresentationConfig
  -> HouseholdReportSurface
  -> Text
renderHouseholdReportSectionsWithIssueVisibility visibility presentation surface =
  T.intercalate "\n"
    [ renderHouseholdReportSection presentation section surface
    | section <-
        [ HouseholdCycleAccounts
        , HouseholdDailyTarget
        , HouseholdPlannedTransactions
        , HouseholdIssues visibility
        , HouseholdEnvelopeBacking
        ]
    ]

-- | Publish the two distinct cycle meanings restored by the typed report core.
-- Current-cycle Accounts is an Account-state observation. Cycle Comparison is
-- the previous cycle at the same elapsed day count, not a second name for the
-- retained Expense-only compatibility matrix.
renderHouseholdCycleReports
  :: PresentationConfig
  -> HouseholdReportSurface
  -> Text
renderHouseholdCycleReports presentation surface = T.intercalate "\n"
  [ renderCurrentCycleAccounts presentation
      (householdCurrentCycleAccounts surface)
  , case householdCycleComparison surface of
      HouseholdCycleComparisonAvailable comparison ->
        renderAlignedCycleComparison presentation comparison
      HouseholdCycleComparisonUnavailable reason ->
        renderUnavailableCycleComparison reason
  ]

renderCurrentCycleAccounts
  :: PresentationConfig
  -> CurrentCycleAccounts
  -> Text
renderCurrentCycleAccounts presentation report = T.intercalate "\n"
  [ terminalHeader "Current Cycle Accounts"
  , terminalMeta ("Cycle: " <> renderPeriod (currentCycleAccountsPeriod report)
      <> " | Observed through: "
      <> renderDay (currentCycleAccountsObservation report))
  , ""
  , renderTerminalTable columns rows (Just totalRow)
  , terminalBoldThen "Double-entry balanced: "
      (renderYesNo (currentCycleAccountsBalanced report))
  , ""
  ]
  where
    columns =
      [ ("Account", AlignLeft)
      , ("Opening", AlignRight)
      , ("Debit", AlignRight)
      , ("Credit", AlignRight)
      , ("Movement", AlignRight)
      , ("Closing", AlignRight)
      ]
    rows =
      [ [ plainCell (accountName (currentCycleAccount row))
        , signedBalanceCellWith presentation (currentCycleAccountOpening row)
        , signedBalanceCellWith presentation (currentCycleAccountDebit row)
        , signedBalanceCellWith presentation (currentCycleAccountCredit row)
        , signedBalanceCellWith presentation (currentCycleAccountRowMovement row)
        , signedBalanceCellWith presentation (currentCycleAccountRowClosing row)
        ]
      | row <- currentCycleAccountsRows report
      ]
    totalRow =
      [ styledCell terminalBold "Total"
      , signedBalanceCellWith presentation (currentCycleAccountsOpeningTotal report)
      , signedBalanceCellWith presentation (currentCycleAccountsDebitTotal report)
      , signedBalanceCellWith presentation (currentCycleAccountsCreditTotal report)
      , signedBalanceCellWith presentation (currentCycleAccountsMovementTotal report)
      , signedBalanceCellWith presentation (currentCycleAccountsClosingTotal report)
      ]

renderAlignedCycleComparison
  :: PresentationConfig
  -> CycleComparison
  -> Text
renderAlignedCycleComparison presentation report = T.intercalate "\n"
  [ terminalHeader "Cycle Comparison"
  , terminalMeta
      ("Policy: " <> renderComparisonPolicy (cycleComparisonPolicy report)
        <> " | Current: " <> renderObservation current
        <> " | Baseline: " <> renderObservation baseline)
  , ""
  , renderTerminalTable columns rows (Just totalRow)
  , terminalBoldThen "Double-entry balanced: "
      (renderYesNo (cycleComparisonBalanced report))
  , ""
  ]
  where
    current = cycleComparisonCurrent report
    baseline = cycleComparisonBaseline report
    columns =
      [ ("Account", AlignLeft)
      , ("Current movement", AlignRight)
      , ("Previous same-day", AlignRight)
      , ("Difference", AlignRight)
      ]
    rows =
      [ [ plainCell (accountName (cycleComparisonAccount row))
        , signedBalanceCellWith presentation (cycleComparisonCurrentMovement row)
        , signedBalanceCellWith presentation (cycleComparisonBaselineMovement row)
        , signedBalanceCellWith presentation (cycleComparisonRowDifference row)
        ]
      | row <- cycleComparisonRows report
      ]
    totalRow =
      [ styledCell terminalBold "Total"
      , signedBalanceCellWith presentation (cycleComparisonCurrentTotal report)
      , signedBalanceCellWith presentation (cycleComparisonBaselineTotal report)
      , signedBalanceCellWith presentation (cycleComparisonDifferenceTotal report)
      ]

renderUnavailableCycleComparison
  :: HouseholdCycleComparisonUnavailable
  -> Text
renderUnavailableCycleComparison reason = T.intercalate "\n"
  [ terminalHeader "Cycle Comparison"
  , terminalMeta "Status: NOT AVAILABLE"
  , terminalDim ("Aligned previous-cycle observation is unavailable: " <> tshow reason)
  , ""
  ]

renderComparisonPolicy :: CycleComparisonPolicy -> Text
renderComparisonPolicy policy = case policy of
  AlignedElapsed -> "aligned_elapsed"
  CompleteCycles -> "complete_cycles"

renderObservation :: CurrentCycleAccounts -> Text
renderObservation report =
  renderPeriod (currentCycleAccountsPeriod report)
    <> " through " <> renderDay (currentCycleAccountsObservation report)

renderYesNo :: Bool -> Text
renderYesNo True = terminalGreen "yes"
renderYesNo False = terminalRed "no"

renderPeriod :: Period -> Text
renderPeriod period =
  "[" <> renderDay (periodStart period)
    <> ", " <> renderDay (periodEndExclusive period) <> ")"

renderDailyTarget :: PresentationConfig -> DailyTarget -> Text
renderDailyTarget presentation report = T.intercalate "\n"
  [ terminalHeader "Daily Target"
  , terminalMeta ("Observation: " <> renderDay (dailyTargetObservedOn report)
      <> " | Target end (exclusive): "
      <> renderDay (dailyTargetEndExclusive report)
      <> " | Remaining days: " <> tshow remainingDays)
  , ""
  , renderTerminalTable columns rows Nothing
  , terminalMeta "Rates are exact rational values; ≈ values are display-only decimals, not stored accounting facts."
  , ""
  ]
  where
    remainingDays = max 1 (diffDays
      (dailyTargetEndExclusive report)
      (dailyTargetObservedOn report))
    columns = [("Coordinate", AlignLeft), ("Exact value", AlignRight)]
    rows =
      [ [plainCell "Eligible scoped Assets", plainBalanceCellWith presentation
          (dailyTargetEligibleAssets report)]
      , [plainCell "Gross scoped obligations", plainBalanceCellWith presentation
          (dailyTargetOpenObligations report)]
      , [plainCell "Already excluded by reservation evidence", plainBalanceCellWith presentation
          (dailyTargetAlreadyExcluded report)]
      , [plainCell "Obligation deduction", plainBalanceCellWith presentation
          (dailyTargetOpenObligations report
            `subtractBalance` dailyTargetAlreadyExcluded report)]
      , [styledCell terminalBold "Capacity", signedBalanceCellWith presentation
          (dailyTargetCapacity report)]
      , [styledCell terminalBold "Exact daily capacity rate", plainCell
          (renderRates (dailyTargetRate report))]
      ]

renderRates :: [(Commodity, Rational)] -> Text
renderRates [] = "0"
renderRates rates = T.intercalate ", " (map renderRate rates)
  where
    renderRate (commodity, rate) =
      renderRational rate <> " " <> commodityCode commodity <> "/day"
    renderRational value
      | denominator value == 1 = tshow (numerator value)
      | otherwise = tshow (numerator value) <> "/" <> tshow (denominator value)
          <> " (≈" <> decimal2 value <> ")"
    decimal2 value =
      let scaled = numerator value * 100 `div` denominator value
          whole = scaled `div` 100
          fraction = abs (scaled `mod` 100)
      in tshow whole <> "." <> T.justifyRight 2 '0' (tshow fraction)

renderPlans :: Period -> [CommittedOutgoingPlan] -> Text
renderPlans period plans = T.intercalate "\n"
  [ terminalHeader "Planned Transactions"
  , terminalMeta "Source: plan.journal | All open outgoing commitments; current-cycle calculations remain cycle-bounded"
  , ""
  , renderPlanHorizon period plans
  , ""
  ]

renderPlanHorizon :: Period -> [CommittedOutgoingPlan] -> Text
renderPlanHorizon _ [] = terminalDim "(none)"
renderPlanHorizon period plans =
  T.intercalate "\n" (beforeLines ++ currentLines ++ afterLines)
  where
    classified = classifyPlannedTransactions period plans
    before = plansAt BeforeCurrentCycle classified
    current = plansAt InCurrentCycle classified
    after = plansAt AfterCurrentCycle classified
    beforeLines
      | null before = []
      | otherwise =
          [ terminalYellow "Open before current cycle"
          , renderPlanLines before
          , ""
          ]
    currentLines
      | null current = [terminalDim "(no open commitments inside current cycle)"]
      | otherwise = [renderPlanLines current]
    afterLines
      | null after = []
      | otherwise =
          [ ""
          , terminalMeta
              ("──────── current cycle ends before "
                <> renderDay (periodEndExclusive period)
                <> " ────────")
          , renderPlanLines after
          ]

plansAt
  :: PlannedTransactionHorizon
  -> [ClassifiedPlannedTransaction]
  -> [CommittedOutgoingPlan]
plansAt horizon classified =
  [ classifiedPlanValue plan
  | plan <- classified
  , classifiedPlanHorizon plan == horizon
  ]

renderPlanLines :: [CommittedOutgoingPlan] -> Text
renderPlanLines = T.intercalate "\n" . map renderCommittedOutgoingPlanLine

renderHouseholdIssues :: IssueVisibility -> [HouseholdIssue] -> Text
renderHouseholdIssues visibility issues = T.intercalate "\n"
  [ terminalHeader "Household Issues"
  , terminalMeta ("Source: issues.tsv | " <> visibilityLabel visibility
      <> " | Displayed: " <> tshow (length visibleIssues)
      <> hiddenLabel)
  , terminalMeta "Issues do not change accounting or budget values"
  , ""
  , if null visibleIssues
      then terminalDim "(none)"
      else T.intercalate "\n\n" (map renderIssueCard visibleIssues)
  , ""
  ]
  where
    visibleIssues = filter (visibleWith visibility) issues
    hiddenCount = length issues - length visibleIssues
    hiddenLabel
      | hiddenCount == 0 = ""
      | otherwise = " | Resolved hidden: " <> tshow hiddenCount

visibleWith :: IssueVisibility -> HouseholdIssue -> Bool
visibleWith visibility issue = case visibility of
  OpenIssuesOnly -> householdIssueStatus issue == Open
  AllIssues -> True

visibilityLabel :: IssueVisibility -> Text
visibilityLabel visibility = case visibility of
  OpenIssuesOnly -> "open issues only"
  AllIssues -> "all issues"

renderIssueCard :: HouseholdIssue -> Text
renderIssueCard issue = T.intercalate "\n"
  (topBorder : concatMap (uncurry renderCardField) fields ++ [bottomBorder])
  where
    fields =
      [ ("ID", issueIdText (householdIssueId issue))
      , ("Recorded", renderDay (householdIssueRecordedOn issue))
      , ("Amount", maybe "—" renderAmount (householdIssueAmount issue))
      , ("Title", householdIssueText issue)
      , ("Details", householdIssueDetails issue)
      ]
    status = T.toUpper (renderStatus (householdIssueStatus issue))
    topLabel = "─ " <> status <> " "
    topBorder = "┌" <> topLabel
      <> T.replicate (issueCardInnerWidth + 2 - displayWidth topLabel) "─" <> "┐"
    bottomBorder = "└" <> T.replicate (issueCardInnerWidth + 2) "─" <> "┘"

renderCardField :: Text -> Text -> [Text]
renderCardField label value = map boxed (zipWith (<>) prefixes wrapped)
  where
    prefix = T.justifyLeft issueCardLabelWidth ' ' label <> " : "
    continuation = T.replicate (displayWidth prefix) " "
    valueWidth = issueCardInnerWidth - displayWidth prefix
    wrapped = wrapDisplayWidth valueWidth value
    prefixes = prefix : repeat continuation
    boxed line = "│ " <> padDisplayWidth issueCardInnerWidth line <> " │"

issueCardInnerWidth :: Int
issueCardInnerWidth = 84

issueCardLabelWidth :: Int
issueCardLabelWidth = 8

renderStatus :: IssueStatus -> Text
renderStatus Open = "open"
renderStatus Resolved = "resolved"
renderStatus Dropped = "dropped"

renderAmount :: Amount -> Text
renderAmount amount =
  renderQuantity (amountQuantity amount)
    <> " " <> commodityCode (amountCommodity amount)

renderEnvelope :: PresentationConfig -> EnvelopeBacking -> Text
renderEnvelope presentation report = T.intercalate "\n"
  [ terminalHeader "Envelope & Backing"
  , terminalMeta ("Cycle: [" <> renderDay (periodStart period)
      <> ", " <> renderDay (periodEndExclusive period) <> ")"
      <> " | Observed through: " <> renderDay (envelopeBackingObservedOn report))
  , ""
  , renderTerminalTable envelopeColumns envelopeRows Nothing
  , renderUnassignedExpenses presentation
      (envelopeUnassignedExpenses report)
  , terminalYellow "Backing evidence"
  , renderTerminalTable backingColumns backingRows Nothing
  , "Status: " <> renderBackingStatus (envelopeBackingSurplus report)
  , ""
  ]
  where
    period = envelopeBackingPeriod report
    envelopeColumns =
      [ ("Envelope", AlignLeft)
      , ("Entitlement", AlignRight)
      , ("Consumption", AlignRight)
      , ("Refunds", AlignRight)
      , ("Remaining", AlignRight)
      , ("Plan reserve", AlignRight)
      , ("Headroom", AlignRight)
      ]
    envelopeRows =
      [ [ plainCell (envelopeBackingName line)
        , plainBalanceCellWith presentation (envelopeEntitlement line)
        , plainBalanceCellWith presentation (envelopeActualConsumption line)
        , plainBalanceCellWith presentation (envelopeActualRefunds line)
        , signedBalanceCellWith presentation (envelopeLedgerRemaining line)
        , plainBalanceCellWith presentation (envelopeOpenPlanReserve line)
        , signedBalanceCellWith presentation (envelopePostPlanHeadroom line)
        ]
      | line <- envelopeBackingLines report
      ]
    backingColumns = [("Coordinate", AlignLeft), ("Amount", AlignRight)]
    backingRows =
      [ [plainCell "Funding balance", plainBalanceCellWith presentation
          (envelopeFundingBalance report)]
      , [plainCell "Signed envelope total", signedBalanceCellWith presentation
          (envelopeSignedTotal report)]
      , [plainCell "Positive backing required", plainBalanceCellWith presentation
          (envelopeBackingRequired report)]
      , [plainCell "Backing surplus", signedBalanceCellWith presentation
          (envelopeBackingSurplus report)]
      , [plainCell "Ledger unassigned", signedBalanceCellWith presentation
          (envelopeLedgerUnassigned report)]
      , [plainCell "Reconciliation delta", signedBalanceCellWith presentation
          (envelopeReconciliationDelta report)]
      ]

renderUnassignedExpenses
  :: PresentationConfig
  -> [(Account, Balance)]
  -> Text
renderUnassignedExpenses _ [] = ""
renderUnassignedExpenses presentation expenses = T.intercalate "\n"
  [ terminalYellow "Expense activity outside an envelope"
  , renderTerminalTable
      [("Account", AlignLeft), ("Movement", AlignRight)]
      [ [ plainCell (accountName account)
        , signedBalanceCellWith presentation balance
        ]
      | (account, balance) <- expenses
      ]
      Nothing
  ]

renderBackingStatus :: Balance -> Text
renderBackingStatus balance
  | all ((>= zeroQuantity) . snd) (balanceEntries balance) = terminalGreen "backed"
  | otherwise = terminalRed "under_backed"

renderHouseholdSourceErrors :: NonEmpty HouseholdSourceError -> Text
renderHouseholdSourceErrors = T.unlines . map render . NonEmpty.toList
  where
    render err = householdSourceName err
      <> lineSuffix (householdSourceLine err)
      <> ": " <> householdSourceMessage err
    lineSuffix 0 = ""
    lineSuffix lineNumber = ":" <> tshow lineNumber

renderDay :: Day -> Text
renderDay = T.pack . formatTime defaultTimeLocale "%F"

renderReportBookWithHouseholdPresentation
  :: PresentationConfig
  -> ReportBook
  -> HouseholdReportSurface
  -> Text
renderReportBookWithHouseholdPresentation presentation report household =
  T.intercalate "\n"
    [ renderReportBookCoreWithPresentation presentation report
    , renderHouseholdReportSections presentation household
    ]

tshow :: Show value => value -> Text
tshow = T.pack . show
