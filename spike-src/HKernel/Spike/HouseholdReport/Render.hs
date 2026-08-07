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
  ( renderCycleAccountsWithPresentation
  , renderReportBookCoreWithPresentation
  )
import HKernel.Render.TerminalStyle
import HKernel.Report (ReportBook)
import HKernel.Report.CycleAccounts (CycleAccounts)
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
renderHouseholdReportSection =
  renderHouseholdReportSectionWithCycle renderCycleAccountsWithPresentation

renderHouseholdReportSections
  :: (PresentationConfig -> CycleAccounts -> Text)
  -> PresentationConfig
  -> HouseholdReportSurface
  -> Text
renderHouseholdReportSections =
  renderHouseholdReportSectionsWithIssueVisibility OpenIssuesOnly

renderHouseholdReportSectionsWithIssueVisibility
  :: IssueVisibility
  -> (PresentationConfig -> CycleAccounts -> Text)
  -> PresentationConfig
  -> HouseholdReportSurface
  -> Text
renderHouseholdReportSectionsWithIssueVisibility visibility renderCycle presentation surface =
  T.intercalate "\n"
    [ renderHouseholdReportSectionWithCycle
        renderCycle presentation section surface
    | section <-
        [ HouseholdCycleAccounts
        , HouseholdDailyTarget
        , HouseholdPlannedTransactions
        , HouseholdIssues visibility
        , HouseholdEnvelopeBacking
        ]
    ]

renderHouseholdReportSectionWithCycle
  :: (PresentationConfig -> CycleAccounts -> Text)
  -> PresentationConfig
  -> HouseholdReportSection
  -> HouseholdReportSurface
  -> Text
renderHouseholdReportSectionWithCycle renderCycle presentation section surface =
  case section of
    HouseholdCycleAccounts ->
      renderCycle presentation (householdCycleAccounts surface)
    HouseholdDailyTarget ->
      renderDailyTarget presentation (householdDailyTarget surface)
    HouseholdPlannedTransactions ->
      renderPlans (householdPlannedTransactions surface)
    HouseholdIssues visibility ->
      renderHouseholdIssues visibility (householdIssues surface)
    HouseholdEnvelopeBacking ->
      renderEnvelope presentation (householdEnvelopeBacking surface)

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

renderPlans :: [CommittedOutgoingPlan] -> Text
renderPlans plans = T.intercalate "\n"
  [ terminalHeader "Planned Transactions"
  , terminalMeta "Source: plan.journal | Open outgoing commitments inside the resolved current cycle"
  , ""
  , if null plans
      then terminalDim "(none)"
      else T.intercalate "\n" (map renderCommittedOutgoingPlanLine plans)
  , ""
  ]

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
    , renderHouseholdReportSections
        renderCycleAccountsWithPresentation presentation household
    ]

tshow :: Show value => value -> Text
tshow = T.pack . show
