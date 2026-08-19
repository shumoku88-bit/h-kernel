#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import posixpath
from pathlib import Path, PurePosixPath
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[1]
MAP_TOOL = ROOT / "tools" / "repo-map"
CONTEXT_TOOL = ROOT / "tools" / "repo-context"
CABAL = os.environ.get("HKERNEL_CABAL", "cabal")
DOCUMENT_ROLES = {"policy", "architecture", "contract", "observation", "reference"}


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def invoke(tool: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return run([str(tool), *args])


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


def verify_generated_context() -> None:
    repository_map = invoke(MAP_TOOL, [])
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

    context = invoke(CONTEXT_TOOL, ["HKernel.Envelope.Remaining"])
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

    invalid_map = invoke(MAP_TOOL, ["extra"])
    if invalid_map.returncode == 0:
        raise AssertionError("tools/repo-map accepted an unexpected argument")

    missing_context = invoke(CONTEXT_TOOL, [])
    if missing_context.returncode != 2 or "requires exactly one TERM" not in missing_context.stderr:
        raise AssertionError(
            "tools/repo-context did not reject a missing term\n"
            f"returncode={missing_context.returncode}\n"
            f"stderr:\n{missing_context.stderr}"
        )

    empty_context = invoke(CONTEXT_TOOL, [""])
    if empty_context.returncode != 2 or "non-empty TERM" not in empty_context.stderr:
        raise AssertionError(
            "tools/repo-context did not reject an empty term\n"
            f"returncode={empty_context.returncode}\n"
            f"stderr:\n{empty_context.stderr}"
        )

    print("repository context verification passed")


def normalize_repository_path(raw: str, label: str) -> str:
    value = raw.replace("\\", "/")
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or ".." in parsed.parts:
        raise AssertionError(f"{label} produced invalid repository path {raw!r}")
    normalized = posixpath.normpath(value)
    if normalized in {"", "."} or normalized.startswith("../"):
        raise AssertionError(f"{label} produced invalid repository path {raw!r}")
    return normalized


def nul_paths(command: list[str], label: str) -> set[str]:
    result = run(command)
    assert_success(result, label)
    return {
        normalize_repository_path(path, label)
        for path in result.stdout.split("\0")
        if path
    }


def indexed_documents() -> set[str]:
    path = ROOT / "docs" / "INDEX.toml"
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    if set(data) != {"documents"} or not isinstance(data["documents"], list):
        raise AssertionError("docs/INDEX.toml must contain only [[documents]] entries")

    documents: set[str] = set()
    for index, entry in enumerate(data["documents"]):
        if not isinstance(entry, dict) or set(entry) != {"path", "role"}:
            raise AssertionError(
                f"docs/INDEX.toml documents[{index}] must contain exactly path and role"
            )
        document_path = entry["path"]
        role = entry["role"]
        if not isinstance(document_path, str) or not isinstance(role, str):
            raise AssertionError(
                f"docs/INDEX.toml documents[{index}] path and role must be strings"
            )
        if role not in DOCUMENT_ROLES:
            raise AssertionError(
                f"docs/INDEX.toml documents[{index}] has unknown role {role!r}"
            )

        normalized = normalize_repository_path(
            document_path, f"docs/INDEX.toml documents[{index}]"
        )
        parsed = PurePosixPath(normalized)
        if not normalized.startswith("docs/") or parsed.suffix != ".md":
            raise AssertionError(
                f"docs/INDEX.toml documents[{index}] has invalid document path {document_path!r}"
            )
        if normalized in documents:
            raise AssertionError(
                f"docs/INDEX.toml contains duplicate document path {document_path!r}"
            )
        documents.add(normalized)

    return documents


def verify_repository_ownership() -> None:
    tracked = nul_paths(["git", "ls-files", "-z"], "git tracked-file inventory")
    packaged = nul_paths(
        [CABAL, "sdist", "-v0", "--list-only", "--null-sep"],
        "Cabal source inventory",
    )
    indexed = indexed_documents()

    tracked_haskell = {
        path for path in tracked if path.endswith((".hs", ".lhs"))
    }
    tracked_documents = {
        path for path in tracked if path.startswith("docs/") and path.endswith(".md")
    }

    findings = [
        *(f"Cabal does not own tracked Haskell source: {path}"
          for path in sorted(tracked_haskell - packaged)),
        *(f"tracked Markdown document is absent from docs/INDEX.toml: {path}"
          for path in sorted(tracked_documents - indexed)),
        *(f"docs/INDEX.toml names a document that Git does not track: {path}"
          for path in sorted(indexed - tracked_documents)),
    ]
    if findings:
        raise AssertionError(
            "repository ownership findings:\n  - " + "\n  - ".join(findings)
        )

    print("repository ownership verification passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--ownership",
        action="store_true",
        help="verify Git/Cabal/docs ownership instead of generated context views",
    )
    args = parser.parse_args()

    if args.ownership:
        verify_repository_ownership()
    else:
        verify_generated_context()


if __name__ == "__main__":
    main()
