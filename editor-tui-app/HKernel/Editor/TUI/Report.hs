{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Report
  ( WorkspaceAction(..)
  , PickerAction(..)
  , PickerState
  , drawWorkspace
  , drawPicker
  , handleWorkspaceEvent
  , handlePickerEvent
  , openPicker
  , reportChoices
  , reportChoiceIndex
  , reportChoiceAt
  , reportSelectionForKey
  ) where

import Brick
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal', singular)

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import qualified Data.Vector as Vec

import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , ReportChoice(..)
  , contextHouseholdState
  )
import qualified HKernel.Editor.TUI.ReportStyle as ReportStyle
import HKernel.Editor.TUI.Scroll qualified as Scroll
import HKernel.Envelope.Consumption (consumptionNet)
import HKernel.Envelope.Fulfillment (fulfillmentNet)
import HKernel.Envelope.Identity (envelopeIdText)
import HKernel.Household.Application (HouseholdState(..))
import HKernel.Household.EnvelopeObservation
  ( EnvelopeChangeBaseline(..)
  , EnvelopeChangeLine
  , EnvelopeCycleComparisonLine
  , HouseholdEnvelopeChange
  , HouseholdEnvelopeCycleComparison
  , envelopeChangeCommitment
  , envelopeChangeConsumptionNet
  , envelopeChangeEntitlement
  , envelopeChangeFulfillmentNet
  , envelopeChangeHeadroom
  , envelopeChangeId
  , envelopeChangeRemaining
  , envelopeCycleBaselineCommitment
  , envelopeCycleBaselineConsumption
  , envelopeCycleBaselineEntitlement
  , envelopeCycleBaselineFulfillment
  , envelopeCycleBaselineHeadroom
  , envelopeCycleBaselineRemaining
  , envelopeCycleCommitmentDifference
  , envelopeCycleConsumptionNetDifference
  , envelopeCycleCurrentCommitment
  , envelopeCycleCurrentConsumption
  , envelopeCycleCurrentEntitlement
  , envelopeCycleCurrentFulfillment
  , envelopeCycleCurrentHeadroom
  , envelopeCycleCurrentRemaining
  , envelopeCycleEntitlementDifference
  , envelopeCycleFulfillmentNetDifference
  , envelopeCycleHeadroomDifference
  , envelopeCycleRemainingDifference
  , envelopeCycleComparisonId
  , householdEnvelopeChangeFrom
  , householdEnvelopeChangeLines
  , householdEnvelopeChangeThrough
  , householdEnvelopeCycleComparisonBaselineThrough
  , householdEnvelopeCycleComparisonCurrentThrough
  , householdEnvelopeCycleComparisonLines
  )
import HKernel.Household.Report.Render
  ( HouseholdReportSection(..)
  , IssueVisibility(..)
  , renderHouseholdReportSection
  , renderReportBookWithHouseholdPresentation
  )
import HKernel.Household.Temporal
  ( householdEnvelopeAlignedPreviousCycle
  , householdEnvelopeChangeFromBaseline
  )
import HKernel.Render
  ( renderBalanceSheetWithPresentation
  , renderDailyFlowWithPresentation
  , renderMonthlyAccountsWithPresentation
  , renderProfitAndLossWithPresentation
  , renderRecentTransactionsWithPresentation
  , renderTrialBalanceWithPresentation
  )
import HKernel.Render.TerminalStyle
  ( Alignment(..)
  , Cell
  , plainCell
  , renderTerminalTable
  , signedBalanceCellWith
  , terminalDim
  , terminalHeaderWith
  , terminalMeta
  , terminalSectionWith
  )
import HKernel.Report (ReportBook(..))
import HKernel.Report.Config (reportConfigurationPresentation)
import HKernel.Report.Plan (ReportPlanError(..))
import HKernel.Report.Presentation (PresentationConfig)

-- | Render the Reports section of the Household workspace. Report bodies stay
-- intentionally two-dimensional and retain horizontal scrolling; only the TUI
-- chrome wraps to the available terminal width.
drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ borderWithLabel (txt ("Household Report: " <> reportChoiceLabel selected))
        (viewport ReportsViewport Both (renderSelectedReport context))
    , strWrap "[Enter] Choose report   [wheel/↑↓←→] Scroll   [Shift+wheel] Horizontal   [PgUp/PgDn] Page"
    , strWrap "[Home/End] Top/Bottom   [Shift+←→] Horizontal page   [r/R] Next/Previous report"
    ]
  where
    selected = contextSelectedReport context

