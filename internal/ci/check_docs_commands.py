#!/usr/bin/env python3
"""Fail when a documented `sol ...` command is not registered by the binary.

The generated CLI reference is guarded against the binary, but the narrative
docs and agent skills were not: removed commands (`sol up`, `sol local infra`,
`sol status`, ...) survived in prose for weeks. This reads every fenced code
block and inline code span in the user docs, the scaffold templates and the
agent skills, extracts each `sol` command, and refuses an unknown top-level
command or an unknown subcommand of a command group.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "internal" / "ci" / "lib"))

import cli_surface

# ADRs, proposals and the hosted boundary are historical/forward-looking
# records; they may name commands that do not exist yet or no longer exist.
SCAN = [
    "README.md",
    "AGENTS.md",
    "docs/*.md",
    "docs/guides/*.md",
    "docs/reference/*.md",
    "docs/deployment/*.md",
    "docs/architecture/*.md",
    "platform/shared/templates/**/README.md",
    ".agents/skills/**/*.md",
    "examples/pluto/README.md",
]
FENCE = re.compile(r"^\s*```")
INLINE = re.compile(r"`([^`\n]+)`")
COMMAND = re.compile(r"(?<![\w-])sol\s+([a-z][a-z0-9-]*)")
WORD = re.compile(r"^[a-z][a-z0-9-]*$")


def files() -> list[Path]:
    found: list[Path] = []
    for pattern in SCAN:
        for path in sorted(ROOT.glob(pattern)):
            if path.is_file() and path not in found:
                found.append(path)
    return found


def code_segments(path: Path) -> list[tuple[int, str]]:
    segments: list[tuple[int, str]] = []
    in_fence = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            if not line.lstrip().startswith(("#", "//")):
                segments.append((number, line))
        else:
            for match in INLINE.finditer(line):
                segments.append((number, match.group(1)))
    return segments


def command_tree(binary: Path | None):
    if binary is not None and binary.is_file():
        commands = cli_surface.registered(str(binary))
        paths = {command.path for command in commands}
        source = "the built binary"
    else:
        page = ROOT / "docs" / "reference" / "cli.md"
        if not page.is_file():
            print(
                "check_docs_commands: neither the binary nor docs/reference/cli.md exists",
                file=sys.stderr,
            )
            raise SystemExit(1)
        paths = set()
        for line in page.read_text(encoding="utf-8").splitlines():
            if line.startswith("| `sol "):
                command = line.split("|", 2)[1].strip().strip("`")
                if command:
                    paths.add(command)
        source = "docs/reference/cli.md"
    if not paths:
        print("check_docs_commands: no registered command paths found", file=sys.stderr)
        raise SystemExit(1)
    children: dict[str, set[str]] = {}
    for path in paths:
        parts = path.split()
        for index in range(2, len(parts)):
            parent = " ".join(parts[:index])
            children.setdefault(parent, set()).add(parts[index])
    return paths, children, source


def check(binary: Path, path: Path, text: str, paths, children, problems: list[str]) -> None:
    for match in COMMAND.finditer(text):
        top = match.group(1)
        if not any(
            command == f"sol {top}" or command.startswith(f"sol {top} ")
            for command in paths
        ):
            problems.append(f"{path}: `sol {top}` is not a registered command")
            continue
        rest = re.match(r"\s+([a-z][a-z0-9-]*)\b", text[match.end():])
        if rest is None:
            continue
        sub = rest.group(1)
        if not WORD.match(sub):
            continue
        parent = f"sol {top}"
        if parent in children and sub not in children[parent]:
            problems.append(
                f"{path}: `sol {top} {sub}` is not a registered command "
                f"(known: {', '.join(sorted(children[parent]))})"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--binary",
        default=str(ROOT / "_build" / "default" / "cli" / "bin" / "main.exe"),
    )
    args = parser.parse_args()
    binary = Path(args.binary)
    paths, children, source = command_tree(binary if binary.is_file() else None)
    problems: list[str] = []
    checked = 0
    for path in files():
        for number, segment in code_segments(path):
            checked += 1
            before = len(problems)
            check(binary, path, segment, paths, children, problems)
            if len(problems) > before:
                problems[-1] = f"{path}:{number}: {problems[-1].split(': ', 1)[-1]}"
    if problems:
        print("check_docs_commands: documented commands are not registered:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        raise SystemExit(1)
    print(
        f"check_docs_commands: {checked} code segments checked against {source}; "
        "every documented `sol` command is registered"
    )


main()
