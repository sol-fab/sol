#!/usr/bin/env python3
"""Validate one `sol resources --json` inventory against its claimed contract.

This is deliberately separate from the CLI: the CLI renders the inventory, and this
validator answers the qualification question — does the recorded/observed result
actually satisfy the verdict it reports?

Usage:
  inventory_contract.py FILE
  inventory_contract.py --expect reconciled FILE
  inventory_contract.py --expect attention FILE
  inventory_contract.py --expect incomplete FILE
  inventory_contract.py --expect unknown FILE
  inventory_contract.py --expect unverified FILE
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

VERDICTS = {"reconciled", "incomplete", "attention_required", "unknown", "unverified"}
STATUSES = {
    "owned",
    "recorded",
    "missing",
    "unrecorded",
    "external",
    "in_cluster",
    "synthetic",
    "uid_mismatch",
    "absent",
    "unknown",
}
DISCREPANCIES = {"unrecorded", "missing", "uid_mismatch"}
RECOVERIES = {"not_applicable", "recoverable", "unrecoverable", "unmapped"}


def load(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"inventory_contract: cannot read {path}: {error}")


def resources(document):
    rows = document.get("resources")
    if not isinstance(rows, list):
        raise ValueError("resources is not a list")
    return rows


def recovery_disposition(row):
    recovery = row.get("recovery")
    if not isinstance(recovery, dict):
        raise ValueError("a resource has no recovery object")
    disposition = recovery.get("disposition")
    if disposition not in RECOVERIES:
        raise ValueError(f"unknown recovery disposition {disposition!r}")
    return disposition


def check(document, expect):
    errors: list[str] = []

    if document.get("schema") != 1:
        errors.append("schema is not 1")
    verdict = document.get("verdict")
    if verdict not in VERDICTS:
        errors.append(f"unknown verdict {verdict!r}")

    coverage = document.get("coverage")
    if not isinstance(coverage, dict):
        errors.append("coverage is not an object")
        coverage = {}
    inventory = coverage.get("inventory") if isinstance(coverage, dict) else None
    verification = coverage.get("verification") if isinstance(coverage, dict) else None
    if not isinstance(inventory, dict) or not isinstance(
        inventory.get("complete"), bool
    ):
        errors.append("coverage.inventory.complete is not a boolean")
        inventory_complete = False
    else:
        inventory_complete = inventory["complete"]
    if not isinstance(verification, dict) or not isinstance(
        verification.get("complete"), bool
    ):
        errors.append("coverage.verification.complete is not a boolean")
        verification_complete = False
    else:
        verification_complete = verification["complete"]

    rows = resources(document)
    statuses = []
    recoveries = []
    for row in rows:
        status = row.get("status")
        if status not in STATUSES:
            errors.append(f"unknown resource status {status!r}")
        statuses.append(status)
        try:
            recoveries.append(recovery_disposition(row))
        except ValueError as error:
            errors.append(str(error))

    unknowns = document.get("unknowns")
    if not isinstance(unknowns, list) or not all(
        isinstance(item, str) for item in unknowns
    ):
        errors.append("unknowns is not a list of strings")
        unknowns = []

    discrepancy = any(status in DISCREPANCIES for status in statuses) or any(
        recovery in {"unrecoverable", "unmapped"} for recovery in recoveries
    )

    if expect is None:
        return errors, {
            "verdict": verdict,
            "inventory_complete": inventory_complete,
            "verification_complete": verification_complete,
            "discrepancy": discrepancy,
            "unknowns": len(unknowns),
        }

    if expect == "reconciled":
        if verdict != "reconciled":
            errors.append(f"expected verdict reconciled, got {verdict!r}")
        if not inventory_complete:
            errors.append("reconciled requires inventory.complete")
        if not verification_complete:
            errors.append("reconciled requires verification.complete")
        if discrepancy:
            errors.append("reconciled has an unrecorded/missing/unrecoverable row")
        if unknowns:
            errors.append("reconciled has unknowns")
    elif expect == "attention":
        if verdict != "attention_required":
            errors.append(f"expected verdict attention_required, got {verdict!r}")
        if not discrepancy:
            errors.append("attention_required has no confirmed discrepancy")
        if not inventory_complete:
            errors.append("attention_required requires inventory.complete")
    elif expect == "incomplete":
        if verdict != "incomplete":
            errors.append(f"expected verdict incomplete, got {verdict!r}")
        if not inventory_complete:
            errors.append("incomplete requires inventory.complete")
        if verification_complete:
            errors.append("incomplete must have verification.complete = false")
        if discrepancy:
            errors.append("incomplete has a confirmed discrepancy")
    elif expect == "unknown":
        if verdict != "unknown":
            errors.append(f"expected verdict unknown, got {verdict!r}")
        if not unknowns:
            errors.append("unknown has no unknowns")
    elif expect == "unverified":
        if verdict != "unverified":
            errors.append(f"expected verdict unverified, got {verdict!r}")
        if verification_complete:
            errors.append("unverified must have verification.complete = false")
    else:
        errors.append(f"unknown expectation {expect!r}")

    return errors, {
        "verdict": verdict,
        "inventory_complete": inventory_complete,
        "verification_complete": verification_complete,
        "discrepancy": discrepancy,
        "unknowns": len(unknowns),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("file", type=Path)
    parser.add_argument(
        "--expect",
        choices=["reconciled", "attention", "incomplete", "unknown", "unverified"],
    )
    args = parser.parse_args()
    document = load(args.file)
    try:
        errors, summary = check(document, args.expect)
    except ValueError as error:
        print(f"inventory_contract: {error}", file=sys.stderr)
        return 1
    if errors:
        print(
            "inventory_contract: inventory does not satisfy its contract:",
            file=sys.stderr,
        )
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1
    print(
        "inventory_contract: "
        + " ".join(f"{key}={value}" for key, value in summary.items())
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
