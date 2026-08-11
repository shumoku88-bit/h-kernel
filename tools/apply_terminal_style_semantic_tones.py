#!/usr/bin/env python3
from pathlib import Path

style_path = Path('src/HKernel/Render/TerminalStyle.hs')
style = style_path.read_text()

replacements = [
    ('  , greenBalanceCell\n', ''),
    ('  , redBalanceCell\n', ''),
    ('  , greenBalanceCellWith\n', '  , positiveBalanceCellWith\n'),
    ('  , redBalanceCellWith\n', '  , negativeBalanceCellWith\n'),
    ('  , terminalRedWith\n', ''),
    ('  , renderBalanceGreen\n', ''),
    ('  , renderBalanceRed\n', ''),
    ('  , renderBalanceGreenWith\n', ''),
    ('  , renderBalanceRedWith\n', ''),
]
for old, new in replacements:
    if old not in style:
        raise SystemExit(f'expected export not found: {old!r}')
    style = style.replace(old, new, 1)

old = '''terminalRedWith :: PresentationColor -> Text -> Text
terminalRedWith = terminalColor

'''
if old not in style:
    raise SystemExit('unused terminalRedWith definition not found')
style = style.replace(old, '', 1)

old = '''greenBalanceCell :: Balance -> Cell
greenBalanceCell = greenBalanceCellWith defaultPresentationConfig

redBalanceCell :: Balance -> Cell
redBalanceCell = redBalanceCellWith defaultPresentationConfig

'''
if old not in style:
    raise SystemExit('legacy unconfigured color cell wrappers not found')
style = style.replace(old, '', 1)

old = '''greenBalanceCellWith :: PresentationConfig -> Balance -> Cell
greenBalanceCellWith config =
  balanceCell config (PositiveTone (presentationPositiveAmountColor config))

redBalanceCellWith :: PresentationConfig -> Balance -> Cell
redBalanceCellWith config =
  balanceCell config (NegativeTone (presentationNegativeAmountColor config))
'''
new = '''positiveBalanceCellWith :: PresentationConfig -> Balance -> Cell
positiveBalanceCellWith config =
  balanceCell config (PositiveTone (presentationPositiveAmountColor config))

negativeBalanceCellWith :: PresentationConfig -> Balance -> Cell
negativeBalanceCellWith config =
  balanceCell config (NegativeTone (presentationNegativeAmountColor config))
'''
if old not in style:
    raise SystemExit('configured color cell definitions not found')
style = style.replace(old, new, 1)

old = '''renderBalanceGreen :: Balance -> Text
renderBalanceGreen = cellStyled . greenBalanceCell

renderBalanceRed :: Balance -> Text
renderBalanceRed = cellStyled . redBalanceCell

'''
if old not in style:
    raise SystemExit('legacy unconfigured render wrappers not found')
style = style.replace(old, '', 1)

old = '''renderBalanceGreenWith :: PresentationConfig -> Balance -> Text
renderBalanceGreenWith config = cellStyled . greenBalanceCellWith config

renderBalanceRedWith :: PresentationConfig -> Balance -> Text
renderBalanceRedWith config = cellStyled . redBalanceCellWith config

'''
if old not in style:
    raise SystemExit('legacy configured render wrappers not found')
style = style.replace(old, '', 1)

style_path.write_text(style)

render_path = Path('src/HKernel/Render.hs')
render = render_path.read_text()
for old, new in [
    ('greenBalanceCellWith', 'positiveBalanceCellWith'),
    ('redBalanceCellWith', 'negativeBalanceCellWith'),
]:
    if old not in render:
        raise SystemExit(f'expected renderer use not found: {old}')
    render = render.replace(old, new)
render_path.write_text(render)

# The remaining literal colour names are fixed status/palette implementation,
# not amount-tone API vocabulary.
for stale in [
    'greenBalanceCell', 'redBalanceCell',
    'renderBalanceGreen', 'renderBalanceRed', 'terminalRedWith',
]:
    for path in [style_path, render_path]:
        if stale in path.read_text():
            raise SystemExit(f'stale amount color API name {stale} remains in {path}')

print('renamed configured amount-tone cells and removed unused color wrappers')
