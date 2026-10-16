#!/usr/bin/env python3
"""Fresh installed-candidate -> typed MECHANISM obligations; never release qualification.

Reuse the product binding fixture builder and actual verifier/producer. Mutations
pin the original assessment unless explicitly testing a structurally invalid new
candidate. The golden was enumerated independently of the catalog/adapter.
"""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

DRIVER, PRODUCER, BINDER, BUILDER, HELPER, REPOSITORY, GOLDEN = map(lambda x: Path(x).resolve(), sys.argv[1:])
sys.argv = [str(HELPER), str(PRODUCER), str(BINDER), str(BUILDER)]
spec = importlib.util.spec_from_file_location("binding_fixture", HELPER)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

class Boundary(fixture.Binding):
    def setUp(self):
        super().setUp()
        env = self.workspace / "sol/environments.yml"
        env.write_text(env.read_text().replace("shape: local", "shape: durable"))
        with (self.workspace / "sol.yml").open("a") as out:
            out.write("  notify_worker:\n    type: worker\n    path: app/comms/notify_worker\n    uses: [app_db]\n")
        unit = self.workspace / "app/comms/notify_worker"
        unit.mkdir(parents=True)
        (unit / "Dockerfile").write_text("FROM scratch\n")
        (unit / "sol.toml").write_text("")
        with env.open("a") as out:
            out.write("      secrets:\n")
            for subject in ("payments/charge_svc", "checkout/checkout_svc", "comms/notify_worker"):
                out.write("        " + subject + ":\n          KAFKA_SASL_PASSWORD:\n            authority: sol\n          KAFKA_SSL_CA_CERT:\n            authority: sol\n")
        (self.private_bin / "cat").symlink_to("/usr/bin/cat")
        self.bound = self.run_binding(True)
        self.pins = self.expected(self.bound)
        self.pin_path = self.root / "pins.json"

    def expected(self, bound):
        s = bound["specimen"]["declaration"]
        return {"revision": bound["candidate"]["revision"],
            "bundle_digest": bound["candidate"]["bundle_sha256"],
            "definition_digest": bound["definition"]["digest"],
            "specimen_digest": bound["specimen"]["digest"],
            "target": s["target"], "requested_target": s["requested_target"]}

    def invoke(self, success, pins=None, exercise=False, scenario="aws"):
        self.pin_path.write_text(json.dumps(pins or self.pins))
        args = [str(DRIVER), str(REPOSITORY), str(self.candidate), str(self.install),
            str(self.workspace), str(self.pin_path), str(self.root / "evidence") if exercise else "-", scenario]
        # Reuse the product fixture's traps during the fresh OCaml verification too.
        env = dict(os.environ, PATH=str(self.private_bin),
                   PROVIDER_MARKER=str(self.root / "provider-called"), SOL_HOME=str(self.root / "wrong-assets"))
        result = subprocess.run(args, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=100)
        self.assertFalse((self.root / "provider-called").exists(), "boundary attempted provider execution")
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        if success:
            return json.loads(result.stdout)
        self.assertNotIn("DISTINCTIVE-CREDENTIAL", result.stdout + result.stderr)
        return result

    def mutated_candidate(self, change):
        """A new self-consistent candidate with a deliberately hostile producer.

        The archive owner still verifies installed bytes. Rehashing is not authority:
        original expected pins must reject it, and malformed declarations must also
        fail when explicitly assessed as a different candidate fixture.
        """
        bound = copy.deepcopy(self.bound)
        change(bound["specimen"]["declaration"])
        bound["specimen"] = fixture.seal(bound["specimen"]["declaration"])
        producer = self.install / "bin/sol-database-contract"
        producer.write_text("#!/bin/sh\ncat <<'SOL_OFFLINE_FIXTURE'\n" + json.dumps(bound["specimen"]) + "\nSOL_OFFLINE_FIXTURE\n")
        producer.chmod(0o755)
        self.archive()
        bound["candidate"] = json.loads(self.candidate.read_text())
        return self.expected(bound)

    def test_boundary_complete_golden(self):
        value = self.invoke(True, exercise=True)
        obligations = value["obligations"]
        self.assertEqual(sorted(obligations["required"]), sorted(GOLDEN.read_text().splitlines()))
        self.assertEqual(obligations["excluded"], [{"subject":"checkout/checkout_svc", "reason":"no declared database dependency"}])
        self.assertEqual(sorted(w["subject"] for w in value["workloads"]),
            ["checkout/checkout_svc", "comms/notify_worker", "payments/charge_svc"])
        self.assertEqual(sorted(value["consumers"]), ["comms/notify_worker", "payments/charge_svc"])
        declared = self.bound["specimen"]["declaration"]["workloads"]
        keys = ("subject", "resource", "namespace", "name", "database", "consuming_containers")
        self.assertEqual(sorted(value["workloads"], key=lambda w:w["subject"]),
            sorted(({k:w[k] for k in keys} for w in declared), key=lambda w:w["subject"]))
        self.assertEqual(value["run"]["origin"], "MECHANISM")
        self.assertEqual(value["run"]["candidate_binding"], {
            "revision":self.pins["revision"], "bundle_digest":self.pins["bundle_digest"],
            "definition_digest":self.pins["definition_digest"], "specimen_digest":self.pins["specimen_digest"],
            "target":self.pins["target"], "requested_target":self.pins["requested_target"],
            "workspace":self.bound["specimen"]["declaration"]["workspace"]})
        for path in (self.root / "evidence").rglob("*"):
            if path.is_file():
                self.assertNotIn(b"DISTINCTIVE-SECRET-CANNOT-APPEAR", path.read_bytes())

    def test_boundary_all_pins(self):
        for key, old in self.pins.items():
            with self.subTest(key=key):
                pins = dict(self.pins)
                pins[key] = ("b" if old[:1] != "b" else "c") + old[1:]
                self.invoke(False, pins)

    def test_boundary_rehashed_omitted_consumer(self):
        pins = self.mutated_candidate(lambda s:s["workloads"].pop())
        self.assertNotEqual(pins["specimen_digest"], self.pins["specimen_digest"])
        self.invoke(False)

    def test_boundary_rehashed_container_substitution(self):
        self.mutated_candidate(lambda s:s["workloads"][1].update(consuming_containers=["other-consumer"]))
        self.invoke(False)

    def test_boundary_structural_hostility(self):
        cases = {
            "schema": lambda s:s.update(schema=2),
            "missing_migration": lambda s:s["database"].pop("migration"),
            "missing_migration_ca": lambda s:s["database"]["migration"].update(ca=None),
            "wrong_migration_container": lambda s:s["database"]["migration"].update(container="another-job-container"),
            "wrong_job_kind": lambda s:s["database"]["migration"].update(resource="Deployment"),
            "database_binding": lambda s:s["workloads"][1].update(database="another_database"),
            "omitted_container": lambda s:s["workloads"][1].update(consuming_containers=[]),
            "duplicate_container": lambda s:s["workloads"][1].update(consuming_containers=["x","x"]),
            "missing_ca": lambda s:s["workloads"][1].update(ca=None),
            "wrong_ca_namespace": lambda s:s["workloads"][1]["ca"]["configmap"].update(namespace="other"),
            "wrong_ca_key": lambda s:s["workloads"][1]["ca"].update(key="ca.crt"),
            "wrong_ca_path": lambda s:s["workloads"][1]["ca"].update(file="/wrong/ca.pem"),
            "unsupported_consumer": lambda s:s["workloads"][1].update(resource="cronjob"),
            "duplicate_identity": lambda s:s["workloads"].append(copy.deepcopy(s["workloads"][1])),
            "duplicate_kube_identity": lambda s:s["workloads"][0].update(namespace=s["workloads"][1]["namespace"],name=s["workloads"][1]["name"]),
            "hidden_dependency": lambda s:s["workloads"][1].update(database=None,ca=None,credential=None,consuming_containers=[]),
            "missing_database": lambda s:s.update(database=None),
            "missing_admin": lambda s:s["database"].update(administrative_references=[]),
            "extra_admin": lambda s:s["database"]["administrative_references"].append({"namespace":"db","name":"another-master"}),
            "missing_authority": lambda s:s["database"].update(credential_authority=None),
            "unknown_field": lambda s:s.update(unexplained_requirement=True),
        }
        original = (self.install / "bin/sol-database-contract").read_bytes()
        for label, change in cases.items():
            with self.subTest(label=label):
                (self.install / "bin/sol-database-contract").write_bytes(original)
                self.archive()
                pins = self.mutated_candidate(change)
                self.invoke(False, pins)

    def test_boundary_candidate_owned_ca_names(self):
        bound = copy.deepcopy(self.bound)
        definition = bound["definition"]["declaration"]
        definition["ca"] = {"key":"root.certificate", "file":"/candidate/certs/root.certificate"}
        bound["definition"] = fixture.seal(definition)
        self.definition.write_text(json.dumps(bound["definition"]))
        specimen = bound["specimen"]["declaration"]
        specimen["definition_digest"] = bound["definition"]["digest"]
        for workload in specimen["workloads"]:
            if workload["ca"]:
                workload["ca"].update(definition["ca"])
        specimen["database"]["migration"]["ca"].update(definition["ca"])
        bound["specimen"] = fixture.seal(specimen)
        producer = self.install / "bin/sol-database-contract"
        producer.write_text("#!/bin/sh\ncat <<'SOL_OFFLINE_FIXTURE'\n" + json.dumps(bound["specimen"]) + "\nSOL_OFFLINE_FIXTURE\n")
        producer.chmod(0o755)
        self.archive()
        bound["candidate"] = json.loads(self.candidate.read_text())
        self.invoke(True, self.expected(bound), exercise=True)

    def test_boundary_stale_candidate_store(self):
        self.invoke(True, exercise=True)
        pins = self.mutated_candidate(lambda s:s["workloads"][1].update(subject="comms/another_worker"))
        self.invoke(True, pins)
        self.invoke(False, pins, exercise=True)

    def test_boundary_gcp_shared_mechanism(self):
        target_file = self.workspace / "sol/environments.yml"
        target_file.write_text(target_file.read_text().replace("aws/region", "gcp/region"))
        old = fixture.TARGET
        try:
            fixture.TARGET = "dev/gcp/region"
            bound = self.run_binding(True)
        finally:
            fixture.TARGET = old
        pins = self.expected(bound)
        value = self.invoke(True, pins, exercise=True, scenario="gcp")
        self.assertEqual(value["run"]["provider"], "gcp")
        self.assertEqual(sorted(value["obligations"]["required"]),
            sorted(line.replace("aws/", "gcp/", 1) for line in GOLDEN.read_text().splitlines()))

    def test_boundary_forged_definition(self):
        definition = json.loads(self.definition.read_text())
        definition["declaration"]["ca"]["key"] = "ca.crt"
        self.definition.write_text(json.dumps(fixture.seal(definition["declaration"])))
        self.invoke(False)

    def test_boundary_failed_verifier_diagnostics(self):
        (self.install / "bin/sol").write_text("#!/bin/sh\necho DISTINCTIVE-CREDENTIAL\nexit 31\n")
        self.archive()
        self.invoke(False)

if __name__ == "__main__":
    suite = unittest.TestSuite(Boundary(name) for name in dir(Boundary) if name.startswith("test_boundary_"))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
