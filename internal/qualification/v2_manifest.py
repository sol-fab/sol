#!/usr/bin/env python3
"""Build a v2 evidence manifest from a completed attempt directory.

Required claims, phases, profile and selection come from the canonical contract.
This producer owns only the mapping from a claim family to the evidence its
operation actually produced; it never decides that the contract requires a
different claim set.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys


class ManifestError(Exception):
    pass


# The operation that establishes each contract claim family.
CLAIM_OBSERVATIONS = {
    "application-transaction": ["transaction"],
    "destroy-preparation": ["destroy-preparation"],
}

# Evidence each observation actually produced, relative to the attempt directory.
EVIDENCE = {
    "aws": {
        "profile": (["v2-target.yml"], "mechanism"),
        "transaction": (["app-transaction.log"], "behavioral"),
        "destroy-preparation": (
            ["cloud-destroy.log", "aws-pre-teardown-identities.json"],
            "behavioral",
        ),
        "boundary": (["app-deploy-gate.log"], "behavioral"),
        "permission": (["app-deploy.log"], "behavioral"),
    },
    "gcp": {
        "profile": (["v2-target.yml"], "mechanism"),
        "transaction": (
            ["app-transaction-ocaml.txt", "app-transaction-ts.txt"],
            "behavioral",
        ),
        "boundary": (["app-deploy-bootstrap.log"], "behavioral"),
        "permission": (["bindings-provisioner-subjects.log"], "behavioral"),
    },
}

PHASE_EVIDENCE = {
    "aws": {
        "prepare": ["candidate-binding.txt"],
        "cloud": ["cloud-apply.log"],
        "app": ["app-transaction.log"],
        "destroy": ["cloud-destroy.log"],
    },
    "gcp": {
        "prepare": ["candidate-binding.txt"],
        "cloud": ["cloud-apply.log"],
        "app": ["app-transaction-ocaml.txt", "app-transaction-ts.txt"],
        "destroy": ["destroy.log"],
    },
}

BOUNDARY = {"aws": "artifact-gate", "gcp": "migration-gate"}


def load(path: str) -> object:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as error:
        raise ManifestError(f"{path}: {error}") from error
    except json.JSONDecodeError as error:
        raise ManifestError(f"{path}: not JSON: {error}") from error


def evidence(directory: str, names: list[str], class_: str) -> list[dict]:
    entries = []
    for name in names:
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            raise ManifestError(f"required evidence {name!r} is not in {directory}")
        if os.path.getsize(path) == 0:
            raise ManifestError(f"required evidence {name!r} is empty")
        entries.append({"path": name, "class": class_})
    return entries


def attempt_field(directory: str, key: str) -> str | None:
    path = os.path.join(directory, "attempt.txt")
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                name, separator, value = line.rstrip("\n").partition("=")
                if separator and name == key and value != "":
                    return value
    except OSError as error:
        raise ManifestError(f"{path}: {error}") from error
    return None


def target_field(directory: str, key: str) -> str | None:
    path = os.path.join(directory, "v2-target.yml")
    try:
        with open(path, encoding="utf-8") as handle:
            pattern = re.compile(rf"^\s*{re.escape(key)}:\s*(.+?)\s*$")
            for line in handle:
                match = pattern.match(line)
                if match:
                    return match.group(1).strip().strip('"')
    except OSError:
        return None
    return None


def harness_revision(directory: str, candidate: dict) -> str:
    path = os.path.join(directory, "candidate-binding.txt")
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                name, separator, value = line.partition(":")
                if separator and name.strip() == "harness_revision" and value.strip():
                    return value.strip()
    except OSError:
        pass
    revision = candidate.get("revision")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ManifestError("candidate has no 40-hex revision")
    return revision


def permission(provider: str, directory: str, candidate: dict) -> dict:
    if provider == "aws":
        identity = target_field(directory, "deploy_role_arn")
        if not identity:
            raise ManifestError("AWS target declares no deploy_role_arn")
        return {
            "deploy_identity": identity,
            "mechanism": "direct",
            "subject": identity,
            "observations": ["permission"],
        }
    identity = "sol-deploy"
    subject = "sol:deployers"
    return {
        "deploy_identity": identity,
        "mechanism": "group",
        "subject": subject,
        "observations": ["permission"],
    }


def build(provider: str, directory: str, contract: dict, candidate: dict) -> dict:
    if provider not in ("aws", "gcp"):
        raise ManifestError(f"unknown provider {provider!r}")
    if contract.get("schema") != 2:
        raise ManifestError("the contract is not schema 2")
    if provider not in contract.get("providers", []):
        raise ManifestError(f"{provider} is not a contract provider")
    profile = contract.get("profile")
    if not isinstance(profile, str) or profile == "":
        raise ManifestError("the contract names no profile")
    selection = contract.get("selection")
    if not isinstance(selection, dict):
        raise ManifestError("the contract names no selection")
    phases = contract.get("phases")
    if not isinstance(phases, list) or not phases:
        raise ManifestError("the contract names no phases")

    mapped_evidence = EVIDENCE[provider]
    observations = []
    for name in ("profile", "transaction", "boundary", "permission"):
        if name not in mapped_evidence:
            raise ManifestError(f"{provider} has no evidence mapping for {name!r}")
        names, class_ = mapped_evidence[name]
        observations.append(
            {"id": name, "evidence": evidence(directory, names, class_)}
        )

    claims = []
    exceptions = {
        (row.get("family"), row.get("provider"))
        for row in contract.get("exceptions", [])
        if isinstance(row, dict)
    }
    for family in contract.get("claims", []):
        claim_id = family.get("ids", {}).get(provider)
        if claim_id is None:
            if (family.get("family"), provider) not in exceptions:
                raise ManifestError(
                    f"contract family {family.get('family')!r} neither maps "
                    f"{provider} nor declares an exception"
                )
            continue
        observation_ids = CLAIM_OBSERVATIONS.get(family.get("family"))
        if observation_ids is None:
            raise ManifestError(
                f"no producer mapping for contract family {family.get('family')!r}"
            )
        if family.get("family") == "destroy-preparation":
            names, class_ = mapped_evidence["destroy-preparation"]
            observations.append(
                {"id": "destroy-preparation", "evidence": evidence(directory, names, class_)}
            )
        claims.append(
            {"id": claim_id, "status": "pass", "observations": observation_ids}
        )

    phase_entries = []
    for phase in phases:
        names = PHASE_EVIDENCE[provider].get(phase)
        if names is None:
            raise ManifestError(f"no producer mapping for phase {phase!r}")
        phase_entries.append(
            {"name": phase, "evidence": evidence(directory, names, "behavioral")}
        )

    return {
        "schema": 1,
        "provider": provider,
        "harness_revision": harness_revision(directory, candidate),
        "profile": {"kind": profile, "observations": ["profile"]},
        "selection": selection,
        "boundary": {
            "kind": BOUNDARY[provider],
            "observations": ["boundary"],
        },
        "permission_binding": permission(provider, directory, candidate),
        "phases": phase_entries,
        "observations": observations,
        "claims": claims,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=["aws", "gcp"])
    parser.add_argument("--attempt-dir", required=True)
    parser.add_argument("--contract", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv[1:])
    try:
        contract = load(args.contract)
        candidate = load(args.candidate)
        manifest = build(args.provider, args.attempt_dir, contract, candidate)
    except ManifestError as error:
        print(f"v2_manifest: {error}", file=sys.stderr)
        return 1
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
