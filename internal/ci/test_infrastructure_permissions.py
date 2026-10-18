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
    return [tfconfig.unquote(value) for value in values]


def matches(statement, action, resource):
    # Deliberately bounded to the existing positive Action/Resource contract.
    if "not_actions" in statement or "not_resources" in statement:
        raise ValueError("negated IAM selectors need explicit contract review")
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
        cls.documents = {
            r.name: tfconfig.blocks(r.body, "statement")
            for r in tfconfig.resources(BOOTSTRAP / "main.tf")
            if r.type == "aws_iam_policy_document"
        }

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
                    grant["resources"] = ['"arn:aws:ecr:us-east-1:999999999999:repository/other/*"']
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
                        deny["resources"] = ['"arn:aws:ecr:us-east-1:999999999999:repository/other/*"']
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

    def test_unrelated_denial_does_not_block_required_operations(self):
        docs = copy.deepcopy(self.documents)
        docs["provisioner"].append({"effect": '"Deny"', "actions": ['"ecr:CreateRepository"'],
                                    "resources": ['"arn:aws:ecr:eu-west-1:999999999999:repository/other/*"']})
        self.assertEqual([], failures(docs))


if __name__ == "__main__":
    unittest.main()
