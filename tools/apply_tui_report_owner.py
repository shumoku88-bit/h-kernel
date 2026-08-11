#!/usr/bin/env python3
from pathlib import Path
import re

main_path = Path('editor-tui-app/Main.hs')
main = main_path.read_text()

main = main.replace('  , ReportChoice(..)\n', '  , ReportChoice\n', 1)
main = main.replace(
    'import qualified HKernel.Editor.TUI.ReportStyle as ReportStyle\n',
    'import qualified HKernel.Editor.TUI.Report as Report\n',
    1,
)

for block in [
    '''import HKernel.Render
  ( renderBalanceSheetWithPresentation
  , renderDailyFlowWithPresentation
  , renderMonthlyAccountsWithPresentation
  , renderProfitAndLossWithPresentation
  , renderRecentTransactionsWithPresentation
  , renderTrialBalanceWithPresentation
  )
''',
    'import HKernel.Report (ReportBook(..))\n',
    'import HKernel.Report.Plan (ReportPlanError(..))\n',
    '''import HKernel.Household.Report.Render
  ( HouseholdReportSection(..)
  , IssueVisibility(..)
  , renderHouseholdReportSection
  , renderReportBookWithHouseholdPresentation
  )
''',
]:
    if block not in main:
        raise SystemExit(f'expected report import block missing: {block!r}')
    main = main.replace(block, '', 1)

main = main.replace(
    'drawUI (AppWrapper _ (ReportPicker choices)) = [drawReportPicker choices]\n',
    'drawUI (AppWrapper _ (ReportPicker choices)) = [Report.drawPicker choices]\n',
    1,
)
main = main.replace(
    '  ReportsSection -> drawReportsView context\n',
    '  ReportsSection -> Report.drawWorkspace context\n',
    1,
)

main, count = re.subn(
    r'drawReportsView :: AppContext -> Widget Name\n.*?(?=drawSettingsView :: AppContext -> Widget Name\n)',
    '',
    main,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f'expected one Report presentation block, removed {count}')

old_keys = '''  VtyEvent (V.EvKey (V.KChar 't') [])
    | inReports -> selectReport ReportTrialBalance
  VtyEvent (V.EvKey (V.KChar 'b') [])
    | inReports -> selectReport ReportBalanceSheet
  VtyEvent (V.EvKey (V.KChar 'p') [])
    | inReports -> selectReport ReportProfitAndLoss
  VtyEvent (V.EvKey (V.KChar 'd') [])
    | inReports -> selectReport ReportDailyFlow
  VtyEvent (V.EvKey (V.KChar 'm') [])
    | inReports -> selectReport ReportMonthlyAccounts
  VtyEvent (V.EvKey (V.KChar 'c') [])
    | inReports -> selectReport (ReportHousehold HouseholdCycleAccounts)
  VtyEvent (V.EvKey (V.KChar 'T') [])
    | inReports -> selectReport (ReportHousehold HouseholdDailyTarget)
  VtyEvent (V.EvKey (V.KChar 'P') [])
    | inReports -> selectReport (ReportHousehold HouseholdPlannedTransactions)
  VtyEvent (V.EvKey (V.KChar 'E') [])
    | inReports -> selectReport (ReportHousehold HouseholdEnvelopeBacking)
  VtyEvent (V.EvKey (V.KChar 'a') [])
    | inReports -> selectReport ReportRecentTransactions
  VtyEvent (V.EvKey (V.KChar 'h') [])
    | inReports -> selectReport ReportCombinedBook
  VtyEvent (V.EvKey (V.KChar 'r') [])
    | inReports -> selectReport (cycleReport (contextSelectedReport context))
  VtyEvent (V.EvKey (V.KChar 'R') [])
    | inReports -> selectReport (cycleReportBack (contextSelectedReport context))
'''
new_keys = '''  VtyEvent (V.EvKey (V.KChar key) [])
    | inReports
    , Just report <- Report.reportSelectionForKey (contextSelectedReport context) key ->
        selectReport report
'''
if old_keys not in main:
    raise SystemExit('Report direct-key block not found')
main = main.replace(old_keys, new_keys, 1)

main = main.replace('Vec.fromList reportChoices', 'Vec.fromList Report.reportChoices', 1)
main = main.replace(
    'selectedIndex = reportChoiceIndex (contextSelectedReport context)',
    'selectedIndex = Report.reportChoiceIndex (contextSelectedReport context)',
    1,
)

old_click = '''  MouseDown ReportPickerList V.BLeft _ (Location (_, row)) ->
    case drop row reportChoices of
      [] -> pure ()
      choice : _ -> openChoice choice
'''
new_click = '''  MouseDown ReportPickerList V.BLeft _ (Location (_, row)) ->
    case Report.reportChoiceAt row of
      Nothing -> pure ()
      Just choice -> openChoice choice
'''
if old_click not in main:
    raise SystemExit('Report picker mouse block not found')
main = main.replace(old_click, new_click, 1)

main, count = re.subn(
    r'reportChoiceIndex :: ReportChoice -> Int\n.*?(?=handleReportPicker ::)',
    '',
    main,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f'expected one local reportChoiceIndex block, removed {count}')

main, count = re.subn(
    r'cycleReport :: ReportChoice -> ReportChoice\n.*?(?=app :: App AppWrapper AppEvent Name\n)',
    '',
    main,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f'expected Report cycling block, removed {count}')

# The Text type import belonged only to the extracted Report feature.
without_text_import = main.replace('import Data.Text (Text)\n', '', 1)
if re.search(r'\bText\b', without_text_import):
    pass
else:
    main = without_text_import

main_path.write_text(main)

cabal_path = Path('h-kernel.cabal')
cabal = cabal_path.read_text()
marker = '''                    , HKernel.Editor.TUI.Plan
                    , HKernel.Editor.TUI.ReportStyle
'''
replacement = '''                    , HKernel.Editor.TUI.Plan
                    , HKernel.Editor.TUI.Report
                    , HKernel.Editor.TUI.ReportStyle
'''
if marker not in cabal:
    raise SystemExit('TUI Cabal module marker not found')
cabal_path.write_text(cabal.replace(marker, replacement, 1))

print('updated Main.hs and h-kernel.cabal')
