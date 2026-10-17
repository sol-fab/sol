#!/usr/bin/env python3
"""Immutable release candidate identity and promotion eligibility.

A release tag builds exactly one candidate -- the release bundle and its
version-aligned migration-runner digest, tied to the tagged revision -- and
records it as a draft release. Nothing is published from the tag.

Promotion consumes that exact candidate. It refuses unless a qualification
verdict refers to the candidate by identity and reports the required AWS and
GCP rows passing, each with an independently observed absence verdict. The
verdict is produced by the explicitly operator-authorized live campaign; this
module makes no provider read and never treats a successful workflow, Sol's exit
code or Terraform state as qualification or absence evidence.

Candidate record:
  {"version": ..., "revision": ..., "bundle": ...,
   "bundle_sha256": ..., "runner_image": "<image>@sha256:<64 hex>"}

Qualification verdict:
  {"candidate": {"version": ..., "revision": ..., "bundle_sha256": ...,
                 "runner_image": ...},
   "providers": {"<name>": {"verdict": "pass"|"fail"|...,
                            "required_rows": ["B1", ...],
                            "rows": [{"id": ..., "status": ...,
                                      "reason": ..., "evidence": ...}],
                            "teardown": {
                              "absence_verdict": "pass",
                              "binding": {"provider": ..., "attempt": ...,
                                          "target": ..., "cluster": ...},
                              "evidence": {"path": ..., "sha256": ...}}}}}

Teardown evidence document (attached beside the verdict):
  {"schema": 1, "provider": ..., "candidate": {...},
   "attempt": ..., "target": ..., "scope": {"cluster": ..., ...},
   "required_classes": [...],
   "classes": [{"class": ..., "expectation": "absent"|"present",
                "state": "ABSENT"|"PRESENT"|"UNKNOWN", ...}],
   "verdict": "ABSENT"|"NOT ABSENT"}

Usage:
    promotion.py record --version V --revision R --bundle PATH
                        --runner-image IMAGE --out FILE
    promotion.py decide --candidate FILE --verdict FILE --dir DIR
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

IDENTITY_FIELDS = ("version", "revision", "bundle_sha256", "runner_image")
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")
HEX64 = re.compile(r"[0-9a-f]{64}")
REQUIRED_PROVIDERS = ("aws", "gcp")
EVIDENCE_SCHEMA = 1
EVIDENCE_EXPECTATIONS = ("absent", "present")
EVIDENCE_STATES = ("ABSENT", "PRESENT", "UNKNOWN")
MAX_EVIDENCE_BYTES = 8 * 1024 * 1024


class InputError(Exception):
    pass


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path: str) -> object:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise InputError(f"{path}: not found") from exc
    except json.JSONDecodeError as exc:
        raise InputError(f"{path}: not JSON: {exc}") from exc


def record(version: str, revision: str, bundle: str, runner_image: str) -> dict:
    if not version or not revision:
        raise InputError("record needs a version and a revision")
    if not os.path.isfile(bundle):
        raise InputError(f"record needs the built bundle, and {bundle} is not a file")
    if not DIGEST.search(runner_image or ""):
        raise InputError(
            f"runner image {runner_image!r} is not an <image>@sha256:<64 hex> reference"
        )
    return {
        "version": version,
        "revision": revision,
        "bundle": os.path.basename(bundle),
        "bundle_sha256": sha256_file(bundle),
        "runner_image": runner_image,
    }


def identity(record: dict) -> dict:
    return {field: record.get(field) for field in IDENTITY_FIELDS}


def runner_image(candidate: object) -> str:
    """Return the candidate's migration-runner digest reference, refusing anything else.

    A mutable tag is never a substituted identity for the digest the candidate
    recorded; promotion looks up exactly this reference.
    """
    if not isinstance(candidate, dict):
        raise InputError("the candidate record is not a JSON object")
    value = candidate.get("runner_image")
    if not isinstance(value, str) or not DIGEST.search(value):
        raise InputError(
            "the candidate's migration-runner image "
            f"{value!r} is not an <image>@sha256:<64 hex> reference"
        )
    return value


def verify_bundle(candidate: object, directory: str) -> None:
    """Raise unless the candidate's recorded bundle is present and matches its digest."""
    if not isinstance(candidate, dict):
        raise InputError("the candidate record is not a JSON object")
    name = candidate.get("bundle")
    digest = candidate.get("bundle_sha256")
    if not isinstance(name, str) or name == "":
        raise InputError("the candidate record names no bundle")
    path = os.path.join(directory, name)
    if not os.path.isfile(path):
        raise InputError(f"the recorded bundle {name} is not present in {directory}")
    actual = sha256_file(path)
    if actual != digest:
        raise InputError(
            f"the bundle {name} has sha256:{actual}, not the recorded sha256:{digest}"
        )


