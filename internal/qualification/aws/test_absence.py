#!/usr/bin/env python3
"""Regression tests for the AWS absence observer.

The point of these tests is the verdict's failure modes, because those are what
a live teardown depends on: a class that is actually present, a provider read
that failed, a response that was JSON but not the shape the class requires, a
required class that was never observed, and an unrelated account resource that
must not be mistaken for the target's residue. Each residue class gets its own
present/absent pair, and the durable prerequisite is checked to be excluded
from the residue verdict.
"""

from __future__ import annotations

import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
from dataclasses import replace

import absence

CLUSTER = "qual-cluster"
REGION = "us-east-1"
ACCOUNT = "123456789012"

CANDIDATE = {
    "version": "v0.1.0-alpha.9",
    "revision": "a" * 40,
    "bundle_sha256": "b" * 64,
    "runner_image": "ghcr.io/example/sol-migration-runner@sha256:" + "c" * 64,
}

RUNTIME = absence.Runtime(
    cluster=CLUSTER,
    region=REGION,
    account=ACCOUNT,
    registry_prefix="pluto",
    base_domain="qual-aws.sol-fab.dev",
    attempt="attempt-1",
    target="qualreg/aws/us-east-1",
    state_key="sol/qualreg/aws/us-east-1/cloud.tfstate",
    candidate=CANDIDATE,
    prior={"resources": {"ebs-volume": [], "security-group": [], "elastic-ip": [], "load-balancer": [], "oidc-provider": [f"arn:aws:iam::{ACCOUNT}:oidc-provider/oidc.eks.{REGION}.amazonaws.com/id/TEST"]}},
)

CLUSTER_TAG = {"Key": f"kubernetes.io/cluster/{CLUSTER}", "Value": "owned"}

# The read each residue class uses, and a resource that is attributable to the
# target. Kept beside each other so adding a class without a fixture fails the
# suite rather than passing unnoticed.
PRESENT_FIXTURES: dict[str, tuple[tuple[str, str], object]] = {
    "kafka-secret": (("secretsmanager", "describe-secret"), {"Name": "sol-kafka-" + CLUSTER}),
    "eks-cluster": (("eks", "list-clusters"), {"clusters": [CLUSTER]}),
    "rds-instance": (
        ("rds", "describe-db-instances"),
        {"DBInstances": [{"DBInstanceIdentifier": f"{CLUSTER}-postgres"}]},
    ),
    "rds-snapshot": (
        ("rds", "describe-db-snapshots"),
        {"DBSnapshots": [{"DBSnapshotIdentifier": f"{CLUSTER}-postgres-final"}]},
    ),
    "ec2-instance": (
        ("ec2", "describe-instances"),
        {
            "Reservations": [
                {
                    "Instances": [
                        {"InstanceId": "i-residue", "State": {"Name": "running"}, "Tags": [CLUSTER_TAG]}
                    ]
                }
            ]
        },
    ),
    "vpc": (("ec2", "describe-vpcs"), {"Vpcs": [{"VpcId": "vpc-residue", "Tags": [CLUSTER_TAG]}]}),
    "nat-gateway": (
        ("ec2", "describe-nat-gateways"),
        {"NatGateways": [{"NatGatewayId": "nat-residue", "State": "available", "Tags": [CLUSTER_TAG]}]},
    ),
    "elastic-ip": (
        ("ec2", "describe-addresses"),
        {"Addresses": [{"AllocationId": "eipalloc-residue", "PublicIp": "198.51.100.5", "Tags": [CLUSTER_TAG]}]},
    ),
    "oidc-provider": (("iam", "list-open-id-connect-providers"), {"OpenIDConnectProviderList": [{"Arn": RUNTIME.prior["resources"]["oidc-provider"][0]}]}),
    "security-group": (("ec2", "describe-security-groups"), {"SecurityGroups": [{"GroupId": "sg-residue", "Tags": [{"Key": "aws:eks:cluster-name", "Value": CLUSTER}]}]}),
    "ebs-volume": (
        ("ec2", "describe-volumes"),
        {"Volumes": [{"VolumeId": "vol-residue", "State": "available", "Tags": [CLUSTER_TAG]}]},
    ),
    "load-balancer": (
        ("elbv2", "describe-load-balancers"),
        {"LoadBalancers": [{"LoadBalancerArn": "arn:aws:elbv2:::loadbalancer/app/k8s-residue", "LoadBalancerName": "k8s-residue"}]},
    ),
    "ecr-repository": (
        ("ecr", "describe-repositories"),
        {"repositories": [{"repositoryName": "pluto/charge-svc"}]},
    ),
    "cloudwatch-log-group": (
        ("logs", "describe-log-groups"),
        {"logGroups": [{"logGroupName": f"/aws/eks/{CLUSTER}/cluster"}]},
    ),
    "rds-subnet-group": (
        ("rds", "describe-db-subnet-groups"),
        {"DBSubnetGroups": [{"DBSubnetGroupName": f"{CLUSTER}-postgres"}]},
    ),
    "iam-role": (("iam", "list-roles"), {"Roles": [{"RoleName": f"{CLUSTER}-ebs-csi"}]}),
    "iam-policy": (("iam", "list-policies"), {"Policies": [{"PolicyName": f"{CLUSTER}-cert-manager"}]}),
    "s3-bucket": (("s3api", "list-buckets"), {"Buckets": [{"Name": f"{CLUSTER}-loki-logs"}]}),
    "cloudwatch-dashboard": (
        ("cloudwatch", "list-dashboards"),
        {"DashboardEntries": [{"DashboardName": f"{CLUSTER}-postgres"}]},
    ),
}

