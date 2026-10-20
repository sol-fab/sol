#!/usr/bin/env python3
"""Behavioral tests for the value-free Kafka delivery observer."""
import copy
import gzip
import importlib.util
import io
import json
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "delivery", Path(__file__).with_name("kafka-delivery.py")
)
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)
PASSWORD = "credential-canary-do-not-record"
CA = "trust-material"


class Delivery(unittest.TestCase):
    def setUp(self):
        handle = tempfile.NamedTemporaryFile("w", delete=False)
        handle.write(
            "charge id: ch_1\n"
            "read-back: the worker effect ch_1 is visible to the service\n"
        )
        handle.close()
        self.transaction = handle.name
        self.args = SimpleNamespace(
            provider="aws",
            cluster="test",
            region="us-east-1",
            account="123",
            project="project",
            kubeconfig="",
            secret_kubeconfig="deploy",
            credential_secret="delivered",
            transaction=self.transaction,
            behavioral_consumer=["app/consumer"],
            namespaces=["app"],
            consumer=["app/consumer"],
            authority={
                "secret_name": "sol-kafka-test",
                "reference": "arn:aws:secretsmanager:us-east-1:123:secret:sol-kafka-test-abc",
                "username": "sol-workloads",
                "mechanism": "SCRAM-SHA-256",
            },
        )
        self.workloads = {
            "items": [
                {
                    "metadata": {"name": "consumer"},
                    "spec": {
                        "template": {
                            "spec": {
                                "containers": [
                                    {
                                        "env": [
                                            {
                                                "name": "KAFKA_SASL_PASSWORD",
                                                "valueFrom": {
                                                    "secretKeyRef": {
                                                        "name": "delivered",
                                                        "key": "KAFKA_SASL_PASSWORD",
                                                    }
                                                },
                                            }
                                        ],
                                        "volumeMounts": [{"name": "ca"}],
                                    }
                                ],
                                "volumes": [
                                    {
                                        "name": "ca",
                                        "secret": {
                                            "secretName": "delivered",
                                            "items": [{"key": "KAFKA_SSL_CA_CERT"}],
                                        },
                                    }
                                ],
                            }
                        }
                    },
                }
            ]
        }
        self.metadata = "delivered"
        self.calls = []

    def tearDown(self):
        Path(self.transaction).unlink(missing_ok=True)

    def read_json(self, argv):
        self.calls.append(argv)
        if argv[:3] == ["gcloud", "projects", "describe"]:
            return {"projectId": "project", "projectNumber": "123"}
        if "deployments" in argv:
            return self.workloads
        self.fail(f"unexpected JSON read: {argv}")

    def read_text(self, argv):
        self.calls.append(argv)
        if "secret" in argv:
            return self.metadata
        self.fail(f"unexpected text read: {argv}")

    def observe(self, provider="aws"):
        self.args.provider = provider
        if provider == "gcp" and self.args.authority["reference"].startswith("arn:"):
            self.args.authority["reference"] = "projects/project/secrets/sol-kafka-test"
        with patch.object(delivery, "read_json", self.read_json), patch.object(
            delivery, "read_text", self.read_text
        ):
            return delivery.observe(self.args)

    def test_both_providers_project_without_reading_values(self):
        for provider in ("aws", "gcp"):
            result = self.observe(provider)
            self.assertEqual(result["consumers"], ["app/consumer"])
            self.assertEqual(result["credential_values"], "never read")
            self.assertEqual(result["authentication"]["consumers"], ["app/consumer"])
            self.assertEqual(result["authentication"]["evidence"], self.transaction)
            # No provider secret read and no Secret data read: the observer only
            # asks deployments for projections and a Secret for its name.
            self.assertFalse(
                any(
                    "secretsmanager" in call
                    or ("secrets" in call and "versions" in call)
                    for call in self.calls
                )
            )
            self.assertFalse(
                any("secret" in call and "-o" in call and "json" in call for call in self.calls)
            )
            self.assertTrue(
                any(
                    "secret" in call and any("jsonpath=" in arg for arg in call)
                    for call in self.calls
                )
            )
            self.assertNotIn(PASSWORD, json.dumps(result))
            self.assertNotIn(PASSWORD, json.dumps(self.calls))
            self.assertNotIn(CA, json.dumps(result))

    def test_gcp_numeric_project_identity_requires_provider_confirmation(self):
        self.args.authority["reference"] = "projects/123/secrets/sol-kafka-test"
        self.assertEqual(
            self.observe("gcp")["authority"], "projects/123/secrets/sol-kafka-test"
        )
        self.assertIn(["gcloud", "projects", "describe", "project", "--format=json"], self.calls)
        self.args.authority["reference"] = "projects/999/secrets/sol-kafka-test"
        with self.assertRaises(delivery.ObservationError):
            self.observe("gcp")

    def test_each_mismatch_or_missing_input_refuses(self):
        original = copy.deepcopy(self.workloads)

        def env():
            return self.workloads["items"][0]["spec"]["template"]["spec"]["containers"][0]["env"]

        cases = {
            "wrong_secret": lambda: env()[0]["valueFrom"]["secretKeyRef"].update(name="other"),
            "wrong_key": lambda: env()[0]["valueFrom"]["secretKeyRef"].update(key="OTHER"),
            "no_ca_item": lambda: self.workloads["items"][0]["spec"]["template"]["spec"][
                "volumes"
            ][0]["secret"].update(items=[]),
            "unmounted": lambda: self.workloads["items"][0]["spec"]["template"]["spec"][
                "containers"
            ][0].update(volumeMounts=[]),
            "missing_consumer": lambda: self.workloads.update(items=[]),
            "missing_secret": lambda: setattr(self, "metadata", "other"),
            "no_behavioral": lambda: setattr(self.args, "behavioral_consumer", []),
            "foreign_behavioral": lambda: setattr(
                self.args, "behavioral_consumer", ["app/other"]
            ),
        }
        for name, change in cases.items():
            self.workloads = copy.deepcopy(original)
            self.metadata = "delivered"
            self.args.behavioral_consumer = ["app/consumer"]
            change()
            with self.subTest(name=name), self.assertRaises(delivery.ObservationError):
                self.observe()

    def test_missing_transaction_marker_refuses(self):
        Path(self.transaction).write_text("charge id: ch_1\n", encoding="utf-8")
        with self.assertRaises(delivery.ObservationError):
            self.observe()
        Path(self.transaction).unlink()
        with self.assertRaises(delivery.ObservationError):
            self.observe()

    def test_authority_scope_refuses(self):
        self.args.authority["reference"] = (
            "arn:aws:secretsmanager:us-east-1:999:secret:sol-kafka-test-abc"
        )
        with self.assertRaises(delivery.ObservationError):
            self.observe()
        self.args.authority["secret_name"] = "sol-kafka-other"
        with self.assertRaises(delivery.ObservationError):
            self.observe()

    def test_public_failure_never_contains_provider_exception_values(self):
        argv = [
            "delivery",
            "--provider",
            "aws",
            "--cluster",
            "test",
            "--region",
            "us-east-1",
            "--secret-kubeconfig",
            "deploy",
            "--credential-secret",
            "delivered",
            "--transaction",
            self.transaction,
            "--behavioral-consumer",
            "app/consumer",
            "--consumer",
            "app/consumer",
            "app",
        ]
        out, err = io.StringIO(), io.StringIO()
        with patch("sys.argv", argv), patch(
            "sys.stdin", io.StringIO(json.dumps(self.args.authority))
        ), patch("sys.stdout", out), patch("sys.stderr", err), patch.object(
            delivery, "read_json", side_effect=ValueError(PASSWORD)
        ):
            self.assertEqual(delivery.main(), 1)
        self.assertNotIn(PASSWORD, out.getvalue() + err.getvalue())


class StateEvidence(unittest.TestCase):
    def test_plain_and_compressed_state_never_archive_values(self):
        spec = importlib.util.spec_from_file_location(
            "state_evidence", Path(__file__).with_name("state-evidence.py")
        )
        state_evidence = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(state_evidence)
        raw = json.dumps(
            {
                "version": 4,
                "serial": 7,
                "resources": [{"secret_data": PASSWORD}],
                "outputs": {
                    "postgres_url": {"value": PASSWORD},
                    "kafka_authority": {"value": {"reference": "public", "password": PASSWORD}},
                    "another_sensitive_output": {"value": PASSWORD},
                },
            }
        ).encode()
        for content in (raw, gzip.compress(raw)):
            result = state_evidence.project(content)
            self.assertNotIn(PASSWORD, json.dumps(result))
            self.assertEqual(
                result["outputs"]["kafka_authority"]["value"], {"reference": "public"}
            )
            self.assertEqual(result["serial"], 7)
            self.assertTrue(result["outputs"]["postgres_url"]["value"])


if __name__ == "__main__":
    unittest.main()
