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
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as Vec

import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , ReportChoice(..)
  , contextHouseholdState
  )
import qualified HKernel.Editor.TUI.ReportStyle as ReportStyle
import HKernel.Household.Application (HouseholdState(..))
import HKernel.Household.Report.Render
  ( HouseholdReportSection(..)
  , IssueVisibility(..)
  , renderHouseholdReportSection
  , renderReportBookWithHouseholdPresentation
  )
import HKernel.Render
  ( renderBalanceSheetWithPresentation
  , renderDailyFlowWithPresentation
  , renderMonthlyAccountsWithPresentation
  , renderProfitAndLossWithPresentation
  , renderRecentTransactionsWithPresentation
  , renderTrialBalanceWithPresentation
  )
import HKernel.Report (ReportBook(..))
import HKernel.Report.Config (reportConfigurationPresentation)
import HKernel.Report.Plan (ReportPlanError(..))

-- | Render the Reports section of the Household workspace. Report bodies stay
-- intentionally two-dimensional and retain horizontal scrolling; only the TUI
-- chrome wraps to the available terminal width.
drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ borderWithLabel (txt ("Household Report: " <> reportChoiceLabel selected))
        (viewport ReportsViewport Both (renderSelectedReport context))
    , strWrap "[Enter] Choose report   [wheel/↑↓←→] Scroll   [PgUp/PgDn] Page   [Shift+←→] Horizontal page"
    , strWrap "[Home/End] Top/Bottom   [r/R] Next/Previous report   [1-7] Switch section   [q] Quit"
    ]
  where
    selected = contextSelectedReport context

type PickerState = L.List Name ReportChoice

data PickerAction
  = PickerMaintain
  | PickerBack
  | PickerQuit
  | PickerOpen ReportChoice
  deriving (Eq, Show)

openPicker :: ReportChoice -> PickerState
openPicker selected =
  L.listMoveTo selectedIndex
    (L.list ReportPickerList (Vec.fromList reportChoices) 1)
  where
    selectedIndex = reportChoiceIndex selected

-- | Render the modal picker for the named Household reports.
drawPicker :: PickerState -> Widget Name
drawPicker choices =
  center
    (borderWithLabel (str "Choose Household Report")
      (hLimit 64
        (vLimit 22
          (padAll 1
            (L.renderList renderReportChoice True choices
              <=> str " "
              <=> strWrap "[wheel/↑/↓ or j/k] Move   [click/Enter] Open   [Esc] Back   [Q] Quit")))))

-- | Keep picker-local list movement and selection inside the Report owner.
-- Main only interprets the resulting application transition.
handlePickerEvent
  :: BrickEvent Name AppEvent
  -> EventM Name PickerState PickerAction
handlePickerEvent event = case event of
  MouseDown ReportPickerList V.BScrollUp _ _ -> do
    L.handleListEvent (V.EvKey V.KUp [])
    pure PickerMaintain
  MouseDown ReportPickerList V.BScrollDown _ _ -> do
    L.handleListEvent (V.EvKey V.KDown [])
    pure PickerMaintain
  MouseDown ReportPickerList V.BLeft _ (Location (_, row)) ->
    pure (maybe PickerMaintain PickerOpen (reportChoiceAt row))
  VtyEvent (V.EvKey V.KEsc []) -> pure PickerBack
  VtyEvent (V.EvKey (V.KChar 'q') []) -> pure PickerQuit
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure PickerQuit
  VtyEvent (V.EvKey V.KEnter []) -> do
    choices <- get
    pure $ case L.listSelectedElement choices of
      Nothing -> PickerBack
      Just (_, choice) -> PickerOpen choice
  VtyEvent vtyEvent -> do
    L.handleListEventVi L.handleListEvent vtyEvent
    pure PickerMaintain
  _ -> pure PickerMaintain

-- | Reports exposed by the interactive TUI. Object-oriented views such as
-- Actual history, Plans, and Issues stay in their owning workspace sections;
-- broader renderers remain available to CLI/export publication paths.
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

-- | Interpret only Report-specific direct-selection keys.
--
-- Application-shell keys such as section switching, scrolling, quitting, and
-- opening the picker remain owned by @Main@.
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

renderReportChoice :: Bool -> ReportChoice -> Widget Name
renderReportChoice selected choice
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = txt (reportChoiceLabel choice)

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
cycleReport choice = go reportChoices
  where
    go [] = ReportTrialBalance
    go [_] = ReportTrialBalance
    go (current : next : rest)
      | current == choice = next
      | otherwise = go (next : rest)

cycleReportBack :: ReportChoice -> ReportChoice
cycleReportBack choice = case reverse reportChoices of
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
handleWorkspaceEvent event = case event of
  MouseDown ReportsViewport V.BScrollUp _ _ -> do
    vScrollBy reportsViewport (-3)
    pure MaintainContext
  MouseDown ReportsViewport V.BScrollDown _ _ -> do
    vScrollBy reportsViewport 3
    pure MaintainContext
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
  where
    reportsViewport = viewportScroll ReportsViewport
