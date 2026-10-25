#!/usr/bin/env python3
"""End-to-end offline authorization chain with the real evaluator.

This composes the producer (`emit-record`), the typed evaluator (`evaluate`),
the release policy and the provenance download path. It does not run a provider
or publish anything; the workflow run is a fixture and the download command is a
local fake.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = pathlib.Path(os.environ["SOL_TEST_REPOSITORY"])
EVALUATOR = os.environ["SOL_TEST_RELEASE_BIN"]
sys.path.insert(0, str(REPO / "internal" / "tooling" / "release"))
sys.path.insert(0, str(REPO / "internal" / "qualification"))

import promotion  # noqa: E402
import evidence_manifest  # noqa: E402

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


def check_reason(label: str, reasons: list[str], needle: str) -> None:
    matched = bool(reasons) and any(needle in reason for reason in reasons)
    check(label, matched)
    if not matched:
        print(f"         reasons: {reasons}")


def run(arguments: list[str], *, check_code: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(arguments, capture_output=True, text=True)
    if check_code and result.returncode != 0:
        raise AssertionError(
            f"{arguments} exited {result.returncode}: {result.stderr or result.stdout}"
        )
    return result


def write(path: str, value: object) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


def sha256(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def evidence(directory: str, name: str) -> dict:
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"evidence": name}) + "\n")
    return {"path": name, "class": "behavioral"}


def write_attempt(directory: str, provider: str, revision: str) -> tuple[str, str, str]:
    attempt = f"{provider}-1"
    target = f"qual-{provider}/{provider}/example"
    cluster = f"sol-qual-{provider}"
    subject = f"{provider}-deploy-identity"
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "attempt.txt"), "w", encoding="utf-8") as handle:
        handle.write(
            "\n".join(
                [
                    f"attempt={attempt}",
                    f"target={target}",
                    f"cluster={cluster}",
                    f"provider={provider}",
                    "claim=production",
                    "issuer=letsencrypt-prod",
                    f"candidate_revision={revision}",
                    "promotion_eligible=yes",
                ]
            )
            + "\n"
        )
    with open(os.path.join(directory, "phase-verdicts.txt"), "w", encoding="utf-8") as handle:
        handle.write(
            "\n".join(
                [
                    "phase=prepare exit=0 at=2026-10-25T00:00:00Z",
                    "phase=cloud exit=0 at=2026-10-25T00:01:00Z",
                    "phase=app exit=0 at=2026-10-25T00:02:00Z",
                    "phase=destroy exit=0 at=2026-10-25T00:03:00Z",
                ]
            )
            + "\n"
        )
    return attempt, target, cluster


def manifest(directory: str, provider: str, revision: str, candidate_doc: dict) -> dict:
    _, _, _ = write_attempt(directory, provider, revision)
    files = [
        "candidate-binding.txt",
        "profile-target.yml",
        "cloud-apply.log",
        "app-transaction.log",
        "app-transaction-ts.log",
        "app-deploy-gate.log",
        "app-deploy.log",
        "cloud-destroy.log",
        "aws-pre-teardown-identities.json",
        "destroy.log",
        "app-transaction-ocaml.txt",
        "app-transaction-ts.txt",
        "app-deploy-bootstrap.log",
        "bindings-provisioner-subjects.log",
    ]
    for name in files:
        with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
            handle.write(f"{name} evidence\n")
    with open(os.path.join(directory, "candidate-binding.txt"), "w", encoding="utf-8") as handle:
        handle.write(f"harness_revision: {revision}\n")
    with open(os.path.join(directory, "profile-target.yml"), "w", encoding="utf-8") as handle:
        handle.write(
            "profile: production-single-region\n"
            "deploy_role_arn: arn:aws:iam::123456789012:role/sol-deploy\n"
        )
    contract = json.loads(
        (REPO / "internal/qualification/qualification-contract.json").read_text()
    )
    return evidence_manifest.build(provider, directory, contract, candidate_doc)


def identity() -> dict:
    result = run([EVALUATOR, "identity"])
    value = json.loads(result.stdout)
    if not value.get("source_revision"):
        raise AssertionError("the test evaluator was built without a source revision")
    return value


BUNDLE_BYTES = b"test candidate bundle"


def candidate(revision: str) -> dict:
    return {
        "version": "v0.0.0-alpha.99",
        "revision": revision,
        "bundle": "sol-v0.0.0-alpha.99-linux-x86_64.tar.gz",
        "bundle_sha256": hashlib.sha256(BUNDLE_BYTES).hexdigest(),
        "runner_image": "ghcr.io/example/sol-migration-runner@sha256:" + "c" * 64,
    }


def teardown_document(provider: str, candidate_doc: dict) -> dict:
    policy = promotion.load_teardown_policy()
    entry = policy["providers"][provider]
    classes = [
        {
            "class": row["class"],
            "expectation": row["expectation"],
            "state": "ABSENT" if row["expectation"] == "absent" else "PRESENT",
        }
        for row in entry["classes"]
    ]
    scope = {
        "cluster": f"sol-qual-{provider}",
        "region": "us-east-1" if provider == "aws" else "us-central1",
        "account": "123456789012",
        "project": "sol-qualification",
    }
    return {
        "schema": 1,
        "policy": policy["policy"],
        "provider": provider,
        "candidate": promotion.identity(candidate_doc),
        "attempt": f"{provider}-1",
        "target": f"qual-{provider}/{provider}/example",
        "scope": scope,
        "required_classes": [row["class"] for row in classes],
        "classes": classes,
        "verdict": "ABSENT",
    }


def teardown_claim(provider: str, candidate_doc: dict, directory: str) -> dict:
    document = teardown_document(provider, candidate_doc)
    name = f"{provider}-inventory-verdict.json"
    path = os.path.join(directory, name)
    write(path, document)
    policy = promotion.load_teardown_policy()
    scope = document["scope"]
    return {
        "absence_verdict": "pass",
        "binding": {
            "provider": provider,
            "attempt": document["attempt"],
            "target": document["target"],
            "cluster": scope["cluster"],
            "scope": {
                field: scope[field]
                for field in policy["providers"][provider]["scope_fields"]
            },
        },
        "evidence": {"path": name, "sha256": sha256(path)},
    }


def fake_gh(directory: str) -> str:
    path = os.path.join(directory, "gh")
    script = f"""#!/bin/sh
