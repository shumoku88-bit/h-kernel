#!/usr/bin/env python3
from collections import defaultdict
from pathlib import Path
import hashlib
import re

HELPERS = [
    "assertEqual",
    "mustRight",
    "assertRight",
    "assertLeftContaining",
    "exactlyOne",
    "failWith",
    "mustJust",
]

TYPE_SIG = re.compile(r"^([A-Za-z_][A-Za-z0-9_']*)\s*::")


def helper_block(lines, helper):
    start = None
    for i, line in enumerate(lines):
        if re.match(rf"^{re.escape(helper)}\s*::", line):
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        match = TYPE_SIG.match(lines[i])
        if match and match.group(1) != helper:
            end = i
            break
    while end > start and not lines[end - 1].strip():
        end -= 1
    return "\n".join(lines[start:end]) + "\n"


def line_count(block):
    return len(block.rstrip("\n").splitlines())


files = sorted(Path("tests").glob("*.hs"))
print(f"test_files={len(files)}")
print()

all_duplicate_lines = 0
ideal_saved_lines = 0
for helper in HELPERS:
    variants = defaultdict(list)
    for path in files:
        block = helper_block(path.read_text().splitlines(), helper)
        if block is not None:
            variants[block].append(path.name)

    occurrences = sum(len(names) for names in variants.values())
    if not occurrences:
        continue

    print(f"[{helper}] occurrences={occurrences} variants={len(variants)}")
    for index, (block, names) in enumerate(
        sorted(variants.items(), key=lambda item: (-len(item[1]), item[0])), 1
    ):
        lines = line_count(block)
        digest = hashlib.sha256(block.encode()).hexdigest()[:10]
        duplicate_lines = lines * len(names)
        saved = lines * max(0, len(names) - 1)
        all_duplicate_lines += duplicate_lines
        ideal_saved_lines += saved
        print(
            f"  variant={index} sha={digest} files={len(names)} "
            f"lines_each={lines} ideal_saved={saved}"
        )
        for name in names:
            print(f"    {name}")
    print()

print(f"definition_lines_observed={all_duplicate_lines}")
print(f"ideal_exact_body_saved_lines={ideal_saved_lines}")
print("note=ideal_saved excludes import/Cabal/shared-module costs")
