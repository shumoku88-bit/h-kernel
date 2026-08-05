#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HUB = ROOT / "tools" / "hk"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def invoke(args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(HUB), *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def assert_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0:
        raise AssertionError(
            f"{label} failed with {result.returncode}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )


def read_log(path: Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8").splitlines()


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary = Path(temporary_directory)
        log = temporary / "delegation.log"
        report_stub = temporary / "report-stub"
        cabal_stub = temporary / "cabal-stub"

        logger = (
            "printf '%s' \"$1\" >> \"$HKERNEL_HUB_LOG\"\n"
            "shift\n"
            "for argument do\n"
            "  printf ' <%s>' \"$argument\" >> \"$HKERNEL_HUB_LOG\"\n"
            "done\n"
            "printf '\\n' >> \"$HKERNEL_HUB_LOG\"\n"
        )
        write_executable(
            report_stub,
            "#!/bin/sh\nset -- report \"$@\"\n" + logger,
        )
        write_executable(
            cabal_stub,
            "#!/bin/sh\nset -- cabal \"$@\"\n" + logger,
        )

        env = os.environ.copy()
        env.update(
            {
                "HKERNEL_REPORT_COMMAND": str(report_stub),
                "HKERNEL_CABAL": str(cabal_stub),
                "HKERNEL_HUB_LOG": str(log),
            }
        )

        result = invoke([], env)
        assert_success(result, "default report")
        if read_log(log) != ["report"]:
            raise AssertionError(f"default report delegation differed: {read_log(log)!r}")

        log.write_text("", encoding="utf-8")
        result = invoke(["report", "all", "2026-08-06"], env)
        assert_success(result, "explicit report")
        if read_log(log) != ["report <all> <2026-08-06>"]:
            raise AssertionError(f"report arguments differed: {read_log(log)!r}")

        log.write_text("", encoding="utf-8")
        result = invoke(["edit", "append", "actual.journal", "coffee shop"], env)
        assert_success(result, "editor delegation")
        expected_editor = [
            "cabal <run> <exe:h-kernel-editor-cli> <--> <append> "
            "<actual.journal> <coffee shop>"
        ]
        if read_log(log) != expected_editor:
            raise AssertionError(f"editor arguments differed: {read_log(log)!r}")

        log.write_text("", encoding="utf-8")
        result = invoke(["check"], env)
        assert_success(result, "repository check")
        expected_check = [
            "cabal <build> <all>",
            "cabal <test> <all>",
            "cabal <run> <exe:repository-audit>",
        ]
        if read_log(log) != expected_check:
            raise AssertionError(f"check delegation differed: {read_log(log)!r}")

        result = invoke(["help"], env)
        assert_success(result, "help")
        if "tools/hk report" not in result.stdout or "tools/hk edit" not in result.stdout:
            raise AssertionError(f"help surface incomplete:\n{result.stdout}")

        result = invoke(["unknown"], env)
        if result.returncode != 2 or "unknown tools/hk command" not in result.stderr:
            raise AssertionError(
                "unknown command did not fail with the documented boundary\n"
                f"returncode={result.returncode}\nstderr:\n{result.stderr}"
            )

        result = invoke(["check", "extra"], env)
        if result.returncode != 2 or "does not accept arguments" not in result.stderr:
            raise AssertionError(
                "check argument rejection differed\n"
                f"returncode={result.returncode}\nstderr:\n{result.stderr}"
            )

    print("daily command hub verification passed")


if __name__ == "__main__":
    main()