def decide(
    candidate: object,
    verdict: object | None,
    directory: object,
    required_providers=REQUIRED_PROVIDERS,
) -> list[str]:
    """Return the reasons this candidate may not be promoted; empty means eligible.

    `directory` is where the evidence attached to the verdict lives. A teardown
    claim is promotion-eligible only when it names a file there whose bytes,
    candidate/provider/attempt/target binding, class coverage and own verdict
    all verify; `absence_verdict: "pass"` alone is not enough.
    """
    if not isinstance(candidate, dict):
        return ["the candidate record is not a JSON object"]
    reasons = []
    for field in IDENTITY_FIELDS:
        value = candidate.get(field)
        if not isinstance(value, str) or value == "":
            reasons.append(f"the candidate record has no {field!r}")
    if not DIGEST.search(candidate.get("runner_image") or ""):
        reasons.append("the candidate's migration-runner image is not a digest reference")
    if not HEX64.fullmatch(candidate.get("bundle_sha256") or ""):
        reasons.append("the candidate's bundle digest is not a sha256")
    if reasons:
        return reasons

    if verdict is None:
        return ["no qualification verdict is attached to the candidate"]
    if not isinstance(verdict, dict):
        return ["the qualification verdict is not a JSON object"]
    claimed = verdict.get("candidate")
    if not isinstance(claimed, dict):
        reasons.append("the qualification verdict names no candidate")
    elif identity(claimed) != identity(candidate):
        reasons.append(
            "the qualification verdict refers to a different candidate than this release"
        )
    providers = verdict.get("providers")
    if not isinstance(providers, dict):
        reasons.append("the qualification verdict names no providers")
        return reasons
    if not isinstance(directory, str) or directory == "":
        reasons.append("no attached evidence directory was supplied")
        return reasons
    for provider in required_providers:
        reasons.extend(
            provider_reasons(provider, providers.get(provider), candidate, directory)
        )
    return reasons


def nonempty(value: object) -> bool:
    return isinstance(value, str) and value != ""


