#!/usr/bin/env python3
from pathlib import Path

path = Path('editor-tui-app/Main.hs')
text = path.read_text()
marker = 'drawSettingsView :: AppContext -> Widget Name\n'
if marker not in text:
    raise SystemExit('Settings marker not found')
if 'drawPlanBudgetSyncPicker\n' in text:
    raise SystemExit('Plan Budget sync picker already present')

block = '''drawPlanBudgetSyncPicker
  :: L.List Name HKernel.Plan.Journal.IdentifiedPlanTransaction
  -> Widget Name
drawPlanBudgetSyncPicker plans =
  center
    (borderWithLabel (str "Retry completed Plan Budget sync")
      (hLimit 86
        (vLimit 24
          (padAll 1
            ( L.renderList renderCompletedPlan True plans
              <=> str " "
              <=> str "[wheel/↑/↓ or j/k] Move   [Enter] Retry sync   [Esc] Back   [Q] Quit")))))

renderCompletedPlan :: Bool -> HKernel.Plan.Journal.IdentifiedPlanTransaction -> Widget Name
renderCompletedPlan selected identified
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    transaction = HKernel.Plan.Journal.identifiedPlanTransaction identified
    row = txt
      ( T.pack (show (HKernel.Ledger.transactionDate transaction))
        <> "  " <> HKernel.Ledger.transactionDescription transaction
        <> "  [" <> planIdText (HKernel.Plan.Journal.identifiedPlanId identified) <> "]"
      )

'''
path.write_text(text.replace(marker, block + marker, 1))
