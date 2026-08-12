#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def invoke(
    binary: Path,
    base: Path,
    work: Path,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.pop("HKERNEL_LEDGER_DATA_DIR", None)
    env.pop("HKERNEL_REPORT_CONFIG", None)
    env["HKERNEL_LEDGER_DATA_DIR"] = str(base)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [str(binary), "trial-balance", "2026-07-31"],
        cwd=work,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def require_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0:
        raise AssertionError(
            f"{label} failed with {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: verify_household_report_config_resolution.py BINARY JOURNAL CONFIG",
            file=sys.stderr,
        )
        return 2

    binary, journal_fixture, config_fixture = (
        Path(value).resolve() for value in sys.argv[1:]
    )

    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary = Path(temporary_directory)
        base = temporary / "household root"
        work = temporary / "working directory"
        base.mkdir()
        work.mkdir()

        shutil.copyfile(journal_fixture, base / "actual.journal")
        shutil.copyfile(config_fixture, work / "report.toml")

        root_config = base / "report.toml"
        root_config.write_text("[reports.trial-balance\n", encoding="utf-8")

        discovered = invoke(binary, base, work)
        if discovered.returncode == 0:
            raise AssertionError(
                "Household root report.toml did not take precedence over cwd report.toml"
            )
        if "report configuration failed" not in discovered.stderr:
            raise AssertionError(
                "Household root report.toml failure was not reported as configuration admission"
            )
        if str(root_config) not in discovered.stderr:
            raise AssertionError(
                "Household root report.toml path was not named in the admission failure"
            )

        explicit = temporary / "explicit-report.toml"
        shutil.copyfile(config_fixture, explicit)
        overridden = invoke(
            binary,
            base,
            work,
            {"HKERNEL_REPORT_CONFIG": str(explicit)},
        )
        require_success(overridden, "explicit HKERNEL_REPORT_CONFIG override")

        root_config.unlink()
        fallback = invoke(binary, base, work)
        require_success(fallback, "cwd report.toml fallback")

    print("household report config resolution verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