data PickerItem
  = PickerReport ReportChoice
  | PickerPreviousObservation
  | PickerExplicitDay
  deriving (Eq, Show)

data TemporalInputKind
  = PreviousObservationInput
  | ExplicitDayInput
  deriving (Eq, Show)

data TemporalInput = TemporalInput
  { temporalDayText :: Text
  } deriving (Eq, Show)

data PickerState
  = PickerList (L.List Name PickerItem)
  | PickerDate TemporalInputKind (Maybe Text) (Form TemporalInput AppEvent Name)

data PickerAction
  = PickerMaintain
  | PickerBack
  | PickerQuit
  | PickerOpen ReportChoice
  deriving (Eq, Show)

openPicker :: ReportChoice -> PickerState
openPicker selected = pickerListAt (pickerItemForReport selected)

pickerListAt :: PickerItem -> PickerState
pickerListAt selected =
  PickerList
    (L.listMoveTo (pickerItemIndex selected)
      (L.list ReportPickerList (Vec.fromList pickerItems) 1))

pickerItemForReport :: ReportChoice -> PickerItem
pickerItemForReport report = case report of
  ReportEnvelopeChangeFromPreviousObservation _ -> PickerPreviousObservation
  ReportEnvelopeChange PreviousObservation -> PickerPreviousObservation
  ReportEnvelopeChange (ExplicitDay _) -> PickerExplicitDay
  ReportEnvelopeChangeBetween _ _ -> PickerExplicitDay
  _ -> PickerReport report

pickerItemIndex :: PickerItem -> Int
pickerItemIndex item = go 0 pickerItems
  where
    go _ [] = 0
    go index (candidate : rest)
      | candidate == item = index
      | otherwise = go (index + 1) rest

pickerItems :: [PickerItem]
pickerItems =
  [ PickerReport ReportTrialBalance
  , PickerReport ReportBalanceSheet
  , PickerReport ReportProfitAndLoss
  , PickerReport ReportDailyFlow
  , PickerReport ReportMonthlyAccounts
  , PickerReport (ReportHousehold HouseholdCycleAccounts)
  , PickerReport (ReportHousehold HouseholdDailyTarget)
  , PickerReport (ReportHousehold HouseholdEnvelopeBacking)
  , PickerReport (ReportEnvelopeChange CycleStart)
  , PickerReport (ReportEnvelopeChange PreviousDay)
  , PickerPreviousObservation
  , PickerExplicitDay
  , PickerReport ReportEnvelopeAlignedPreviousCycle
  ]

pickerItemAt :: Int -> Maybe PickerItem
pickerItemAt row = case drop row pickerItems of
  [] -> Nothing
  item : _ -> Just item

temporalDayTextL :: Lens' TemporalInput Text
temporalDayTextL f input =
  (\value -> input { temporalDayText = value }) <$> f (temporalDayText input)

mkTemporalForm :: Form TemporalInput AppEvent Name
mkTemporalForm =
  setFormFocus DateField
    (newForm
      [ editTextField temporalDayTextL DateField (Just 1)
      ]
      (TemporalInput ""))

zoomPickerList :: Traversal' PickerState (L.List Name PickerItem)
zoomPickerList f (PickerList choices) = PickerList <$> f choices
zoomPickerList _ state = pure state

zoomTemporalForm :: Traversal' PickerState (Form TemporalInput AppEvent Name)
zoomTemporalForm f (PickerDate kind message form) =
  PickerDate kind message <$> f form
zoomTemporalForm _ state = pure state

