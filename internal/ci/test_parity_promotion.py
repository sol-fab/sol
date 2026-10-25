#!/usr/bin/env python3
"""Regression tests for the parity-to-promotion composition boundary.

`parity_reasons` recomputes parity from the contract and the exact provider
records. The recorded parity verdict is accepted only when it is the same
verdict. This is deliberately not the promotion decision itself: teardown,
candidate bundle verification and release policy remain in promotion.decide.
"""

from __future__ import annotations

import copy
import json
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "internal" / "tooling" / "release"))
sys.path.insert(0, str(HERE))

import promotion  # noqa: E402
import qualification_parity as parity  # noqa: E402
from test_qualification_parity import CANDIDATE, contract, record  # noqa: E402

checks = 0
failures = 0


def check(label: str, condition: bool) -> None:
    global checks, failures
    checks += 1
    if condition:
        print(f"  [OK]   {label}")
    else:
        print(f"  [FAIL] {label}")
        failures += 1


def write(path: pathlib.Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True) + "\n")


def accepted(label: str, reasons: list[str]) -> None:
    check(label, reasons == [])
    if reasons:
        print(f"         reasons: {reasons}")


def refused(label: str, reasons: list[str], needle: str = "") -> None:
    matched = bool(reasons) and (not needle or any(needle in reason for reason in reasons))
    check(label, matched)
    if not matched:
        print(f"         reasons: {reasons}")


def fixture(directory: pathlib.Path, contract_doc: dict | None = None):
    contract_doc = contract_doc if contract_doc is not None else contract()
    aws = record("aws", contract_doc)
    gcp = record("gcp", contract_doc)
    verdict = parity.evaluate(contract_doc, {"aws": aws, "gcp": gcp})
    paths = {
        "contract": directory / "contract.json",
        "aws": directory / "aws.json",
        "gcp": directory / "gcp.json",
        "parity": directory / "parity.json",
    }
    write(paths["contract"], contract_doc)
    write(paths["aws"], aws)
    write(paths["gcp"], gcp)
    write(paths["parity"], verdict)
    return paths, verdict, contract_doc


def test_accepted() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        directory = pathlib.Path(temporary)
        paths, verdict, _ = fixture(directory)
        reasons = promotion.parity_reasons(
            CANDIDATE, verdict, str(paths["contract"]), str(paths["aws"]), str(paths["gcp"])
        )
        accepted("matching contract, records and verdict pass", reasons)


def test_recorded_verdict() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        directory = pathlib.Path(temporary)
        paths, verdict, _ = fixture(directory)
        altered = copy.deepcopy(verdict)
        altered["harness_revision"] = "f" * 40
        reasons = promotion.parity_reasons(
            CANDIDATE, altered, str(paths["contract"]), str(paths["aws"]), str(paths["gcp"])
        )
        refused("a recorded verdict detached from the recomputation refuses", reasons, "does not match")

        reasons = promotion.parity_reasons(
            CANDIDATE, None, str(paths["contract"]), str(paths["aws"]), str(paths["gcp"])
        )
        refused("a missing recorded parity verdict refuses", reasons, "no recorded")


def test_candidate() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        directory = pathlib.Path(temporary)
        paths, verdict, _ = fixture(directory)
        other = copy.deepcopy(CANDIDATE)
        other["revision"] = "e" * 40
        reasons = promotion.parity_reasons(
            other, verdict, str(paths["contract"]), str(paths["aws"]), str(paths["gcp"])
        )
        refused("a parity verdict for another candidate refuses", reasons, "different candidate")


def test_contract_change() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        directory = pathlib.Path(temporary)
        paths, verdict, contract_doc = fixture(directory)
        changed = copy.deepcopy(contract_doc)
        changed["claims"].append({"id": "B5", "providers": ["aws", "gcp"]})
        write(paths["contract"], changed)
        reasons = promotion.parity_reasons(
            CANDIDATE, verdict, str(paths["contract"]), str(paths["aws"]), str(paths["gcp"])
        )
        refused("a contract change invalidates old records and verdicts", reasons, "contract digest")


def test_refused_parity() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        directory = pathlib.Path(temporary)
        paths, verdict, _ = fixture(directory)
        gcp = record("gcp")
        gcp["harness_revision"] = "e" * 40
        write(paths["gcp"], gcp)
        # The recorded verdict now refers to the old record; recomputation must
        # refuse both the mismatch and the detached record.
        reasons = promotion.parity_reasons(
            CANDIDATE, verdict, str(paths["contract"]), str(paths["aws"]), str(paths["gcp"])
        )
        refused("a refused recomputation refuses promotion", reasons, "did not pass")


def test_unusable_input() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        directory = pathlib.Path(temporary)
        paths, verdict, _ = fixture(directory)
        reasons = promotion.parity_reasons(
            CANDIDATE, verdict, str(directory / "missing.json"), str(paths["aws"]), str(paths["gcp"])
        )
        refused("missing contract evidence refuses", reasons, "not usable")
        paths["gcp"].write_text("{not json")
        reasons = promotion.parity_reasons(
            CANDIDATE, verdict, str(paths["contract"]), str(paths["aws"]), str(paths["gcp"])
        )
        refused("unreadable provider evidence refuses", reasons, "not usable")


def main() -> int:
    print("parity promotion")
    test_accepted()
    test_recorded_verdict()
    test_candidate()
    test_contract_change()
    test_refused_parity()
    test_unusable_input()
    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
