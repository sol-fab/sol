#!/usr/bin/env python3
"""Regression tests for the release-candidate promotion decision.

The decision is what stops a release being published from its tag before the
authorized AWS and GCP qualification exists, and what stops a verdict for one
candidate promoting another. The failure modes are the point: no verdict, a
verdict for a different candidate, a missing or failing required provider, an
omitted or non-passing release-blocking row, a blocked or excluded row without a
reason, and a teardown claim that is not backed by a verifiable attached
evidence document must all refuse; a complete verdict that refers to the exact
candidate and carries matching evidence must allow promotion. These tests
establish the decision mechanics only -- they are not qualification evidence.
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "internal" / "tooling" / "release"))

import promotion  # noqa: E402

checks = 0
failures = 0
EVIDENCE_DIR = ""

CANDIDATE = {
    "version": "v0.1.0-alpha.9",
    "revision": "a" * 40,
    "bundle": "sol-v0.1.0-alpha.9-linux-x86_64.tar.gz",
    "bundle_sha256": "b" * 64,
    "runner_image": "ghcr.io/example/sol-migration-runner@sha256:" + "c" * 64,
}


def check(label: str, condition: bool) -> None:
    global checks, failures
    checks += 1
    if condition:
        print(f"  [OK]   {label}")
    else:
        print(f"  [FAIL] {label}")
        failures += 1


def evidence_document(provider: str = "aws") -> dict:
    return {
        "schema": 1,
        "provider": provider,
        "candidate": promotion.identity(CANDIDATE),
        "attempt": "attempt-1",
        "target": "target-1",
        "scope": {"cluster": "cluster-1", "region": "us-east-1", "account": "123"},
        "required_classes": ["class-a", "class-b", "durable-zone"],
        "classes": [
            {"class": "class-a", "expectation": "absent", "state": "ABSENT"},
            {"class": "class-b", "expectation": "absent", "state": "ABSENT"},
            {"class": "durable-zone", "expectation": "present", "state": "PRESENT"},
        ],
        "verdict": "ABSENT",
    }


def default_binding(provider: str) -> dict:
    return {
        "provider": provider,
        "attempt": "attempt-1",
        "target": "target-1",
        "cluster": "cluster-1",
    }


def write_evidence(provider: str, document: dict | None = None) -> tuple[str, str]:
    document = document if document is not None else evidence_document(provider)
    name = f"{provider}-evidence.json"
    data = json.dumps(document, indent=2, sort_keys=True).encode("utf-8")
    with open(os.path.join(EVIDENCE_DIR, name), "wb") as handle:
        handle.write(data)
    return name, hashlib.sha256(data).hexdigest()


def teardown(
    provider: str, document: dict | None = None, binding: dict | None = None, evidence: dict | None = None
) -> dict:
    name, digest = write_evidence(provider, document)
    return {
        "absence_verdict": "pass",
        "binding": binding if binding is not None else default_binding(provider),
        "evidence": evidence if evidence is not None else {"path": name, "sha256": digest},
    }


def verdict(*, aws: dict | None = None, gcp: dict | None = None) -> dict:
    return {
        "candidate": promotion.identity(CANDIDATE),
        "providers": {
            "aws": {
                "verdict": "pass",
                "required_rows": ["B1", "I8"],
                "rows": [
                    {"id": "B1", "status": "pass"},
                    {"id": "I8", "status": "pass"},
                ],
                "teardown": aws if aws is not None else teardown("aws"),
            },
            "gcp": {
                "verdict": "pass",
                "required_rows": ["B1"],
                "rows": [{"id": "B1", "status": "pass"}],
                "teardown": gcp if gcp is not None else teardown("gcp"),
            },
        },
    }


def refuses(label: str, candidate, document) -> None:
    check(label, promotion.decide(candidate, document, EVIDENCE_DIR) != [])


def refuses_with(label: str, document, needle: str, candidate=CANDIDATE) -> None:
    reasons = promotion.decide(candidate, document, EVIDENCE_DIR)
    matched = bool(reasons) and any(needle in reason for reason in reasons)
    check(label, matched)
    if not matched:
        print(f"         reasons: {reasons}")


def allows(label: str, candidate, document) -> None:
    reasons = promotion.decide(candidate, document, EVIDENCE_DIR)
    check(label, reasons == [])
    if reasons:
        print(f"         reasons: {reasons}")


def test_identity() -> None:
    allows("a complete verdict for the exact candidate is eligible", CANDIDATE, verdict())
    refuses("no verdict refuses", CANDIDATE, None)
    refuses(
        "a verdict for another revision refuses",
        CANDIDATE,
        {**verdict(), "candidate": {**promotion.identity(CANDIDATE), "revision": "d" * 40}},
    )
    refuses(
        "a verdict for another bundle refuses",
        CANDIDATE,
        {**verdict(), "candidate": {**promotion.identity(CANDIDATE), "bundle_sha256": "e" * 64}},
    )
    refuses(
        "a verdict for another runner refuses",
        CANDIDATE,
        {
            **verdict(),
            "candidate": {
                **promotion.identity(CANDIDATE),
                "runner_image": "ghcr.io/example/other@sha256:" + "f" * 64,
            },
        },
    )
    refuses("a candidate without a digest runner refuses", {**CANDIDATE, "runner_image": "latest"}, verdict())
    refuses("a threadbare candidate refuses", {"version": "v0.1.0"}, verdict())
    reasons = promotion.decide(CANDIDATE, verdict(), "")
    check(
        "a decision without an attached evidence directory refuses",
        bool(reasons) and any("evidence directory" in reason for reason in reasons),
    )


def test_providers() -> None:
    refuses("a missing provider refuses", CANDIDATE, {**verdict(), "providers": {"aws": verdict()["providers"]["aws"]}})
    document = verdict()
    document["providers"]["gcp"]["verdict"] = "fail"
    refuses("a failing provider refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["gcp"]["verdict"] = "blocked"
    document["providers"]["gcp"]["reason"] = "quota"
    refuses("a blocked provider refuses", CANDIDATE, document)
    document = verdict()
    del document["providers"]["aws"]["teardown"]
    refuses("a provider without a teardown result refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["teardown"]["absence_verdict"] = "present"
    refuses("a provider whose absence result is not a pass refuses", CANDIDATE, document)


def test_rows() -> None:
    document = verdict()
    document["providers"]["aws"]["rows"][1]["status"] = "fail"
    refuses("a failing required row refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["rows"][1]["status"] = "not_run"
    refuses("a not-run required row refuses", CANDIDATE, document)
    document = verdict()
    del document["providers"]["aws"]["rows"][1]
    refuses("an omitted required row refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["required_rows"] = []
    refuses("a provider that names no required rows refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["rows"].append({"id": "C9", "status": "blocked"})
    refuses("a blocked extra row without a reason refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["rows"].append(
        {"id": "C9", "status": "blocked", "reason": "not reachable on this target"}
    )
    allows("a blocked extra row with a reason stays visible and does not block", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["rows"].append(
        {"id": "C9", "status": "excluded", "reason": "out of scope for this profile"}
    )
    allows("an excluded row with a reason stays visible and does not block", CANDIDATE, document)


def test_teardown_evidence() -> None:
    allows("a complete attached evidence document is eligible", CANDIDATE, verdict())

    document = verdict()
    del document["providers"]["aws"]["teardown"]["evidence"]
    refuses_with("a teardown claim with no evidence refuses", document, "names no evidence member")

    document = verdict()
    document["providers"]["aws"]["teardown"]["evidence"] = 17
    refuses_with("teardown evidence that is not an object refuses", document, "names no evidence member")

    document = verdict(aws=teardown("aws", evidence={"path": "missing.json", "sha256": "d" * 64}))
    refuses_with("evidence that is not attached refuses", document, "is not attached")

    document = verdict(aws=teardown("aws", evidence={"path": "../escape.json", "sha256": "d" * 64}))
    refuses_with("a path outside the evidence directory refuses", document, "is not a plain file name")

    document = verdict(aws=teardown("aws", evidence={"path": "/etc/passwd", "sha256": "d" * 64}))
    refuses_with("an absolute evidence path refuses", document, "is not a plain file name")

    entry = teardown("aws")
    document = verdict(aws={**entry, "evidence": {**entry["evidence"], "sha256": "e" * 64}})
    refuses_with("a digest that does not match the bytes refuses", document, "has sha256:")

    name = "malformed-evidence.json"
    data = b"{"
    with open(os.path.join(EVIDENCE_DIR, name), "wb") as handle:
        handle.write(data)
    document = verdict(
        aws=teardown("aws", evidence={"path": name, "sha256": hashlib.sha256(data).hexdigest()})
    )
    refuses_with("evidence that is not JSON refuses", document, "is not JSON")

    document = verdict(aws=teardown("aws", document=evidence_document("gcp")))
    refuses_with("evidence from another provider refuses", document, "names provider 'gcp'")

    binding = default_binding("aws")
    binding["provider"] = "gcp"
    document = verdict(aws=teardown("aws", binding=binding))
    refuses_with("a binding that names another provider refuses", document, "binding names provider 'gcp'")

    changed_candidate = evidence_document("aws")
    changed_candidate["candidate"]["revision"] = "d" * 40
    document = verdict(aws=teardown("aws", document=changed_candidate))
    refuses_with("evidence for another candidate refuses", document, "does not name this candidate")

    changed_attempt = evidence_document("aws")
    changed_attempt["attempt"] = "attempt-2"
    document = verdict(aws=teardown("aws", document=changed_attempt))
    refuses_with("evidence from another attempt refuses", document, "binds attempt")

    changed_target = evidence_document("aws")
    changed_target["target"] = "target-2"
    document = verdict(aws=teardown("aws", document=changed_target))
    refuses_with("evidence from another target refuses", document, "binds target")

    changed_cluster = evidence_document("aws")
    changed_cluster["scope"]["cluster"] = "cluster-2"
    document = verdict(aws=teardown("aws", document=changed_cluster))
    refuses_with("evidence from another cluster refuses", document, "binds cluster")

    incomplete = evidence_document("aws")
    incomplete["required_classes"].append("class-c")
    document = verdict(aws=teardown("aws", document=incomplete))
    refuses_with("incomplete class coverage refuses", document, "does not observe required class")

    duplicate = evidence_document("aws")
    duplicate["classes"].append({"class": "class-a", "expectation": "absent", "state": "ABSENT"})
    document = verdict(aws=teardown("aws", document=duplicate))
    refuses_with("a duplicated class refuses", document, "more than once")

    undeclared = evidence_document("aws")
    undeclared["classes"].append({"class": "class-c", "expectation": "absent", "state": "ABSENT"})
    document = verdict(aws=teardown("aws", document=undeclared))
    refuses_with("an undeclared class refuses", document, "undeclared class")

    unknown = evidence_document("aws")
    unknown["classes"][0]["state"] = "UNKNOWN"
    document = verdict(aws=teardown("aws", document=unknown))
    refuses_with("an UNKNOWN disposable class refuses", document, "is UNKNOWN, not ABSENT")

    present = evidence_document("aws")
    present["classes"][0]["state"] = "PRESENT"
    document = verdict(aws=teardown("aws", document=present))
    refuses_with("a PRESENT disposable class refuses", document, "is PRESENT, not ABSENT")

    missing_durable = evidence_document("aws")
    missing_durable["classes"][2]["state"] = "ABSENT"
    document = verdict(aws=teardown("aws", document=missing_durable))
    refuses_with("an absent durable prerequisite refuses", document, "is ABSENT, not PRESENT")

    not_absent = evidence_document("aws")
    not_absent["verdict"] = "NOT ABSENT"
    document = verdict(aws=teardown("aws", document=not_absent))
    refuses_with("a report that is not ABSENT refuses", document, "records verdict 'NOT ABSENT'")

    wrong_schema = evidence_document("aws")
    wrong_schema["schema"] = 2
    document = verdict(aws=teardown("aws", document=wrong_schema))
    refuses_with("an unknown evidence schema refuses", document, "schema 2")

    wrong_type = evidence_document("aws")
    wrong_type["classes"] = "none"
    document = verdict(aws=teardown("aws", document=wrong_type))
    refuses_with("a class list of the wrong type refuses", document, "records no class observations")

    wrong_expectation = evidence_document("aws")
    wrong_expectation["classes"][0]["expectation"] = "maybe"
    document = verdict(aws=teardown("aws", document=wrong_expectation))
    refuses_with("an invalid expectation refuses", document, "has expectation 'maybe'")

    wrong_state = evidence_document("aws")
    wrong_state["classes"][0]["state"] = "GONE"
    document = verdict(aws=teardown("aws", document=wrong_state))
    refuses_with("an invalid state refuses", document, "has state 'GONE'")

    altered_entry = teardown("aws")
    altered_document = verdict(aws=altered_entry)
    with open(os.path.join(EVIDENCE_DIR, altered_entry["evidence"]["path"]), "wb") as handle:
        handle.write(b"{}")
    refuses_with("evidence altered after the claim was written refuses", altered_document, "has sha256:")


def test_record() -> None:
    with tempfile.TemporaryDirectory() as directory:
        bundle = os.path.join(directory, "sol-v0.1.0-alpha.9-linux-x86_64.tar.gz")
        with open(bundle, "wb") as handle:
            handle.write(b"bundle")
        data = promotion.record(
            "v0.1.0-alpha.9", "a" * 40, bundle, CANDIDATE["runner_image"]
        )
        check("record names the built bundle", data["bundle"] == os.path.basename(bundle))
        check("record digests the built bundle", data["bundle_sha256"] == promotion.sha256_file(bundle))
        check("record keeps the runner digest", data["runner_image"] == CANDIDATE["runner_image"])
        try:
            promotion.record("v", "a" * 40, bundle, "latest")
        except promotion.InputError:
            check("record refuses a non-digest runner", True)
        else:
            check("record refuses a non-digest runner", False)
        promotion.verify_bundle(data, directory)
        check("verify accepts the recorded bundle", True)
        with open(bundle, "wb") as handle:
            handle.write(b"tampered")
        try:
            promotion.verify_bundle(data, directory)
        except promotion.InputError:
            check("verify refuses a bundle that is not the recorded one", True)
        else:
            check("verify refuses a bundle that is not the recorded one", False)
        with open(bundle, "wb") as handle:
            handle.write(b"bundle")
        os.remove(bundle)
        try:
            promotion.verify_bundle(data, directory)
        except promotion.InputError:
            check("verify refuses a missing recorded bundle", True)
        else:
            check("verify refuses a missing recorded bundle", False)


def test_command_line() -> None:
    global EVIDENCE_DIR
    with tempfile.TemporaryDirectory() as directory:
        EVIDENCE_DIR = directory
        candidate_path = os.path.join(directory, "candidate.json")
        verdict_path = os.path.join(directory, "verdict.json")
        with open(candidate_path, "w", encoding="utf-8") as handle:
            json.dump(CANDIDATE, handle)
        script = str(REPO / "internal" / "tooling" / "release" / "promotion.py")
        document = verdict()
        with open(verdict_path, "w", encoding="utf-8") as handle:
            json.dump(document, handle)
        result = subprocess.run(
            [
                sys.executable,
                script,
                "decide",
                "--candidate",
                candidate_path,
                "--verdict",
                verdict_path,
                "--dir",
                directory,
            ],
            capture_output=True,
            text=True,
        )
        check("the command line allows a complete verdict", result.returncode == 0)

        result = subprocess.run(
            [sys.executable, script, "decide", "--candidate", candidate_path, "--verdict", verdict_path],
            capture_output=True,
            text=True,
        )
        check(
            "the command line refuses a decision without an evidence directory",
            result.returncode == 2,
        )

        document = verdict(aws=teardown("aws", evidence={"path": "missing.json", "sha256": "d" * 64}))
        with open(verdict_path, "w", encoding="utf-8") as handle:
            json.dump(document, handle)
        result = subprocess.run(
            [
                sys.executable,
                script,
                "decide",
                "--candidate",
                candidate_path,
                "--verdict",
                verdict_path,
                "--dir",
                directory,
            ],
            capture_output=True,
            text=True,
        )
        check("the command line refuses evidence that is not attached", result.returncode == 1)
        check("and it names the missing evidence", "is not attached" in result.stderr)

        stale = copy.deepcopy(verdict())
        stale["candidate"]["revision"] = "d" * 40
        with open(verdict_path, "w", encoding="utf-8") as handle:
            json.dump(stale, handle)
        result = subprocess.run(
            [
                sys.executable,
                script,
                "decide",
                "--candidate",
                candidate_path,
                "--verdict",
                verdict_path,
                "--dir",
                directory,
            ],
            capture_output=True,
            text=True,
        )
        check("the command line refuses a stale verdict", result.returncode == 1)
        check("and it names the mismatch", "different candidate" in result.stderr)
        same = subprocess.run(
            [sys.executable, script, "same", "--left", candidate_path, "--right", candidate_path],
            capture_output=True,
            text=True,
        )
        check("same accepts one candidate recorded twice", same.returncode == 0)
        different = subprocess.run(
            [sys.executable, script, "same", "--left", candidate_path, "--right", verdict_path],
            capture_output=True,
            text=True,
        )
        check("same refuses a candidate that moved", different.returncode == 1)
        recorded = subprocess.run(
            [sys.executable, script, "runner-image", "--candidate", candidate_path],
            capture_output=True,
            text=True,
        )
        check(
            "the command line prints the exact recorded runner digest",
            recorded.returncode == 0 and recorded.stdout.strip() == CANDIDATE["runner_image"],
        )
        tagged_path = os.path.join(directory, "tagged.json")
        with open(tagged_path, "w", encoding="utf-8") as handle:
            json.dump({**CANDIDATE, "runner_image": "ghcr.io/example/sol-migration-runner:latest"}, handle)
        tagged = subprocess.run(
            [sys.executable, script, "runner-image", "--candidate", tagged_path],
            capture_output=True,
            text=True,
        )
        check("the command line refuses a mutable tag as a runner identity", tagged.returncode == 2)


def main() -> int:
    global EVIDENCE_DIR
    print("release candidate promotion decision")
    with tempfile.TemporaryDirectory() as directory:
        EVIDENCE_DIR = directory
        test_identity()
        test_providers()
        test_rows()
        test_teardown_evidence()
        test_record()
        test_command_line()
    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
