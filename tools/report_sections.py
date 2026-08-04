#!/usr/bin/env python3
"""Normalize terminal reports and identify semantic report sections."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
HEADING = re.compile(r"^== (.+) ==$")

SECTION_KEYS = (
    ("envelope", "Envelope & Backing"),
    ("trial-balance", "Account Balances"),
    ("balance-sheet", "Balance Sheet"),
    ("profit-and-loss", "Profit & Loss"),
    ("daily-flow", "Daily Flow"),
    ("recent-transactions", "Recent Transactions"),
    ("monthly-accounts", "Monthly Accounts"),
    ("cycle-accounts", "Cycle Accounts"),
    ("daily-target", "Daily Target"),
    ("planned", "Planned"),
    ("issues", "Issues"),
)


def plain_text(path: Path) -> str:
    return ANSI.sub("", path.read_text(encoding="utf-8"))


def canonical_key(title: str) -> str:
    matches = [key for key, marker in SECTION_KEYS if marker in title]
    if len(matches) != 1:
        raise ValueError(f"unrecognized or ambiguous report heading: {title!r}")
    return matches[0]


def sections(text: str) -> dict[str, str]:
    result: dict[str, list[str]] = {}
    current: str | None = None
    for line in text.splitlines(keepends=True):
        match = HEADING.match(line.rstrip("\n"))
        if match:
            current = canonical_key(match.group(1))
            if current in result:
                raise ValueError(f"duplicate report section: {current}")
            result[current] = []
        if current is not None:
            result[current].append(line)
    return {key: "".join(lines) for key, lines in result.items()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("strip",))
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    args.destination.write_text(plain_text(args.source), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
