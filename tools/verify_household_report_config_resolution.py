#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HUB = ROOT / "tools" / "hk"


def invoke(base: Path, report_stub: Path, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.pop("HKERNEL_LEDGER_DATA_DIR", None)
    env.pop("HKERNEL_REPORT_CONFIG", None)
    env["HKERNEL_REPORT_COMMAND"] = str(report_stub)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [str(HUB), "--base", str(base), "report", "all"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def require_success(result: subprocess.CompletedProcess[str]) -> str:
    if result.returncode != 0:
        raise AssertionError(
            f"report delegation failed with {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result.stdout.strip()


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary = Path(temporary_directory)
        base = temporary / "household root"
        base.mkdir()
        report_config = base / "report.toml"
        report_config.write_text("[reports]\n", encoding="utf-8")

        report_stub = temporary / "report-stub"
        report_stub.write_text(
            "#!/bin/sh\n"
            "printf 'data=%s\\n' \"${HKERNEL_LEDGER_DATA_DIR-}\"\n"
            "printf 'report=%s\\n' \"${HKERNEL_REPORT_CONFIG-}\"\n",
            encoding="utf-8",
        )
        report_stub.chmod(0o755)

        discovered = require_success(invoke(base, report_stub))
        expected = f"data={base}\nreport={report_config}"
        if discovered != expected:
            raise AssertionError(
                f"household report.toml discovery differed:\n{discovered!r}"
            )

        explicit = temporary / "explicit-report.toml"
        preserved = require_success(
            invoke(
                base,
                report_stub,
                {"HKERNEL_REPORT_CONFIG": str(explicit)},
            )
        )
        expected = f"data={base}\nreport={explicit}"
        if preserved != expected:
            raise AssertionError(
                f"explicit HKERNEL_REPORT_CONFIG was not preserved:\n{preserved!r}"
            )

        report_config.unlink()
        absent = require_success(invoke(base, report_stub))
        expected = f"data={base}\nreport="
        if absent != expected:
            raise AssertionError(
                f"missing household report.toml did not preserve fallback:\n{absent!r}"
            )

    print("household report config resolution verification passed")


if __name__ == "__main__":
    main()
