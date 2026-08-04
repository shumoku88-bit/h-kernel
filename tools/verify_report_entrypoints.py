#!/usr/bin/env python3
"""Verify that configured all and standalone reports share presentation output."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

from report_sections import ANSI, sections

REPORTS = {
    "trial-balance": ["trial-balance", "2026-07-31"],
    "balance-sheet": ["balance-sheet", "2026-07-31"],
    "profit-and-loss": ["profit-and-loss", "2026-07-01", "2026-07-31"],
    "daily-flow": ["daily-flow", "2026-07-01", "2026-07-31"],
    "recent-transactions": ["recent-transactions", "2026-07-31"],
    "monthly-accounts": ["monthly-accounts", "2026-07-01", "2026-07-31"],
}


def run(binary: Path, journal: Path, arguments: list[str], config: Path) -> str:
    environment = os.environ.copy()
    environment["HKERNEL_REPORT_CONFIG"] = str(config)
    with tempfile.TemporaryDirectory(prefix="h_kernel-report-entrypoint-") as work:
        completed = subprocess.run(
            [str(binary), str(journal), *arguments],
            cwd=work,
            env=environment,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    return ANSI.sub("", completed.stdout)


def payload(text: str) -> str:
    return text.rstrip("\n") + "\n"


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: verify_report_entrypoints.py BINARY JOURNAL CONFIG",
            file=sys.stderr,
        )
        return 2

    binary, journal, config = (Path(value).resolve() for value in sys.argv[1:])
    all_output = run(binary, journal, ["all", "2026-07-31"], config)
    all_sections = sections(all_output)

    for key, arguments in REPORTS.items():
        standalone = sections(run(binary, journal, arguments, config))
        if set(standalone) != {key}:
            raise RuntimeError(
                f"standalone {key} emitted unexpected sections: {sorted(standalone)}"
            )
        if payload(all_sections[key]) != payload(standalone[key]):
            raise RuntimeError(f"all/standalone presentation differs: {key}")
        print(f"[MATCH] {key}")

    if "-10,000 JPY" not in all_output or "(10,000 JPY)" in all_output:
        raise RuntimeError("configured minus notation was not shared by all")
    if "Max date columns: 5" not in all_sections["daily-flow"]:
        raise RuntimeError("configured Daily Flow columns were not shared")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
