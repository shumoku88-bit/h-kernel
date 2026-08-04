#!/usr/bin/env python3
"""Verify every immutable report-corpus file against its SHA-256 manifest."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_report_corpus.py MANIFEST", file=sys.stderr)
        return 2
    manifest = Path(sys.argv[1])
    expected: dict[str, str] = {}
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        checksum, name = line.split(maxsplit=1)
        expected[name] = checksum

    corpus_files = {
        path.name
        for path in manifest.parent.iterdir()
        if path.is_file() and path.name not in {"MANIFEST", "README.md"}
    }
    if corpus_files != expected.keys():
        print("manifest file set does not match corpus file set", file=sys.stderr)
        print(f"manifest: {sorted(expected)}", file=sys.stderr)
        print(f"corpus:   {sorted(corpus_files)}", file=sys.stderr)
        return 1

    failures = [
        name
        for name, checksum in expected.items()
        if digest(manifest.parent / name) != checksum
    ]
    if failures:
        print("corpus checksum mismatch: " + ", ".join(failures), file=sys.stderr)
        return 1
    print(f"report corpus manifest matches ({len(expected)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
