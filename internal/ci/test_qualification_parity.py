#!/usr/bin/env python3
"""Regression tests for contract-bound cross-provider parity.

These tests are about composition, not about a provider run. A valid record is
not enough: the records must name the same contract digest, candidate, harness
revision and selection, cover the contract's claims and phases, and bind their
bytes into the parity verdict.
"""

from __future__ import annotations

import copy
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "internal" / "tooling" / "release"))

import qualification_parity as parity  # noqa: E402

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


CANDIDATE = {
    "version": "v0.1.0-alpha.52",
    "revision": "a" * 40,
    "bundle_sha256": "b" * 64,
    "runner_image": "ghcr.io/example/sol-migration-runner@sha256:" + "c" * 64,
}


def contract() -> dict:
    return {
        "schema": 1,
        "id": "parity-test-v1",
        "providers": ["aws", "gcp"],
        "claims": [
            {"id": "B1", "providers": ["aws", "gcp"]},
            {"id": "B4", "providers": ["aws", "gcp"]},
        ],
        "phases": ["cloud", "app", "destroy"],
        "selection": {
            "languages": ["ocaml", "typescript"],
            "primitives": ["svc", "worker"],
        },
        "exceptions": [],
    }


def record(provider: str, contract_doc: dict | None = None) -> dict:
    contract_doc = contract_doc if contract_doc is not None else contract()
    return {
        "schema": 1,
        "provider": provider,
        "candidate": copy.deepcopy(CANDIDATE),
        "harness_revision": "d" * 40,
        "contract": {
            "id": contract_doc["id"],
            "digest": parity.contract_digest(contract_doc),
        },
        "selection": copy.deepcopy(contract_doc["selection"]),
        "phases": [
            {"name": "cloud", "exit": 0},
            {"name": "app", "exit": 0},
            {"name": "destroy", "exit": 0},
        ],
        "claims": [
            {"id": "B1", "status": "pass", "evidence": "aws/b1.json"},
            {"id": "B4", "status": "pass", "evidence": "aws/b4.json"},
        ],
    }


def evaluate(contract_doc: dict | None = None, aws: dict | None = None, gcp: dict | None = None):
    contract_doc = contract_doc if contract_doc is not None else contract()
    return parity.evaluate(
        contract_doc,
        {
            "aws": aws if aws is not None else record("aws", contract_doc),
            "gcp": gcp if gcp is not None else record("gcp", contract_doc),
        },
    )


def refused(label: str, verdict: dict) -> None:
    check(label, verdict["verdict"] == "REFUSED" and bool(verdict["reasons"]))


def test_valid() -> None:
    verdict = evaluate()
    check("matching records produce a parity pass", verdict["verdict"] == "PASS")
    check("the verdict binds the contract digest", verdict["contract"]["digest"] == parity.contract_digest(contract()))
    check(
        "the verdict binds both record hashes",
        verdict["providers"]["aws"]["record_sha256"] == parity.record_digest(record("aws"))
        and verdict["providers"]["gcp"]["record_sha256"] == parity.record_digest(record("gcp")),
    )
    check("the verdict carries the candidate identity", verdict["candidate"] == CANDIDATE)
    check("the verdict carries the harness revision", verdict["harness_revision"] == "d" * 40)
    check(
        "the verdict carries the contract selection",
        verdict["selection"] == contract()["selection"],
    )


def test_candidate_and_harness() -> None:
    aws = record("aws")
    aws["candidate"]["revision"] = "e" * 40
    refused("a different candidate revision refuses", evaluate(aws=aws))

    gcp = record("gcp")
    gcp["harness_revision"] = "f" * 40
    refused("a different harness revision refuses", evaluate(gcp=gcp))

    gcp = record("gcp")
    gcp["selection"]["languages"] = ["ocaml"]
    refused("a different selection refuses", evaluate(gcp=gcp))