def verify_teardown(
    provider: str, entry: object, candidate: dict, directory: str
) -> list[str]:
    """Return the reasons this provider's teardown claim is not verified.

    Only the recorded evidence is read. This function never observes the
    provider, and it does not reconstruct the provider's inventory: the
    producer owns the class universe; this gate verifies that the document is
    complete against the universe it declares and that every recorded state is
    terminal.
    """
    if not isinstance(entry, dict):
        return [f"no {provider} qualification verdict"]
    teardown = entry.get("teardown")
    if not isinstance(teardown, dict):
        return [f"the {provider} verdict has no teardown result"]
    if teardown.get("absence_verdict") != "pass":
        return [f"the {provider} verdict has no independently observed passing absence result"]

    reasons: list[str] = []
    binding = teardown.get("binding")
    if not isinstance(binding, dict):
        return [f"the {provider} teardown claim names no candidate/attempt/target binding"]
    for field in ("provider", "attempt", "target", "cluster"):
        if not nonempty(binding.get(field)):
            reasons.append(f"the {provider} teardown binding has no {field!r}")
    if binding.get("provider") != provider:
        reasons.append(
            f"the {provider} teardown binding names provider {binding.get('provider')!r}, "
            f"not {provider!r}"
        )

    evidence = teardown.get("evidence")
    if not isinstance(evidence, dict):
        reasons.append(f"the {provider} teardown claim names no evidence member")
        return reasons
    path = evidence.get("path")
    digest = evidence.get("sha256")
    if not nonempty(path):
        reasons.append(f"the {provider} teardown evidence names no path")
    elif (
        os.path.isabs(path)
        or os.path.basename(path) != path
        or path in (".", "..")
        or "\\" in path
        or "\x00" in path
    ):
        reasons.append(
            f"the {provider} teardown evidence path {path!r} is not a plain file name"
        )
    if not isinstance(digest, str) or not HEX64.fullmatch(digest):
        reasons.append(f"the {provider} teardown evidence digest is not a sha256")
    if reasons:
        return reasons

    base = os.path.realpath(directory)
    if not os.path.isdir(base):
        return [f"the attached evidence directory {directory!r} is not a directory"]
    real = os.path.realpath(os.path.join(base, path))
    if os.path.dirname(real) != base:
        return [
            f"the {provider} teardown evidence {path!r} is not inside the attached evidence"
        ]
    try:
        if not os.path.isfile(real):
            return [f"the {provider} teardown evidence {path!r} is not attached"]
        if os.path.getsize(real) > MAX_EVIDENCE_BYTES:
            return [
                f"the {provider} teardown evidence {path!r} is larger than "
                f"{MAX_EVIDENCE_BYTES} bytes"
            ]
        with open(real, "rb") as handle:
            data = handle.read()
    except OSError as error:
        return [
            f"the {provider} teardown evidence {path!r} is not readable: "
            f"{error.strerror or error}"
        ]

    actual = hashlib.sha256(data).hexdigest()
    if actual != digest:
        return [
            f"the {provider} teardown evidence {path!r} has sha256:{actual}, "
            f"not the recorded sha256:{digest}"
        ]
    try:
        document = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return [f"the {provider} teardown evidence {path!r} is not JSON: {error}"]
    if not isinstance(document, dict):
        return [f"the {provider} teardown evidence {path!r} is not a JSON object"]

    if document.get("schema") != EVIDENCE_SCHEMA:
        reasons.append(
            f"the {provider} teardown evidence has schema {document.get('schema')!r}, "
            f"not {EVIDENCE_SCHEMA}"
        )
    if document.get("provider") != provider:
        reasons.append(
            f"the {provider} teardown evidence names provider "
            f"{document.get('provider')!r}, not {provider!r}"
        )
    scope = document.get("scope")
    scope_cluster = scope.get("cluster") if isinstance(scope, dict) else None
    observed = {
        "attempt": document.get("attempt"),
        "target": document.get("target"),
        "cluster": scope_cluster,
    }
    for field, value in observed.items():
        if value != binding.get(field):
            reasons.append(
                f"the {provider} teardown evidence binds {field} {value!r}, "
                f"not the claim's {binding.get(field)!r}"
            )
    if not nonempty(scope_cluster):
        reasons.append(f"the {provider} teardown evidence records no cluster scope")
    claimed_candidate = document.get("candidate")
    if not isinstance(claimed_candidate, dict) or identity(claimed_candidate) != identity(
        candidate
    ):
        reasons.append(f"the {provider} teardown evidence does not name this candidate")

    required = document.get("required_classes")
    if (
        not isinstance(required, list)
        or not required
        or not all(nonempty(name) for name in required)
    ):
        reasons.append(f"the {provider} teardown evidence names no required class universe")
        required = []
    elif len(set(required)) != len(required):
        reasons.append(f"the {provider} teardown evidence repeats a required class")

    classes = document.get("classes")
    if not isinstance(classes, list) or not classes:
        reasons.append(f"the {provider} teardown evidence records no class observations")
        classes = []
    seen: dict[str, dict] = {}
    for row in classes:
        if not isinstance(row, dict):
            reasons.append(
                f"the {provider} teardown evidence has a class row that is not an object"
            )
            continue
        name = row.get("class")
        if not nonempty(name):
            reasons.append(f"the {provider} teardown evidence has a class row with no class")
            continue
        if name in seen:
            reasons.append(
                f"the {provider} teardown evidence observes class {name!r} more than once"
            )
            continue
        seen[name] = row
        expectation = row.get("expectation")
        state = row.get("state")
        if expectation not in EVIDENCE_EXPECTATIONS:
            reasons.append(
                f"the {provider} teardown class {name!r} has expectation {expectation!r}"
            )
        if state not in EVIDENCE_STATES:
            reasons.append(f"the {provider} teardown class {name!r} has state {state!r}")
        elif expectation == "absent" and state != "ABSENT":
            reasons.append(f"the {provider} teardown class {name!r} is {state}, not ABSENT")
        elif expectation == "present" and state != "PRESENT":
            reasons.append(f"the {provider} teardown class {name!r} is {state}, not PRESENT")

    if isinstance(required, list) and isinstance(classes, list):
        missing = [name for name in required if name not in seen]
        extra = [name for name in seen if name not in required]
        if missing:
            reasons.append(
                f"the {provider} teardown evidence does not observe required class(es): "
                f"{', '.join(missing)}"
            )
        if extra:
            reasons.append(
                f"the {provider} teardown evidence observes undeclared class(es): "
                f"{', '.join(extra)}"
            )
    if document.get("verdict") != "ABSENT":
        reasons.append(
            f"the {provider} teardown evidence records verdict "
            f"{document.get('verdict')!r}, not 'ABSENT'"
        )
    return reasons


