#!/usr/bin/env python3
"""Regression tests for the release-candidate promotion decision.

This release-policy decision stops a release from being published before the
authorized AWS and GCP qualification exists, and stops a verdict for one
candidate from promoting another. It verifies candidate identity and the
independently observed teardown evidence. Cross-provider claims and phases are
owned by the typed parity evaluator and its workflow artifact provenance, not by
a second required-row list here.

The teardown checks are decided against the versioned release teardown policy,
not against the evidence document's own declaration. The tests therefore build
their valid fixture from the policy: a self-consistent document that omits
policy classes, or reclassifies a disposable class as durable, must fail.

These tests establish the decision mechanics only -- they are not qualification
evidence.
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
POLICY = promotion.load_teardown_policy()

CANDIDATE = {
    "version": "v0.1.0-alpha.9",
    "revision": "a" * 40,
    "bundle": "sol-v0.1.0-alpha.9-linux-x86_64.tar.gz",
    "bundle_sha256": "b" * 64,
    "runner_image": "ghcr.io/example/sol-migration-runner@sha256:" + "c" * 64,
}

SCOPE = {
    "cluster": "cluster-1",
    "region": "us-east-1",
    "account": "123456789012",
    "project": "sol-qualification",
    "caller": "operator@example.invalid",
    "state_key": "sol/state",
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
    classes = [
        {
            "class": row["class"],
            "expectation": row["expectation"],
            "state": "ABSENT" if row["expectation"] == "absent" else "PRESENT",
        }
        for row in POLICY["providers"][provider]["classes"]
    ]
    return {
        "schema": 1,
        "policy": POLICY["policy"],
        "provider": provider,
        "candidate": promotion.identity(CANDIDATE),
        "attempt": "attempt-1",
        "target": "target-1",
        "scope": dict(SCOPE),
        "required_classes": [row["class"] for row in classes],
        "classes": classes,
        "verdict": "ABSENT",
    }


def default_binding(provider: str) -> dict:
    return {
        "provider": provider,
        "attempt": "attempt-1",
        "target": "target-1",
        "cluster": SCOPE["cluster"],
        "scope": {
            field: SCOPE[field] for field in POLICY["providers"][provider]["scope_fields"]
        },
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
            "aws": {"teardown": aws if aws is not None else teardown("aws")},
            "gcp": {"teardown": gcp if gcp is not None else teardown("gcp")},
        },
    }


def refuses(label: str, candidate, document) -> None:
    check(label, promotion.release_policy_reasons(candidate, document, EVIDENCE_DIR) != [])


def refuses_with(label: str, document, needle: str, candidate=CANDIDATE) -> None:
    reasons = promotion.release_policy_reasons(candidate, document, EVIDENCE_DIR)
    matched = bool(reasons) and any(needle in reason for reason in reasons)
    check(label, matched)
    if not matched:
        print(f"         reasons: {reasons}")


def allows(label: str, candidate, document) -> None:
    reasons = promotion.release_policy_reasons(candidate, document, EVIDENCE_DIR)
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
    reasons = promotion.release_policy_reasons(CANDIDATE, verdict(), "")
    check(
        "a decision without an attached evidence directory refuses",
        bool(reasons) and any("evidence directory" in reason for reason in reasons),
    )


def test_providers() -> None:
    refuses("a missing provider refuses", CANDIDATE, {**verdict(), "providers": {"aws": verdict()["providers"]["aws"]}})
    document = verdict()
    del document["providers"]["aws"]["teardown"]
    refuses("a provider without a teardown result refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["teardown"]["absence_verdict"] = "present"
    refuses("a provider whose absence result is not a pass refuses", CANDIDATE, document)


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

    changed_account = evidence_document("aws")
    changed_account["scope"]["account"] = "111122223333"
    document = verdict(aws=teardown("aws", document=changed_account))
    refuses_with("evidence from another account refuses", document, "binds account")

    changed_project = evidence_document("gcp")
    changed_project["scope"]["project"] = "another-project"
    document = verdict(gcp=teardown("gcp", document=changed_project))
    refuses_with("evidence from another project refuses", document, "binds project")

    missing_region = evidence_document("aws")
    del missing_region["scope"]["region"]
    document = verdict(aws=teardown("aws", document=missing_region))
    refuses_with("evidence without the policy scope refuses", document, "binds region")

    binding = default_binding("aws")
    del binding["scope"]["account"]
    document = verdict(aws=teardown("aws", binding=binding))
    refuses_with("a binding without the policy account scope refuses", document, "has no 'account' scope")

    binding = default_binding("aws")
    binding["scope"] = "us-east-1"
    document = verdict(aws=teardown("aws", binding=binding))
    refuses_with("a binding scope that is not an object refuses", document, "names no provider scope")

    truncated = evidence_document("aws")
    only = truncated["classes"][0]
    truncated["required_classes"] = [only["class"]]
    truncated["classes"] = [only]
    document = verdict(aws=teardown("aws", document=truncated))
    refuses_with(
        "a self-consistent truncated evidence document refuses",
        document,
        "incomplete required class universe",
    )

    for provider in ("aws", "gcp"):
        incomplete = evidence_document(provider)
        incomplete["classes"] = [row for row in incomplete["classes"] if row["class"] != "kafka-secret"]
        incomplete["required_classes"] = [name for name in incomplete["required_classes"] if name != "kafka-secret"]
        document = verdict(**{provider: teardown(provider, document=incomplete)})
        refuses_with(f"{provider}: omission of Kafka authority cannot shrink release requirements", document,
                     "incomplete required class universe")

    reclassified = evidence_document("aws")
    disposable = next(row for row in reclassified["classes"] if row["expectation"] == "absent")
    disposable["expectation"] = "present"
    disposable["state"] = "PRESENT"
    document = verdict(aws=teardown("aws", document=reclassified))
    refuses_with(
        "a disposable class reclassified as durable refuses",
        document,
        "declares expectation 'present'; the release policy requires 'absent'",
    )

    duplicate = evidence_document("aws")
    duplicate["classes"].append(dict(duplicate["classes"][0]))
    document = verdict(aws=teardown("aws", document=duplicate))
    refuses_with("a duplicated class refuses", document, "more than once")

    undeclared = evidence_document("aws")
    undeclared["classes"].append({"class": "class-c", "expectation": "absent", "state": "ABSENT"})
    document = verdict(aws=teardown("aws", document=undeclared))
    refuses_with(
        "an undeclared class refuses",
        document,
        "observes class(es) the release policy does not require",
    )

    unknown = evidence_document("aws")
    unknown["classes"][0]["state"] = "UNKNOWN"
    document = verdict(aws=teardown("aws", document=unknown))
    refuses_with(
        "an UNKNOWN disposable class refuses",
        document,
        "is UNKNOWN; the release policy requires ABSENT",
    )

    present = evidence_document("aws")
    present["classes"][0]["state"] = "PRESENT"
    document = verdict(aws=teardown("aws", document=present))
    refuses_with(
        "a PRESENT disposable class refuses",
        document,
        "is PRESENT; the release policy requires ABSENT",
    )

    missing_durable = evidence_document("aws")
    durable = next(row for row in missing_durable["classes"] if row["expectation"] == "present")
    durable["state"] = "ABSENT"
    document = verdict(aws=teardown("aws", document=missing_durable))
    refuses_with(
        "an absent durable prerequisite refuses",
        document,
        "is ABSENT; the release policy requires PRESENT",
    )

    unknown_policy = evidence_document("aws")
    unknown_policy["policy"] = "sol-teardown-v999"
    document = verdict(aws=teardown("aws", document=unknown_policy))
    refuses_with("evidence under an unknown policy refuses", document, "not the release policy")

    missing_policy = evidence_document("aws")
    del missing_policy["policy"]
    document = verdict(aws=teardown("aws", document=missing_policy))
    refuses_with("evidence without a policy identity refuses", document, "names no teardown policy")

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
    refuses_with(
        "an invalid expectation refuses",
        document,
        "declares expectation 'maybe'; the release policy requires 'absent'",
    )

    wrong_state = evidence_document("aws")
    wrong_state["classes"][0]["state"] = "GONE"
    document = verdict(aws=teardown("aws", document=wrong_state))
    refuses_with("an invalid state refuses", document, "has state 'GONE'")

    altered_entry = teardown("aws")
    altered_document = verdict(aws=altered_entry)
    with open(os.path.join(EVIDENCE_DIR, altered_entry["evidence"]["path"]), "wb") as handle:
        handle.write(b"{}")
    refuses_with("evidence altered after the claim was written refuses", altered_document, "has sha256:")


def test_policy_file() -> None:
    with tempfile.TemporaryDirectory() as directory:
        bad = os.path.join(directory, "bad-policy.json")
        with open(bad, "w", encoding="utf-8") as handle:
            json.dump({"schema": 1}, handle)
        reasons = promotion.release_policy_reasons(CANDIDATE, verdict(), EVIDENCE_DIR, policy_path=bad)
        check(
            "a malformed release policy refuses",
            bool(reasons) and any("release teardown policy" in reason for reason in reasons),
        )
        missing = os.path.join(directory, "missing-policy.json")
        reasons = promotion.release_policy_reasons(CANDIDATE, verdict(), EVIDENCE_DIR, policy_path=missing)
        check(
            "a missing release policy refuses",
            bool(reasons) and any("release teardown policy" in reason for reason in reasons),
        )


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
        gone = subprocess.run(
            [sys.executable, script, "decide", "--candidate", candidate_path],
            capture_output=True,
            text=True,
        )
        check("the obsolete pre-parity decide command is gone", gone.returncode == 2)
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
        test_teardown_evidence()
        test_policy_file()
        test_record()
        test_command_line()
    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
