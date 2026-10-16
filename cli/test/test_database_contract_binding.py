#!/usr/bin/env python3
"""Offline installed-candidate fixtures; never a release verdict."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

PRODUCER = Path(sys.argv.pop(1)).resolve()
BINDER = Path(sys.argv.pop(1)).resolve()
BUILDER = Path(sys.argv.pop(1)).resolve()
VERSION = "v0.0.0-projection-fixture"
REVISION = "a" * 40
TARGET = "dev/aws/region"


def seal(payload):
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return {"digest": hashlib.sha256(encoded).hexdigest(), "declaration": payload}


class Binding(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sol-contract-binding-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.install = self.root / ("sol-" + VERSION)
        self.share = self.install / "share/sol" / VERSION
        (self.install / "bin").mkdir(parents=True)
        (self.share / "platform/shared").mkdir(parents=True)
        (self.share / "platform/shared/components.json").write_text("{}")
        (self.share / "VERSION").write_text(VERSION + "\n")
        (self.share / "REVISION").write_text(REVISION + "\n")
        self.runner = "registry.invalid/runner@sha256:" + "b" * 64
        (self.share / "migration-runner-image").write_text(self.runner + "\n")
        main = self.install / "bin/sol"
        main.write_text("#!/bin/sh\nprintf '%s\\n' '" + VERSION + "'\n")
        main.chmod(0o755)
        shutil.copy2(PRODUCER, self.install / "bin/sol-database-contract")
        (self.install / "bin/sol-database-contract").chmod(0o755)
        definition = subprocess.check_output([str(PRODUCER), "definition", REVISION], text=True)
        self.definition = self.share / "database-contract.json"
        self.definition.write_text(definition)
        self.candidate = self.root / "candidate.json"
        self.workspace = self.root / "specimen"
        (self.workspace / "sol").mkdir(parents=True)
        (self.workspace / "sol.yml").write_text("""project: specimen
resources:
  app_db:
    type: postgres
services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
    uses: [app_db]
  checkout_svc:
    type: http
    path: app/checkout/checkout_svc
""")
        for domain, name in (("payments", "charge_svc"), ("checkout", "checkout_svc")):
            unit = self.workspace / "app" / domain / name
            unit.mkdir(parents=True)
            (unit / "Dockerfile").write_text("FROM scratch\n")
            (unit / "sol.toml").write_text("")
        (self.workspace / "sol/environments.yml").write_text("""dev:
  shape: local
  targets:
    aws/region:
      registry: registry.invalid