-- | Render the modal picker for named Household reports and the two temporal
-- requests that require explicit caller context before they become reports.
drawPicker :: PickerState -> Widget Name
drawPicker state = case state of
  PickerList choices ->
    center
      (borderWithLabel (str "Choose Household Report")
        (hLimit 68
          (vLimit 24
            (padAll 1
              (L.renderList renderPickerItem True choices
                <=> str " "
                <=> strWrap "[wheel/↑/↓ or j/k] Move   [click/Enter] Open   [Esc] Back   [Q] Quit")))))
  PickerDate kind message form ->
    center
      (borderWithLabel (str (temporalInputTitle kind))
        (hLimit 68
          (padAll 1
            ( strWrap (temporalInputExplanation kind)
              <=> str " "
              <=> str "Date (YYYY-MM-DD):"
              <=> renderForm form
              <=> maybe emptyWidget
                    (padTop (Pad 1) . withAttr (attrName "warning") . txtWrap)
                    message
              <=> str " "
              <=> strWrap "[Enter] Open report   [Esc] Report list   [Q] Quit"))))

renderPickerItem :: Bool -> PickerItem -> Widget Name
renderPickerItem selected item
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = txt (pickerItemLabel item)

pickerItemLabel :: PickerItem -> Text
pickerItemLabel item = case item of
  PickerReport report -> reportChoiceLabel report
  PickerPreviousObservation -> "Envelope Change: Since previous observation..."
  PickerExplicitDay -> "Envelope Change: Since chosen day..."

temporalInputTitle :: TemporalInputKind -> String
temporalInputTitle kind = case kind of
  PreviousObservationInput -> "Envelope Change: Previous observation"
  ExplicitDayInput -> "Envelope Change: Chosen day"

temporalInputExplanation :: TemporalInputKind -> String
temporalInputExplanation kind = case kind of
  PreviousObservationInput ->
    "Enter the day you mean by the previous observation. The TUI passes this context explicitly; it is never inferred from accounting evidence."
  ExplicitDayInput ->
    "Enter the exact day you want to compare. It must stay inside the same cycle and may equal the current observation for an intentional zero-length comparison."

-- | Keep picker-local list movement, temporal context entry, and selection
-- inside the Report owner. Main only interprets the resulting application
-- transition after a complete ReportChoice exists.
handlePickerEvent
  :: BrickEvent Name AppEvent
  -> EventM Name PickerState PickerAction
handlePickerEvent event = do
  state <- get
  case state of
    PickerList _ -> handlePickerListEvent event
    PickerDate kind _ form -> handlePickerDateEvent kind form event

handlePickerListEvent
  :: BrickEvent Name AppEvent
  -> EventM Name PickerState PickerAction
handlePickerListEvent event = case Scroll.listWheelEvent ReportPickerList event of
  Just wheelEvent -> do
    zoom (singular zoomPickerList) (L.handleListEvent wheelEvent)
    pure PickerMaintain
  Nothing -> case event of
    MouseDown ReportPickerList V.BLeft _ (Location (_, row)) ->
      maybe (pure PickerMaintain) openPickerItem (pickerItemAt row)
    VtyEvent (V.EvKey V.KEsc []) -> pure PickerBack
    VtyEvent (V.EvKey (V.KChar 'q') []) -> pure PickerQuit
    VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure PickerQuit
    VtyEvent (V.EvKey V.KEnter []) -> do
      state <- get
      case state of
        PickerList choices -> case L.listSelectedElement choices of
          Nothing -> pure PickerBack
          Just (_, item) -> openPickerItem item
        _ -> pure PickerMaintain
    VtyEvent vtyEvent -> do
      zoom (singular zoomPickerList)
        (L.handleListEventVi L.handleListEvent vtyEvent)
      pure PickerMaintain
    _ -> pure PickerMaintain

openPickerItem :: PickerItem -> EventM Name PickerState PickerAction
openPickerItem item = case item of
  PickerReport choice -> pure (PickerOpen choice)
  PickerPreviousObservation -> do
    put (PickerDate PreviousObservationInput Nothing mkTemporalForm)
    pure PickerMaintain
  PickerExplicitDay -> do
    put (PickerDate ExplicitDayInput Nothing mkTemporalForm)
    pure PickerMaintain

handlePickerDateEvent
  :: TemporalInputKind
  -> Form TemporalInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name PickerState PickerAction
