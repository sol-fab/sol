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

DRIVER, PRODUCER, BINDER, BUILDER, HELPER, REPOSITORY, GOLDEN, CA_DRIVER = map(lambda x: Path(x).resolve(), sys.argv[1:])
sys.argv = [str(HELPER), str(PRODUCER), str(BINDER), str(BUILDER)]
spec = importlib.util.spec_from_file_location("binding_fixture", HELPER)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

# A candidate's own sol: it reports the installed release version to the existing
# verifier and speaks the private receipt protocol when the launcher runs it.
PROTOCOL_SOL = """#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:2] == ["--version"]:
    print("__VERSION__")
    sys.exit(0)
if sys.argv[1:3] == ["migrate", "apply"]:
    receipt = {
        "schema": 1,
        "kind": "MigrationExecution",
        "binding": os.environ["SOL_MIGRATION_EXECUTION_BINDING"],
        "target": sys.argv[3],
        "namespace": os.environ.get("FAKE_MIGRATION_NAMESPACE", "database-system"),
        "name": os.environ.get("FAKE_MIGRATION_NAME", "boundary-migration"),
        "uid": os.environ.get("FAKE_MIGRATION_UID", "boundary-submission-uid"),
        "principal": os.environ.get("FAKE_MIGRATION_PRINCIPAL", "offline-reader"),
        "cluster": os.environ.get("FAKE_MIGRATION_CLUSTER", "offline-cluster"),
        "endpoint": os.environ.get("FAKE_MIGRATION_ENDPOINT", "https://offline.invalid"),
        "observed_at": 1,
    }
    os.write(0, (json.dumps(receipt) + "\\n").encode())
    ack = os.read(0, 64).decode().strip()
    sys.exit(0 if ack == "capture-finished" else 3)
sys.exit(2)
"""

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

    def test_boundary_launcher_runs_the_verified_candidate(self):
        # The launcher must execute the verified candidate's own sol (the one whose
        # bytes the archive digest covers), not a path supplied later.
        sol = self.install / "bin/sol"
        sol.write_text(PROTOCOL_SOL.replace("__VERSION__", fixture.VERSION))
        sol.chmod(0o755)
        self.archive()
        bound = self.run_binding(True)
        pins = self.expected(bound)
        result = self.root / "launcher.json"
        os.environ["SOL_LAUNCHER_RESULT"] = str(result)
        try:
            self.invoke(True, pins, exercise=True)
        finally:
            del os.environ["SOL_LAUNCHER_RESULT"]
        value = json.loads(result.read_text())
        self.assertTrue(value["ok"], value)
        self.assertEqual(value["uid"], "boundary-submission-uid")
        self.assertEqual(value["name"], "boundary-migration")
        self.assertEqual(value["namespace"], "database-system")
        self.assertEqual(value["target"], pins["requested_target"])

    def integration_environment(self):
        root = self.root / "integration"
        root.mkdir()
        # The evidence store creates and restricts its own directory; a
        # pre-created empty directory is treated as an existing store.
        evidence = self.root / "integration-evidence"
        kubeconfig = root / "explicit.kubeconfig"
        kubeconfig.write_text("")
        # The controlled Kubernetes fixture replaces the provider guard for this
        # test: the live transport is expected to read, but only locally.
        kubectl = self.private_bin / "kubectl"
        kubectl.write_text(Path(__file__).with_name("fixture_live_kubectl.py").read_text())
        kubectl.chmod(0o755)
        env = {
            "SOL_TEST_WORLD": str(root / "world.json"),
            "SOL_TEST_CALLS": str(root / "calls.json"),
            "SOL_TEST_KUBECONFIG": str(kubeconfig),
            "KUBECONFIG": str(kubeconfig),
            "SOL_INTEGRATION_ROOT": str(root),
            "SOL_INTEGRATION_EVIDENCE": str(evidence),
            "SOL_INTEGRATION_RESULT": str(root / "result.json"),
        }
        return root, env

    def run_integrated_path(self, mutation=None, fault=False):
        # The integrated path verifies the candidate, observes every declared
        # consumer through the authenticated transport, launches the candidate's
        # own migration execution, captures its Job UID and observes its CA.
        sol = self.install / "bin/sol"
        sol.write_text(PROTOCOL_SOL.replace("__VERSION__", fixture.VERSION))
        sol.chmod(0o755)
        self.archive()
        bound = self.run_binding(True)
        pins = self.expected(bound)
        root, env = self.integration_environment()
        if mutation is not None:
            env["SOL_INTEGRATION_MUTATION"] = mutation
        if fault:
            env["SOL_INTEGRATION_FAULT"] = "1"
        previous = {key: os.environ.get(key) for key in env}
        os.environ.update(env)
        try:
            self.invoke(True, pins)
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        return json.loads((root / "result.json").read_text())

    def test_boundary_integrated_path(self):
        value = self.run_integrated_path()
        self.assertTrue(value["ok"], value)
        self.assertTrue(value["application"], value)
        self.assertEqual(len(value["application"]), 2, value)  # consumers only
        self.assertTrue(all(item["decision"] == "pass" for item in value["application"]), value)
        self.assertTrue(all(item["decision"] == "pass" for item in value["migration"]), value)
        self.assertFalse(value["accept_mechanism"], "CA-only evidence accepted a release")

    def test_boundary_integrated_path_missing_mount_fails(self):
        value = self.run_integrated_path("missing_mount")
        self.assertTrue(value["ok"], value)
        self.assertIn("fail", [item["decision"] for item in value["application"]], value)
        self.assertFalse(value["accept_mechanism"])

    def test_boundary_integrated_path_wrong_configmap_fails(self):
        value = self.run_integrated_path("wrong_configmap")
        self.assertTrue(value["ok"], value)
        self.assertIn("fail", [item["decision"] for item in value["application"]], value)
        self.assertFalse(value["accept_mechanism"])

    def test_boundary_integrated_path_renamed_volume_passes(self):
        # Volume names are internal linkage; a consistently renamed volume keeps
        # the source, delivered path and consuming-container guarantees.
        value = self.run_integrated_path("renamed_volume")
        self.assertTrue(value["ok"], value)
        self.assertTrue(all(item["decision"] == "pass" for item in value["application"]), value)

    def test_boundary_integrated_path_changed_authority_is_unestablished(self):
        value = self.run_integrated_path("changed_authority")
        self.assertFalse(value["ok"], value)

    def test_boundary_integrated_path_replaced_job_uid_fails(self):
        value = self.run_integrated_path("wrong_job_uid")
        self.assertTrue(value["ok"], value)
        # A same-name Job with another UID is the wrong identity, so it is UNKNOWN
        # rather than a positive-absence FAIL; either way it is never a PASS.
        self.assertNotIn("pass", [item["decision"] for item in value["migration"]], value)
        self.assertFalse(value["accept_mechanism"])

    def test_boundary_integrated_path_interrupted_capture(self):
        value = self.run_integrated_path(fault=True)
        self.assertFalse(value["ok"], value)

    # --- the actual compiled driver through the row's request/phase interface ---

    def ca_request(self, root, pins, phase, capture, report, binding, evidence,
                   scenario="aws", authority=None, submission_authority=None):
        request = {
            "repository": str(REPOSITORY),
            "candidate": str(self.candidate),
            "install": str(self.install),
            "workspace": str(self.workspace),
            "pins": pins,
            "authority": authority or {
                "principal": "offline-reader", "cluster": "offline-cluster",
                "endpoint": "https://offline.invalid"},
            "submission_authority": submission_authority or {
                "principal": "offline-reader", "cluster": "offline-cluster",
                "endpoint": "https://offline.invalid"},
            "kubeconfig": str(root / "explicit.kubeconfig"),
            "context": "explicit-observer",
            "identity_scope": "qualifier",
            "attempt": "offline",
            "assessment": "a1",
            "scenario": scenario,
            "evidence": str(evidence),
            "phase": phase,
            "capture": str(capture),
            "report": str(report),
            "binding": binding,
            "migration_capture": str(root / "ca-migration-capture.json"),
            "application_capture": str(root / "ca-application-capture.json"),
        }
        path = root / f"ca-request-{phase}.json"
        path.write_text(json.dumps(request))
        return path

    def invoke_ca_driver(self, phase, request, env):
        result = subprocess.run(
            [str(CA_DRIVER), "--phase", phase, "--request", str(request)],
            env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        self.assertFalse((self.root / "provider-called").exists(),
                         "the real driver attempted provider execution")
        return result

    def run_real_driver(self, mutation=None, deny_reads=False, scenario="aws",
                        authority=None, submission_authority=None, receipt_principal=None):
        authority = authority or {
            "principal": "offline-reader", "cluster": "offline-cluster",
            "endpoint": "https://offline.invalid"}
        submission_authority = submission_authority or authority
        receipt_principal = receipt_principal or submission_authority["principal"]
        target_file = self.workspace / "sol/environments.yml"
        original_target = target_file.read_text()
        original_target_name = fixture.TARGET
        if scenario == "gcp":
            target_file.write_text(original_target.replace("aws/region", "gcp/region"))
            fixture.TARGET = "dev/gcp/region"
        try:
            sol = self.install / "bin/sol"
            sol.write_text(PROTOCOL_SOL.replace("__VERSION__", fixture.VERSION))
            sol.chmod(0o755)
            self.archive()
            bound = self.run_binding(True)
            pins = self.expected(bound)
            self.pin_path.write_text(json.dumps(pins))
            root, env = self.integration_environment()
            env["SOL_INTEGRATION_PRINCIPAL"] = authority["principal"]
            if mutation is not None:
                env["SOL_INTEGRATION_MUTATION"] = mutation
            previous = {key: os.environ.get(key) for key in env}
            os.environ.update(env)
            try:
                os.environ["SOL_WORLD_ONLY"] = "1"
                try:
                    self.invoke(True, pins, exercise=False, scenario=scenario)
                finally:
                    os.environ.pop("SOL_WORLD_ONLY", None)
                migration = json.loads((root / "migration.json").read_text())
                if deny_reads:
                    world = json.loads((root / "world.json").read_text())
                    world["deny_reads"] = True
                    (root / "world.json").write_text(json.dumps(world))
                driver_env = dict(
                    os.environ, PATH=str(self.private_bin),
                    PROVIDER_MARKER=str(self.root / "provider-called"),
                    SOL_HOME=str(self.root / "wrong-assets"),
                    FAKE_MIGRATION_NAMESPACE=migration["namespace"],
                    FAKE_MIGRATION_NAME=migration["name"],
                    FAKE_MIGRATION_UID=migration["uid"],
                    FAKE_MIGRATION_PRINCIPAL=receipt_principal,
                    FAKE_MIGRATION_CLUSTER=submission_authority["cluster"],
                    FAKE_MIGRATION_ENDPOINT=submission_authority["endpoint"])
                evidence = root / "ca-evidence"
                results = {}
                request = self.ca_request(
                    root, pins, "requirements", "", str(root / "ca-requirements.json"), "",
                    evidence, scenario=scenario, authority=authority,
                    submission_authority=submission_authority)
                results["requirements"] = self.invoke_ca_driver(
                    "requirements", request, driver_env)
                requirements = (
                    json.loads(results["requirements"].stdout)
                    if results["requirements"].returncode == 0 else None)
                for phase in ("migration", "application"):
                    capture = root / f"ca-{phase}-capture.json"
                    request = self.ca_request(
                        root, pins, phase, capture, root / f"ca-{phase}.json", "b" * 64,
                        evidence, scenario=scenario, authority=authority,
                        submission_authority=submission_authority)
                    results[phase] = self.invoke_ca_driver(phase, request, driver_env)
                report_path = root / "ca-report.json"
                request = self.ca_request(
                    root, pins, "report", "", report_path, "", evidence,
                    scenario=scenario, authority=authority,
                    submission_authority=submission_authority)
                results["report"] = self.invoke_ca_driver("report", request, driver_env)
                value = json.loads(report_path.read_text()) if report_path.exists() else None
                return {"root": root, "env": driver_env, "pins": pins, "migration": migration,
                        "results": results, "report": value, "evidence": evidence,
                        "requirements": requirements}
            finally:
                for key, value in previous.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value
        finally:
            fixture.TARGET = original_target_name
            target_file.write_text(original_target)

    def test_boundary_real_driver_report(self):
        run = self.run_real_driver()
        for phase in ("requirements", "migration", "application", "report"):
            result = run["results"][phase]
            self.assertEqual(result.returncode, 0, phase + ": " + result.stderr)
        value = run["report"]
        self.assertEqual(value["ca_family"], "pass", value)
        self.assertTrue(value["complete"], value)
        self.assertFalse(value["release_accepted"], value)
        self.assertEqual(value["identity_scope"], "qualifier", value)
        self.assertTrue(value["independent_qualifier"], value)
        # Two declared database consumers and one migration context; the
        # Kafka-only nonconsumer is not required to carry the CA.
        self.assertEqual(len(value["outcomes"]), 3, value)
        self.assertFalse(
            any("checkout" in item["instance"] for item in value["outcomes"]), value)

    def test_boundary_real_driver_gcp_separates_submission_from_observation(self):
        observer = {"principal": "gcp:qualifier", "cluster": "offline-cluster",
                    "endpoint": "https://offline.invalid"}
        writer = {"principal": "gcp:deployer", "cluster": "offline-cluster",
                  "endpoint": "https://offline.invalid"}
        run = self.run_real_driver(scenario="gcp", authority=observer,
                                   submission_authority=writer)
        for phase in ("migration", "application", "report"):
            result = run["results"][phase]
            self.assertEqual(result.returncode, 0, phase + ": " + result.stderr)
        value = run["report"]
        self.assertEqual(value["ca_family"], "pass", value)
        self.assertTrue(value["complete"], value)
        self.assertFalse(value["release_accepted"], value)
        self.assertEqual(value["authority"]["principal"], "gcp:qualifier", value)
        self.assertEqual(value["submission_authority"]["principal"], "gcp:deployer", value)
        self.assertEqual(len(value["outcomes"]), 3, value)
        self.assertTrue(all(item["instance"].startswith("gcp/")
                            for item in value["outcomes"]), value)
        requirements = run["requirements"]
        self.assertEqual(sorted(requirements["namespaces"]),
                         ["sol-db-specimen-dev-gcp-region", "specimen-comms",
                          "specimen-payments"], requirements)
        self.assertIn({"namespace": "sol-db-specimen-dev-gcp-region",
                       "resource": "jobs.batch"}, requirements["reads"], requirements)
        self.assertIn({"namespace": "specimen-payments",
                       "resource": "deployments.apps"}, requirements["reads"], requirements)

    def test_boundary_real_driver_gcp_rejects_foreign_submission_identity(self):
        observer = {"principal": "gcp:qualifier", "cluster": "offline-cluster",
                    "endpoint": "https://offline.invalid"}
        writer = {"principal": "gcp:deployer", "cluster": "offline-cluster",
                  "endpoint": "https://offline.invalid"}
        run = self.run_real_driver(scenario="gcp", authority=observer,
                                   submission_authority=writer,
                                   receipt_principal="gcp:intruder")
        result = run["results"]["migration"]
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        phase = json.loads((run["root"] / "ca-migration.json").read_text())
        self.assertIn("another Kubernetes authority", phase["error"])

    def test_boundary_real_driver_gcp_report_without_phases_fails(self):
        observer = {"principal": "gcp:qualifier", "cluster": "offline-cluster",
                    "endpoint": "https://offline.invalid"}
        writer = {"principal": "gcp:deployer", "cluster": "offline-cluster",
                  "endpoint": "https://offline.invalid"}
        run = self.run_real_driver(scenario="gcp", authority=observer,
                                   submission_authority=writer)
        empty = run["root"] / "ca-empty-evidence"
        report = run["root"] / "ca-empty-report.json"
        request = self.ca_request(
            run["root"], run["pins"], "report", "", report, "", empty,
            scenario="gcp", authority=observer, submission_authority=writer)
        result = self.invoke_ca_driver("report", request, run["env"])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_boundary_real_driver_missing_mount_fails(self):
        run = self.run_real_driver(mutation="missing_mount")
        self.assertEqual(run["results"]["migration"].returncode, 0,
                         run["results"]["migration"].stderr)
        self.assertNotEqual(run["results"]["application"].returncode, 0)

    def test_boundary_real_driver_list_authority_without_get(self):
        # The fixture allows list and denies get: the actual collection operation
        # is sufficient, without an unrelated named-object grant.
        run = self.run_real_driver()
        self.assertEqual(run["results"]["report"].returncode, 0,
                         run["results"]["report"].stderr)

    def test_boundary_real_driver_get_without_list_refuses(self):
        run = self.run_real_driver(deny_reads=True)
        self.assertNotEqual(run["results"]["migration"].returncode, 0)
        self.assertIn("cannot read", run["results"]["migration"].stderr)

    def test_boundary_real_driver_rejects_mismatched_evidence(self):
        run = self.run_real_driver()
        self.assertEqual(run["results"]["report"].returncode, 0)
        evidence = run["evidence"]
        root = run["root"]
        for direction in ("verdicts", "binding"):
            tampered = root / f"ca-tampered-{direction}.json"
            env = dict(run["env"], SOL_TAMPER=direction,
                       SOL_TAMPER_EVIDENCE=str(evidence),
                       SOL_TAMPER_SOURCE=str(root / "ca-application-capture.json"),
                       SOL_TAMPER_OUT=str(tampered))
            probe = subprocess.run(
                [str(DRIVER), str(REPOSITORY), str(self.candidate), str(self.install),
                 str(self.workspace), str(self.pin_path), "-", "aws"],
                env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
            self.assertEqual(probe.returncode, 0, probe.stderr)
            report_path = root / f"ca-report-tampered-{direction}.json"
            request = self.ca_request(root, run["pins"], "report", "", report_path, "", evidence)
            data = json.loads(request.read_text())
            data["migration_capture"] = str(tampered)
            request.write_text(json.dumps(data))
            result = self.invoke_ca_driver("report", request, run["env"])
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == "__main__":
    suite = unittest.TestSuite(Boundary(name) for name in dir(Boundary) if name.startswith("test_boundary_"))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