EMPTY_RESPONSES: dict[tuple[str, str], object] = {
    ("eks", "list-clusters"): {"clusters": []},
    ("rds", "describe-db-instances"): {"DBInstances": []},
    ("rds", "describe-db-subnet-groups"): {"DBSubnetGroups": []},
    ("rds", "describe-db-snapshots"): {"DBSnapshots": []},
    ("ec2", "describe-instances"): {"Reservations": []},
    ("ec2", "describe-vpcs"): {"Vpcs": []},
    ("ec2", "describe-nat-gateways"): {"NatGateways": []},
    ("ec2", "describe-addresses"): {"Addresses": []},
    ("ec2", "describe-volumes"): {"Volumes": []},
    ("ec2", "describe-security-groups"): {"SecurityGroups": []},
    ("iam", "list-open-id-connect-providers"): {"OpenIDConnectProviderList": []},
    ("elbv2", "describe-load-balancers"): {"LoadBalancers": []},
    ("elbv2", "describe-tags"): {"TagDescriptions": []},
    ("ecr", "describe-repositories"): {"repositories": []},
    ("iam", "list-roles"): {"Roles": []},
    ("iam", "list-policies"): {"Policies": []},
    ("s3api", "list-buckets"): {"Buckets": []},
    ("cloudwatch", "list-dashboards"): {"DashboardEntries": []},
    ("logs", "describe-log-groups"): {"logGroups": []},
    ("sts", "get-caller-identity"): {"Account": ACCOUNT, "Arn": f"arn:aws:iam::{ACCOUNT}:user/qualifier"},
    ("route53", "list-hosted-zones"): {"HostedZones": [{"Name": "qual-aws.sol-fab.dev.", "Id": "/hostedzone/Z1"}]},
}