handlePickerDateEvent kind form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> do
    put (pickerListAt (temporalPickerItem kind))
    pure PickerMaintain
  VtyEvent (V.EvKey (V.KChar 'q') []) -> pure PickerQuit
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure PickerQuit
  VtyEvent (V.EvKey V.KEnter []) ->
    case parseTemporalDay (temporalDayText (formState form)) of
      Left message -> do
        put (PickerDate kind (Just message) form)
        pure PickerMaintain
      Right day -> pure (PickerOpen (temporalReportChoice kind day))
  _ -> do
    zoom (singular zoomTemporalForm) (handleFormEvent event)
    current <- get
    case current of
      PickerDate currentKind _ currentForm ->
        put (PickerDate currentKind Nothing currentForm)
      _ -> pure ()
    pure PickerMaintain

temporalPickerItem :: TemporalInputKind -> PickerItem
temporalPickerItem kind = case kind of
  PreviousObservationInput -> PickerPreviousObservation
  ExplicitDayInput -> PickerExplicitDay

temporalReportChoice :: TemporalInputKind -> Day -> ReportChoice
temporalReportChoice kind day = case kind of
  PreviousObservationInput -> ReportEnvelopeChangeFromPreviousObservation day
  ExplicitDayInput -> ReportEnvelopeChange (ExplicitDay day)

parseTemporalDay :: Text -> Either Text Day
parseTemporalDay text =
  case parseTimeM True defaultTimeLocale "%Y-%m-%d"
      (T.unpack (T.strip text)) of
    Nothing -> Left "Date must be YYYY-MM-DD."
    Just day -> Right day

-- | Reports exposed by deterministic next/previous cycling. Contextual temporal
-- requests live in 'pickerItems' because they are incomplete until a day is
-- supplied explicitly.
reportChoices :: [ReportChoice]
reportChoices =
  [ ReportTrialBalance
  , ReportBalanceSheet
  , ReportProfitAndLoss
  , ReportDailyFlow
  , ReportMonthlyAccounts
  , ReportHousehold HouseholdCycleAccounts
  , ReportHousehold HouseholdDailyTarget
  , ReportHousehold HouseholdEnvelopeBacking
  , ReportEnvelopeChange CycleStart
  , ReportEnvelopeChange PreviousDay
  , ReportEnvelopeAlignedPreviousCycle
  ]

reportChoiceIndex :: ReportChoice -> Int
reportChoiceIndex choice = go 0 reportChoices
  where
    go _ [] = 0
    go index (candidate : rest)
      | candidate == choice = index
      | otherwise = go (index + 1) rest

reportChoiceAt :: Int -> Maybe ReportChoice
reportChoiceAt row = case drop row reportChoices of
  [] -> Nothing
  choice : _ -> Just choice

-- | Interpret only Report-specific direct-selection keys. Shell focus traversal
-- and application quit stay outside this owner; report selection and scrolling
-- remain local to the Report surface.
reportSelectionForKey :: ReportChoice -> Char -> Maybe ReportChoice
reportSelectionForKey current key = case key of
  't' -> Just ReportTrialBalance
  'b' -> Just ReportBalanceSheet
  'p' -> Just ReportProfitAndLoss
  'd' -> Just ReportDailyFlow
  'm' -> Just ReportMonthlyAccounts
  'c' -> Just (ReportHousehold HouseholdCycleAccounts)
  'T' -> Just (ReportHousehold HouseholdDailyTarget)
  'E' -> Just (ReportHousehold HouseholdEnvelopeBacking)
  'r' -> Just (cycleReport current)
  'R' -> Just (cycleReportBack current)
  _ -> Nothing