""")
        # Trap any accidental provider operation. The producer can use no host tool fallback.
        self.private_bin = self.root / "private-bin"
        self.private_bin.mkdir()
        for tool in ("head", "python3"):
            (self.private_bin / tool).symlink_to("/usr/bin/" + tool)
        for tool in ("kubectl", "aws", "gcloud", "terraform", "helm", "docker"):
            guard = self.private_bin / tool
            guard.write_text("#!/bin/sh\nprintf called >>\"$PROVIDER_MARKER\"\nprintf '%s\\n' unexpected-provider-operation >&2\nexit 99\n")
            guard.chmod(0o755)
        self.archive()

    def archive(self, omit=None):
        archive = self.root / "bundle.tar.gz"
        omitted = self.install / omit if omit else None
        with tarfile.open(archive, "w:gz") as bundle:
            for path in sorted(self.install.rglob("*")):
                if path != omitted:
                    bundle.add(path, arcname=str(path.relative_to(self.root)), recursive=False)
        self.candidate.write_text(json.dumps({"version": VERSION, "revision": REVISION,
            "bundle": archive.name, "bundle_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            "runner_image": self.runner}))

    def run_binding(self, expected, diagnostics=None):
        env = dict(os.environ)
        env["PATH"] = str(self.private_bin)
        # An ambient SOL_HOME must not replace the verified candidate's asset scope.
        env["PROVIDER_MARKER"] = str(self.root / "provider-called")
        env["SOL_HOME"] = str(self.root / "wrong-assets")
        args = [sys.executable, str(BINDER), "--candidate", str(self.candidate),
            "--install", str(self.install), "--workspace", str(self.workspace), "--target", TARGET]
        if diagnostics is not None:
            args += ["--raw-diagnostics", str(diagnostics)]
        result = subprocess.run(args,
            env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        self.assertFalse((self.root / "provider-called").exists(), "projection attempted provider execution")
        self.assertEqual(result.returncode == 0, expected, result.stdout + result.stderr)
        if expected:
            return json.loads(result.stdout)
        self.assertIn("database contract:", result.stderr)
        return result

    def test_subprocess_diagnostics_are_operator_only(self):
        secret = "DISTINCTIVE-CREDENTIAL-DO-NOT-CAPTURE"
        producer = self.install / "bin/sol-database-contract"
        producer.write_text("#!/bin/sh\nprintf '%s\\n' '" + secret + "'\nprintf '%s\\n' '" + secret + "' >&2\nexit 31\n")
        self.archive()
        result = self.run_binding(False)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertIn("producer exited with status 31", result.stderr)
        self.assertLess(len(result.stdout + result.stderr), 200)
        raw = self.root / "operator-only.log"
        result = self.run_binding(False, diagnostics=raw)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertIn(secret, raw.read_text())
        self.assertEqual(raw.stat().st_mode & 0o777, 0o600)
        before = raw.read_bytes()
        self.run_binding(False, diagnostics=raw)
        self.assertEqual(raw.read_bytes(), before, "raw diagnostics must never overwrite a file")

    def test_verifier_output_is_not_inherited(self):
        secret = "VERIFIER-CREDENTIAL-DO-NOT-CAPTURE"
        # The legacy verifier includes unexpected --version stdout in its failure.
        (self.install / "bin/sol").write_text("#!/bin/sh\nprintf '%s\\n' '" + secret + "'\n")
        self.archive()
        result = self.run_binding(False)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertIn("candidate verification exited with status 2", result.stderr)
        self.assertLess(len(result.stdout + result.stderr), 200)

    def mutate_definition(self, fn):
        document = json.loads(self.definition.read_text())
        self.definition.write_text(json.dumps(seal(fn(document["declaration"]))))
        self.archive()

    def test_release_assembler_ships_definition_and_producer(self):
        repo = self.root / "source"
        script = repo / "internal/tooling/scripts/build-release-bundle.sh"
        script.parent.mkdir(parents=True)
        shutil.copy2(BUILDER, script)
        (repo / "platform/shared").mkdir(parents=True)
        (repo / "platform/shared/components.json").write_text("{}")
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                   GIT_AUTHOR_NAME="offline fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                   GIT_COMMITTER_NAME="offline fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        for args in (("init", "--quiet"), ("add", "."),
                     ("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")):
            subprocess.run(["git", "-C", str(repo), *args], env=env, check=True, capture_output=True)
        revision = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], env=env, text=True).strip()
        output = self.root / "assembled"
        result = subprocess.run(["/bin/bash", str(script), "--version", VERSION, "--runner-image", self.runner,
            "--setup-image", "registry.invalid/postgres@sha256:" + "d" * 64, "--out", str(output),
            "--binary", str(self.install / "bin/sol"), "--contract-binary", str(PRODUCER), "--revision", revision],
            check=True, capture_output=True, text=True, env=env, timeout=15)
        archive = Path(result.stdout.strip())
        prefix = "sol-" + VERSION + "/"
        with tarfile.open(archive) as bundle:
            definition = json.load(bundle.extractfile(prefix + "share/sol/" + VERSION + "/database-contract.json"))
            producer = bundle.extractfile(prefix + "bin/sol-database-contract").read()
        self.assertEqual(definition["declaration"]["product_revision"], revision)
        self.assertEqual(hashlib.sha256(producer).digest(), hashlib.sha256(PRODUCER.read_bytes()).digest())
        self.assertEqual(definition, seal(definition["declaration"]))

    def test_verified_candidate_and_complete_specimen(self):
        result = self.run_binding(True)
        projection = result["specimen"]["declaration"]
        self.assertEqual(len(projection["workloads"]), 2)
        self.assertEqual(sum(w["database"] is not None for w in projection["workloads"]), 1)
        self.assertEqual(projection["database"]["migration"]["context"], "database_migration")
        self.assertEqual(projection["definition_digest"], result["definition"]["digest"])
        self.assertEqual(result, self.run_binding(True), "deterministic repeat")

    def test_missing_projection(self):
        self.definition.unlink()
        self.archive()
        self.run_binding(False)

    def test_unarchived_extra_producer(self):
        self.archive(omit="bin/sol-database-contract")
        self.run_binding(False)

    def test_changed_installed_definition(self):
        self.definition.write_text("{}")
        self.run_binding(False)

    def test_different_product_revision(self):
        self.mutate_definition(lambda value: {**value, "product_revision": "c" * 40})
        self.run_binding(False)

    def test_unsupported_schema(self):
        self.mutate_definition(lambda value: {**value, "schema": 2})
        self.run_binding(False)

    def test_boolean_schema(self):
        self.mutate_definition(lambda value: {**value, "schema": True})
        self.run_binding(False)

    def test_rehashed_wrong_product_constants(self):
        def wrong(value):
            value["ca"]["key"] = "ca.crt"
            return value
        self.mutate_definition(wrong)
        self.run_binding(False)

    def test_invalid_digest(self):
        value = json.loads(self.definition.read_text())
        value["digest"] = "0" * 64
        self.definition.write_text(json.dumps(value))
        self.archive()
        self.run_binding(False)

    def test_duplicate_field(self):
        text = self.definition.read_text().strip()
        self.definition.write_text('{"digest":"other",' + text[1:])
        self.archive()
        self.run_binding(False)

    def test_foreign_producer_bytes(self):
        with (self.install / "bin/sol-database-contract").open("ab") as handle:
            handle.write(b"foreign candidate")
        self.run_binding(False)

    def test_corrupt_archive(self):
        with (self.root / "bundle.tar.gz").open("ab") as handle:
            handle.write(b"corruption")
        self.run_binding(False)

    def test_missing_specimen_facts(self):
        definition = json.loads(self.definition.read_text())
        header = {"schema": 1, "product_revision": REVISION,
                  "definition_digest": definition["digest"], "requested_target": TARGET}
        complete = {**header, "workspace": "specimen", "target": TARGET, "database": None}
        for payload in (header, {**complete, "workloads": []},
                        {**complete, "workloads": [1.5]},
                        {**complete, "workloads": [float("nan")]}):
            with self.subTest(payload=payload):
                producer = self.install / "bin/sol-database-contract"
                producer.write_text("#!/usr/bin/python3\nprint(" + repr(json.dumps(seal(payload))) + ")\n")
                self.archive()
                self.run_binding(False)

    def test_missing_expected_consumer(self):
        (self.workspace / "app/payments/charge_svc/Dockerfile").unlink()
        self.run_binding(False)


if __name__ == "__main__":
    unittest.main()
