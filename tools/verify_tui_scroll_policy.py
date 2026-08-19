#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TUI_ROOT = ROOT / "editor-tui-app"
SCROLL_OWNER = TUI_ROOT / "HKernel" / "Editor" / "TUI" / "Scroll.hs"
RAW_WHEEL_TOKENS = ("BScrollUp", "BScrollDown")


def main() -> None:
    findings: list[str] = []
    for path in sorted(TUI_ROOT.rglob("*.hs")):
        if path == SCROLL_OWNER:
            continue
        text = path.read_text(encoding="utf-8")
        for token in RAW_WHEEL_TOKENS:
            if token in text:
                findings.append(
                    f"{path.relative_to(ROOT)} owns raw {token}; route wheel input through HKernel.Editor.TUI.Scroll"
                )

    if findings:
        raise AssertionError(
            "TUI scroll ownership findings:\n  - " + "\n  - ".join(findings)
        )

    owner_text = SCROLL_OWNER.read_text(encoding="utf-8")
    for token in RAW_WHEEL_TOKENS:
        if token not in owner_text:
            raise AssertionError(
                f"scroll owner no longer handles required raw token {token}"
            )

    print("TUI scroll ownership verification passed")


if __name__ == "__main__":
    main()
