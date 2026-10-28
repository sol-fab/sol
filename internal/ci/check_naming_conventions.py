#!/usr/bin/env python3
"""Enforce the mechanically checkable naming conventions.

Sol identities are snake_case; provider resources are derived kebab-case. OCaml
filenames must be valid module names (snake_case), and documentation filenames use
kebab-case except the standard README.md entry point.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ML_FILE = re.compile(r"^[a-z][a-z0-9_]*\.(ml|mli)$")
DOC_FILE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*\.md$")


def tracked_files() -> list[str]:
    output = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files"], text=True
    )
    return [line for line in output.splitlines() if line]


def main() -> int:
    errors: list[str] = []
    for path in tracked_files():
        name = Path(path).name
        if path.startswith(("cli/", "framework/")) and name.endswith((".ml", ".mli")):
            if not ML_FILE.fullmatch(name):
                errors.append(
                    f"{path}: OCaml filenames must be snake_case (lowercase, underscores)"
                )
        elif path.startswith("docs/") and name.endswith(".md") and name != "README.md":
            if not DOC_FILE.fullmatch(name):
                errors.append(
                    f"{path}: documentation filenames must be kebab-case"
                )
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(
            "check_naming_conventions: fix filenames or add an explicit, reviewed "
            "exception",
            file=sys.stderr,
        )
        return 1
    print("check_naming_conventions: filenames follow the convention")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
