#!/usr/bin/env python3
"""Offline regression for the bootstrap policy contracts, not effective cloud IAM.

These operations need unconditional authority in the generated contract. Conditions
on a matching grant or denial require an explicit review of that contract; this test
never assumes an unknown condition is satisfied or harmless. External attachments,
SCPs, role trust and provider-internal operations remain live qualification concerns.
"""
import copy
import fnmatch
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP = ROOT / "platform/cloud/aws/bootstrap"
REPOSITORY = "arn:aws:ecr:eu-west-1:111122223333:repository/review/charge-svc"

# An independent operation oracle: do not derive this from the policy's actions.
ECR_LIFECYCLE = (
    "CreateRepository", "DeleteRepository", "DescribeRepositories",
    "PutLifecyclePolicy", "GetLifecyclePolicy", "DeleteLifecyclePolicy",
    "PutImageScanningConfiguration", "TagResource", "UntagResource", "ListTagsForResource",
)
PUBLISH = (
    "BatchCheckLayerAvailability", "InitiateLayerUpload", "UploadLayerPart",
    "CompleteLayerUpload", "PutImage", "BatchGetImage", "GetDownloadUrlForLayer",
)
REQUIRED = (
    [("provisioner", "ecr:" + action, REPOSITORY) for action in ECR_LIFECYCLE]
    + [("provisioner", "ecr:DescribeRepositories", "*")]
    + [("publisher", "ecr:" + action, REPOSITORY) for action in PUBLISH]
    + [("publisher", "ecr:GetAuthorizationToken", "*")]
    + [("provisioner", action, resource) for action, resource in (
        ("eks:CreateCluster", "arn:aws:eks:eu-west-1:111122223333:cluster/review"),
        ("eks:DescribeCluster", "arn:aws:eks:eu-west-1:111122223333:cluster/review"),
        ("eks:DeleteCluster", "arn:aws:eks:eu-west-1:111122223333:cluster/review"),
        ("ec2:DescribeVpcs", "*"),
        ("ec2:CreateVpc", "arn:aws:ec2:eu-west-1:111122223333:vpc/*"),
        ("ec2:DeleteVpc", "arn:aws:ec2:eu-west-1:111122223333:vpc/vpc-review"),
        ("rds:CreateDBInstance", "arn:aws:rds:eu-west-1:111122223333:db:review-postgres"),
        ("rds:DescribeDBInstances", "*"),
        ("rds:DeleteDBInstance", "arn:aws:rds:eu-west-1:111122223333:db:review-postgres"),
    )]
)
FORBIDDEN = (
    [("provisioner", "ecr:" + action, REPOSITORY) for action in PUBLISH]
    + [("provisioner", "ecr:GetAuthorizationToken", "*")]
    + [("publisher", "ecr:" + action, REPOSITORY)
       for action in ("CreateRepository", "DeleteRepository", "PutLifecyclePolicy")]
)


def strings(statement, key):
    values = statement.get(key, [])
    if not isinstance(values, list):
        raise ValueError(f"{key} is not a literal list")
    if any(not tfconfig.is_string_literal(value) for value in values):
        raise ValueError(f"{key} contains an unevaluated expression")
    decoded = [tfconfig.unquote(value) for value in values]
    if any("${" in value or "%{" in value for value in decoded):
        raise ValueError(f"{key} contains an unevaluated interpolation")
    return decoded


def matches(statement, action, resource):
    # Deliberately bounded to the existing positive Action/Resource contract.
    if any(key in statement for key in ("not_actions", "not_resources", "principals", "not_principals")):
        raise ValueError("additional IAM selectors need explicit contract review")
    if tfconfig.unquote(statement.get("effect", '\"Allow\"')) not in ("Allow", "Deny"):
        raise ValueError("unevaluated IAM effect needs explicit contract review")
    return (
        any(fnmatch.fnmatchcase(action.lower(), pattern.lower())
            for pattern in strings(statement, "actions"))
        and any(fnmatch.fnmatchcase(resource, pattern)
                for pattern in strings(statement, "resources"))
    )


def failures(documents):
    failures = []
    for policy, action, resource in REQUIRED + FORBIDDEN:
        required = (policy, action, resource) in REQUIRED
        matching = [s for s in documents[policy] if matches(s, action, resource)]
        allows = [s for s in matching if tfconfig.unquote(s.get("effect", '"Allow"')) == "Allow"]
        denies = [s for s in matching if tfconfig.unquote(s.get("effect", '"Allow"')) == "Deny"]
        unconditional_allows = [s for s in allows if not tfconfig.blocks(s, "condition")]
        unconditional_denies = [s for s in denies if not tfconfig.blocks(s, "condition")]
        if required and (not unconditional_allows or denies):
            failures.append((policy, action, resource, "required unconditional lifecycle authority"))
        if not required and not unconditional_denies:
            failures.append((policy, action, resource, "required unconditional separation deny"))
    return failures