class FakeAws:
    """A provider runner keyed by the read's (service, subcommand)."""

    def __init__(self) -> None:
        self.responses = dict(EMPTY_RESPONSES)
        self.returncodes: dict[tuple[str, str], int] = {}
        self.timeouts: set[tuple[str, str]] = set()
        self.calls: list[list[str]] = []

    def set(self, key: tuple[str, str], value: object) -> None:
        self.responses[key] = value

    def fail(self, key: tuple[str, str], returncode: int = 255) -> None:
        self.returncodes[key] = returncode

    def hang(self, key: tuple[str, str]) -> None:
        self.timeouts.add(key)

    def __call__(self, argv: list[str]) -> absence.ReadResult:
        self.calls.append(list(argv))
        key = (argv[0], argv[1]) if len(argv) > 1 else (argv[0], "")
        if key in self.timeouts:
            return absence.ReadResult(argv, 124, "", "timed out", timed_out=True)
        code = self.returncodes.get(key, 0)
        if code != 0:
            return absence.ReadResult(argv, code, "", "stub provider failure")
        if key == ("secretsmanager", "describe-secret") and key not in self.responses:
            return absence.ReadResult(argv, 255, "", "An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: Secrets Manager can't find the specified secret.")
        value = self.responses.get(key, {})
        text = value if isinstance(value, str) else json.dumps(value)
        return absence.ReadResult(argv, 0, text, "")


failures: list[str] = []
checks = 0


def check(description: str, condition: bool) -> None:
    global checks
    checks += 1
    if condition:
        print(f"  ok   {description}")
    else:
        print(f"  FAIL {description}")
        failures.append(description)


def states(report: absence.Report) -> dict[str, str]:
    return {o.resource_class: o.state for o in report.observations}