reportChoiceLabel :: ReportChoice -> Text
reportChoiceLabel choice = case choice of
  ReportTrialBalance -> "Account Balances"
  ReportBalanceSheet -> "Balance Sheet"
  ReportProfitAndLoss -> "Profit & Loss"
  ReportDailyFlow -> "Daily Flow"
  ReportMonthlyAccounts -> "Monthly Accounts"
  ReportHousehold section -> case section of
    HouseholdCycleAccounts -> "Cycle Accounts & Comparison"
    HouseholdDailyTarget -> "Daily Target"
    HouseholdPlannedTransactions -> "Planned Transactions"
    HouseholdIssues visibility -> case visibility of
      OpenIssuesOnly -> "Open Issues"
      AllIssues -> "All Issues"
    HouseholdEnvelopeBacking -> "Envelope & Backing"
  ReportEnvelopeChange baseline -> case baseline of
    CycleStart -> "Envelope Change: Since cycle start"
    PreviousDay -> "Envelope Change: Since previous day"
    PreviousObservation -> "Envelope Change: Since previous observation"
    ExplicitDay day -> "Envelope Change: Since " <> renderDay day
  ReportEnvelopeChangeFromPreviousObservation day ->
    "Envelope Change: Since previous observation (" <> renderDay day <> ")"
  ReportEnvelopeChangeBetween from through ->
    "Envelope Change: " <> renderDay from <> " → " <> renderDay through
  ReportEnvelopeAlignedPreviousCycle ->
    "Envelope Comparison: Previous cycle"
  ReportRecentTransactions -> "Recent Actual"
  ReportCombinedBook -> "Full Household Report"

renderSelectedReport :: AppContext -> Widget Name
renderSelectedReport context = case contextSelectedReport context of
  ReportTrialBalance -> withReportBook $ \(ReportBook trial _ _ _ _ _) ->
    reportText (renderTrialBalanceWithPresentation pres trial)
  ReportBalanceSheet -> withReportBook $ \(ReportBook _ balance _ _ _ _) ->
    reportText (renderBalanceSheetWithPresentation pres balance)
  ReportProfitAndLoss -> withReportBook $ \(ReportBook _ _ profit _ _ _) ->
    reportText (renderProfitAndLossWithPresentation pres profit)
  ReportDailyFlow -> withReportBook $ \(ReportBook _ _ _ daily _ _) ->
    reportText (renderDailyFlowWithPresentation pres daily)
  ReportMonthlyAccounts -> withReportBook $ \(ReportBook _ _ _ _ _ monthly) ->
    reportText (renderMonthlyAccountsWithPresentation pres monthly)
  ReportHousehold section -> renderHouseholdSection section
  ReportEnvelopeChange baseline ->
    case householdEnvelopeChangeFromBaseline
        (contextObservationDay context) Nothing baseline state of
      Left err -> reportText
        (renderTemporalUnavailable pres (reportChoiceLabel (ReportEnvelopeChange baseline)) err)
      Right change -> reportText (renderEnvelopeChange pres baseline change)
  ReportEnvelopeChangeFromPreviousObservation previousObservation ->
    case householdEnvelopeChangeFromBaseline
        (contextObservationDay context)
        (Just previousObservation)
        PreviousObservation
        state of
      Left err -> reportText
        (renderTemporalUnavailable pres
          (reportChoiceLabel
            (ReportEnvelopeChangeFromPreviousObservation previousObservation))
          err)
      Right change -> reportText
        (renderEnvelopeChange pres PreviousObservation change)
  ReportEnvelopeChangeBetween from through ->
    case householdEnvelopeChangeFromBaseline through Nothing (ExplicitDay from) state of
      Left err -> reportText
        (renderTemporalUnavailable pres
          (reportChoiceLabel (ReportEnvelopeChangeBetween from through)) err)
      Right change -> reportText (renderEnvelopeChangeBetween pres change)
  ReportEnvelopeAlignedPreviousCycle ->
    case householdEnvelopeAlignedPreviousCycle (contextObservationDay context) state of
      Left err -> reportText
        (renderTemporalUnavailable pres "Envelope Comparison: Previous cycle" err)
      Right comparison -> reportText (renderEnvelopeCycleComparison pres comparison)
  ReportRecentTransactions -> withReportBook $ \(ReportBook _ _ _ _ recent _) ->
    reportText (renderRecentTransactionsWithPresentation pres recent)
  ReportCombinedBook -> withReportBook $ \book -> case householdSurface of
    Left err -> reportText ("Report surface error: " <> T.pack (show err))
    Right surface -> reportText
      (renderReportBookWithHouseholdPresentation pres book surface)
  where
    state = contextHouseholdState context
    reportConfig = householdStateReportConfig state
    pres = reportConfigurationPresentation reportConfig
    householdSurface = contextHouseholdReportSurface context
    resolvedReportBook = contextResolvedReportBook context
    withReportBook renderBook = case resolvedReportBook of
      Left err -> reportText ("Report plan error: " <> renderReportPlanError err)
      Right book -> renderBook book
    renderHouseholdSection section = case householdSurface of
      Left err -> reportText ("Report surface error: " <> T.pack (show err))
      Right surface -> reportText (renderHouseholdReportSection pres section surface)