class InfrastructurePermissions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.documents = {}
        for resource in tfconfig.resources(BOOTSTRAP / "main.tf"):
            if resource.type != "aws_iam_policy_document":
                continue
            unsupported = set(resource.body) - {"statement", "version", "policy_id", "__is_block__"}
            if unsupported:
                raise ValueError(f"unmodeled policy composition: {sorted(unsupported)}")
            cls.documents[resource.name] = tfconfig.blocks(resource.body, "statement")

    def test_real_policy_contract(self):
        self.assertEqual([], failures(self.documents))
        outputs = tfconfig.load(BOOTSTRAP / "outputs.tf")["output"]
        for policy in ("provisioner", "publisher"):
            with self.subTest(policy=policy):
                binding = next(body for output in outputs for name, body in output.items()
                               if tfconfig.unquote(name) == policy + "_policy_json")
                self.assertEqual("${data.aws_iam_policy_document." + policy + ".json}", binding["value"])

    def test_every_lifecycle_action_is_required_on_the_correct_principal(self):
        for action in ECR_LIFECYCLE:
            with self.subTest(action=action):
                docs = copy.deepcopy(self.documents)
                grant = docs["provisioner"][0]
                grant["actions"].remove('"ecr:' + action + '"')
                # Presence on the wrong identity must not satisfy provisioning.
                docs["publisher"][0]["actions"].append('"ecr:' + action + '"')
                self.assertTrue(any(f[:2] == ("provisioner", "ecr:" + action) for f in failures(docs)))

    def test_wrong_resources_and_conditions_do_not_satisfy_lifecycle(self):
        for change in ("wrong-resource", "condition", "explicit-deny", "conditional-deny"):
            with self.subTest(change=change):
                docs = copy.deepcopy(self.documents)
                grant = docs["provisioner"][0]
                condition = [{"test": '"StringEquals"', "variable": '"aws:RequestedRegion"',
                              "values": ['"us-east-1"']}]
                if change == "wrong-resource":
                    grant["resources"] = ['"arn:aws:ecr:us-east-1:000000000000:repository/other/*"']
                elif change == "condition":
                    grant["condition"] = condition
                else:
                    deny = {"effect": '"Deny"', "actions": ['"ecr:CreateRepository"'], "resources": ['"*"']}
                    if change == "conditional-deny":
                        deny["condition"] = condition
                    docs["provisioner"].append(deny)
                self.assertTrue(any(f[:2] == ("provisioner", "ecr:CreateRepository") for f in failures(docs)))

    def test_separation_denials_cover_actions_resources_and_conditions(self):
        for policy, index in (("provisioner", 1), ("publisher", 1)):
            for change in ("action", "resource", "condition"):
                with self.subTest(policy=policy, change=change):
                    docs = copy.deepcopy(self.documents)
                    deny = docs[policy][index]
                    if change == "action":
                        deny["actions"] = ['"ecr:UnrelatedAction"']
                    elif change == "resource":
                        deny["resources"] = ['"arn:aws:ecr:us-east-1:000000000000:repository/other/*"']
                    else:
                        deny["condition"] = [{"test": '"Bool"', "variable": '"aws:SecureTransport"', "values": ['"false"']}]
                    self.assertTrue(any(f[0] == policy and "separation deny" in f[3] for f in failures(docs)))

    def test_resource_scoped_grant_and_action_wildcard_are_semantic(self):
        docs = copy.deepcopy(self.documents)
        docs["provisioner"][0]["actions"].remove('"ecr:CreateRepository"')
        docs["provisioner"].append({"effect": '\"Allow\"',
                                    "actions": ['\"ecr:CreateRepositor?\"'],
                                    "resources": ['\"arn:aws:ecr:eu-west-1:111122223333:repository/review/*\"']})
        self.assertEqual([], failures(docs))

    def test_opaque_or_additional_selectors_cannot_be_assumed_harmless(self):
        for field, value in (
            ("resources", ['\"arn:aws:ecr:${var.region}:111122223333:repository/*\"']),
            ("effect", "${var.effect}"),
            ("principals", [{"type": '\"AWS\"', "identifiers": ['\"other-account\"']}]),
        ):
            with self.subTest(field=field):
                docs = copy.deepcopy(self.documents)
                deny = {"effect": '\"Deny\"', "actions": ['\"ecr:CreateRepository\"'], "resources": ['\"*\"']}
                deny[field] = value
                docs["provisioner"].append(deny)
                with self.assertRaises(ValueError):
                    failures(docs)

    def test_unrelated_denial_does_not_block_required_operations(self):
        docs = copy.deepcopy(self.documents)
        docs["provisioner"].append({"effect": '"Deny"', "actions": ['"ecr:CreateRepository"'],
                                    "resources": ['"arn:aws:ecr:eu-west-1:000000000000:repository/other/*"']})
        self.assertEqual([], failures(docs))


