#!/usr/bin/env python3
"""Immutable release candidate identity and v2 promotion authorization.

A release tag builds exactly one candidate. Qualification attaches provider
records, evidence archives, the canonical contract and a typed parity verdict.
Promotion authorizes publishing that exact candidate only when the recorded
bundle still hashes to the candidate identity; the release teardown policy
verifies independently observed absence; the typed parity verdict names this
candidate and contract; a successful run of the authorized release workflow on
the candidate's immutable revision produced a `qualification-release` artifact
whose bytes match the verdict's evaluator digest; and that exact artifact
reports the candidate revision and its own digest, then reproduces the recorded
verdict over the attached evidence.

A draft release attachment is not a trust root: the evaluator comes from the
workflow run artifact. There is no source-only fallback and no v1 parity
evaluator.

Candidate record:
  {"version": ..., "revision": ..., "bundle": ...,
   "bundle_sha256": ..., "runner_image": "<image>@sha256:<64 hex>"}
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

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


def canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


TEARDOWN_POLICY_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "teardown-policy.v1.json"
)


def load_teardown_policy(path: str | None = None) -> dict:
    """Load the versioned release teardown policy.

    The policy, not the evidence document, decides which resource classes a
    candidate's teardown must cover and whether each must be absent or present.
    It is a reviewed release artefact; the producer only reports observations.
    """
    path = path or TEARDOWN_POLICY_PATH
    document = load(path)
    if not isinstance(document, dict):
        raise InputError(f"{path}: the teardown policy is not a JSON object")
    if document.get("schema") != 1:
        raise InputError(f"{path}: the teardown policy schema is not 1")
    if not nonempty(document.get("policy")):
        raise InputError(f"{path}: the teardown policy has no name")
    providers = document.get("providers")
    if not isinstance(providers, dict):
        raise InputError(f"{path}: the teardown policy names no providers")
    for provider in REQUIRED_PROVIDERS:
        entry = providers.get(provider)
        if not isinstance(entry, dict):
            raise InputError(f"{path}: the teardown policy has no {provider} entry")
        fields = entry.get("scope_fields")
        if (
            not isinstance(fields, list)
            or not fields
            or not all(nonempty(field) for field in fields)
            or len(set(fields)) != len(fields)
        ):
            raise InputError(f"{path}: the {provider} policy names no usable scope fields")
        classes = entry.get("classes")
        if not isinstance(classes, list) or not classes:
            raise InputError(f"{path}: the {provider} policy names no classes")
        seen: set[str] = set()
        for row in classes:
            if not isinstance(row, dict):
                raise InputError(f"{path}: a {provider} class is not an object")
            name = row.get("class")
            expectation = row.get("expectation")
            if not nonempty(name) or expectation not in EVIDENCE_EXPECTATIONS:
                raise InputError(f"{path}: the {provider} policy has an invalid class row")
            if name in seen:
                raise InputError(f"{path}: the {provider} policy repeats class {name!r}")
            seen.add(name)
    return document


def policy_provider(policy: dict, provider: str) -> tuple[dict[str, str], list[str]]:
    entry = policy["providers"][provider]
    classes = {row["class"]: row["expectation"] for row in entry["classes"]}
    return classes, list(entry["scope_fields"])


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



def nonempty(value: object) -> bool:
    return isinstance(value, str) and value != ""


def verify_teardown(
    provider: str, entry: object, candidate: dict, directory: str, policy: dict
) -> list[str]:
    """Return the reasons this provider's teardown claim is not verified.

    Only the recorded evidence is read. This function never observes the
    provider. The release teardown policy decides the required class set and
    each class's expected disposition; the evidence document only reports what
    was observed. A self-consistent document that omits policy classes, or
    reclassifies a disposable class as durable, is refused.
    """
    if not isinstance(entry, dict):
        return [f"no {provider} qualification verdict"]
    teardown = entry.get("teardown")
    if not isinstance(teardown, dict):
        return [f"the {provider} verdict has no teardown result"]
    if teardown.get("absence_verdict") != "pass":
        return [f"the {provider} verdict has no independently observed passing absence result"]
    try:
        expected, scope_fields = policy_provider(policy, provider)
    except KeyError:
        return [f"the release teardown policy has no {provider} class contract"]

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
    binding_scope = binding.get("scope")
    if not isinstance(binding_scope, dict):
        reasons.append(f"the {provider} teardown binding names no provider scope")
        binding_scope = {}
    for field in scope_fields:
        if not nonempty(binding_scope.get(field)):
            reasons.append(f"the {provider} teardown binding has no {field!r} scope")

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
    if not nonempty(document.get("policy")):
        reasons.append(f"the {provider} teardown evidence names no teardown policy")
    elif document.get("policy") != policy.get("policy"):
        reasons.append(
            f"the {provider} teardown evidence names policy {document.get('policy')!r}, "
            f"not the release policy {policy.get('policy')!r}"
        )
    scope = document.get("scope")
    evidence_scope = scope if isinstance(scope, dict) else {}
    scope_cluster = evidence_scope.get("cluster")
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
    for field in scope_fields:
        if evidence_scope.get(field) != binding_scope.get(field):
            reasons.append(
                f"the {provider} teardown evidence binds {field} "
                f"{evidence_scope.get(field)!r}, not the claim's "
                f"{binding_scope.get(field)!r}"
            )
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
    if required:
        declared = set(required)
        missing_declared = [name for name in expected if name not in declared]
        extra_declared = [name for name in required if name not in expected]
        if missing_declared:
            reasons.append(
                f"the {provider} teardown evidence declares an incomplete required "
                f"class universe; the release policy requires: "
                f"{', '.join(missing_declared)}"
            )
        if extra_declared:
            reasons.append(
                f"the {provider} teardown evidence declares classes the release "
                f"policy does not require: {', '.join(extra_declared)}"
            )

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
        if name not in expected:
            continue
        expectation = row.get("expectation")
        state = row.get("state")
        policy_expectation = expected[name]
        if expectation != policy_expectation:
            reasons.append(
                f"the {provider} teardown class {name!r} declares expectation "
                f"{expectation!r}; the release policy requires {policy_expectation!r}"
            )
        if state not in EVIDENCE_STATES:
            reasons.append(f"the {provider} teardown class {name!r} has state {state!r}")
        elif policy_expectation == "absent" and state != "ABSENT":
            reasons.append(
                f"the {provider} teardown class {name!r} is {state}; "
                f"the release policy requires ABSENT"
            )
        elif policy_expectation == "present" and state != "PRESENT":
            reasons.append(
                f"the {provider} teardown class {name!r} is {state}; "
                f"the release policy requires PRESENT"
            )

    missing = [name for name in expected if name not in seen]
    extra = [name for name in seen if name not in expected]
    if missing:
        reasons.append(
            f"the {provider} teardown evidence does not observe required class(es): "
            f"{', '.join(missing)}"
        )
    if extra:
        reasons.append(
            f"the {provider} teardown evidence observes class(es) the release policy "
            f"does not require: {', '.join(extra)}"
        )
    if document.get("verdict") != "ABSENT":
        reasons.append(
            f"the {provider} teardown evidence records verdict "
            f"{document.get('verdict')!r}, not 'ABSENT'"
        )
    return reasons



def provider_reasons(
    provider: str, entry: object, candidate: dict, directory: str, policy: dict
) -> list[str]:
    """Return the reasons this provider's teardown claim is not verified.

    The contract owns claims and phases; this release policy owns independently
    observed teardown. A recorded provider verdict or row list is not authority.
    """
    if not isinstance(entry, dict):
        return [f"no {provider} qualification verdict"]
    return verify_teardown(provider, entry, candidate, directory, policy)


def release_policy_reasons(
    candidate: object,
    verdict: object | None,
    directory: object,
    policy_path: str | None = None,
) -> list[str]:
    """Return the reasons the candidate/teardown release policy is not met."""
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
    try:
        policy = load_teardown_policy(policy_path)
    except InputError as error:
        reasons.append(f"the release teardown policy is not usable: {error}")
        return reasons
    for provider in REQUIRED_PROVIDERS:
        reasons.extend(
            provider_reasons(provider, providers.get(provider), candidate, directory, policy)
        )
    return reasons


RELEASE_WORKFLOW = ".github/workflows/release.yml"
EVALUATOR_ARTIFACT = "qualification-release"
EVALUATOR_TIMEOUT_S = 120


def read_json_file(path: str) -> object:
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as error:
        raise InputError(f"{path}: {error.strerror or error}") from error
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InputError(f"{path}: not JSON: {error}") from error


def matching_release_runs(
    runs_document: object, candidate: dict, version: str, repository: str
) -> tuple[list[dict], list[str]]:
    """Select successful release-workflow runs for this exact tag revision.

    The GitHub workflow run is the provenance root. A release asset or a
    producer-supplied file cannot substitute for it.
    """
    if not isinstance(runs_document, dict):
        return [], ["the workflow-run document is not a JSON object"]
    runs = runs_document.get("workflow_runs")
    if not isinstance(runs, list):
        return [], ["the workflow-run document names no workflow_runs"]
    matched = []
    for run in runs:
        if not isinstance(run, dict) or not isinstance(run.get("id"), int):
            continue
        if run.get("path") != RELEASE_WORKFLOW:
            continue
        if run.get("head_sha") != candidate.get("revision"):
            continue
        if run.get("event") != "push":
            continue
        if run.get("conclusion") != "success":
            continue
        if run.get("head_branch") != version:
            continue
        run_repository = run.get("repository")
        if (
            not isinstance(run_repository, dict)
            or run_repository.get("full_name") != repository
        ):
            continue
        matched.append(run)
    if not matched:
        return [], [
            f"no successful {RELEASE_WORKFLOW} run on revision "
            f"{candidate.get('revision')} for tag {version} in {repository}"
        ]
    return matched, []


def download_evaluator(run_id: int, destination: str, gh: str = "gh") -> tuple[str | None, str | None]:
    """Download the evaluator artifact produced by one workflow run."""
    os.makedirs(destination, exist_ok=True)
    try:
        result = subprocess.run(
            [
                gh,
                "run",
                "download",
                str(run_id),
                "--name",
                EVALUATOR_ARTIFACT,
                "--dir",
                destination,
            ],
            capture_output=True,
            text=True,
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, f"release run {run_id}: evaluator download failed: {error}"
    if result.returncode != 0:
        return None, (
            f"release run {run_id}: evaluator artifact is not downloadable: "
            f"{(result.stderr or result.stdout).strip()}"
        )
    path = os.path.join(destination, EVALUATOR_ARTIFACT)
    if not os.path.isfile(path):
        return None, f"release run {run_id}: artifact contains no {EVALUATOR_ARTIFACT}"
    return path, None


def run_evaluator(path: str, arguments: list[str]) -> tuple[int, str, str] | None:
    try:
        result = subprocess.run(
            [path] + arguments,
            capture_output=True,
            text=True,
            timeout=EVALUATOR_TIMEOUT_S,
        )
        return result.returncode, result.stdout, result.stderr
    except (OSError, subprocess.TimeoutExpired):
        return None




def safe_extract(archive: str, destination: str) -> list[str]:
    """Extract a provider evidence archive without traversal or links."""
    reasons = []
    os.makedirs(destination, exist_ok=True)
    base = os.path.realpath(destination)
    try:
        with tarfile.open(archive, "r:*") as bundle:
            members = bundle.getmembers()
            for member in members:
                name = member.name
                parts = [part for part in name.replace("\\", "/").split("/") if part]
                if (
                    os.path.isabs(name)
                    or ".." in parts
                    or member.issym()
                    or member.islnk()
                    or not (member.isfile() or member.isdir())
                ):
                    reasons.append(f"the evidence archive contains an unsafe member {name!r}")
                    continue
                target = os.path.realpath(os.path.join(base, *parts))
                if target != base and not target.startswith(base + os.sep):
                    reasons.append(f"the evidence archive member {name!r} escapes the directory")
                    continue
            if reasons:
                return reasons
            bundle.extractall(base, members=members)
    except (OSError, tarfile.TarError) as error:
        return [f"the evidence archive {archive} is not usable: {error}"]
    return []


def recorded_evaluator(parity: object, candidate: dict) -> tuple[dict | None, list[str]]:
    if not isinstance(parity, dict):
        return None, ["no recorded parity verdict was supplied"]
    recorded = parity.get("evaluator")
    if not isinstance(recorded, dict):
        return None, ["the recorded parity verdict has no evaluator identity"]
    reasons = []
    for field in ("revision", "binary_sha256", "source_revision"):
        if not nonempty(recorded.get(field)):
            reasons.append(f"the recorded evaluator has no {field!r}")
    if not HEX64.fullmatch(recorded.get("binary_sha256") or ""):
        reasons.append("the recorded evaluator binary digest is not a sha256")
    source = recorded.get("source_revision")
    if not nonempty(source) or len(source) != 40 or not all(c in "0123456789abcdef" for c in source):
        reasons.append("the recorded evaluator source revision is not a 40-hex commit")
    elif source != candidate.get("revision"):
        reasons.append(
            "the recorded evaluator was built from a different revision than the candidate"
        )
    return (None if reasons else recorded), reasons


def verify_evaluator_identity(
    path: str, recorded: dict, candidate: dict
) -> list[str]:
    """Verify the downloaded bytes and the identity they report at execution."""
    reasons = []
    if not os.access(path, os.X_OK):
        return [f"the evaluator artifact {path} is not executable"]
    actual = sha256_file(path)
    if actual != recorded["binary_sha256"]:
        reasons.append(
            f"the evaluator artifact has sha256:{actual}, not the recorded "
            f"sha256:{recorded['binary_sha256']}"
        )
        return reasons
    result = run_evaluator(path, ["identity"])
    if result is None:
        return ["the evaluator artifact could not be executed for identity"]
    code, stdout, stderr = result
    if code != 0:
        return [f"the evaluator identity command exited {code}: {(stderr or stdout).strip()}"]
    try:
        identity_doc = json.loads(stdout)
    except json.JSONDecodeError:
        return ["the evaluator identity command did not emit JSON"]
    if not isinstance(identity_doc, dict):
        return ["the evaluator identity is not an object"]
    if identity_doc.get("revision") != recorded["revision"]:
        reasons.append("the evaluator artifact reports a different semantic revision")
    if identity_doc.get("source_revision") != candidate.get("revision"):
        reasons.append("the evaluator artifact reports a different source revision")
    if identity_doc.get("binary_sha256") != recorded["binary_sha256"]:
        reasons.append("the evaluator artifact reports a different binary digest")
    if identity_doc.get("binary_sha256") != actual:
        reasons.append("the evaluator artifact does not hash to the digest it reports")
    return reasons


def resolve_evaluator(
    candidate: dict,
    parity: object,
    version: str,
    repository_slug: str,
    runs_document: object,
    workdir: str,
    gh: str = "gh",
) -> tuple[str | None, list[str]]:
    """Find and verify the exact evaluator built by the release workflow."""
    recorded, reasons = recorded_evaluator(parity, candidate)
    if recorded is None:
        return None, reasons
    runs, reasons = matching_release_runs(runs_document, candidate, version, repository_slug)
    if not runs:
        return None, reasons
    failures = []
    for run in runs:
        destination = os.path.join(workdir, f"evaluator-{run['id']}")
        path, error = download_evaluator(run["id"], destination, gh)
        if error is not None:
            failures.append(error)
            continue
        digest = sha256_file(path)
        if digest != recorded["binary_sha256"]:
            failures.append(
                f"release run {run['id']} produced evaluator sha256:{digest}, "
                f"not the verdict's sha256:{recorded['binary_sha256']}"
            )
            continue
        identity_reasons = verify_evaluator_identity(path, recorded, candidate)
        if identity_reasons:
            failures.extend(identity_reasons)
            continue
        return path, []
    return None, failures or ["no release workflow run produced the recorded evaluator"]


def verify_attached_contract(
    attached_path: str, repository: str
) -> list[str]:
    """The attached contract is evidence; the repository copy is authority."""
    canonical = os.path.join(
        repository, "internal", "qualification", "qualification-contract.json"
    )
    try:
        with open(attached_path, "rb") as handle:
            attached = handle.read()
        with open(canonical, "rb") as handle:
            repository_copy = handle.read()
    except OSError as error:
        return [f"the canonical contract is not readable: {error}"]
    if attached != repository_copy:
        return [
            "the attached qualification contract is not the repository-owned contract"
        ]
    return []


def evaluate_parity(
    evaluator: str,
    repository: str,
    candidate: dict,
    parity: object,
    aws_record: str,
    gcp_record: str,
    aws_evidence: str,
    gcp_evidence: str,
) -> list[str]:
    """Re-run the verified evaluator over the exact attached evidence."""
    result = run_evaluator(
        evaluator,
        [
            "evaluate",
            "--repository",
            repository,
            "--aws-record",
            aws_record,
            "--aws-evidence",
            aws_evidence,
            "--gcp-record",
            gcp_record,
            "--gcp-evidence",
            gcp_evidence,
        ],
    )
    if result is None:
        return ["the verified evaluator could not be executed"]
    code, stdout, stderr = result
    if code != 0:
        return [
            f"the verified evaluator refused the attached evidence (exit {code}): "
            f"{(stderr or stdout).strip()}"
        ]
    try:
        computed = json.loads(stdout)
    except json.JSONDecodeError:
        return ["the verified evaluator did not emit a JSON verdict"]
    if not isinstance(computed, dict) or computed.get("verdict") != "PASS":
        return ["the verified evaluator did not return a PASS verdict"]
    if not isinstance(parity, dict):
        return ["no recorded parity verdict was supplied"]
    if canonical(computed) != canonical(parity):
        return [
            "the recorded parity verdict does not match the recomputation over "
            "the attached contract and evidence"
        ]
    claimed = computed.get("candidate")
    if not isinstance(claimed, dict) or identity(claimed) != identity(candidate):
        return ["the recomputed parity verdict refers to a different candidate"]
    return []


def authorize_reasons(
    candidate: object,
    verdict: object | None,
    directory: object,
    contract_path: str,
    parity: object | None,
    aws_record: str,
    gcp_record: str,
    aws_evidence: str,
    gcp_evidence: str,
    repository: str,
    repository_slug: str,
    version: str,
    runs_document: object,
    workdir: str,
    policy_path: str | None = None,
    gh: str = "gh",
) -> list[str]:
    """Return the reasons promotion must refuse; empty means authorized."""
    if not isinstance(candidate, dict):
        return ["the candidate record is not a JSON object"]
    reasons = release_policy_reasons(candidate, verdict, directory, policy_path)
    reasons.extend(verify_attached_contract(contract_path, repository))
    if reasons:
        return reasons
    if not isinstance(parity, dict):
        return ["no recorded parity verdict was supplied"]
    evaluator, reasons = resolve_evaluator(
        candidate, parity, version, repository_slug, runs_document, workdir, gh
    )
    if evaluator is None:
        return reasons
    return evaluate_parity(
        evaluator,
        repository,
        candidate,
        parity,
        aws_record,
        gcp_record,
        aws_evidence,
        gcp_evidence,
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    record_parser = commands.add_parser("record")
    record_parser.add_argument("--version", required=True)
    record_parser.add_argument("--revision", required=True)
    record_parser.add_argument("--bundle", required=True)
    record_parser.add_argument("--runner-image", required=True)
    record_parser.add_argument("--out", required=True)
    authorize_parser = commands.add_parser("authorize")
    authorize_parser.add_argument("--candidate", required=True)
    authorize_parser.add_argument("--verdict", required=True)
    authorize_parser.add_argument("--dir", required=True)
    authorize_parser.add_argument("--contract", required=True)
    authorize_parser.add_argument("--aws-record", required=True)
    authorize_parser.add_argument("--gcp-record", required=True)
    authorize_parser.add_argument("--aws-evidence", required=True)
    authorize_parser.add_argument("--gcp-evidence", required=True)
    authorize_parser.add_argument("--parity", required=True)
    authorize_parser.add_argument("--runs", required=True)
    authorize_parser.add_argument("--repository", required=True)
    authorize_parser.add_argument("--repository-slug", required=True)
    authorize_parser.add_argument("--version", required=True)
    authorize_parser.add_argument("--policy")
    extract_parser = commands.add_parser("extract")
    extract_parser.add_argument("--archive", required=True)
    extract_parser.add_argument("--dir", required=True)
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
        if args.command == "extract":
            reasons = safe_extract(args.archive, args.dir)
            if reasons:
                for reason in reasons:
                    print(reason, file=sys.stderr)
                return 1
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
        parity = load(args.parity)
        runs_document = read_json_file(args.runs)
        with tempfile.TemporaryDirectory() as workdir:
            reasons = authorize_reasons(
                candidate,
                verdict,
                args.dir,
                args.contract,
                parity,
                args.aws_record,
                args.gcp_record,
                args.aws_evidence,
                args.gcp_evidence,
                args.repository,
                args.repository_slug,
                args.version,
                runs_document,
                workdir,
                args.policy,
            )
        if reasons:
            print("promotion refused:", file=sys.stderr)
            for reason in reasons:
                print(f"  - {reason}", file=sys.stderr)
            return 1
        print(
            f"candidate {candidate['version']} ({candidate['revision']}) is authorized for promotion"
        )
        print(f"  bundle {candidate['bundle']} sha256:{candidate['bundle_sha256']}")
        print(f"  runner {candidate['runner_image']}")
        return 0
    except InputError as exc:
        print(f"promotion: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