def test_completeness() -> None:
    refused("a missing provider refuses", parity.evaluate(contract(), {"aws": record("aws")}))
    mislabeled = record("aws")
    refused("a record in the wrong provider slot refuses", evaluate(gcp=mislabeled))
    gcp = record("gcp")
    gcp["phases"] = [p for p in gcp["phases"] if p["name"] != "app"]
    refused("a missing required phase refuses", evaluate(gcp=gcp))
    gcp = record("gcp")
    gcp["phases"][1]["exit"] = 1
    refused("a non-zero required phase refuses", evaluate(gcp=gcp))
    gcp = record("gcp")
    gcp["phases"].append({"name": "app", "exit": 0})
    refused("a duplicate phase refuses", evaluate(gcp=gcp))
    gcp = record("gcp")
    gcp["claims"] = [c for c in gcp["claims"] if c["id"] != "B4"]
    refused("a missing required claim refuses", evaluate(gcp=gcp))
    gcp = record("gcp")
    gcp["claims"][0]["status"] = "fail"
    refused("a failing required claim refuses", evaluate(gcp=gcp))
    gcp = record("gcp")
    del gcp["claims"][0]["evidence"]
    refused("a pass without evidence refuses", evaluate(gcp=gcp))


def test_contract_binding() -> None:
    contract_doc = contract()
    old = record("aws", contract_doc)
    old_gcp = record("gcp", contract_doc)
    changed = copy.deepcopy(contract_doc)
    changed["claims"].append({"id": "B5", "providers": ["aws", "gcp"]})
    refused(
        "a changed contract invalidates records bound to the old digest",
        parity.evaluate(changed, {"aws": old, "gcp": old_gcp}),
    )

    gcp = record("gcp")
    gcp["claims"][0]["status"] = "excluded"
    gcp["claims"][0]["reason"] = "provider does not implement this row"
    refused("an excluded claim without a contract exception refuses", evaluate(gcp=gcp))

    with_exception = contract()
    with_exception["exceptions"].append(
        {
            "claim": "B1",
            "provider": "gcp",
            "reason": "GCP has no equivalent primitive",
            "test": "internal/ci/test_qualification_parity.py",
        }
    )
    gcp = record("gcp", with_exception)
    gcp["claims"][0]["status"] = "excluded"
    gcp["claims"][0]["reason"] = "GCP has no equivalent primitive"
    verdict = evaluate(with_exception, gcp=gcp)
    check("a declared and tested exception can cover a claim", verdict["verdict"] == "PASS")
    check(
        "the exception does not remove the claim from the parity verdict",
        any(row["id"] == "B1" for row in verdict["claims"]),
    )

    missing_test = copy.deepcopy(with_exception)
    del missing_test["exceptions"][0]["test"]
    try:
        parity.evaluate(missing_test, {"aws": record("aws", contract()), "gcp": gcp})
    except parity.InputError as error:
        check("an exception without a test is invalid", "test" in str(error))
    else:
        check("an exception without a test is invalid", False)


def test_cli_refusal() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        (base / "contract.json").write_text(json.dumps(contract()))
        (base / "aws.json").write_text(json.dumps(record("aws")))
        (base / "gcp.json").write_text(json.dumps(record("gcp")))
        out = base / "verdict.json"
        code = parity.main(
            [
                "qualification_parity.py",
                "--contract",
                str(base / "contract.json"),
                "--aws",
                str(base / "aws.json"),
                "--gcp",
                str(base / "gcp.json"),
                "--out",
                str(out),
            ]
        )
        check("the CLI writes a passing verdict", code == 0 and json.loads(out.read_text())["verdict"] == "PASS")

        gcp = record("gcp")
        gcp["harness_revision"] = "f" * 40
        (base / "gcp.json").write_text(json.dumps(gcp))
        code = parity.main(
            [
                "qualification_parity.py",
                "--contract",
                str(base / "contract.json"),
                "--aws",
                str(base / "aws.json"),
                "--gcp",
                str(base / "gcp.json"),
                "--out",
                str(out),
            ]
        )
        check(
            "the CLI writes a refusal for a mismatch",
            code == 1 and json.loads(out.read_text())["verdict"] == "REFUSED",
        )


def main() -> int:
    print("qualification parity")
    test_valid()
    test_candidate_and_harness()
    test_completeness()
    test_contract_binding()
    test_cli_refusal()
    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
