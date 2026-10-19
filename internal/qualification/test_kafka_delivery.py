#!/usr/bin/env python3
"""Behavioral tests at the provider/Kubernetes read boundary."""
import base64
import copy
import importlib.util
import io
import gzip
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("delivery", Path(__file__).with_name("kafka-delivery.py"))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)
PASSWORD = "credential-canary-do-not-record"
CA = "trust-material"


def encoded(value):
    return base64.b64encode(value.encode()).decode()


class Delivery(unittest.TestCase):
    def setUp(self):
        self.args = SimpleNamespace(provider="aws", cluster="test", region="us-east-1", account="123",
            project="project", kubeconfig="", namespaces=["app"], consumer=["app/consumer"],
            authority={"secret_name":"sol-kafka-test", "reference":"arn:aws:secretsmanager:us-east-1:123:secret:sol-kafka-test-abc",
                       "username":"sol-workloads", "mechanism":"SCRAM-SHA-256"})
        self.secrets = {
            "redpanda-users":{"users.txt":encoded(f"sol-workloads:{PASSWORD}:SCRAM-SHA-256")},
            "redpanda-default-cert":{"ca.crt":encoded(CA)},
            "delivered":{"KAFKA_SASL_PASSWORD":encoded(PASSWORD),"KAFKA_SSL_CA_CERT":encoded(CA)},
        }
        self.workloads = {"items":[{"metadata":{"name":"consumer"},"spec":{"template":{"spec":{
            "containers":[{"env":[{"name":"KAFKA_SASL_PASSWORD","valueFrom":{"secretKeyRef":{"name":"delivered","key":"KAFKA_SASL_PASSWORD"}}}],
                           "volumeMounts":[{"name":"ca"}]}],
            "volumes":[{"name":"ca","secret":{"secretName":"delivered","items":[{"key":"KAFKA_SSL_CA_CERT"}]}}]
        }}}}]}
        self.calls = []

    def read(self, argv, **kwargs):
        self.calls.append(argv)
        if argv[0] == "aws":
            self.assertIn("get-secret-value", argv)
            return {"SecretString":PASSWORD}
        if argv[:3] == ["gcloud", "projects", "describe"]:
            return {"projectId":"project", "projectNumber":"123"}
        if argv[0] == "gcloud":
            self.assertEqual(argv[1:4], ["secrets","versions","access"])
            return PASSWORD.encode()
        if "deployments" in argv:
            return self.workloads
        return {"data":self.secrets[argv[argv.index("secret")+1]]}

    def test_both_providers_match_without_recording_values(self):
        for provider in ("aws","gcp"):
            self.args.provider = provider
            if provider == "gcp":
                self.args.authority["reference"] = "projects/project/secrets/sol-kafka-test"
            with patch.object(delivery, "read", self.read):
                result = delivery.observe(self.args)
            self.assertEqual(result["consumers"], ["app/consumer"])
            self.assertNotIn(PASSWORD, json.dumps(result))
            self.assertNotIn(PASSWORD, json.dumps(self.calls))
            self.assertFalse(any("create" in a or "patch" in a for a in self.calls))

    def test_gcp_numeric_project_identity_requires_provider_confirmation(self):
        self.args.provider = "gcp"
        self.args.authority["reference"] = "projects/123/secrets/sol-kafka-test"
        with patch.object(delivery, "read", self.read):
            self.assertTrue(delivery.observe(self.args)["broker_matches_authority"])
        self.args.authority["reference"] = "projects/999/secrets/sol-kafka-test"
        with patch.object(delivery, "read", self.read), self.assertRaises(ValueError):
            delivery.observe(self.args)

    def test_each_mismatch_or_missing_input_refuses(self):
        original = copy.deepcopy(self.secrets)
        for name,key in [("redpanda-users","users.txt"),("delivered","KAFKA_SASL_PASSWORD"),("delivered","KAFKA_SSL_CA_CERT")]:
            for value in ("", encoded("wrong")):
                self.secrets = copy.deepcopy(original)
                self.secrets[name][key] = value
                with patch.object(delivery,"read",self.read), self.assertRaises(ValueError):
                    delivery.observe(self.args)

    def test_missing_consumer_and_unmounted_trust_refuse(self):
        original = copy.deepcopy(self.workloads)
        for change in ("missing","unmounted"):
            self.workloads = copy.deepcopy(original)
            if change == "missing":
                self.workloads["items"] = []
            else:
                self.workloads["items"][0]["spec"]["template"]["spec"]["containers"][0]["volumeMounts"] = []
            with patch.object(delivery,"read",self.read), self.assertRaises(ValueError):
                delivery.observe(self.args)

    def test_public_failure_never_contains_provider_exception_values(self):
        argv = ["delivery","--provider","aws","--cluster","test","--region","us-east-1","--consumer","app/consumer","app"]
        out,err = io.StringIO(),io.StringIO()
        with patch("sys.argv",argv), patch("sys.stdin",io.StringIO(json.dumps(self.args.authority))), \
             patch("sys.stdout",out), patch("sys.stderr",err), \
             patch.object(delivery,"read",side_effect=ValueError(PASSWORD)):
            self.assertEqual(delivery.main(),1)
        self.assertNotIn(PASSWORD,out.getvalue()+err.getvalue())


class StateEvidence(unittest.TestCase):
    def test_plain_and_compressed_state_never_archive_values(self):
        spec = importlib.util.spec_from_file_location("state_evidence", Path(__file__).with_name("state-evidence.py"))
        state_evidence = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(state_evidence)
        raw = json.dumps({"version":4,"serial":7,"resources":[{"secret_data":PASSWORD}],
                          "outputs":{"postgres_url":{"value":PASSWORD},
                                     "kafka_authority":{"value":{"reference":"public", "password":PASSWORD}},
                                     "another_sensitive_output":{"value":PASSWORD}}}).encode()
        for content in (raw,gzip.compress(raw)):
            result = state_evidence.project(content)
            self.assertNotIn(PASSWORD,json.dumps(result))
            self.assertEqual(result["outputs"]["kafka_authority"]["value"], {"reference":"public"})
            self.assertEqual(result["serial"],7)
            self.assertTrue(result["outputs"]["postgres_url"]["value"])


if __name__ == "__main__":
    unittest.main()