set -eu
destination=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) destination="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$destination" ] || exit 2
mkdir -p "$destination"
cp {EVALUATOR!r} "$destination/qualification-release"
# Artifact uploads reset the file mode; authorization must restore it.
"""
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(script)
    os.chmod(path, 0o755)
    return path


def runs(revision: str, version: str, **overrides) -> dict:
    run_doc = {
        "id": 7,
        "path": promotion.RELEASE_WORKFLOW,
        "head_sha": revision,
        "event": "push",
        "conclusion": "success",
        "status": "completed",
        "head_branch": version,
        "repository": {"full_name": "sol-fab/sol"},
    }
    run_doc.update(overrides)
    return {"workflow_runs": [run_doc]}


def main() -> int:
    print("authorization end-to-end (offline)")
    evaluator = identity()
    revision = evaluator["source_revision"]
    candidate_doc = candidate(revision)
    version = candidate_doc["version"]
    with tempfile.TemporaryDirectory() as directory:
        aws_dir = os.path.join(directory, "aws")
        gcp_dir = os.path.join(directory, "gcp")
        candidate_dir = os.path.join(directory, "candidate")
        os.makedirs(candidate_dir)
        candidate_path = os.path.join(candidate_dir, "candidate.json")
        with open(os.path.join(candidate_dir, candidate_doc["bundle"]), "wb") as handle:
            handle.write(BUNDLE_BYTES)
        write(candidate_path, candidate_doc)

        for provider, provider_dir in (("aws", aws_dir), ("gcp", gcp_dir)):
            manifest(provider_dir, provider, revision, candidate_doc)
            record_path = os.path.join(directory, f"{provider}-record.json")
            environment = dict(os.environ)
            environment["SOL_QUALIFICATION_EVALUATOR"] = EVALUATOR
            result = subprocess.run(
                [
                    "bash",
                    str(REPO / "internal/qualification/record.sh"),
                    "--provider",
                    provider,
                    "--attempt-dir",
                    provider_dir,
                    "--candidate",
                    candidate_path,
                    "--auto",
                    "--out",
                    record_path,
                ],
                capture_output=True,
                text=True,
                env=environment,
            )
            if result.returncode != 0:
                print(result.stderr or result.stdout)
            check(
                f"the producer emitted the {provider} record",
                result.returncode == 0 and os.path.isfile(record_path),
            )

        parity_path = os.path.join(directory, "parity-verdict.json")
        result = run(
            [
                EVALUATOR,
                "evaluate",
                "--repository",
                str(REPO),
                "--aws-record",
                os.path.join(directory, "aws-record.json"),
                "--aws-evidence",
                aws_dir,
                "--gcp-record",
                os.path.join(directory, "gcp-record.json"),
                "--gcp-evidence",
                gcp_dir,
                "--out",
                parity_path,
            ],
            check_code=False,
        )
        if result.returncode != 0:
            print(result.stdout)
            print(result.stderr)
            if os.path.exists(parity_path):
                print(open(parity_path, encoding="utf-8").read())
            raise SystemExit(1)
        with open(parity_path, encoding="utf-8") as handle:
            parity = json.load(handle)
        check("the typed evaluator returned PASS", parity.get("verdict") == "PASS")
        check(
            "the parity verdict binds the evaluator source revision",
            parity.get("evaluator", {}).get("source_revision") == revision,
        )

        attached_contract = os.path.join(candidate_dir, "qualification-contract.json")
        with open(REPO / "internal/qualification/qualification-contract.json", "rb") as handle:
            contract_bytes = handle.read()
        with open(attached_contract, "wb") as handle:
            handle.write(contract_bytes)

        providers = {
            provider: {
                "teardown": teardown_claim(provider, candidate_doc, candidate_dir)
            }
            for provider in ("aws", "gcp")
        }
        verdict = {
            "candidate": promotion.identity(candidate_doc),
            "providers": providers,
        }
        gh = fake_gh(directory)
        with tempfile.TemporaryDirectory() as workdir:
            def authorize_with(
                *,
                candidate_doc=candidate_doc,
                verdict=verdict,
                contract=attached_contract,
                parity=parity,
            ):
                return promotion.authorize_reasons(
                    candidate_doc,
                    verdict,
                    candidate_dir,
                    contract,
                    parity,
                    os.path.join(directory, "aws-record.json"),
                    os.path.join(directory, "gcp-record.json"),
                    aws_dir,
                    gcp_dir,
                    str(REPO),
                    "sol-fab/sol",
                    version,
                    revision,
                    runs(revision, version),
                    workdir,
                    gh=gh,
                )

            reasons = promotion.authorize_reasons(
                candidate_doc,
                verdict,
                candidate_dir,
                attached_contract,
                parity,
                os.path.join(directory, "aws-record.json"),
                os.path.join(directory, "gcp-record.json"),
                aws_dir,
                gcp_dir,
                str(REPO),
                "sol-fab/sol",
                version,
                revision,
                runs(revision, version),
                workdir,
                gh=gh,
            )
            check("the complete real-evaluator chain authorizes", reasons == [])
            if reasons:
                print(f"         reasons: {reasons}")

            wrong_run = promotion.authorize_reasons(
                candidate_doc,
                verdict,
                candidate_dir,
                attached_contract,
                parity,
                os.path.join(directory, "aws-record.json"),
                os.path.join(directory, "gcp-record.json"),
                aws_dir,
                gcp_dir,
                str(REPO),
                "sol-fab/sol",
                version,
                revision,
                runs(revision, version, path=".github/workflows/ci.yml"),
                workdir,
                gh=gh,
            )
            check_reason("an untrusted workflow refuses", wrong_run, "no successful")

            stale = dict(candidate_doc)
            stale["revision"] = "f" * 40
            stale_reasons = promotion.authorize_reasons(
                stale,
                verdict,
                candidate_dir,
                attached_contract,
                parity,
                os.path.join(directory, "aws-record.json"),
                os.path.join(directory, "gcp-record.json"),
                aws_dir,
                gcp_dir,
                str(REPO),
                "sol-fab/sol",
                version,
                revision,
                runs(revision, version),
                workdir,
                gh=gh,
            )
            check_reason("a candidate from another revision refuses", stale_reasons, "current tag revision")

            moved_tag = promotion.authorize_reasons(
                candidate_doc,
                verdict,
                candidate_dir,
                attached_contract,
                parity,
                os.path.join(directory, "aws-record.json"),
                os.path.join(directory, "gcp-record.json"),
                aws_dir,
                gcp_dir,
                str(REPO),
                "sol-fab/sol",
                version,
                "f" * 40,
                runs(revision, version),
                workdir,
                gh=gh,
            )
            check_reason("a moved tag refuses", moved_tag, "current tag revision")

            wrong_attempt = {
                **verdict,
                "providers": {
                    **verdict["providers"],
                    "aws": {
                        "teardown": {
                            **verdict["providers"]["aws"]["teardown"],
                            "binding": {
                                **verdict["providers"]["aws"]["teardown"]["binding"],
                                "attempt": "aws-other",
                            },
                        }
                    },
                },
            }
            attempt_reasons = promotion.authorize_reasons(
                candidate_doc,
                wrong_attempt,
                candidate_dir,
                attached_contract,
                parity,
                os.path.join(directory, "aws-record.json"),
                os.path.join(directory, "gcp-record.json"),
                aws_dir,
                gcp_dir,
                str(REPO),
                "sol-fab/sol",
                version,
                revision,
                runs(revision, version),
                workdir,
                gh=gh,
            )
            check_reason("teardown evidence from another attempt refuses", attempt_reasons, "not the record's")
            wrong_version = authorize_with(candidate_doc={**candidate_doc, "version": "v9.9.9"})
            check_reason("a candidate for another version refuses", wrong_version, "not the requested version")

            bundle_path = os.path.join(candidate_dir, candidate_doc["bundle"])
            with open(bundle_path, "wb") as handle:
                handle.write(b"tampered")
            tampered_bundle = authorize_with()
            check_reason("a bundle that does not match the candidate refuses", tampered_bundle, "bundle")
            with open(bundle_path, "wb") as handle:
                handle.write(BUNDLE_BYTES)

            altered_contract = os.path.join(directory, "altered-contract.json")
            with open(altered_contract, "wb") as handle:
                handle.write(b"{}\n")
            changed_contract = authorize_with(contract=altered_contract)
            check_reason(
                "an attached contract that is not the repository copy refuses",
                changed_contract,
                "repository-owned contract",
            )

            aws_inventory = os.path.join(candidate_dir, "aws-inventory-verdict.json")
            with open(aws_inventory, "rb") as handle:
                original_inventory = handle.read()
            with open(aws_inventory, "wb") as handle:
                handle.write(b"{}\n")
            tampered_teardown = authorize_with()
            check_reason(
                "tampered teardown evidence refuses", tampered_teardown, "sha256"
            )
            with open(aws_inventory, "wb") as handle:
                handle.write(original_inventory)
            gcp_record_path = os.path.join(directory, "gcp-record.json")
            with open(gcp_record_path, encoding="utf-8") as handle:
                gcp_record = json.load(handle)
            original_record = dict(gcp_record)
            no_profile = {
                key: value for key, value in gcp_record.items() if key != "profile"
            }
            with open(gcp_record_path, "w", encoding="utf-8") as handle:
                json.dump(no_profile, handle, sort_keys=True)
            missing_profile = authorize_with()
            check_reason(
                "a record without the production profile refuses promotion",
                missing_profile,
                "profile",
            )
            durable_profile = dict(original_record)
            durable_profile["profile"] = {
                "kind": "durable",
                "observations": ["profile"],
            }
            with open(gcp_record_path, "w", encoding="utf-8") as handle:
                json.dump(durable_profile, handle, sort_keys=True)
            durable_reasons = authorize_with()
            check_reason(
                "durable-shape evidence cannot authorize the production profile",
                durable_reasons,
                "profile",
            )
            with open(gcp_record_path, "w", encoding="utf-8") as handle:
                json.dump(original_record, handle, sort_keys=True)

    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
