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
    # Verify that shell script does not perform field inputs for Plan/Budget/Issue
    hk_content = HUB.read_text(encoding="utf-8")
    for forbidden in ["prompt_input", "pargs", "optargs", "run_editor_cli"]:
        if forbidden in hk_content:
            raise AssertionError(f"tools/hk contains removed prompt/field helper: {forbidden}")

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
            "#!/bin/sh\n"
            "if [ \"${1:-}\" = sdist ]; then\n"
            "  set -- cabal \"$@\"\n"
            + logger
            + "  git ls-files -z\n"
            "  exit 0\n"
            "fi\n"
            "set -- cabal \"$@\"\n"
            + logger,
        )

        base_env = os.environ.copy()
        base_env.pop("HKERNEL_LEDGER_DATA_DIR", None)
        base_env.update(
            {
                "HKERNEL_REPORT_COMMAND": str(report_stub),
                "HKERNEL_CABAL": str(cabal_stub),
                "HKERNEL_HUB_LOG": str(log),
            }
        )

        # 1. Non-interactive no-arg execution must reject immediately
        result = invoke([], base_env)
        if result.returncode != 2 or "requires a TTY" not in result.stderr:
            raise AssertionError(
                "Non-TTY no-arg execution did not fail with TTY requirement\n"
                f"returncode={result.returncode}\nstderr:\n{result.stderr}"
            )

        # 2. Report routing & argument preservation
        log.write_text("", encoding="utf-8")
        result = invoke(["report", "all", "2026-08-06"], base_env)
        assert_success(result, "explicit report")
        if read_log(log) != ["report <all> <2026-08-06>"]:
            raise AssertionError(f"report arguments differed: {read_log(log)!r}")

        # 3. Data directory resolution order: --base > HKERNEL_LEDGER_DATA_DIR > ledger-data.local
        data_dir_1 = temporary / "dir1 with space"
        data_dir_2 = temporary / "dir2 with space"
        data_dir_1.mkdir()
        data_dir_2.mkdir()
        (data_dir_1 / "actual.journal").write_text("2026-08-01 header\n", encoding="utf-8")
        (data_dir_2 / "actual.journal").write_text("2026-08-02 header\n", encoding="utf-8")

        env_with_data = base_env.copy()
        env_with_data["HKERNEL_LEDGER_DATA_DIR"] = str(data_dir_2)

        # 3a. Fallback to HKERNEL_LEDGER_DATA_DIR for actual-add without explicit file arg
        log.write_text("", encoding="utf-8")
        result = invoke(["actual-add"], env_with_data)
        assert_success(result, "Actual add with env data dir")
        if read_log(log) != [f"cabal <run> <exe:h-kernel-editor-tui> <--> <{data_dir_2 / 'actual.journal'}>"]:
            raise AssertionError(f"Actual add fallback to env dir failed: {read_log(log)!r}")

        # 3b. --base takes precedence over HKERNEL_LEDGER_DATA_DIR (testing path with space)
        log.write_text("", encoding="utf-8")
        result = invoke(["--base", str(data_dir_1), "actual-add"], env_with_data)
        assert_success(result, "Actual add with --base override")
        if read_log(log) != [f"cabal <run> <exe:h-kernel-editor-tui> <--> <{data_dir_1 / 'actual.journal'}>"]:
            raise AssertionError(f"Actual add --base precedence failed: {read_log(log)!r}")

        # 4. Routing for all direct subcommands (preserving argument boundaries and space)
        log.write_text("", encoding="utf-8")
        result = invoke(["actual-multi", "actual.journal", "2026-08-06", "transfer", "Assets:Bank:A", "-1000", "JPY", "Assets:Bank:B", "1000", "JPY"], base_env)
        assert_success(result, "actual-multi delegation")
        if read_log(log) != ["cabal <run> <exe:h-kernel-editor-cli> <--> <append> <actual.journal> <2026-08-06> <transfer> <Assets:Bank:A> <-1000> <JPY> <Assets:Bank:B> <1000> <JPY>"]:
            raise AssertionError(f"actual-multi delegation differed: {read_log(log)!r}")

        log.write_text("", encoding="utf-8")
        result = invoke(["actual-reverse", "--commit", "actual.journal", "rev-id", "tgt-id", "2026-08-06", "reversal"], base_env)
        assert_success(result, "actual-reverse delegation")
        if read_log(log) != ["cabal <run> <exe:h-kernel-editor-cli> <--> <reverse> <--commit> <actual.journal> <rev-id> <tgt-id> <2026-08-06> <reversal>"]:
            raise AssertionError(f"actual-reverse delegation differed: {read_log(log)!r}")

        log.write_text("", encoding="utf-8")
        result = invoke(["account", "actual.journal", "Assets:Saving", "asset", "JPY"], base_env)
        assert_success(result, "account delegation")
        if read_log(log) != ["cabal <run> <exe:h-kernel-editor-cli> <--> <account> <actual.journal> <Assets:Saving> <asset> <JPY>"]:
            raise AssertionError(f"account delegation differed: {read_log(log)!r}")

        # 4a. Plan direct command preserving "plan" and "add" as separate arguments
        log.write_text("", encoding="utf-8")
        result = invoke(["plan", "add", "plan.journal", "actual.journal", "--date", "2026-08-06", "--description", "desc", "--posting", "Assets:Cash", "500", "JPY"], base_env)
        assert_success(result, "plan delegation")
        if read_log(log) != ["cabal <run> <exe:h-kernel-editor-cli> <--> <plan> <add> <plan.journal> <actual.journal> <--date> <2026-08-06> <--description> <desc> <--posting> <Assets:Cash> <500> <JPY>"]:
            raise AssertionError(f"plan delegation differed: {read_log(log)!r}")

        log.write_text("", encoding="utf-8")
        result = invoke(["entitlement", "entitlement.journal", "2026-08-06", "memo", "unallocated", "daily", "1000", "JPY"], base_env)
        assert_success(result, "entitlement delegation")
        if read_log(log) != ["cabal <run> <exe:h-kernel-editor-cli> <--> <entitlement> <entitlement.journal> <2026-08-06> <memo> <unallocated> <daily> <1000> <JPY>"]:
            raise AssertionError(f"entitlement delegation differed: {read_log(log)!r}")

        log.write_text("", encoding="utf-8")
        result = invoke(["issue", "issues.tsv", "ISS-1", "open", "2026-08-06", "cat", "title", "-", "-", "details"], base_env)
        assert_success(result, "issue delegation")
        if read_log(log) != ["cabal <run> <exe:h-kernel-editor-cli> <--> <issue> <issues.tsv> <ISS-1> <open> <2026-08-06> <cat> <title> <-> <-> <details>"]:
            raise AssertionError(f"issue delegation differed: {read_log(log)!r}")

        log.write_text("", encoding="utf-8")
        result = invoke(["edit", "append", "actual.journal", "coffee shop"], base_env)
        assert_success(result, "edit delegation")
        if read_log(log) != ["cabal <run> <exe:h-kernel-editor-cli> <--> <append> <actual.journal> <coffee shop>"]:
            raise AssertionError(f"edit delegation differed: {read_log(log)!r}")

        log.write_text("", encoding="utf-8")
        result = invoke(["check"], base_env)
        assert_success(result, "repository check")
        if read_log(log) != [
            "cabal <build> <all>",
            "cabal <test> <all>",
            "cabal <sdist> <-v0> <--list-only> <--null-sep>",
        ]:
            raise AssertionError(f"check delegation differed: {read_log(log)!r}")

        log.write_text("", encoding="utf-8")
        result = invoke(["--base", str(data_dir_1), "check-household"], base_env)
        assert_success(result, "private Household check")
        if read_log(log) != ["cabal <run> <exe:h-kernel> <--> <all>"]:
            raise AssertionError(f"check-household delegation differed: {read_log(log)!r}")

        # 5. Help surface check
        result = invoke(["help"], base_env)
        assert_success(result, "help")
        expected_help_entries = (
            "tools/hk [--base DIR] report",
            "tools/hk [--base DIR] actual-add",
            "tools/hk [--base DIR] actual-multi",
            "tools/hk [--base DIR] actual-reverse",
            "tools/hk [--base DIR] account",
            "tools/hk [--base DIR] plan",
            "tools/hk [--base DIR] entitlement",
            "tools/hk [--base DIR] issue",
            "tools/hk [--base DIR] edit",
            "tools/hk check",
            "tools/hk check-report",
            "tools/hk [--base DIR] check-household",
        )
        if not all(entry in result.stdout for entry in expected_help_entries):
            raise AssertionError(f"help surface incomplete:\n{result.stdout}")

        # 6. Error handling checks
        result = invoke(["unknown"], base_env)
        if result.returncode != 2 or "unknown tools/hk command" not in result.stderr:
            raise AssertionError("unknown command did not fail as expected")

        result = invoke(["actual-add", "one", "two"], base_env)
        if result.returncode != 2 or "accepts at most one" not in result.stderr:
            raise AssertionError("actual-add extra path argument rejection failed")

        result = invoke(["check", "extra"], base_env)
        if result.returncode != 2 or "does not accept arguments" not in result.stderr:
            raise AssertionError("check argument rejection failed")

        result = invoke(["check-report", "extra"], base_env)
        if result.returncode != 2 or "does not accept arguments" not in result.stderr:
            raise AssertionError("check-report argument rejection failed")

        result = invoke(["check-household", "extra"], env_with_data)
        if result.returncode != 2 or "does not accept arguments" not in result.stderr:
            raise AssertionError("check-household argument rejection failed")

    print("daily command hub verification passed")


if __name__ == "__main__":
    main()