class KafkaAuthorityPermissions(unittest.TestCase):
    """Resolve only concrete test inputs; Terraform and IAM still own evaluation."""
    region = "eu-west-1"
    account = "111122223333"
    target_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:sol-kafka-review-a1b2c3"
    deploy_role = "arn:aws:iam::111122223333:role/deploy"
    lifecycle = (
        "CreateSecret", "DeleteSecret", "DescribeSecret", "GetSecretValue",
        "PutSecretValue", "UpdateSecret", "ListSecretVersionIds",
        "UpdateSecretVersionStage", "TagResource", "UntagResource",
        "GetResourcePolicy", "PutResourcePolicy", "DeleteResourcePolicy",
    )

    @classmethod
    def resolved(cls, value):
        # These are bound fixture inputs, never inferred policy grants. Unknown
        # expressions remain errors rather than being assumed permissive.
        refs = {
            "var.region": cls.region,
            "data.aws_caller_identity.current.account_id": cls.account,
            "aws_secretsmanager_secret.kafka[0].arn": cls.target_arn,
            "var.deploy_role_arn": cls.deploy_role,
        }
        if isinstance(value, list):
            return [cls.resolved(v) for v in value]
        if isinstance(value, dict):
            return {k: cls.resolved(v) for k, v in value.items()}
        if isinstance(value, str):
            import json
            if value.startswith("${") and value.endswith("}") and value[2:-1] in refs:
                return json.dumps(refs[value[2:-1]])
            for key, replacement in refs.items():
                value = value.replace("${" + key + "}", replacement)
            if "${" in value or "%{" in value:
                raise ValueError("unresolved Kafka policy fixture input")
        return value

    @classmethod
    def setUpClass(cls):
        bootstrap = next(r for r in tfconfig.resources(BOOTSTRAP / "main.tf")
                         if r.type == "aws_iam_policy_document" and r.name == "provisioner")
        cls.provisioner = cls.resolved(tfconfig.blocks(bootstrap.body, "statement"))
        native = tfconfig.resources(ROOT / "platform/cloud/aws/cluster/kafka.tf")
        reader = next(r for r in native if r.type == "aws_iam_policy_document" and r.name == "kafka_reader")
        cls.reader = cls.resolved(tfconfig.blocks(reader.body, "statement"))
        cls.binding = next(r for r in native if r.type == "aws_secretsmanager_secret_policy" and r.name == "kafka_reader")

    def allows(self, statements, action, resource):
        matching = [s for s in statements if matches(s, action, resource)]
        self.assertTrue(all(not tfconfig.blocks(s, "condition") for s in matching),
                        "conditional authority requires an explicit behavioral model")
        return (any(tfconfig.unquote(s.get("effect", '\"Allow\"')) == "Allow" for s in matching)
                and not any(tfconfig.unquote(s.get("effect", '\"Allow\"')) == "Deny" for s in matching))

    def test_provisioner_lifecycle_is_scoped_to_its_region_account_and_native_namespace(self):
        for action in self.lifecycle:
            with self.subTest(action=action):
                self.assertTrue(self.allows(self.provisioner, "secretsmanager:" + action, self.target_arn))
                for outside in (
                    self.target_arn.replace(self.region, "us-east-1"),
                    self.target_arn.replace(self.account, "000000000000"),
                    self.target_arn.replace("sol-kafka-review", "application-password"),
                ):
                    self.assertFalse(self.allows(self.provisioner, "secretsmanager:" + action, outside))

    def test_deploy_reader_has_only_one_secret_and_no_mutation_authority(self):
        self.assertEqual("${data.aws_iam_policy_document.kafka_reader[0].json}", self.binding.body["policy"])
        self.assertEqual(self.target_arn, tfconfig.unquote(self.resolved(self.binding.body["secret_arn"])))
        self.assertEqual(True, self.binding.body["block_public_policy"])
        for statement in self.reader:
            self.assertEqual({"AWS"}, {tfconfig.unquote(p["type"]) for p in tfconfig.blocks(statement, "principals")})
            for principal in tfconfig.blocks(statement, "principals"):
                self.assertEqual([self.deploy_role], strings(principal, "identifiers"))
        # Resource-policy principals are checked above; the selector matcher is
        # deliberately the same bounded matcher as the identity-policy tests.
        statements = [{k: v for k, v in s.items() if k != "principals"} for s in self.reader]
        self.assertTrue(self.allows(statements, "secretsmanager:GetSecretValue", self.target_arn))
        self.assertFalse(self.allows(statements, "secretsmanager:GetSecretValue", self.target_arn + "other"))
        for action in set(self.lifecycle) - {"GetSecretValue"}:
            self.assertFalse(self.allows(statements, "secretsmanager:" + action, self.target_arn))


if __name__ == "__main__":
    unittest.main()
