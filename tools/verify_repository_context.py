#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HUB = ROOT / "tools" / "hk"


def invoke(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(HUB), *args],
        cwd=ROOT,
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


def assert_contains(output: str, fragments: tuple[str, ...], label: str) -> None:
    missing = [fragment for fragment in fragments if fragment not in output]
    if missing:
        raise AssertionError(
            f"{label} was missing {missing!r}\n"
            f"output:\n{output}"
        )


def main() -> None:
    repository_map = invoke(["map"])
    assert_success(repository_map, "repository map")
    assert_contains(
        repository_map.stdout,
        (
            "cabal-components\n",
            "library h-kernel\n",
            "  public HKernel.Envelope.Remaining\n",
            "  internal HKernel.Engine.Facts\n",
            "test-suite h-kernel-test\n",
            "  main Spec.hs\n",
            "active-documents\n",
            "  architecture docs/ARCHITECTURE.md\n",
        ),
        "repository map",
    )

    context = invoke(["context", "HKernel.Envelope.Remaining"])
    assert_success(context, "repository context")
    assert_contains(
        context.stdout,
        (
            "query HKernel.Envelope.Remaining\n",
            "map-matches\n",
            "HKernel.Envelope.Remaining",
            "source-haskell\n",
            "src/HKernel/Envelope/Remaining.hs",
            "test-haskell\n",
            "tests/EnvelopeRemainingSpec.hs",
            "documents\n",
        ),
        "repository context",
    )

    invalid_map = invoke(["map", "extra"])
    if invalid_map.returncode != 2 or "does not accept arguments" not in invalid_map.stderr:
        raise AssertionError(
            "tools/hk map did not reject extra arguments\n"
            f"returncode={invalid_map.returncode}\n"
            f"stderr:\n{invalid_map.stderr}"
        )

    missing_context = invoke(["context"])
    if missing_context.returncode != 2 or "requires exactly one TERM" not in missing_context.stderr:
        raise AssertionError(
            "tools/hk context did not reject a missing term\n"
            f"returncode={missing_context.returncode}\n"
            f"stderr:\n{missing_context.stderr}"
        )

    empty_context = invoke(["context", ""])
    if empty_context.returncode != 2 or "non-empty TERM" not in empty_context.stderr:
        raise AssertionError(
            "tools/hk context did not reject an empty term\n"
            f"returncode={empty_context.returncode}\n"
            f"stderr:\n{empty_context.stderr}"
        )

    print("repository context verification passed")


if __name__ == "__main__":
    main()
