#!/usr/bin/env python3
"""Adversarial tests for v2 promotion authorization.

The evaluator is not trusted because it is attached to the release. Promotion
selects a successful run of the authorized release workflow on the candidate's
immutable revision, downloads the run's evaluator artifact, and requires its
bytes, self-reported identity, source revision and recomputed verdict to agree.
These tests mutate each of those facts independently.
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import pathlib
import stat
import sys
import tarfile
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "internal" / "tooling" / "release"))

import promotion  # noqa: E402

checks = 0
failures = 0

CANDIDATE = {
    "version": "v0.1.0-alpha.99",
    "revision": "a" * 40,
    "bundle": "sol-v0.1.0-alpha.99-linux-x86_64.tar.gz",
    "bundle_sha256": "b" * 64,
    "runner_image": "ghcr.io/example/sol-migration-runner@sha256:" + "c" * 64,
}
REPOSITORY = "sol-fab/sol"
VERSION = CANDIDATE["version"]
EVALUATOR_REVISION = "sol-qual-release/v2"


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


def sha256(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def write_executable(path: str, identity_path: str, verdict_path: str, exit_code: int = 0) -> None:
    script = f"""#!/usr/bin/env python3
import json
import sys
with open({identity_path!r}, encoding="utf-8") as handle:
    identity = json.load(handle)
with open({verdict_path!r}, encoding="utf-8") as handle:
    verdict = json.load(handle)
if len(sys.argv) < 2:
    raise SystemExit(2)
if sys.argv[1] == "identity":
    print(json.dumps(identity, sort_keys=True))
    raise SystemExit(0)
if sys.argv[1] == "evaluate":
    print(json.dumps(verdict, sort_keys=True))
    raise SystemExit({exit_code})