def main() -> int:  # noqa: C901 - one linear suite reads better than nested fixtures
    print("absence: the declared class set matches the checks")
    runner = FakeAws()
    report = absence.evaluate(RUNTIME, runner)
    check("every declared residue class is observed", sorted(states(report)) == sorted(absence.RESIDUE_CLASSES))
    check("a clean account passes", report.ok)
    check("every class is ABSENT when nothing is attributable", set(states(report).values()) == {absence.ABSENT})

    print("absence: Kafka authority cannot escape the independent verdict")
    key = ("secretsmanager", "describe-secret")
    for label, value in [
        ("pending deletion", {"Name": "sol-kafka-" + CLUSTER, "DeletedDate": 1700000000}),
        ("scheduled date already passed", {"Name": "sol-kafka-" + CLUSTER, "DeletedDate": 1}),
    ]:
        fake = FakeAws()
        fake.set(key, value)
        evidence = absence.evaluate(RUNTIME, fake)
        check(label + " is present, never absence", not evidence.ok and states(evidence)["kafka-secret"] == absence.PRESENT)
    for label, value in [("malformed", "not json"), ("missing identity", {}),
                         ("wrong identity", {"Name": "another-secret"}),
                         ("bad deletion marker", {"Name": "sol-kafka-" + CLUSTER, "DeletedDate": []})]:
        fake = FakeAws()
        fake.set(key, value)
        evidence = absence.evaluate(RUNTIME, fake)
        check(label + " is unknown", not evidence.ok and states(evidence)["kafka-secret"] == absence.UNKNOWN)
    for failure in ("fail", "hang"):
        fake = FakeAws()
        getattr(fake, failure)(key)
        evidence = absence.evaluate(RUNTIME, fake)
        check(failure + " cannot prove secret absence", not evidence.ok and states(evidence)["kafka-secret"] == absence.UNKNOWN)
    def denied_with_notfound(argv):
        if argv[:2] == list(key):
            return absence.ReadResult(argv, 255, "", "AccessDenied: An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: denied")
        return FakeAws()(argv)
    check("a denied read mentioning not-found is still unknown",
          states(absence.evaluate(RUNTIME, denied_with_notfound))["kafka-secret"] == absence.UNKNOWN)
    original_checks = absence.RESIDUE_CHECKS
    try:
        absence.RESIDUE_CHECKS = [probe for probe in original_checks if probe != absence.check_kafka_secret]
        evidence = absence.evaluate(RUNTIME, FakeAws())
        check("omitting the Kafka probe fails the actual verdict", not evidence.ok and states(evidence)["kafka-secret"] == absence.UNKNOWN)
    finally:
        absence.RESIDUE_CHECKS = original_checks

    print("absence: independently captured identities survive tag and cluster loss")
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "identities.json")
        runner = FakeAws()
        runner.set(("eks", "list-clusters"), {"clusters": [CLUSTER]})
        runner.set(("eks", "describe-cluster"), {"cluster": {
            "name": CLUSTER, "arn": f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/{CLUSTER}",
            "identity": {"oidc": {"issuer": f"https://oidc.eks.{REGION}.amazonaws.com/id/TEST"}}}})
        runner.set(("ec2", "describe-volumes"), {"Volumes": [{"VolumeId": "vol-historical", "Tags": [CLUSTER_TAG]}]})
        runner.set(("ec2", "describe-security-groups"), {"SecurityGroups": [{"GroupId": "sg-historical", "Tags": [CLUSTER_TAG]}]})
        runner.set(("ec2", "describe-addresses"), {"Addresses": [{"AllocationId": "eipalloc-historical", "Tags": [CLUSTER_TAG]}]})
        runner.set(("elbv2", "describe-load-balancers"), {"LoadBalancers": [{"LoadBalancerArn": "arn:historical", "LoadBalancerName": "opaque"}]})
        runner.set(("elbv2", "describe-tags"), {"TagDescriptions": [{"ResourceArn": "arn:historical", "Tags": [CLUSTER_TAG]}]})
        absence.capture(replace(RUNTIME, prior=None), runner, path)
        captured = absence.load_prior(path, RUNTIME)
        runner.set(("eks", "list-clusters"), {"clusters": []})
        runner.set(("ec2", "describe-volumes"), {"Volumes": [{"VolumeId": "vol-historical", "Tags": []}, {"VolumeId": "vol-unrelated", "Tags": []}]})
        runner.set(("ec2", "describe-security-groups"), {"SecurityGroups": [{"GroupId": "sg-historical", "Tags": []}]})
        oidc = captured["resources"]["oidc-provider"][0]
        runner.set(("iam", "list-open-id-connect-providers"), {"OpenIDConnectProviderList": [{"Arn": oidc}]})
        runner.set(("ec2", "describe-addresses"), {"Addresses": [{"AllocationId": "eipalloc-historical", "Tags": []}]})
        runner.set(("elbv2", "describe-tags"), {"TagDescriptions": []})
        historical = replace(RUNTIME, prior=captured)
        report = absence.evaluate(historical, runner)
        for name in absence.CONTINUITY_CLASSES:
            check(f"{name}: identity loss cannot become absence", states(report)[name] == absence.PRESENT)
        check("historical residue fails the complete independent verdict", not report.ok)
        absence.capture(historical, runner, path)
        check("retry preserves original identities after tags disappear", absence.load_prior(path, RUNTIME)["resources"] == captured["resources"])
        runner = FakeAws()
        check("actual provider deletion establishes absence", absence.evaluate(historical, runner).ok)
        runner.set(("ec2", "describe-volumes"), {"Volumes": [{"VolumeId": "vol-unrelated", "Tags": []}]})
        check("an unrelated untagged disk remains outside ownership", absence.evaluate(historical, runner).ok)
        for name in ("account", "region", "cluster", "attempt", "target", "state_key", "candidate"):
            value = None if name == "candidate" else "other"
            try:
                absence.load_prior(path, replace(RUNTIME, **{name: value}))
                rejected = False
            except ValueError:
                rejected = True
            check(f"capture from another {name} is rejected", rejected)
        for key in (("ec2", "describe-volumes"), ("ec2", "describe-security-groups"), ("iam", "list-open-id-connect-providers")):
            broken = FakeAws()
            broken.fail(key)
            try:
                absence.capture(historical, broken, path)
                rejected = False
            except ValueError:
                rejected = True
            check(f"failed capture {key} refuses and preserves evidence", rejected and absence.load_prior(path, RUNTIME)["resources"] == captured["resources"])
        check("no historical capture never produces a clean verdict", not absence.evaluate(replace(RUNTIME, prior=None), FakeAws()).ok)

    runner = FakeAws()
    runner.set(("ec2", "describe-security-groups"), {"SecurityGroups": [
        {"GroupId": "sg-unrelated", "GroupName": CLUSTER + "-rds-other"}]})
    check("an unrelated RDS name prefix is not ownership", absence.evaluate(RUNTIME, runner).ok)

    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "initial.json")
        runner = FakeAws()
        runner.set(("iam", "list-open-id-connect-providers"), {"OpenIDConnectProviderList": [{"Arn": "arn:unrelated"}]})
        absence.capture(replace(RUNTIME, prior=None), runner, path, initial=True)
        initial = absence.load_prior(path, RUNTIME)
        check("fresh target can capture before its issuer exists in a shared account", initial["resources"]["oidc-provider"] == [])
        check("initial capture never certifies unattributable OIDC absence", not absence.evaluate(replace(RUNTIME, prior=initial), runner).ok)

    print("absence: each required class participates in the verdict")
    for resource_class, (key, value) in PRESENT_FIXTURES.items():
        runner = FakeAws()
        runner.set(key, value)
        if resource_class == "load-balancer":
            runner.set(
                ("elbv2", "describe-tags"),
                {"TagDescriptions": [{"ResourceArn": "arn:aws:elbv2:::loadbalancer/app/k8s-residue", "Tags": [CLUSTER_TAG]}]},
            )
        report = absence.evaluate(RUNTIME, runner)
        result = states(report)
        check(f"{resource_class}: a target resource reads PRESENT", result[resource_class] == absence.PRESENT)
        check(f"{resource_class}: only that class fails", report.failed and all(o.resource_class == resource_class for o in report.failed))
        check(f"{resource_class}: the failure is reported as residue", report.failed[0].state == absence.PRESENT and bool(report.failed[0].detail))

    print("absence: unrelated account resources are not the target's residue")
    runner = FakeAws()
    runner.set(
        ("ec2", "describe-instances"),
        {
            "Reservations": [
                {
                    "Instances": [
                        {
                            "InstanceId": "i-other",
                            "State": {"Name": "running"},
                            "Tags": [{"Key": "kubernetes.io/cluster/another-cluster", "Value": "owned"}],
                        }
                    ]
                }
            ]
        },
    )
    runner.set(("ec2", "describe-vpcs"), {"Vpcs": [{"VpcId": "vpc-other", "Tags": [{"Key": "Name", "Value": "another-cluster"}]}]})
    runner.set(("rds", "describe-db-instances"), {"DBInstances": [{"DBInstanceIdentifier": "another-cluster-postgres"}]})
    runner.set(("ecr", "describe-repositories"), {"repositories": [{"repositoryName": "otherservice/api"}]})
    runner.set(("logs", "describe-log-groups"), {"logGroups": [{"logGroupName": "/aws/eks/another-cluster/cluster"}]})
    report = absence.evaluate(RUNTIME, runner)
    result = states(report)
    check("an unrelated cluster's instance is not residue", result["ec2-instance"] == absence.ABSENT)
    check("a similarly named VPC is not matched by substring", result["vpc"] == absence.ABSENT)
    check("another cluster's database is not residue", result["rds-instance"] == absence.ABSENT)
    check("another registry path is not residue", result["ecr-repository"] == absence.ABSENT)
    check("another cluster's log group is not residue", result["cloudwatch-log-group"] == absence.ABSENT)
    check("the clean run still passes", report.ok)

    print("absence: terminal records are not live residue")
    runner = FakeAws()
    runner.set(
        ("ec2", "describe-instances"),
        {"Reservations": [{"Instances": [{"InstanceId": "i-dead", "State": {"Name": "terminated"}, "Tags": [CLUSTER_TAG]}]}]},
    )
    runner.set(("ec2", "describe-nat-gateways"), {"NatGateways": [{"NatGatewayId": "nat-dead", "State": "deleted", "Tags": [CLUSTER_TAG]}]})
    report = absence.evaluate(RUNTIME, runner)
    result = states(report)
    check("a terminated instance reads ABSENT", result["ec2-instance"] == absence.ABSENT)
    check("a deleted NAT gateway reads ABSENT", result["nat-gateway"] == absence.ABSENT)
    check("terminal records do not fail the verdict", report.ok)

    print("absence: a failed, hanging, malformed or wrong-shaped read is UNKNOWN, never absence")
    for label, configure in (
        ("a provider failure", lambda r: r.fail(("ec2", "describe-volumes"))),
        ("a hanging read", lambda r: r.hang(("ec2", "describe-volumes"))),
        ("a non-JSON response", lambda r: r.set(("ec2", "describe-volumes"), "not json at all")),
        ("a wrong-shaped response", lambda r: r.set(("ec2", "describe-volumes"), {"Volumes": {}})),
        ("a response missing its key", lambda r: r.set(("ec2", "describe-volumes"), {"unexpected": []})),
    ):
        runner = FakeAws()
        configure(runner)
        report = absence.evaluate(RUNTIME, runner)
        result = states(report)
        check(f"{label}: ebs-volume reads UNKNOWN", result["ebs-volume"] == absence.UNKNOWN)
        check(f"{label}: UNKNOWN is not absence", result["ebs-volume"] != absence.ABSENT)
        check(f"{label}: the verdict fails", not report.ok)

    print("absence: the account identity is a prerequisite for attribution")
    runner = FakeAws()
    runner.set(("sts", "get-caller-identity"), {"Account": "111122223333", "Arn": "arn:aws:iam::111122223333:user/other"})
    report = absence.evaluate(RUNTIME, runner)
    check("a foreign account is refused", not report.identity.ok)
    check("and every class is UNKNOWN rather than absent", set(states(report).values()) == {absence.UNKNOWN})
    check("so the verdict fails", not report.ok)

    runner = FakeAws()
    runner.fail(("sts", "get-caller-identity"))
    report = absence.evaluate(RUNTIME, runner)
    check("an unreadable identity fails closed", not report.identity.ok and not report.ok)

    print("absence: durable prerequisites are distinct from residue")
    runner = FakeAws()
    report = absence.evaluate(RUNTIME, runner)
    check("a present durable zone is recorded", report.durable and report.durable[0].state == absence.PRESENT)
    check("and does not fail the residue verdict", report.ok)
    runner = FakeAws()
    runner.set(("route53", "list-hosted-zones"), {"HostedZones": []})
    report = absence.evaluate(RUNTIME, runner)
    check("an absent durable zone is still reported", report.durable and report.durable[0].state == absence.ABSENT)
    check("and is not treated as residue", report.ok)

    print("absence: declared retention is excluded from residue")
    runner = FakeAws()
    runner.set(("rds", "describe-db-snapshots"), {"DBSnapshots": [{"DBSnapshotIdentifier": f"{CLUSTER}-postgres-final"}]})
    retaining = absence.Runtime(
        cluster=CLUSTER, region=REGION, account=ACCOUNT, registry_prefix="pluto", retention="final-snapshot", prior=RUNTIME.prior
    )
    report = absence.evaluate(retaining, runner)
    check("a declared final snapshot is not residue", states(report)["rds-snapshot"] == absence.ABSENT)
    check("and the run can still pass", report.ok)

    print("absence: reads arrive as argv vectors, not shell strings")
    runner = FakeAws()
    absence.evaluate(RUNTIME, runner)
    check(
        "every regional read passes the region as its own argv word",
        all(call[i + 1] == REGION for call in runner.calls for i, word in enumerate(call[:-1]) if word == "--region"),
    )
    check("no call smuggles a shell metacharacter", all(all(";" not in word and "|" not in word for word in call) for call in runner.calls))
    check("every call starts with the provider program", all(call[0] in {"eks", "rds", "ec2", "elbv2", "ecr", "iam", "s3api", "cloudwatch", "logs", "sts", "route53", "secretsmanager"} for call in runner.calls))

    print("absence: the evidence bundle is complete")
    with tempfile.TemporaryDirectory() as scratch:
        absence.collect(RUNTIME, FakeAws(), scratch)
        inventory = pathlib.Path(scratch, "aws-inventory.txt").read_text()
        verdict = pathlib.Path(scratch, "aws-inventory-verdict.txt").read_text()
        document = json.loads(pathlib.Path(scratch, "aws-inventory-verdict.json").read_text())
        check("the inventory carries the run identity", "attempt=attempt-1" in inventory and "state_key=" in inventory)
        check("the inventory retains the raw provider output", '"clusters"' in inventory)
        check("the verdict names every class", all(name in verdict for name in absence.RESIDUE_CLASSES))
        check("the verdict states absence", "verdict: ABSENT" in verdict)
        check("the inventory states its attribution limitations", "limitations:" in inventory and "attribution is by the target's declared identities" in inventory)
        check("the structured verdict names its schema and provider", document["schema"] == 1 and document["provider"] == "aws")
        check("the structured verdict names the release teardown policy", document["policy"] == absence.POLICY_NAME)
        check("the structured verdict names the candidate it was observed for", document["candidate"] == CANDIDATE)
        check("the structured verdict binds the attempt and target", document["attempt"] == "attempt-1" and document["target"] == "qualreg/aws/us-east-1")
        check("the structured verdict records the provider scope", document["scope"]["cluster"] == CLUSTER and document["scope"]["region"] == REGION and document["scope"]["account"] == ACCOUNT)
        check("the structured verdict declares the required class universe", document["required_classes"] == absence.RESIDUE_CLASSES + ["durable-hosted-zone"])
        check("the structured verdict carries the same disposable classes", [c["class"] for c in document["classes"] if c["expectation"] == "absent"] == absence.RESIDUE_CLASSES)
        check("every disposable class expects absence", all(c["state"] == "ABSENT" for c in document["classes"] if c["expectation"] == "absent"))
        check("the durable prerequisite expects presence", [c for c in document["classes"] if c["expectation"] == "present"][0]["state"] == "PRESENT")
        check("the structured verdict states absence", document["verdict"] == "ABSENT")

    print("absence: the command runs end to end against a stub provider")
    with tempfile.TemporaryDirectory() as scratch:
        directory = pathlib.Path(scratch)
        stub = directory / "aws"
        empty = {
            "eks list-clusters": {"clusters": []},
            "rds describe-db-instances": {"DBInstances": []},
            "rds describe-db-subnet-groups": {"DBSubnetGroups": []},
            "rds describe-db-snapshots": {"DBSnapshots": []},
            "ec2 describe-instances": {"Reservations": []},
            "ec2 describe-vpcs": {"Vpcs": []},
            "ec2 describe-nat-gateways": {"NatGateways": []},
            "ec2 describe-addresses": {"Addresses": []},
            "ec2 describe-volumes": {"Volumes": []},
            "ec2 describe-security-groups": {"SecurityGroups": []},
            "iam list-open-id-connect-providers": {"OpenIDConnectProviderList": []},
            "elbv2 describe-load-balancers": {"LoadBalancers": []},
            "ecr describe-repositories": {"repositories": []},
            "iam list-roles": {"Roles": []},
            "iam list-policies": {"Policies": []},
            "s3api list-buckets": {"Buckets": []},
            "cloudwatch list-dashboards": {"DashboardEntries": []},
            "logs describe-log-groups": {"logGroups": []},
            "sts get-caller-identity": {"Account": ACCOUNT, "Arn": f"arn:aws:iam::{ACCOUNT}:user/q"},
            "route53 list-hosted-zones": {"HostedZones": []},
        }
        cases = "\n".join(f'  "{key}") printf \'%s\\n\' \'{json.dumps(value)}\' ;;' for key, value in empty.items())
        stub.write_text(
            "#!/bin/sh\n"
            'case "$1 $2" in\n'
            '  "secretsmanager describe-secret") echo "An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: not found" >&2; exit 255 ;;\n'
            f"{cases}\n"
            "  *) printf '{}\\n' ;;\n"
            "esac\n"
            "exit 0\n"
        )
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        environment = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}", ACCOUNT=ACCOUNT)
        candidate = directory / "candidate.json"
        candidate.write_text(json.dumps(CANDIDATE))
        prior = directory / "prior.json"
        cli_runtime = replace(RUNTIME, attempt="", target="", state_key="", base_domain=None)
        absence.capture(cli_runtime, FakeAws(), str(prior))
        out = directory / "evidence"
        result = subprocess.run(
            [
                sys.executable,
                str(pathlib.Path(__file__).resolve().parent / "absence.py"),
                "collect",
                "--prior",
                str(prior),
                "--dir",
                str(out),
                "--cluster",
                CLUSTER,
                "--region",
                REGION,
                "--account",
                ACCOUNT,
                "--registry-prefix",
                "pluto",
                "--candidate",
                str(candidate),
            ],
            capture_output=True,
            text=True,
            env=environment,
        )
        check("a clean inventory exits 0", result.returncode == 0)
        check("and writes its verdict", (out / "aws-inventory-verdict.txt").is_file())
        document = json.loads((out / "aws-inventory-verdict.json").read_text())
        check(
            "and its structured verdict names the candidate and provider",
            document["candidate"] == CANDIDATE and document["provider"] == "aws",
        )

        stub.write_text(
            "#!/bin/sh\n"
            'case "$1 $2" in\n'
            '  "sts get-caller-identity") printf \'{"Account":"%s","Arn":"arn:aws:iam::%s:user/q"}\\n\' "$ACCOUNT" "$ACCOUNT" ;;\n'
            '  "rds describe-db-instances") printf \'{"DBInstances":[{"DBInstanceIdentifier":"qual-cluster-postgres"}]}\\n\' ;;\n'
            "  *) printf '{}\\n' ;;\n"
            "esac\n"
            "exit 0\n"
        )
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        result = subprocess.run(
            [
                sys.executable,
                str(pathlib.Path(__file__).resolve().parent / "absence.py"),
                "collect",
                "--prior",
                str(prior),
                "--dir",
                str(out),
                "--cluster",
                CLUSTER,
                "--region",
                REGION,
                "--account",
                ACCOUNT,
                "--registry-prefix",
                "pluto",
                "--candidate",
                str(candidate),
            ],
            capture_output=True,
            text=True,
            env=environment,
        )
        check("residue fails the command", result.returncode != 0)
        check("and the failing class is named", "rds-instance: PRESENT" in (out / "aws-inventory-verdict.txt").read_text())
        document = json.loads((out / "aws-inventory-verdict.json").read_text())
        check("and the structured verdict does not claim absence", document["verdict"] == "NOT ABSENT")
        check(
            "and the failing class is PRESENT in the structured verdict",
            [c["state"] for c in document["classes"] if c["class"] == "rds-instance"] == ["PRESENT"],
        )

        bad_candidate = directory / "bad-candidate.json"
        bad_candidate.write_text(json.dumps({"version": "v0.1.0-alpha.9"}))
        result = subprocess.run(
            [
                sys.executable,
                str(pathlib.Path(__file__).resolve().parent / "absence.py"),
                "collect",
                "--prior",
                str(prior),
                "--dir",
                str(directory / "bad-evidence"),
                "--cluster",
                CLUSTER,
                "--region",
                REGION,
                "--account",
                ACCOUNT,
                "--candidate",
                str(bad_candidate),
            ],
            capture_output=True,
            text=True,
            env=environment,
        )
        check("a candidate without the full identity fails closed", result.returncode == 2)
        check("and the error names the missing identity", "candidate document has no" in result.stderr)

    print(f"\n{checks - len(failures)} passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
