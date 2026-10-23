#!/usr/bin/env python3
"""Render and verify the README's product evidence table.

`internal/qualification/product-matrix.yaml` is the one machine-readable
snapshot of what the contract currently has evidence for. This check renders
it into README.md and fails when the committed table is stale. It also verifies
that every evidence link resolves, so a status cannot point at a vanished record.

It is not a release policy and it is not a worklog: no dates, no history, no
support tiers. A cell is evidence, not a product level.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import json

ROOT = Path(__file__).resolve().parents[2]
MATRIX = ROOT / "internal/qualification/product-matrix.json"
README = ROOT / "README.md"
BEGIN = "<!-- BEGIN GENERATED: product-status -->"
END = "<!-- END GENERATED: product-status -->"
STATUSES = {"local", "live", "prod", "partial", "none"}
EVIDENCE_LABELS = {"local": "local", "aws": "AWS", "gcp": "GCP"}


def fail(message: str) -> None:
    print(f"check_product_matrix: {message}", file=sys.stderr)
    raise SystemExit(1)


def cell(value: object) -> str:
    if value is None:
        return "none"
    if not isinstance(value, str) or value not in STATUSES:
        fail(f"unknown evidence status {value!r}")
    return value


def table_cell(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ").strip()


def evidence(row: dict) -> str:
    links = []
    for key, path in (row.get("evidence") or {}).items():
        if key not in EVIDENCE_LABELS:
            fail(f"{row.get('id')}: unknown evidence key {key!r}")
        target = ROOT / path
        if not target.exists():
            fail(f"{row.get('id')}: evidence {path!r} does not exist")
        links.append(f"[{EVIDENCE_LABELS[key]}]({path})")
    return ", ".join(links) if links else "—"


def render_rows(rows: list[dict], kind: str) -> list[str]:
    lines = []
    if kind == "primitives":
        lines += [
            "### Workloads",
            "",
            "| Workload | Local | AWS | GCP | Evidence | Gap |",
            "|---|---|---|---|---|---|",
        ]
        for row in rows:
            lines.append(
                "| {label} | {local} | {aws} | {gcp} | {evidence} | {gap} |".format(
                    label=table_cell(row["label"]),
                    local=cell(row.get("local")),
                    aws=cell(row.get("aws")),
                    gcp=cell(row.get("gcp")),
                    evidence=evidence(row),
                    gap=table_cell(row.get("gap", "")),
                )
            )
    elif kind == "lifecycle":
        lines += [
            "### Lifecycle and observability",
            "",
            "| Capability | Local | AWS | GCP | Gap |",
            "|---|---|---|---|---|",
        ]
        for row in rows:
            lines.append(
                "| {label} | {local} | {aws} | {gcp} | {gap} |".format(
                    label=table_cell(row["label"]),
                    local=cell(row.get("local")),
                    aws=cell(row.get("aws")),
                    gcp=cell(row.get("gcp")),
                    gap=table_cell(row.get("gap", "")),
                )
            )
    elif kind == "production":
        lines += [
            "### Production profile",
            "",
            "| Requirement | AWS | GCP | Gap |",
            "|---|---|---|---|",
        ]
        for row in rows:
            lines.append(
                "| {label} | {aws} | {gcp} | {gap} |".format(
                    label=table_cell(row["label"]),
                    aws=cell(row.get("aws")),
                    gcp=cell(row.get("gcp")),
                    gap=table_cell(row.get("gap", "")),
                )
            )
    else:
        fail(f"unknown table kind {kind}")
    return lines


def render(document: dict) -> str:
    if document.get("contract") != "production-single-region/v1":
        fail("the matrix must name production-single-region/v1")
    blocks = []
    for key, kind in (
        ("primitives", "primitives"),
        ("lifecycle", "lifecycle"),
        ("production", "production"),
    ):
        rows = document.get(key)
        if not isinstance(rows, list) or not rows:
            fail(f"the matrix has no {key} rows")
        blocks.extend(render_rows(rows, kind))
        blocks.append("")
    blocks += [
        "Evidence: `local` = repeatable local test; `live` = deployed and behaviorally",
        "verified; `partial` = some evidence; `prod` = production-profile evidence;",
        "`none` = no qualifying evidence. The contract still applies to every cell;",
        "a status is a measurement, not a product tier.",
        "",
    ]
    return "\n".join(blocks)


def replace(page: str, body: str) -> str:
    start = page.find(BEGIN)
    stop = page.find(END, start)
    if start < 0 or stop < 0:
        fail(f"README.md must contain {BEGIN} and {END}")
    return page[: start + len(BEGIN)] + "\n" + body + page[stop:]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="rewrite README.md")
    args = parser.parse_args()

    if not MATRIX.is_file():
        fail(f"{MATRIX} does not exist")
    document = json.loads(MATRIX.read_text())
    if not isinstance(document, dict):
        fail("the matrix is not a mapping")
    generated = render(document)
    page = README.read_text()
    updated = replace(page, generated)
    if args.write:
        README.write_text(updated)
        print("check_product_matrix: README.md updated")
        return
    if updated != page:
        fail(
            "README.md's product table is stale; run "
            "`python3 internal/ci/check_product_matrix.py --write`"
        )
    print("check_product_matrix: README.md matches the product matrix")


main()
