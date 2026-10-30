#!/usr/bin/env python3
"""Contract-derived qualification producer mapping tests."""

from __future__ import annotations

import copy
import json
import os
import pathlib
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "internal" / "qualification"))
import evidence_manifest  # noqa: E402

checks = 0
failures = 0
CONTRACT = json.loads(
    (REPO / "internal/qualification/qualification-contract.json").read_text()
)
REVISION = "a" * 40
CANDIDATE = {
    "version": "v0.0.0-test",
    "revision": REVISION,
    "bundle_sha256": "b" * 64,
    "runner_image": "ghcr.io/example/runner@sha256:" + "c" * 64,
}


def check(label: str, condition: bool) -> None:
    global checks, failures
    checks += 1
    if condition:
        print(f"  [OK]   {label}")
    else:
        print(f"  [FAIL] {label}")
        failures += 1


def reason(label: str, fn, needle: str) -> None:
    try:
        fn()
    except evidence_manifest.ManifestError as error:
        check(label, needle in str(error))
    else:
        check(label + " (did not refuse)", False)


def attempt(directory: str, provider: str) -> None:
    files = {
        "attempt.txt": "\n".join(
            [
                f"attempt={provider}-1",
                f"target=qual-{provider}/{provider}/example",
                f"cluster=sol-qual-{provider}",
                f"provider={provider}",
                "claim=production",
                "issuer=letsencrypt-prod",
                f"candidate_revision={REVISION}",
                "promotion_eligible=yes",
            ]
        ),
        "phase-verdicts.txt": "\n".join(
            [
                "phase=prepare exit=0 at=2026-10-25T00:00:00Z",
                "phase=cloud exit=0 at=2026-10-25T00:01:00Z",
                "phase=app exit=0 at=2026-10-25T00:02:00Z",
                "phase=destroy exit=0 at=2026-10-25T00:03:00Z",
            ]
        ),
        "candidate-binding.txt": f"harness_revision: {REVISION}\n",
        "profile-target.yml": "profile: production-single-region\n"
        "deploy_role_arn: arn:aws:iam::123456789012:role/sol-deploy\n",
        "cloud-apply.log": "cloud applied\n",
    }
    for name, text in files.items():
        with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
            handle.write(text)
    names = {
        "aws": [
            "app-transaction.log",
            "app-transaction-ts.txt",
            "cloud-destroy.log",
            "aws-pre-teardown-identities.json",
            "app-deploy-gate.log",
            "app-deploy.log",
        ],
        "gcp": [
            "app-transaction-ocaml.txt",
            "app-transaction-ts.txt",
            "app-deploy-bootstrap.log",
            "bindings-provisioner-subjects.log",
            "destroy.log",
        ],
    }[provider]
    for name in names:
        with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
            handle.write(f"{name} evidence\n")


def build(directory: str, provider: str, contract: dict | None = None) -> dict:
    return evidence_manifest.build(
        provider, directory, contract or CONTRACT, CANDIDATE
    )


def main() -> int:
    print("qualification producer manifest")
    with tempfile.TemporaryDirectory() as directory:
        for provider in ("aws", "gcp"):
            path = os.path.join(directory, provider)
            os.makedirs(path)
            attempt(path, provider)
            manifest = build(path, provider)
            required = [
                family["ids"][provider]
                for family in CONTRACT["claims"]
                if provider in family.get("ids", {})
            ]
            check(
                f"{provider}: contract claim ids are emitted",
                sorted(claim["id"] for claim in manifest["claims"]) == sorted(required),
            )
            check(
                f"{provider}: the contract profile is typed",
                manifest["profile"]["kind"] == "production-single-region/v1",
            )
            check(
                f"{provider}: the profile observation is mechanism evidence",
                manifest["profile"]["observations"] == ["profile"]
                and any(
                    observation["id"] == "profile"
                    and observation["evidence"][0]["class"] == "mechanism"
                    for observation in manifest["observations"]
                ),
            )
            check(
                f"{provider}: every phase has evidence",
                [phase["name"] for phase in manifest["phases"]]
                == ["prepare", "cloud", "app", "destroy"],
            )
            check(
                f"{provider}: the permission binding is explicit",
                manifest["permission_binding"]["observations"] == ["permission"],
            )

        missing = os.path.join(directory, "missing")
        os.makedirs(missing)
        attempt(missing, "aws")
        os.unlink(os.path.join(missing, "app-transaction.log"))
        reason("missing claim evidence refuses", lambda: build(missing, "aws"), "required evidence")

        unknown = copy.deepcopy(CONTRACT)
        unknown["claims"].append(
            {
                "family": "unmapped-family",
                "evidence_class": "behavioral",
                "test": "x",
                "ids": {"aws": "ZZ", "gcp": "ZZ"},
            }
        )
        reason(
            "a contract family with no producer operation refuses",
            lambda: build(os.path.join(directory, "aws"), "aws", unknown),
            "no producer mapping",
        )
    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