renderEnvelopeChange
  :: PresentationConfig
  -> EnvelopeChangeBaseline
  -> HouseholdEnvelopeChange
  -> Text
renderEnvelopeChange presentation baseline =
  renderEnvelopeChangeWithBasis presentation
    ("Baseline request: " <> renderBaseline baseline)

renderEnvelopeChangeBetween
  :: PresentationConfig
  -> HouseholdEnvelopeChange
  -> Text
renderEnvelopeChangeBetween presentation =
  renderEnvelopeChangeWithBasis presentation
    "Selection: explicit Calendar FROM/THROUGH observations"

renderEnvelopeChangeWithBasis
  :: PresentationConfig
  -> Text
  -> HouseholdEnvelopeChange
  -> Text
renderEnvelopeChangeWithBasis presentation basis change = T.intercalate "\n"
  [ terminalHeaderWith presentation "Envelope Change"
  , terminalMeta basis
  , terminalMeta
      ("FROM observation: through " <> renderDay (householdEnvelopeChangeFrom change)
        <> " | THROUGH observation: through "
        <> renderDay (householdEnvelopeChangeThrough change))
  , terminalMeta
      "Meaning: each endpoint is a cumulative typed Envelope observation through that inclusive day."
  , terminalMeta
      "Diff: THROUGH minus FROM. Activity dated on the FROM day is already present in the FROM observation."
  , terminalMeta
      "Evidence: admitted Entitlement history, Actual, Plan, Expense routing, and Fulfillment routing."
  , terminalMeta
      "Scope: same Household cycle only; this view rereads no source and writes no canonical data."
  , ""
  , renderTerminalTable columns rows Nothing
  , ""
  ]
  where
    columns =
      [ ("Envelope", AlignLeft)
      , ("Entitlement diff", AlignRight)
      , ("Consumption diff", AlignRight)
      , ("Fulfillment diff", AlignRight)
      , ("Remaining diff", AlignRight)
      , ("Commitment diff", AlignRight)
      , ("Headroom diff", AlignRight)
      ]
    rows = map (renderEnvelopeChangeLine presentation)
      (householdEnvelopeChangeLines change)

renderEnvelopeChangeLine
  :: PresentationConfig
  -> EnvelopeChangeLine
  -> [Cell]
renderEnvelopeChangeLine presentation line =
  [ plainCell (envelopeIdText (envelopeChangeId line))
  , signedBalanceCellWith presentation (envelopeChangeEntitlement line)
  , signedBalanceCellWith presentation (envelopeChangeConsumptionNet line)
  , signedBalanceCellWith presentation (envelopeChangeFulfillmentNet line)
  , signedBalanceCellWith presentation (envelopeChangeRemaining line)
  , signedBalanceCellWith presentation (envelopeChangeCommitment line)
  , signedBalanceCellWith presentation (envelopeChangeHeadroom line)
  ]

renderEnvelopeCycleComparison
  :: PresentationConfig
  -> HouseholdEnvelopeCycleComparison
  -> Text
