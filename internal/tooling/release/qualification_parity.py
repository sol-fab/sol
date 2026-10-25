#!/usr/bin/env python3
"""Contract-bound cross-provider qualification parity.

This module owns the composition layer, not a second qualification policy.

A provider run record is valid only against the contract it names. Parity is the
separate question: do the provider records jointly satisfy the same contract,
for the same candidate, harness revision and selection, with the required
claims and phases?

Contract (input, canonical):
  {"schema": 1,
   "id": "<contract id>",
   "providers": ["aws", "gcp"],
   "claims": [{"id": "B1", "providers": ["aws", "gcp"]}, ...],
   "phases": ["prepare", "cloud", "app", "destroy", "verify"],
   "selection": {"languages": ["ocaml", "typescript"],
                 "primitives": ["svc", "worker"]},
   "exceptions": [{"claim": "...", "provider": "...",
                   "reason": "...", "test": "..."}]}

Provider run record (input):
  {"schema": 1,
   "provider": "aws",
   "candidate": {"version": ..., "revision": ..., "bundle_sha256": ...,
                 "runner_image": "<image>@sha256:<64 hex>"},
   "harness_revision": "<40-hex commit>",
   "contract": {"id": ..., "digest": "<sha256 of canonical contract>"},
   "selection": {"languages": [...], "primitives": [...]},
   "phases": [{"name": "cloud", "exit": 0}, ...],
   "claims": [{"id": "B1", "status": "pass", "evidence": "..."}, ...]}

Parity verdict (output):
  {"schema": 1,
   "kind": "cross-provider-qualification-parity",
   "contract": {"id": ..., "digest": ...},
   "candidate": {...},
   "harness_revision": ...,
   "selection": {...},
   "providers": {"aws": {"record_sha256": ...}, "gcp": {...}},
   "claims": [{"id": "B1", "providers": ["aws", "gcp"]}],
   "verdict": "PASS" | "REFUSED",
   "reasons": []}

The contract owns the required claim/phase/selection set. The parity verdict
binds the contract digest and the exact records by content hash. It does not
grant promotion authority; a separate authorization decision must consume it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys

SCHEMA = 1
VERDICT_KIND = "cross-provider-qualification-parity"
DEFAULT_PROVIDERS = ("aws", "gcp")
HEX40 = re.compile(r"[0-9a-f]{40}$")
HEX64 = re.compile(r"[0-9a-f]{64}$")
DIGEST_IMAGE = re.compile(r"@sha256:[0-9a-f]{64}$")
CLAIM_STATUSES = ("pass", "fail", "blocked", "not_run", "excluded")
EVIDENCE_FIELDS = ("version", "revision", "bundle_sha256", "runner_image")


class InputError(Exception):
    pass


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )


def sha256(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def contract_digest(contract: object) -> str:
    return sha256(contract)


def record_digest(record: object) -> str:
    return sha256(record)


def _nonempty(value: object) -> bool:
    return isinstance(value, str) and value != ""


def _strings(value: object, what: str) -> list[str]:
    if not isinstance(value, list) or not value or not all(_nonempty(item) for item in value):
        raise InputError(f"{what} must be a non-empty list of non-empty strings")
    if len(set(value)) != len(value):
        raise InputError(f"{what} repeats a value")
    return list(value)


def validate_contract(contract: object) -> dict:
    if not isinstance(contract, dict):
        raise InputError("the qualification contract is not a JSON object")
    if contract.get("schema") != SCHEMA:
        raise InputError(f"the qualification contract schema is not {SCHEMA}")
    if not _nonempty(contract.get("id")):
        raise InputError("the qualification contract has no id")
    providers = contract.get("providers", list(DEFAULT_PROVIDERS))
    providers = _strings(providers, "the contract providers")
    claims = contract.get("claims")
    if not isinstance(claims, list) or not claims:
        raise InputError("the qualification contract names no claims")
    claim_ids = []
    for claim in claims:
        if not isinstance(claim, dict) or not _nonempty(claim.get("id")):
            raise InputError("the qualification contract has a claim with no id")
        claim_id = claim["id"]
        if claim_id in claim_ids:
            raise InputError(f"the qualification contract repeats claim {claim_id!r}")
        claim_ids.append(claim_id)
        claim_providers = claim.get("providers", list(providers))
        _strings(claim_providers, f"claim {claim_id} providers")
        for provider in claim_providers:
            if provider not in providers:
                raise InputError(
                    f"claim {claim_id} names provider {provider!r}, not a contract provider"
                )
    phases = _strings(contract.get("phases"), "the contract phases")
    selection = contract.get("selection")
    if not isinstance(selection, dict):
        raise InputError("the qualification contract has no selection")
    _strings(selection.get("languages"), "the contract languages")
    _strings(selection.get("primitives"), "the contract primitives")
    exceptions = contract.get("exceptions", [])
    if not isinstance(exceptions, list):
        raise InputError("the contract exceptions are not a list")
    seen = set()
    for exception in exceptions:
        if not isinstance(exception, dict):
            raise InputError("a contract exception is not an object")
        claim = exception.get("claim")
        provider = exception.get("provider")
        if claim not in claim_ids:
            raise InputError(f"a contract exception names unknown claim {claim!r}")
        if provider not in providers:
            raise InputError(f"a contract exception names unknown provider {provider!r}")
        for field in ("reason", "test"):
            if not _nonempty(exception.get(field)):
                raise InputError(
                    f"the exception for {claim}/{provider} has no {field}; an exception "
                    "must be declared and tested, not a silent exclusion"
                )
        key = (claim, provider)
        if key in seen:
            raise InputError(f"the contract repeats the exception for {claim}/{provider}")
        seen.add(key)
    return contract


def contract_claims_for(contract: dict, provider: str) -> list[str]:
    return [
        claim["id"]
        for claim in contract["claims"]
        if provider in claim.get("providers", contract.get("providers", list(DEFAULT_PROVIDERS)))
    ]


def contract_exception(contract: dict, claim: str, provider: str) -> dict | None:
    for exception in contract.get("exceptions", []):
        if exception["claim"] == claim and exception["provider"] == provider:
            return exception
    return None


def validate_record(record: object, contract: dict) -> dict:
    if not isinstance(record, dict):
        raise InputError("a provider record is not a JSON object")
    if record.get("schema") != SCHEMA:
        raise InputError(f"a provider record schema is not {SCHEMA}")
    provider = record.get("provider")
    if provider not in contract.get("providers", list(DEFAULT_PROVIDERS)):
        raise InputError(f"a provider record names provider {provider!r}, not a contract provider")
    candidate = record.get("candidate")
    if not isinstance(candidate, dict):
        raise InputError(f"the {provider} record has no candidate")
    for field in EVIDENCE_FIELDS:
        if not _nonempty(candidate.get(field)):
            raise InputError(f"the {provider} record candidate has no {field}")
    if not DIGEST_IMAGE.search(candidate["runner_image"]):
        raise InputError(f"the {provider} record runner image is not a digest reference")
    if not HEX64.fullmatch(candidate["bundle_sha256"]):
        raise InputError(f"the {provider} record bundle sha256 is not a sha256")
    if not HEX40.fullmatch(record.get("harness_revision") or ""):
        raise InputError(f"the {provider} record has no 40-hex harness revision")
    named = record.get("contract")
    if not isinstance(named, dict):
        raise InputError(f"the {provider} record names no contract")
    if named.get("id") != contract.get("id"):
        raise InputError(
            f"the {provider} record names contract {named.get('id')!r}, "
            f"not {contract.get('id')!r}"
        )
    expected_digest = contract_digest(contract)
    if named.get("digest") != expected_digest:
        raise InputError(
            f"the {provider} record names contract digest {named.get('digest')!r}, "
            f"not the current contract digest {expected_digest}"
        )
    if record.get("selection") != contract["selection"]:
        raise InputError(f"the {provider} record selection is not the contract selection")
    phases = record.get("phases")
    if not isinstance(phases, list) or not phases:
        raise InputError(f"the {provider} record has no phases")
    seen_phases = {}
    for phase in phases:
        if not isinstance(phase, dict) or not _nonempty(phase.get("name")):
            raise InputError(f"the {provider} record has a phase with no name")
        name = phase["name"]
        if name in seen_phases:
            raise InputError(f"the {provider} record repeats phase {name!r}")
        seen_phases[name] = phase
        exit_code = phase.get("exit")
        if not isinstance(exit_code, int) or isinstance(exit_code, bool):
            raise InputError(f"the {provider} phase {name!r} has no integer exit")
    for required in contract["phases"]:
        phase = seen_phases.get(required)
        if phase is None:
            raise InputError(f"the {provider} record omits required phase {required!r}")
        if phase["exit"] != 0:
            raise InputError(f"the {provider} phase {required!r} exited {phase['exit']}")
    claims = record.get("claims")
    if not isinstance(claims, list) or not claims:
        raise InputError(f"the {provider} record has no claims")
    seen_claims = {}
    for claim in claims:
        if not isinstance(claim, dict) or not _nonempty(claim.get("id")):
            raise InputError(f"the {provider} record has a claim with no id")
        claim_id = claim["id"]
        if claim_id in seen_claims:
            raise InputError(f"the {provider} record repeats claim {claim_id!r}")
        status = claim.get("status")
        if status not in CLAIM_STATUSES:
            raise InputError(
                f"the {provider} claim {claim_id!r} has status {status!r}"
            )
        if status == "pass" and not _nonempty(claim.get("evidence")):
            raise InputError(
                f"the {provider} claim {claim_id!r} passes without an evidence reference"
            )
        if status == "excluded":
            exception = contract_exception(contract, claim_id, provider)
            if exception is None:
                raise InputError(
                    f"the {provider} claim {claim_id!r} is excluded without a contract exception"
                )
            if not _nonempty(claim.get("reason")):
                raise InputError(
                    f"the {provider} claim {claim_id!r} is excluded without a reason"
                )
        seen_claims[claim_id] = claim
    for claim_id in contract_claims_for(contract, provider):
        claim = seen_claims.get(claim_id)
        if claim is None:
            raise InputError(f"the {provider} record omits required claim {claim_id!r}")
        if claim["status"] not in ("pass", "excluded"):
            raise InputError(
                f"the {provider} required claim {claim_id!r} is {claim['status']!r}, not 'pass'"
            )
    return record


def evaluate(contract: object, records: dict[str, object]) -> dict:
    """Return a parity verdict; never raises for a refusal, only for bad input.

    A refusal is a correctly formed verdict with `verdict: REFUSED` and reasons.
    Input errors raise InputError because no honest verdict can be formed.
    """
    try:
        contract = validate_contract(contract)
    except InputError as error:
        raise InputError(f"the qualification contract is invalid: {error}") from error
    expected = list(contract.get("providers", list(DEFAULT_PROVIDERS)))
    missing = [provider for provider in expected if provider not in records]
    extra = [provider for provider in records if provider not in expected]
    if missing or extra:
        reasons = []
        if missing:
            reasons.append(f"missing provider record(s): {', '.join(missing)}")
        if extra:
            reasons.append(f"unexpected provider record(s): {', '.join(extra)}")
        return _refused(contract, records, reasons)
    checked = {}
    reasons = []
    for provider in expected:
        try:
            checked[provider] = validate_record(records[provider], contract)
            if checked[provider].get("provider") != provider:
                reasons.append(
                    f"the {provider} slot contains a record for "
                    f"{checked[provider].get('provider')!r}"
                )
        except InputError as error:
            reasons.append(f"{provider}: {error}")
    if reasons:
        return _refused(contract, records, reasons)
    candidates = {provider: checked[provider]["candidate"] for provider in expected}
    first = candidates[expected[0]]
    for provider in expected[1:]:
        if candidates[provider] != first:
            reasons.append(
                f"{provider} candidate differs from {expected[0]} candidate"
            )
    harness = {provider: checked[provider]["harness_revision"] for provider in expected}
    first_harness = harness[expected[0]]
    for provider in expected[1:]:
        if harness[provider] != first_harness:
            reasons.append(
                f"{provider} harness revision {harness[provider]!r} differs from "
                f"{expected[0]} harness revision {first_harness!r}"
            )
    for provider in expected:
        for claim_id in contract_claims_for(contract, provider):
            row = next(
                claim for claim in checked[provider]["claims"] if claim["id"] == claim_id
            )
            if row["status"] == "excluded" and contract_exception(
                contract, claim_id, provider
            ) is None:
                reasons.append(
                    f"{provider} claim {claim_id!r} is excluded without a contract exception"
                )
    claims = []
    for claim in contract["claims"]:
        claim_providers = claim.get("providers", expected)
        claims.append({"id": claim["id"], "providers": list(claim_providers)})
    if reasons:
        return _refused(contract, records, reasons)
    verdict = {
        "schema": SCHEMA,
        "kind": VERDICT_KIND,
        "contract": {"id": contract["id"], "digest": contract_digest(contract)},
        "candidate": first,
        "harness_revision": first_harness,
        "selection": contract["selection"],
        "providers": {
            provider: {"record_sha256": record_digest(records[provider])}
            for provider in expected
        },
        "claims": claims,
        "verdict": "PASS",
        "reasons": [],
    }
    return verdict


def _refused(contract: object, records: dict[str, object], reasons: list[str]) -> dict:
    candidate = None
    for record in records.values():
        if isinstance(record, dict) and isinstance(record.get("candidate"), dict):
            candidate = record["candidate"]
            break
    return {
        "schema": SCHEMA,
        "kind": VERDICT_KIND,
        "contract": {
            "id": contract.get("id") if isinstance(contract, dict) else None,
            "digest": contract_digest(contract) if isinstance(contract, dict) else None,
        },
        "candidate": candidate,
        "harness_revision": next(
            (
                record.get("harness_revision")
                for record in records.values()
                if isinstance(record, dict)
            ),
            None,
        ),
        "selection": (
            contract.get("selection") if isinstance(contract, dict) else None
        ),
        "providers": {
            provider: {"record_sha256": record_digest(record)}
            for provider, record in records.items()
        },
        "claims": [],
        "verdict": "REFUSED",
        "reasons": reasons,
    }


def load(path: str) -> object:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise InputError(f"{path}: not found") from exc
    except json.JSONDecodeError as exc:
        raise InputError(f"{path}: not JSON: {exc}") from exc


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", required=True)
    parser.add_argument("--aws", required=True)
    parser.add_argument("--gcp", required=True)
    parser.add_argument("--out")
    args = parser.parse_args(argv[1:])
    try:
        contract = load(args.contract)
        records = {"aws": load(args.aws), "gcp": load(args.gcp)}
        verdict = evaluate(contract, records)
    except InputError as error:
        print(f"qualification_parity: {error}", file=sys.stderr)
        return 2
    text = json.dumps(verdict, indent=2, sort_keys=True) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    return 0 if verdict["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