def provider_reasons(
    provider: str, entry: object, candidate: dict, directory: str
) -> list[str]:
    if not isinstance(entry, dict):
        return [f"no {provider} qualification verdict"]
    reasons = []
    if entry.get("verdict") != "pass":
        reasons.append(f"the {provider} verdict is {entry.get('verdict')!r}, not 'pass'")
    reasons.extend(verify_teardown(provider, entry, candidate, directory))
    required = entry.get("required_rows")
    if not isinstance(required, list) or not required:
        reasons.append(f"the {provider} verdict names no release-blocking row set")
        required = []
    rows = entry.get("rows")
    if not isinstance(rows, list) or not rows:
        reasons.append(f"the {provider} verdict lists no rows")
        return reasons
    by_id: dict[str, dict] = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or row["id"] == "":
            reasons.append(f"the {provider} verdict has a row with no id")
            continue
        by_id[row["id"]] = row
        status = row.get("status")
        if status == "pass":
            continue
        if status in ("excluded", "blocked", "not_run"):
            if not isinstance(row.get("reason"), str) or row["reason"] == "":
                reasons.append(f"{provider} row {row['id']} is {status!r} without a reason")
            continue
        reasons.append(f"{provider} row {row['id']} is {status!r}, not 'pass'")
    for row_id in required:
        row = by_id.get(row_id)
        if row is None:
            reasons.append(f"the {provider} verdict omits release-blocking row {row_id}")
        elif row.get("status") != "pass":
            reasons.append(
                f"{provider} release-blocking row {row_id} is {row.get('status')!r}, not 'pass'"
            )
    return reasons


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    record_parser = commands.add_parser("record")
    record_parser.add_argument("--version", required=True)
    record_parser.add_argument("--revision", required=True)
    record_parser.add_argument("--bundle", required=True)
    record_parser.add_argument("--runner-image", required=True)
    record_parser.add_argument("--out", required=True)
    decide_parser = commands.add_parser("decide")
    decide_parser.add_argument("--candidate", required=True)
    decide_parser.add_argument("--verdict", required=True)
    decide_parser.add_argument(
        "--dir",
        required=True,
        help="the directory holding the candidate bundle and the evidence the verdict names",
    )
    same_parser = commands.add_parser("same")
    same_parser.add_argument("--left", required=True)
    same_parser.add_argument("--right", required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--candidate", required=True)
    verify_parser.add_argument("--dir", required=True)
    runner_parser = commands.add_parser("runner-image")
    runner_parser.add_argument("--candidate", required=True)
    args = parser.parse_args(argv[1:])
    try:
        if args.command == "record":
            data = record(args.version, args.revision, args.bundle, args.runner_image)
            with open(args.out, "w", encoding="utf-8") as handle:
                json.dump(data, handle, indent=2, sort_keys=True)
                handle.write("\n")
            print(f"recorded candidate {data['version']} at {args.out}")
            return 0
        if args.command == "same":
            if load(args.left) == load(args.right):
                print(f"{args.left} and {args.right} record the same candidate")
                return 0
            print("the recorded candidate differs from the rebuilt one", file=sys.stderr)
            return 1
        if args.command == "verify":
            verify_bundle(load(args.candidate), args.dir)
            print("the recorded bundle matches the candidate identity")
            return 0
        if args.command == "runner-image":
            print(runner_image(load(args.candidate)))
            return 0
        candidate = load(args.candidate)
        verdict = load(args.verdict)
        reasons = decide(candidate, verdict, args.dir)
        if reasons:
            print("promotion refused:", file=sys.stderr)
            for reason in reasons:
                print(f"  - {reason}", file=sys.stderr)
            return 1
        print(
            f"candidate {candidate['version']} ({candidate['revision']}) is eligible for promotion"
        )
        print(f"  bundle {candidate['bundle']} sha256:{candidate['bundle_sha256']}")
        print(f"  runner {candidate['runner_image']}")
        return 0
    except InputError as exc:
        print(f"promotion: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