renderEnvelopeCycleComparison presentation comparison = T.intercalate "\n"
  [ terminalHeaderWith presentation "Envelope Previous-Cycle Comparison"
  , terminalMeta
      ("Current through: "
        <> renderDay (householdEnvelopeCycleComparisonCurrentThrough comparison)
        <> " | Previous aligned through: "
        <> renderDay (householdEnvelopeCycleComparisonBaselineThrough comparison))
  , terminalMeta "Activity is Period-bounded; positions are snapshots at the aligned observation days."
  , ""
  , terminalSectionWith presentation "Cycle activity"
  , renderTerminalTable activityColumns activityRows Nothing
  , ""
  , terminalSectionWith presentation "Aligned positions"
  , renderTerminalTable positionColumns positionRows Nothing
  , ""
  ]
  where
    lines' = householdEnvelopeCycleComparisonLines comparison
    activityColumns =
      [ ("Envelope", AlignLeft)
      , ("Use now", AlignRight)
      , ("Use prev", AlignRight)
      , ("Use diff", AlignRight)
      , ("Fulfill now", AlignRight)
      , ("Fulfill prev", AlignRight)
      , ("Fulfill diff", AlignRight)
      ]
    activityRows = map (renderActivityLine presentation) lines'
    positionColumns =
      [ ("Envelope", AlignLeft)
      , ("Entitlement now", AlignRight)
      , ("Prev", AlignRight)
      , ("Diff", AlignRight)
      , ("Remaining now", AlignRight)
      , ("Prev", AlignRight)
      , ("Diff", AlignRight)
      , ("Commitment now", AlignRight)
      , ("Prev", AlignRight)
      , ("Diff", AlignRight)
      , ("Headroom now", AlignRight)
      , ("Prev", AlignRight)
      , ("Diff", AlignRight)
      ]
    positionRows = map (renderPositionLine presentation) lines'

renderActivityLine
  :: PresentationConfig
  -> EnvelopeCycleComparisonLine
  -> [Cell]
renderActivityLine presentation line =
  [ plainCell (envelopeIdText (envelopeCycleComparisonId line))
  , signedBalanceCellWith presentation
      (consumptionNet (envelopeCycleCurrentConsumption line))
  , signedBalanceCellWith presentation
      (consumptionNet (envelopeCycleBaselineConsumption line))
  , signedBalanceCellWith presentation
      (envelopeCycleConsumptionNetDifference line)
  , signedBalanceCellWith presentation
      (fulfillmentNet (envelopeCycleCurrentFulfillment line))
  , signedBalanceCellWith presentation
      (fulfillmentNet (envelopeCycleBaselineFulfillment line))
  , signedBalanceCellWith presentation
      (envelopeCycleFulfillmentNetDifference line)
  ]

renderPositionLine
  :: PresentationConfig
  -> EnvelopeCycleComparisonLine
  -> [Cell]
renderPositionLine presentation line =
  [ plainCell (envelopeIdText (envelopeCycleComparisonId line))
  , signedBalanceCellWith presentation (envelopeCycleCurrentEntitlement line)
  , signedBalanceCellWith presentation (envelopeCycleBaselineEntitlement line)
  , signedBalanceCellWith presentation (envelopeCycleEntitlementDifference line)
  , signedBalanceCellWith presentation (envelopeCycleCurrentRemaining line)
  , signedBalanceCellWith presentation (envelopeCycleBaselineRemaining line)
  , signedBalanceCellWith presentation (envelopeCycleRemainingDifference line)
  , signedBalanceCellWith presentation (envelopeCycleCurrentCommitment line)
  , signedBalanceCellWith presentation (envelopeCycleBaselineCommitment line)
  , signedBalanceCellWith presentation (envelopeCycleCommitmentDifference line)
  , signedBalanceCellWith presentation (envelopeCycleCurrentHeadroom line)
  , signedBalanceCellWith presentation (envelopeCycleBaselineHeadroom line)
  , signedBalanceCellWith presentation (envelopeCycleHeadroomDifference line)
  ]

renderTemporalUnavailable
  :: Show error
  => PresentationConfig
  -> Text
  -> error
  -> Text
renderTemporalUnavailable presentation title err = T.intercalate "\n"
  [ terminalHeaderWith presentation title
  , terminalMeta "Status: NOT AVAILABLE"
  , terminalDim (T.pack (show err))
  , ""
  ]

renderBaseline :: EnvelopeChangeBaseline -> Text
renderBaseline baseline = case baseline of
  PreviousObservation -> "previous observation"
  PreviousDay -> "previous day"
  CycleStart -> "cycle start"
  ExplicitDay day -> renderDay day

renderDay :: Show day => day -> Text
renderDay = T.pack . show

renderReportPlanError :: ReportPlanError -> Text
renderReportPlanError errorValue = case errorValue of
  InvalidReportRange reportName start end ->
    "invalid " <> reportName <> " range: start " <> T.pack (show start)
      <> " is after end " <> T.pack (show end)
  CurrentCycleContextRequired reportName ->
    reportName
      <> " range current-cycle-to-date requires canonical Household cycle context"
  CurrentCycleObservationOutsidePeriod reportName observation ->
    reportName <> " current-cycle-to-date observation "
      <> T.pack (show observation) <> " is outside the resolved current cycle"

