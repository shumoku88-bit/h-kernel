#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TUI_ROOT = ROOT / "editor-tui-app"
SCROLL_OWNER = TUI_ROOT / "HKernel" / "Editor" / "TUI" / "Scroll.hs"
RAW_WHEEL_TOKENS = ("BScrollUp", "BScrollDown")
VIEWPORT_PATTERN = re.compile(
    r"\bviewport\s+([A-Z][A-Za-z0-9_]*)\s+(Vertical|Horizontal|Both)\b"
)


def main() -> None:
    """Keep raw wheel translation centralized and every viewport wheel-aware."""
    findings: list[str] = []
    source_texts: dict[Path, str] = {
        path: path.read_text(encoding="utf-8")
        for path in sorted(TUI_ROOT.rglob("*.hs"))
    }

    for path, text in source_texts.items():
        if path == SCROLL_OWNER:
            continue
        for token in RAW_WHEEL_TOKENS:
            if token in text:
                findings.append(
                    f"{path.relative_to(ROOT)} owns raw {token}; route wheel input through HKernel.Editor.TUI.Scroll"
                )

    all_source = "\n".join(source_texts.values())
    for path, text in source_texts.items():
        for viewport_name, _axis in VIEWPORT_PATTERN.findall(text):
            expected = f"Scroll.viewportWheelHandler {viewport_name}"
            if expected not in all_source:
                findings.append(
                    f"{path.relative_to(ROOT)} declares viewport {viewport_name} without shared mouse-wheel policy"
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
