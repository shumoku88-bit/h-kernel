from pathlib import Path
import re

render_path = Path('src/HKernel/Render.hs')
render = render_path.read_text()

old = '''renderReportBookWithPresentation
  :: PresentationConfig
  -> ReportBook
  -> Text
renderReportBookWithPresentation presentation report =
  T.intercalate "\\n"
    [ renderReportBookCoreWithPresentation presentation report
    , renderUnavailableCycleAccounts presentation
    , renderUnavailableDailyTarget presentation
    , renderUnavailablePlannedTransactions presentation
    , renderUnavailableHouseholdIssues presentation
    , renderUnavailableEnvelopeBacking presentation
    ]
'''
new = '''renderReportBookWithPresentation
  :: PresentationConfig
  -> ReportBook
  -> Text
renderReportBookWithPresentation = renderReportBookCoreWithPresentation
'''
if old not in render:
    raise SystemExit('combined ReportBook renderer block not found')
render = render.replace(old, new, 1)

render, count = re.subn(
    r'''\n-- These sections deliberately complete the observable household surface without\n-- manufacturing domain facts\. Each message names the evidence still missing\.\nrenderUnavailableCycleAccounts :: PresentationConfig -> Text\n.*?\nunavailableSection presentation title reason = T\.intercalate "\\n"\n  \[ terminalHeaderWith presentation title\n  , terminalMeta "Status: NOT IMPLEMENTED"\n  , terminalDim reason\n  , ""\n  \]\n''',
    '\n',
    render,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f'expected one obsolete Household placeholder block, removed {count}')
render_path.write_text(render)

spec_path = Path('tests/ReportBookSpec.hs')
spec = spec_path.read_text()

spec = spec.replace(
    '''  assertEqual
    "configured heading color reaches combined report headings"
    True
    ("\\ESC[1;34m== Account Balances (h-kernel Engine) ==\\ESC[0m"
      `T.isInfixOf` renderedWithPresentation
      && "\\ESC[1;34m== Envelope & Backing ==\\ESC[0m"
        `T.isInfixOf` renderedWithPresentation)
''',
    '''  assertEqual
    "configured heading color reaches combined Journal report headings"
    True
    ("\\ESC[1;34m== Account Balances (h-kernel Engine) ==\\ESC[0m"
      `T.isInfixOf` renderedWithPresentation
      && "\\ESC[1;34m== Monthly Accounts (Account × Month) ==\\ESC[0m"
        `T.isInfixOf` renderedWithPresentation)
''',
    1,
)

old_missing = '''  assertEqual
    "missing household semantics remain explicit instead of looking empty"
    True
    ("== Daily Target ==" `T.isInfixOf` renderedWithPresentation
      && "Status: NOT IMPLEMENTED" `T.isInfixOf` renderedWithPresentation
      && "Status: NOT AVAILABLE IN COMBINED REPORT"
        `T.isInfixOf` renderedWithPresentation)
'''
new_missing = '''  assertEqual
    "Journal-only ReportBook does not manufacture Household sections"
    False
    (any (`T.isInfixOf` renderedWithPresentation)
      [ "== Cycle Accounts & Comparison Matrix =="
      , "== Daily Target =="
      , "== Planned Transactions =="
      , "== Household Issues =="
      , "== Envelope & Backing =="
      ])
'''
if old_missing not in spec:
    raise SystemExit('obsolete missing-Household assertion not found')
spec = spec.replace(old_missing, new_missing, 1)

old_headings = '''expectedHeadings =
  [ "\\ESC[1;36m== Account Balances (h-kernel Engine) ==\\ESC[0m"
  , "\\ESC[1;36m== Balance Sheet (h-kernel Engine) ==\\ESC[0m"
  , "\\ESC[1;36m== Profit & Loss Statement (h-kernel Engine) ==\\ESC[0m"
  , "\\ESC[1;36m== Daily Flow (Category × Date) ==\\ESC[0m"
  , "\\ESC[1;36m== Recent Transactions (Last 5 Transactions) ==\\ESC[0m"
  , "\\ESC[1;36m== Monthly Accounts (Account × Month) ==\\ESC[0m"
  , "\\ESC[1;36m== Cycle Accounts & Comparison Matrix ==\\ESC[0m"
  , "\\ESC[1;36m== Daily Target ==\\ESC[0m"
  , "\\ESC[1;36m== Planned Transactions ==\\ESC[0m"
  , "\\ESC[1;36m== Household Issues ==\\ESC[0m"
  , "\\ESC[1;36m== Envelope & Backing ==\\ESC[0m"
  ]
'''
new_headings = '''expectedHeadings =
  [ "\\ESC[1;36m== Account Balances (h-kernel Engine) ==\\ESC[0m"
  , "\\ESC[1;36m== Balance Sheet (h-kernel Engine) ==\\ESC[0m"
  , "\\ESC[1;36m== Profit & Loss Statement (h-kernel Engine) ==\\ESC[0m"
  , "\\ESC[1;36m== Daily Flow (Category × Date) ==\\ESC[0m"
  , "\\ESC[1;36m== Recent Transactions (Last 5 Transactions) ==\\ESC[0m"
  , "\\ESC[1;36m== Monthly Accounts (Account × Month) ==\\ESC[0m"
  ]
'''
if old_headings not in spec:
    raise SystemExit('expected heading block not found')
spec = spec.replace(old_headings, new_headings, 1)
spec_path.write_text(spec)

# Keep the change intentionally small.
changed = [render_path, spec_path]
for path in changed:
    print(path)