raise SystemExit(2)
"""
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(script)
    os.chmod(path, 0o755)


def write_json(path: str, value: object) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True)


def evaluator_identity(binary_sha256: str, source_revision: str = CANDIDATE["revision"], revision: str = EVALUATOR_REVISION) -> dict:
    return {
        "revision": revision,
        "source_revision": source_revision,
        "binary_sha256": binary_sha256,
    }


def parity(binary_sha256: str, candidate: dict | None = None) -> dict:
    candidate = candidate if candidate is not None else CANDIDATE
    return {
        "schema": 2,
        "kind": "cross-provider-qualification-parity",
        "verdict": "PASS",
        "contract": {"id": "sol-cross-provider-release/v2", "digest": "d" * 64},
        "candidate": promotion.identity(candidate),
        "harness_revision": "e" * 40,
        "selection": {"languages": ["ocaml", "typescript"], "primitives": ["svc", "worker"]},
        "evaluator": evaluator_identity(binary_sha256),
        "records": [
            {"provider": "aws", "attempt": "aws-1", "record_sha256": "f" * 64},
            {"provider": "gcp", "attempt": "gcp-1", "record_sha256": "0" * 64},
        ],
        "claims": [],
        "exceptions": [],
        "reasons": [],
    }


def runs_document(**overrides) -> dict:
    run = {
        "id": 4242,
        "path": promotion.RELEASE_WORKFLOW,
        "head_sha": CANDIDATE["revision"],
        "event": "push",
        "conclusion": "success",
        "status": "completed",
        "head_branch": VERSION,
        "repository": {"full_name": REPOSITORY},
    }
    run.update(overrides)
    return {"workflow_runs": [run]}


def with_fake_download(path: str):
    original = promotion.download_evaluator

    def fake(run_id: int, destination: str, gh: str = "gh"):
        return path, None

    promotion.download_evaluator = fake
    return original


def test_run_selection() -> None:
    matched, reasons = promotion.matching_release_runs(
        runs_document(), CANDIDATE, VERSION, REPOSITORY
    )
    check("a successful release run on the candidate revision matches", len(matched) == 1 and not reasons)
    for field, value in (
        ("path", ".github/workflows/ci.yml"),
        ("head_sha", "f" * 40),
        ("event", "workflow_dispatch"),
        ("conclusion", "failure"),
        ("head_branch", "main"),
    ):
        matched, reasons = promotion.matching_release_runs(
            runs_document(**{field: value}), CANDIDATE, VERSION, REPOSITORY
        )
        check(f"a run with the wrong {field} is not provenance", not matched and bool(reasons))
    wrong_repository = runs_document()
    wrong_repository["workflow_runs"][0]["repository"] = {"full_name": "attacker/sol"}
    matched, reasons = promotion.matching_release_runs(
        wrong_repository, CANDIDATE, VERSION, REPOSITORY
    )
    check("a run from another repository is not provenance", not matched and bool(reasons))


def test_resolve_evaluator() -> None:
    with tempfile.TemporaryDirectory() as directory:
        evaluator = os.path.join(directory, promotion.EVALUATOR_ARTIFACT)
        identity_path = os.path.join(directory, "identity.json")
        verdict_path = os.path.join(directory, "verdict.json")
        write_executable(evaluator, identity_path, verdict_path)
        digest = sha256(evaluator)
        recorded = parity(digest)
        identity = evaluator_identity(digest)
        write_json(verdict_path, recorded)
        write_json(identity_path, identity)

        original = with_fake_download(evaluator)
        try:
            path, reasons = promotion.resolve_evaluator(
                CANDIDATE, recorded, VERSION, REPOSITORY, runs_document(), directory
            )
            check("the workflow artifact matching the verdict is selected", path == evaluator and not reasons)

            substituted = parity(digest)
            substituted["evaluator"]["binary_sha256"] = "1" * 64
            path, reasons = promotion.resolve_evaluator(
                CANDIDATE, substituted, VERSION, REPOSITORY, runs_document(), directory
            )
            check_reason("a different artifact digest refuses", reasons, "not the verdict's")

            wrong_source = parity(digest)
            wrong_source["evaluator"]["source_revision"] = "f" * 40
            path, reasons = promotion.resolve_evaluator(
                CANDIDATE, wrong_source, VERSION, REPOSITORY, runs_document(), directory
            )
            check_reason("a recorded source revision outside the candidate refuses", reasons, "different revision")

            untrusted = runs_document(path=".github/workflows/ci.yml")
            path, reasons = promotion.resolve_evaluator(
                CANDIDATE, recorded, VERSION, REPOSITORY, untrusted, directory
            )
            check_reason("no authorized workflow run refuses", reasons, "no successful")

            # The bytes match the recorded digest, but the executed evaluator
            # reports a different binary identity.
            write_json(identity_path, evaluator_identity("2" * 64))
            path, reasons = promotion.resolve_evaluator(
                CANDIDATE, recorded, VERSION, REPOSITORY, runs_document(), directory
            )
            check_reason("execution of a different binary refuses", reasons, "different binary digest")
        finally:
            promotion.download_evaluator = original


def test_parity_recomputation() -> None:
    with tempfile.TemporaryDirectory() as directory:
        evaluator = os.path.join(directory, promotion.EVALUATOR_ARTIFACT)
        identity_path = os.path.join(directory, "identity.json")
        verdict_path = os.path.join(directory, "verdict.json")
        digest = "3" * 64
        recorded = parity(digest)
        write_executable(evaluator, identity_path, verdict_path)
        write_json(identity_path, evaluator_identity(digest))
        write_json(verdict_path, recorded)
        reasons = promotion.evaluate_parity(
            evaluator,
            directory,
            CANDIDATE,
            recorded,
            os.path.join(directory, "aws-record.json"),
            os.path.join(directory, "gcp-record.json"),
            directory,
            directory,
        )
        check("a matching recomputation authorizes parity", reasons == [])

        altered = copy.deepcopy(recorded)
        altered["harness_revision"] = "9" * 40
        write_json(verdict_path, altered)
        reasons = promotion.evaluate_parity(
            evaluator,
            directory,
            CANDIDATE,
            recorded,
            "aws",
            "gcp",
            directory,
            directory,
        )
        check_reason("a recorded verdict detached from the recomputation refuses", reasons, "does not match")

        write_executable(evaluator, identity_path, verdict_path, exit_code=1)
        reasons = promotion.evaluate_parity(
            evaluator, directory, CANDIDATE, recorded, "aws", "gcp", directory, directory
        )
        check_reason("an evaluator refusal refuses promotion", reasons, "refused")


def test_authorize_chain() -> None:
    with tempfile.TemporaryDirectory() as directory:
        evaluator = os.path.join(directory, promotion.EVALUATOR_ARTIFACT)
        identity_path = os.path.join(directory, "identity.json")
        verdict_path = os.path.join(directory, "verdict.json")
        write_executable(evaluator, identity_path, verdict_path)
        digest = sha256(evaluator)
        recorded = parity(digest)
        write_json(identity_path, evaluator_identity(digest))
        write_json(verdict_path, recorded)
        contract = os.path.join(directory, "qualification-contract.json")
        with open(contract, "w", encoding="utf-8") as handle:
            handle.write("{}\n")
        candidate_path = os.path.join(directory, "candidate.json")
        with open(candidate_path, "w", encoding="utf-8") as handle:
            json.dump(CANDIDATE, handle)

        original_download = with_fake_download(evaluator)
        original_policy = promotion.release_policy_reasons
        original_contract = promotion.verify_attached_contract
        promotion.release_policy_reasons = lambda *args, **kwargs: []
        promotion.verify_attached_contract = lambda *args, **kwargs: []
        try:
            reasons = promotion.authorize_reasons(
                CANDIDATE,
                {"candidate": promotion.identity(CANDIDATE), "providers": {}},
                directory,
                contract,
                recorded,
                "aws",
                "gcp",
                directory,
                directory,
                REPOSITORY,
                VERSION,
                runs_document(),
                directory,
            )
            check("the complete provenance/execution chain authorizes", reasons == [])

            missing = promotion.authorize_reasons(
                CANDIDATE,
                None,
                directory,
                contract,
                None,
                "aws",
                "gcp",
                directory,
                directory,
                REPOSITORY,
                VERSION,
                runs_document(),
                directory,
            )
            check_reason("a missing parity verdict refuses authorization", missing, "no recorded parity")
        finally:
            promotion.download_evaluator = original_download
            promotion.release_policy_reasons = original_policy
            promotion.verify_attached_contract = original_contract


def test_safe_extract() -> None:
    with tempfile.TemporaryDirectory() as directory:
        good = os.path.join(directory, "good.tar.gz")
        with tarfile.open(good, "w:gz") as bundle:
            for name, text in (("attempt.txt", "attempt=aws-1\n"), ("evidence.json", "{}\n")):
                payload = text.encode("utf-8")
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                import io

                bundle.addfile(info, io.BytesIO(payload))
        out = os.path.join(directory, "out")
        check("a plain evidence archive extracts", promotion.safe_extract(good, out) == [])
        check(
            "the extracted attempt binding is present",
            os.path.isfile(os.path.join(out, "attempt.txt")),
        )

        traversal = os.path.join(directory, "traversal.tar.gz")
        with tarfile.open(traversal, "w:gz") as bundle:
            payload = b"escape\n"
            info = tarfile.TarInfo("../escape.txt")
            info.size = len(payload)
            import io

            bundle.addfile(info, io.BytesIO(payload))
        reasons = promotion.safe_extract(traversal, os.path.join(directory, "traversal-out"))
        check_reason("a traversing archive member refuses", reasons, "unsafe member")
        check(
            "a traversing member is not written outside the directory",
            not os.path.exists(os.path.join(directory, "escape.txt")),
        )

        linked = os.path.join(directory, "link.tar.gz")
        with tarfile.open(linked, "w:gz") as bundle:
            info = tarfile.TarInfo("link")
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            bundle.addfile(info)
        reasons = promotion.safe_extract(linked, os.path.join(directory, "link-out"))
        check_reason("an archive symlink refuses", reasons, "unsafe member")


def main() -> int:
    print("v2 promotion authorization")
    test_run_selection()
    test_resolve_evaluator()
    test_parity_recomputation()
    test_authorize_chain()
    test_safe_extract()
    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