reportText :: Text -> Widget Name
reportText = ReportStyle.renderTerminalReport

cycleReport :: ReportChoice -> ReportChoice
cycleReport choice = case choice of
  ReportEnvelopeChangeFromPreviousObservation _ -> ReportEnvelopeAlignedPreviousCycle
  ReportEnvelopeChange (ExplicitDay _) -> ReportEnvelopeAlignedPreviousCycle
  ReportEnvelopeChange PreviousObservation -> ReportEnvelopeAlignedPreviousCycle
  ReportEnvelopeChangeBetween _ _ -> ReportEnvelopeAlignedPreviousCycle
  _ -> go reportChoices
  where
    go [] = ReportTrialBalance
    go [_] = ReportTrialBalance
    go (current : next : rest)
      | current == choice = next
      | otherwise = go (next : rest)

cycleReportBack :: ReportChoice -> ReportChoice
cycleReportBack choice = case choice of
  ReportEnvelopeChangeFromPreviousObservation _ -> ReportEnvelopeChange PreviousDay
  ReportEnvelopeChange (ExplicitDay _) -> ReportEnvelopeChange PreviousDay
  ReportEnvelopeChange PreviousObservation -> ReportEnvelopeChange PreviousDay
  ReportEnvelopeChangeBetween _ _ -> ReportEnvelopeChange PreviousDay
  _ -> case reverse reportChoices of
    [] -> ReportTrialBalance
    lastChoice : _ -> go lastChoice reportChoices
  where
    go previous [] = previous
    go previous (current : rest)
      | current == choice = previous
      | otherwise = go current rest

data WorkspaceAction
  = MaintainContext
  | OpenPicker

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext WorkspaceAction
handleWorkspaceEvent event =
  case Scroll.viewportWheelHandler ReportsViewport Scroll.VerticalAndHorizontal event of
    Just scroll -> scroll >> pure MaintainContext
    Nothing -> handleNonWheel event
  where
    handleNonWheel currentEvent = case currentEvent of
      VtyEvent (V.EvKey V.KEnter []) -> pure OpenPicker
      VtyEvent (V.EvKey V.KUp []) -> do
        vScrollBy reportsViewport (-1)
        pure MaintainContext
      VtyEvent (V.EvKey V.KDown []) -> do
        vScrollBy reportsViewport 1
        pure MaintainContext
      VtyEvent (V.EvKey V.KLeft [V.MShift]) -> do
        hScrollPage reportsViewport Up
        pure MaintainContext
      VtyEvent (V.EvKey V.KRight [V.MShift]) -> do
        hScrollPage reportsViewport Down
        pure MaintainContext
      VtyEvent (V.EvKey V.KLeft []) -> do
        hScrollBy reportsViewport (-4)
        pure MaintainContext
      VtyEvent (V.EvKey V.KRight []) -> do
        hScrollBy reportsViewport 4
        pure MaintainContext
      VtyEvent (V.EvKey V.KPageUp []) -> do
        vScrollPage reportsViewport Up
        pure MaintainContext
      VtyEvent (V.EvKey V.KPageDown []) -> do
        vScrollPage reportsViewport Down
        pure MaintainContext
      VtyEvent (V.EvKey V.KHome []) -> do
        vScrollToBeginning reportsViewport
        pure MaintainContext
      VtyEvent (V.EvKey V.KEnd []) -> do
        vScrollToEnd reportsViewport
        pure MaintainContext
      VtyEvent (V.EvKey (V.KChar key) []) -> do
        context <- get
        case reportSelectionForKey (contextSelectedReport context) key of
          Nothing -> pure MaintainContext
          Just report -> do
            modify (\ctx -> ctx { contextSelectedReport = report })
            vScrollToBeginning reportsViewport
            hScrollToBeginning reportsViewport
            pure MaintainContext
      _ -> pure MaintainContext
    reportsViewport = viewportScroll ReportsViewport
