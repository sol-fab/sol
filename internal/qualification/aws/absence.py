#!/usr/bin/env python3
"""Independent, read-only AWS residue observation for a qualification target.

The AWS row harness destroys a target through Sol's public lifecycle
(``sol destroy <target> --apply``) and must then decide, independently of
Sol, whether the target's disposable resources are actually gone. Sol's destroy
exit code, its Terraform state and Sol's own absence report are not that
decision; this module makes the decision from provider reads alone.

Every required disposable class gets provider reads, expected JSON shapes and an
attribution predicate that says which returned resources belong to *this*
target (its cluster tag, its cluster-name prefix, or its registry path). A
class is:

  * ABSENT  -- the read succeeded, its shape was the expected one, and no live
               resource in the class is attributable to the target;
  * PRESENT -- the read succeeded and at least one attributable resource is
               live residue;
  * UNKNOWN -- the read failed, timed out, returned something that was not JSON,
               did not have the expected shape, or could not be attributed to
               the target.

UNKNOWN is never absence. A required class that is UNKNOWN or PRESENT fails the
verdict, so an unreadable provider response cannot be read as a clean teardown.

The reads enumerate a whole class in the region and filter in this process,
rather than trusting a server-side tag filter: an empty tag search is not proof
of absence when the query itself might be wrong. Attribution then has to hold
after the target has disappeared, so it is derived from the target's declared
identities (``kubernetes.io/cluster/<cluster>`` tags, the cluster-name prefix in
resource names, the target's registry path) or the provider identities independently
captured while those ownership facts hold.

Durable prerequisites and explicitly retained resources are observed
separately and are excluded from the residue verdict: a delegation zone or a
state bucket outliving the target is the contract, not residue.

Usage:
    absence.py collect --dir D --cluster C --region R --account A
                       [--registry-prefix P] [--base-domain B]
                       [--retention none|final-snapshot]
                       [--attempt A] [--target T] [--state-key K]
                       [--candidate FILE] --prior FILE
                       [--bound 30] [--aws-command aws]

The structured verdict (``aws-inventory-verdict.json``) names the candidate it
was observed for when ``--candidate`` is supplied. Release promotion accepts
only a document that names the candidate, provider, attempt and target it is
attached to; a document without that binding is diagnostic evidence, not
promotion-eligible teardown evidence.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field, replace
from typing import Any, Callable, Sequence

PRESENT = "PRESENT"
ABSENT = "ABSENT"
UNKNOWN = "UNKNOWN"

# Every class the independent verdict decides. Kept explicit so a reviewer can
# read the coverage off the module rather than infer it from the probes, and so
# the harness test can pin it.
RESIDUE_CLASSES = [
    "eks-cluster",
    "rds-instance",
    "rds-subnet-group",
    "rds-snapshot",
    "ec2-instance",
    "vpc",
    "nat-gateway",
    "elastic-ip",
    "ebs-volume",
    "oidc-provider",
    "security-group",
    "load-balancer",
    "ecr-repository",
    "iam-role",
    "iam-policy",
    "s3-bucket",
    "cloudwatch-dashboard",
    "cloudwatch-log-group",
]

CLUSTER_TAG_PREFIX = "kubernetes.io/cluster/"

# What this verdict does and does not establish. Recorded in the inventory so a
# reader does not have to infer it from the probes.
LIMITATIONS = [
    "attribution is by the target's declared identities: the "
    f"{CLUSTER_TAG_PREFIX}<cluster> tag, the cluster name as a name component, or the target's "
    "registry path. Independently captured EBS, EIP, load-balancer and security-group identities and the EKS issuer "
    "are retained in this attempt's evidence across teardown; loss of tags does not erase ownership.",
    "the verdict is read-only. Teardown itself is Sol's `sol destroy <target> --apply`; "
    "this observer never mutates the provider and never infers absence from Sol's exit code or "
    "Terraform state.",
    "sub-resources whose lifecycle is owned by a checked parent (for example EKS node groups "
    "inside the checked cluster) are covered by the parent's absence.",
]


IDENTITY_FIELDS = ("version", "revision", "bundle_sha256", "runner_image")
REVISION = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
RUNNER_DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")

# The release teardown policy this document is eligible under. The promotion
# gate loads `internal/tooling/release/teardown-policy.v1.json`; a document
# naming another policy is not promotion-eligible. Keep this value in sync with
# that file; `internal/ci/test_teardown_policy.py` guards the class universe.
POLICY_NAME = "sol-teardown-v1"


@dataclass(frozen=True)
class Runtime:
    cluster: str
    region: str
    account: str
    registry_prefix: str | None = None
    base_domain: str | None = None
    retention: str = "none"
    attempt: str = ""
    target: str = ""
    state_key: str = ""
    candidate: dict[str, str] | None = None
    prior: dict[str, Any] | None = None
    prior_error: str = ""


def load_candidate(path: str) -> dict[str, str]:
    """Read the four-field candidate identity the run is qualifying.

    The fields are the identity `promotion.py` compares. A document that cannot
    name all four is not promotion-eligible evidence, so this fails closed
    rather than writing a partially bound verdict.
    """
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: the candidate document is not a JSON object")
    candidate: dict[str, str] = {}
    for field in IDENTITY_FIELDS:
        value = data.get(field)
        if not isinstance(value, str) or value == "":
            raise ValueError(f"{path}: the candidate document has no {field!r}")
        candidate[field] = value
    if not REVISION.fullmatch(candidate["revision"]):
        raise ValueError(f"{path}: revision {candidate['revision']!r} is not a 40-hex commit")
    if not HEX64.fullmatch(candidate["bundle_sha256"]):
        raise ValueError(f"{path}: bundle_sha256 is not a 64-hex digest")
    if not RUNNER_DIGEST.search(candidate["runner_image"]):
        raise ValueError(f"{path}: runner_image is not an <image>@sha256:<64 hex> reference")
    return candidate


@dataclass
class ReadResult:
    argv: list[str]
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool = False


@dataclass
class Observation:
    resource_class: str
    state: str
    identity: str
    attribution: str
    detail: str
    queries: list[list[str]] = field(default_factory=list)
    raw: list[str] = field(default_factory=list)
    resources: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.state == ABSENT


@dataclass
class Identity:
    ok: bool
    account: str
    arn: str
    detail: str
    queries: list[list[str]] = field(default_factory=list)
    raw: list[str] = field(default_factory=list)


@dataclass
class Report:
    identity: Identity
    observations: list[Observation]
    durable: list[Observation] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.identity.ok and all(o.ok for o in self.observations)

    @property
    def failed(self) -> list[Observation]:
        return [o for o in self.observations if not o.ok]


class ShapeError(Exception):
    """A provider response that was JSON but not the shape the class requires."""


def require(condition: Any, message: str) -> None:
    if not condition:
        raise ShapeError(message)


class Reads:
    """One observation's reads: bounded, accounted for, and kept as evidence."""

    def __init__(self, runner: "Runner") -> None:
        self.runner = runner
        self.queries: list[list[str]] = []
        self.raw: list[str] = []

    def json(self, argv: Sequence[str]) -> tuple[Any | None, str]:
        argv = list(argv)
        self.queries.append(argv)
        label = " ".join(argv)
        result = self.runner(argv)
        if result.timed_out:
            self.raw.append(f"$ {label}\n[timed out after the phase bound]")
            return None, f"the read timed out: {label}"
        if result.returncode != 0:
            self.raw.append(f"$ {label}\n[exit {result.returncode}]\n{result.stderr.strip()}")
            return None, f"the read failed (exit {result.returncode}): {label}"
        try:
            parsed = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.raw.append(f"$ {label}\n[output is not JSON]\n{result.stdout[:2000]}")
            return None, f"the read did not return JSON: {label}"
        self.raw.append(f"$ {label}\n{result.stdout.strip()}")
        return parsed, ""

    def stream(self, argv: Sequence[str]) -> tuple[str | None, str]:
        argv = list(argv)
        self.queries.append(argv)
        label = " ".join(argv)
        result = self.runner(argv)
        if result.timed_out:
            self.raw.append(f"$ {label}\n[timed out after the phase bound]")
            return None, f"the read timed out: {label}"
        if result.returncode != 0:
            self.raw.append(f"$ {label}\n[exit {result.returncode}]\n{result.stderr.strip()}")
            return None, f"the read failed (exit {result.returncode}): {label}"
        self.raw.append(f"$ {label}\n{result.stdout.strip()}")
        return result.stdout, ""


Runner = Callable[[list[str]], ReadResult]


def subprocess_runner(bound: float, program: str = "aws") -> Runner:
    def run(argv: list[str]) -> ReadResult:
        command = [program, *argv]
        started = time.monotonic()
        try:
            completed = subprocess.run(command, capture_output=True, text=True, timeout=bound)
        except subprocess.TimeoutExpired as expired:
            partial = expired.stdout or ""
            if isinstance(partial, bytes):  # pragma: no cover - text=True keeps it a str
                partial = partial.decode("utf-8", "replace")
            return ReadResult(argv, 124, partial, f"timed out after {bound:g}s", timed_out=True)
        except OSError as error:
            return ReadResult(argv, 127, "", f"could not run {program}: {error}")
        return ReadResult(argv, completed.returncode, completed.stdout, completed.stderr)

    return run


# --------------------------------------------------------------------------
# attribution helpers
# --------------------------------------------------------------------------


def tag_map(resource: Any) -> dict[str, str]:
    """A resource's Tags as a plain dict; {} when the shape is unusable."""
    if not isinstance(resource, dict):
        return {}
    tags = resource.get("Tags")
    if not isinstance(tags, list):
        return {}
    found: dict[str, str] = {}
    for tag in tags:
        if isinstance(tag, dict) and isinstance(tag.get("Key"), str):
            value = tag.get("Value")
            found[tag["Key"]] = value if isinstance(value, str) else ""
    return found


def mentions(value: str, cluster: str) -> bool:
    """True when a resource name carries the cluster name as a name component.

    ``mycluster`` must not be matched by a query for ``cluster``; a shared
    substring is not containment evidence.
    """
    if not value or not cluster:
        return False
    return re.search(rf"(^|[^A-Za-z0-9]){re.escape(cluster)}([^A-Za-z0-9]|$)", value) is not None


def cluster_owned(resource: Any, runtime: Runtime) -> bool:
    """The target's cluster tag, or a resource name that names its cluster."""
    tags = tag_map(resource)
    key = CLUSTER_TAG_PREFIX + runtime.cluster
    if key in tags and tags[key] in ("", "owned", "shared"):
        return True
    return mentions(tags.get("Name", ""), runtime.cluster)


def unknown(resource_class: str, identity: str, attribution: str, detail: str, reads: Reads) -> Observation:
    return Observation(resource_class, UNKNOWN, identity, attribution, detail, reads.queries, reads.raw)


def observation(
    resource_class: str, found: list[str], identity: str, attribution: str, reads: Reads
) -> Observation:
    if found:
        return Observation(
            resource_class,
            PRESENT,
            identity,
            attribution,
            f"{len(found)} live resource(s) attributable to this target: {', '.join(found[:8])}",
            reads.queries,
            reads.raw,
            resources=found,
        )
    return Observation(
        resource_class,
        ABSENT,
        identity,
        attribution,
        "the read succeeded, its shape held, and no live resource is attributable to this target",
        reads.queries,
        reads.raw,
    )


def as_list(parsed: Any, key: str) -> list[Any]:
    require(isinstance(parsed, dict), "the response is not a JSON object")
    items = parsed.get(key)
    require(isinstance(items, list), f'the response has no "{key}" list')
    return items  # type: ignore[return-value]


def require_str(obj: Any, key: str, where: str) -> str:
    require(isinstance(obj, dict), f"{where} is not a JSON object")
    value = obj.get(key)
    require(isinstance(value, str) and value != "", f'{where} has no "{key}" string')
    return value


# --------------------------------------------------------------------------
# residue checks
# --------------------------------------------------------------------------


def check_eks_cluster(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    identity = f"cluster named {runtime.cluster}"
    attribution = "an EKS cluster whose name is exactly the target's cluster name"
    argv = ["eks", "list-clusters", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("eks-cluster", identity, attribution, reason, reads)
    try:
        clusters = as_list(parsed, "clusters")
        require(all(isinstance(name, str) for name in clusters), 'a "clusters" entry is not a name')
    except ShapeError as error:
        return unknown("eks-cluster", identity, attribution, str(error), reads)
    found = [name for name in clusters if name == runtime.cluster]
    return observation("eks-cluster", found, identity, attribution, reads)


def check_rds_instance(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    prefix = runtime.cluster + "-"
    identity = f"RDS instance named {prefix}*"
    attribution = "the target's cluster-name prefix on the instance identifier"
    argv = ["rds", "describe-db-instances", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("rds-instance", identity, attribution, reason, reads)
    try:
        instances = as_list(parsed, "DBInstances")
        names = [require_str(item, "DBInstanceIdentifier", "an RDS instance") for item in instances]
    except ShapeError as error:
        return unknown("rds-instance", identity, attribution, str(error), reads)
    found = [name for name in names if name.startswith(prefix)]
    return observation("rds-instance", found, identity, attribution, reads)


def check_rds_snapshot(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    prefix = runtime.cluster + "-"
    identity = f"RDS snapshot named {prefix}*"
    attribution = "the target's cluster-name prefix on the snapshot identifier"
    argv = ["rds", "describe-db-snapshots", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("rds-snapshot", identity, attribution, reason, reads)
    try:
        snapshots = as_list(parsed, "DBSnapshots")
        names = [require_str(item, "DBSnapshotIdentifier", "an RDS snapshot") for item in snapshots]
    except ShapeError as error:
        return unknown("rds-snapshot", identity, attribution, str(error), reads)
    matched = [name for name in names if name.startswith(prefix)]
    if matched and runtime.retention == "final-snapshot":
        # The target declares a final snapshot as its retention policy: that
        # snapshot is explicitly retained, not residue.
        return Observation(
            "rds-snapshot",
            ABSENT,
            identity,
            attribution,
            "the target declares destroy_retention=final-snapshot; "
            f"retained snapshot(s) excluded from residue: {', '.join(matched[:8])}",
            reads.queries,
            reads.raw,
        )
    return observation("rds-snapshot", matched, identity, attribution, reads)


def check_ec2_instance(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    identity = f"EC2 instances tagged for cluster {runtime.cluster}"
    attribution = f"the target's {CLUSTER_TAG_PREFIX}{runtime.cluster} tag, or a Name naming it"
    argv = ["ec2", "describe-instances", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("ec2-instance", identity, attribution, reason, reads)
    terminal = {"terminated", "shutting-down"}
    found: list[str] = []
    try:
        reservations = as_list(parsed, "Reservations")
        for reservation in reservations:
            instances = as_list(reservation, "Instances")
            for instance in instances:
                if not cluster_owned(instance, runtime):
                    continue
                state = instance.get("State")
                require(isinstance(state, dict), "an EC2 instance has no State object")
                name = state.get("Name")
                require(isinstance(name, str), "an EC2 instance State has no Name")
                if name in terminal:
                    continue
                found.append(require_str(instance, "InstanceId", "an EC2 instance"))
    except ShapeError as error:
        return unknown("ec2-instance", identity, attribution, str(error), reads)
    return observation("ec2-instance", found, identity, attribution, reads)


def check_vpc(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    identity = f"VPCs tagged for cluster {runtime.cluster}"
    attribution = f"the target's {CLUSTER_TAG_PREFIX}{runtime.cluster} tag, or a Name naming it"
    argv = ["ec2", "describe-vpcs", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("vpc", identity, attribution, reason, reads)
    found: list[str] = []
    try:
        vpcs = as_list(parsed, "Vpcs")
        for vpc in vpcs:
            if cluster_owned(vpc, runtime):
                found.append(require_str(vpc, "VpcId", "a VPC"))
    except ShapeError as error:
        return unknown("vpc", identity, attribution, str(error), reads)
    return observation("vpc", found, identity, attribution, reads)


def check_nat_gateway(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    identity = f"NAT gateways tagged for cluster {runtime.cluster}"
    attribution = f"the target's {CLUSTER_TAG_PREFIX}{runtime.cluster} tag, or a Name naming it"
    argv = ["ec2", "describe-nat-gateways", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("nat-gateway", identity, attribution, reason, reads)
    terminal = {"deleted", "deleting", "failed"}
    found: list[str] = []
    try:
        gateways = as_list(parsed, "NatGateways")
        for gateway in gateways:
            if not cluster_owned(gateway, runtime):
                continue
            state = gateway.get("State")
            require(isinstance(state, str), "a NAT gateway has no State string")
            if state in terminal:
                continue
            found.append(require_str(gateway, "NatGatewayId", "a NAT gateway"))
    except ShapeError as error:
        return unknown("nat-gateway", identity, attribution, str(error), reads)
    return observation("nat-gateway", found, identity, attribution, reads)


def check_elastic_ip(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    identity = f"elastic IP allocations independently attributed to cluster {runtime.cluster}"
    attribution = "current target ownership or an independently captured EIP allocation ID"
    argv = ["ec2", "describe-addresses", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("elastic-ip", identity, attribution, reason, reads)
    found: list[str] = []
    try:
        addresses = as_list(parsed, "Addresses")
        for address in addresses:
            allocation = require_str(address, "AllocationId", "an elastic IP")
            if cluster_owned(address, runtime) or allocation in prior_ids(runtime, "elastic-ip"):
                found.append(allocation)
    except ShapeError as error:
        return unknown("elastic-ip", identity, attribution, str(error), reads)
    return observation("elastic-ip", found, identity, attribution, reads)


def check_ebs_volume(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    identity = f"EBS volumes independently attributed to cluster {runtime.cluster}"
    attribution = "current target ownership or an independently captured EBS volume ID"
    argv = ["ec2", "describe-volumes", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("ebs-volume", identity, attribution, reason, reads)
    found: list[str] = []
    try:
        volumes = as_list(parsed, "Volumes")
        for volume in volumes:
            if cluster_owned(volume, runtime) or volume.get("VolumeId") in prior_ids(runtime, "ebs-volume"):
                found.append(require_str(volume, "VolumeId", "an EBS volume"))
    except ShapeError as error:
        return unknown("ebs-volume", identity, attribution, str(error), reads)
    return observation("ebs-volume", found, identity, attribution, reads)


def prior_ids(runtime: Runtime, resource_class: str) -> list[str]:
    return (runtime.prior or {}).get("resources", {}).get(resource_class, [])


def check_security_group(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    identity = f"security groups of cluster {runtime.cluster}"
    attribution = "cluster ownership tags, target RDS name, or independently captured group ID"
    parsed, reason = reads.json(["ec2", "describe-security-groups", "--region", runtime.region, "--output", "json"])
    if parsed is None:
        return unknown("security-group", identity, attribution, reason, reads)
    try:
        found = []
        for group in as_list(parsed, "SecurityGroups"):
            group_id = require_str(group, "GroupId", "a security group")
            tags = tag_map(group)
            if (cluster_owned(group, runtime)
                    or tags.get("aws:eks:cluster-name") == runtime.cluster
                    or group.get("GroupName") == runtime.cluster + "-rds"
                    or group_id in prior_ids(runtime, "security-group")):
                found.append(group_id)
    except (ShapeError, AttributeError) as error:
        return unknown("security-group", identity, attribution, str(error), reads)
    return observation("security-group", found, identity, attribution, reads)


def check_oidc_provider(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    identity = f"IAM OIDC provider for cluster {runtime.cluster}"
    attribution = "exact EKS issuer captured independently before cluster destruction"
    parsed, reason = reads.json(["iam", "list-open-id-connect-providers", "--output", "json"])
    if parsed is None:
        return unknown("oidc-provider", identity, attribution, reason, reads)
    try:
        arns = [require_str(item, "Arn", "an OIDC provider")
                for item in as_list(parsed, "OpenIDConnectProviderList")]
        issuers = prior_ids(runtime, "oidc-provider")
        if arns and not issuers:
            return unknown("oidc-provider", identity, attribution,
                           "no independently captured EKS issuer; surviving providers cannot be attributed", reads)
        found = [arn for arn in arns if arn in issuers]
    except ShapeError as error:
        return unknown("oidc-provider", identity, attribution, str(error), reads)
    return observation("oidc-provider", found, identity, attribution, reads)


CONTINUITY_CLASSES = ("ebs-volume", "security-group", "oidc-provider", "elastic-ip", "load-balancer")


def capture_scope(runtime: Runtime) -> dict[str, Any]:
    return {name: getattr(runtime, name) for name in
            ("cluster", "region", "account", "attempt", "target", "state_key", "candidate")}


def load_prior(path: str, runtime: Runtime) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
    if (not isinstance(document, dict) or document.get("schema") != 1
            or document.get("scope") != capture_scope(runtime)):
        raise ValueError("independent identity capture does not match this attempt, target, account, region and candidate")
    resources = document.get("resources")
    if not isinstance(resources, dict) or set(resources) != set(CONTINUITY_CLASSES):
        raise ValueError("independent identity capture omits a required resource class")
    for values in resources.values():
        if not isinstance(values, list) or not all(isinstance(v, str) and v for v in values):
            raise ValueError("independent identity capture contains invalid resource identities")
    return document


def capture(runtime: Runtime, runner: Runner, path: str, *, initial: bool = False) -> None:
    """Read before mutation; append identities to existing attempt evidence on retries."""
    if os.path.exists(path):
        runtime = replace(runtime, prior=load_prior(path, runtime))
    identity = observe_identity(runner, runtime)
    if not identity.ok:
        raise ValueError(identity.detail + "\n" + "\n".join(identity.raw))
    reads = Reads(runner)
    # Read the cluster list first: only an exact absent name permits skipping describe.
    parsed, reason = reads.json(["eks", "list-clusters", "--region", runtime.region, "--output", "json"])
    if parsed is None:
        raise ValueError(reason + "\n" + "\n".join(reads.raw))
    clusters = as_list(parsed, "clusters")
    require(all(isinstance(v, str) for v in clusters), "invalid EKS cluster list")
    issuers = prior_ids(runtime, "oidc-provider")[:]
    if runtime.cluster in clusters:
        parsed, reason = reads.json(["eks", "describe-cluster", "--name", runtime.cluster,
                                    "--region", runtime.region, "--output", "json"])
        if parsed is None:
            raise ValueError(reason + "\n" + "\n".join(reads.raw))
        require(isinstance(parsed, dict) and isinstance(parsed.get("cluster"), dict), "missing EKS cluster")
        cluster = parsed["cluster"]
        require(cluster.get("name") == runtime.cluster, "EKS returned another cluster")
        expected_arn = f"arn:aws:eks:{runtime.region}:{runtime.account}:cluster/{runtime.cluster}"
        require(cluster.get("arn") == expected_arn, "EKS cluster ARN does not match the target scope")
        identity_data = cluster.get("identity", {})
        require(isinstance(identity_data, dict) and isinstance(identity_data.get("oidc"), dict), "missing EKS OIDC identity")
        issuer = require_str(identity_data["oidc"], "issuer", "the EKS OIDC identity")
        require(re.fullmatch(r"https://oidc\.eks\." + re.escape(runtime.region) + r"\.amazonaws\.com/id/[A-Za-z0-9]+", issuer),
                "EKS issuer is not in the target region")
        issuers.append(f"arn:aws:iam::{runtime.account}:oidc-provider/{issuer.removeprefix('https://')}")
    resources = {"oidc-provider": sorted(set(issuers))}
    runtime = replace(runtime, prior={"resources": {**(runtime.prior or {}).get("resources", {}), **resources}})
    capture_reads = [{"queries": reads.queries, "raw": reads.raw}]
    checks = [check_ebs_volume, check_security_group, check_elastic_ip, check_load_balancer]
    # Before provisioning there may be no EKS issuer to capture. Record that fact,
    # without claiming OIDC absence or excluding unrelated account providers.
    # Strict recapture before teardown and final verification still require attribution.
    if not initial or issuers:
        checks.append(check_oidc_provider)
    for check in checks:
        result = check(runner, runtime)
        if result.state == UNKNOWN:
            raise ValueError(f"{result.resource_class}: {result.detail}\n" + "\n".join(result.raw))
        resources[result.resource_class] = sorted(set(prior_ids(runtime, result.resource_class) + result.resources))
        capture_reads.append({"queries": result.queries, "raw": result.raw})
    document = {"schema": 1, "scope": capture_scope(runtime), "resources": resources,
                "reads": (runtime.prior or {}).get("reads", []) + capture_reads}
    # Replace only after every required read succeeds; a failed recapture cannot erase evidence.
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)


def check_load_balancer(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    identity = f"load balancers independently attributed to cluster {runtime.cluster}"
    attribution = "current target ownership or an independently captured load-balancer ARN"
    argv = ["elbv2", "describe-load-balancers", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("load-balancer", identity, attribution, reason, reads)
    found: list[str] = []
    try:
        balancers = as_list(parsed, "LoadBalancers")
        for balancer in balancers:
            arn = require_str(balancer, "LoadBalancerArn", "a load balancer")
            name = balancer.get("LoadBalancerName")
            tagged = arn in prior_ids(runtime, "load-balancer")
            if isinstance(name, str) and mentions(name, runtime.cluster):
                tagged = True
            elif not tagged:
                tags_argv = [
                    "elbv2",
                    "describe-tags",
                    "--region",
                    runtime.region,
                    "--resource-arns",
                    arn,
                    "--output",
                    "json",
                ]
                tags_parsed, tags_reason = reads.json(tags_argv)
                if tags_parsed is None:
                    return unknown("load-balancer", identity, attribution, tags_reason, reads)
                descriptions = as_list(tags_parsed, "TagDescriptions")
                key = CLUSTER_TAG_PREFIX + runtime.cluster
                for description in descriptions:
                    tags = tag_map({"Tags": description.get("Tags")} if isinstance(description, dict) else {})
                    if key in tags and tags[key] in ("", "owned", "shared"):
                        tagged = True
                        break
            if tagged:
                found.append(arn)
    except ShapeError as error:
        return unknown("load-balancer", identity, attribution, str(error), reads)
    return observation("load-balancer", found, identity, attribution, reads)


def check_ecr_repository(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    if runtime.registry_prefix:
        identity = f"ECR repositories under {runtime.registry_prefix}/"
        attribution = "the target's declared registry path"
    else:
        identity = "ECR repositories"
        attribution = "the target's declared registry path"
    argv = ["ecr", "describe-repositories", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("ecr-repository", identity, attribution, reason, reads)
    if not runtime.registry_prefix:
        return unknown(
            "ecr-repository",
            identity,
            attribution,
            "the target declares no registry path, so repositories cannot be attributed to it",
            reads,
        )
    found: list[str] = []
    try:
        repositories = as_list(parsed, "repositories")
        names = [require_str(item, "repositoryName", "an ECR repository") for item in repositories]
    except ShapeError as error:
        return unknown("ecr-repository", identity, attribution, str(error), reads)
    prefix = runtime.registry_prefix
    found = [name for name in names if name == prefix or name.startswith(prefix + "/")]
    return observation("ecr-repository", found, identity, attribution, reads)


def check_cloudwatch_log_group(runner: Runner, runtime: Runtime) -> Observation:
    reads = Reads(runner)
    identity = f"CloudWatch log groups under /aws/eks/{runtime.cluster}"
    attribution = "the EKS control-plane and Container Insights log-group prefixes"
    argv = ["logs", "describe-log-groups", "--region", runtime.region, "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown("cloudwatch-log-group", identity, attribution, reason, reads)
    try:
        groups = as_list(parsed, "logGroups")
        names = [require_str(item, "logGroupName", "a log group") for item in groups]
    except ShapeError as error:
        return unknown("cloudwatch-log-group", identity, attribution, str(error), reads)
    prefixes = (f"/aws/eks/{runtime.cluster}", f"/aws/containerinsights/{runtime.cluster}")
    found = [name for name in names if name.startswith(prefixes)]
    return observation("cloudwatch-log-group", found, identity, attribution, reads)


def prefix_observation(
    runner: Runner,
    runtime: Runtime,
    *,
    resource_class: str,
    identity: str,
    attribution: str,
    argv: list[str],
    list_key: str,
    item_key: str,
    prefix: str,
) -> Observation:
    """A class identified by the target's cluster-name prefix on every name."""
    reads = Reads(runner)
    parsed, reason = reads.json(argv)
    if parsed is None:
        return unknown(resource_class, identity, attribution, reason, reads)
    try:
        items = as_list(parsed, list_key)
        names = [require_str(item, item_key, f"a {resource_class}") for item in items]
    except ShapeError as error:
        return unknown(resource_class, identity, attribution, str(error), reads)
    found = [name for name in names if name.startswith(prefix)]
    return observation(resource_class, found, identity, attribution, reads)


def check_rds_subnet_group(runner: Runner, runtime: Runtime) -> Observation:
    return prefix_observation(
        runner,
        runtime,
        resource_class="rds-subnet-group",
        identity=f"RDS subnet groups named {runtime.cluster}-*",
        attribution="the target's cluster-name prefix",
        argv=["rds", "describe-db-subnet-groups", "--region", runtime.region, "--output", "json"],
        list_key="DBSubnetGroups",
        item_key="DBSubnetGroupName",
        prefix=runtime.cluster + "-",
    )


def check_iam_role(runner: Runner, runtime: Runtime) -> Observation:
    return prefix_observation(
        runner,
        runtime,
        resource_class="iam-role",
        identity=f"IAM roles named {runtime.cluster}-*",
        attribution=(
            "the target's cluster-name prefix; the operator's durable identity roles are not "
            "named for the cluster"
        ),
        argv=["iam", "list-roles", "--output", "json"],
        list_key="Roles",
        item_key="RoleName",
        prefix=runtime.cluster + "-",
    )


def check_iam_policy(runner: Runner, runtime: Runtime) -> Observation:
    return prefix_observation(
        runner,
        runtime,
        resource_class="iam-policy",
        identity=f"customer-managed IAM policies named {runtime.cluster}-*",
        attribution="the target's cluster-name prefix on a local policy",
        argv=["iam", "list-policies", "--scope", "Local", "--output", "json"],
        list_key="Policies",
        item_key="PolicyName",
        prefix=runtime.cluster + "-",
    )


def check_s3_bucket(runner: Runner, runtime: Runtime) -> Observation:
    return prefix_observation(
        runner,
        runtime,
        resource_class="s3-bucket",
        identity=f"S3 buckets named {runtime.cluster}-*",
        attribution=(
            "the target's cluster-name prefix; the durable state bucket is not named for the cluster"
        ),
        argv=["s3api", "list-buckets", "--output", "json"],
        list_key="Buckets",
        item_key="Name",
        prefix=runtime.cluster + "-",
    )


def check_cloudwatch_dashboard(runner: Runner, runtime: Runtime) -> Observation:
    return prefix_observation(
        runner,
        runtime,
        resource_class="cloudwatch-dashboard",
        identity=f"CloudWatch dashboards named {runtime.cluster}-*",
        attribution="the target's cluster-name prefix",
        argv=["cloudwatch", "list-dashboards", "--region", runtime.region, "--output", "json"],
        list_key="DashboardEntries",
        item_key="DashboardName",
        prefix=runtime.cluster + "-",
    )


RESIDUE_CHECKS: list[Callable[[Runner, Runtime], Observation]] = [
    check_eks_cluster,
    check_rds_instance,
    check_rds_subnet_group,
    check_rds_snapshot,
    check_ec2_instance,
    check_vpc,
    check_nat_gateway,
    check_elastic_ip,
    check_ebs_volume,
    check_oidc_provider,
    check_security_group,
    check_load_balancer,
    check_ecr_repository,
    check_iam_role,
    check_iam_policy,
    check_s3_bucket,
    check_cloudwatch_dashboard,
    check_cloudwatch_log_group,
]


# --------------------------------------------------------------------------
# identity and durable observations
# --------------------------------------------------------------------------


def observe_identity(runner: Runner, runtime: Runtime) -> Identity:
    reads = Reads(runner)
    argv = ["sts", "get-caller-identity", "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return Identity(False, "", "", reason, reads.queries, reads.raw)
    try:
        account = require_str(parsed, "Account", "the caller identity")
        arn = require_str(parsed, "Arn", "the caller identity")
    except ShapeError as error:
        return Identity(False, "", "", str(error), reads.queries, reads.raw)
    if runtime.account and account != runtime.account:
        return Identity(
            False,
            account,
            arn,
            f"the caller is account {account}, not the run's {runtime.account}",
            reads.queries,
            reads.raw,
        )
    return Identity(True, account, arn, "the caller identity is the run's account", reads.queries, reads.raw)


def observe_durable(runner: Runner, runtime: Runtime) -> list[Observation]:
    """Durable prerequisites, recorded but excluded from the residue verdict."""
    if not runtime.base_domain:
        return []
    reads = Reads(runner)
    identity = f"hosted zone {runtime.base_domain}"
    attribution = "a durable delegation zone the operator publishes; it outlives the target"
    argv = ["route53", "list-hosted-zones", "--output", "json"]
    parsed, reason = reads.json(argv)
    if parsed is None:
        return [unknown("durable-hosted-zone", identity, attribution, reason, reads)]
    try:
        zones = as_list(parsed, "HostedZones")
        names = [require_str(item, "Name", "a hosted zone") for item in zones]
    except ShapeError as error:
        return [unknown("durable-hosted-zone", identity, attribution, str(error), reads)]
    wanted = runtime.base_domain.rstrip(".") + "."
    present = [name for name in names if name == wanted]
    return [
        Observation(
            "durable-hosted-zone",
            ABSENT if not present else PRESENT,
            identity,
            attribution,
            (
                "recorded as a retained durable prerequisite, not residue"
                if present
                else "the durable delegation zone was not observed; this is a prerequisite gap, "
                "not target residue"
            ),
            reads.queries,
            reads.raw,
        )
    ]


def evaluate(runtime: Runtime, runner: Runner) -> Report:
    identity = observe_identity(runner, runtime)
    if not identity.ok:
        blocked = f"the run's account identity was not established: {identity.detail}"
        observations = [
            Observation(
                check.__name__.removeprefix("check_").replace("_", "-"),
                UNKNOWN,
                "",
                "",
                blocked,
                [],
                [],
            )
            for check in RESIDUE_CHECKS
        ]
        return Report(identity, observations, [])
    observations = [check(runner, runtime) for check in RESIDUE_CHECKS]
    if runtime.prior is None or runtime.prior_error:
        for item in observations:
            if item.resource_class in CONTINUITY_CLASSES:
                item.state = UNKNOWN
                item.detail = runtime.prior_error or "independent pre-teardown identity capture is missing"
    return Report(identity, observations, observe_durable(runner, runtime))


# --------------------------------------------------------------------------
# evidence and verdict rendering
# --------------------------------------------------------------------------


def identity_header(runtime: Runtime, identity: Identity) -> list[str]:
    return [
        f"attempt={runtime.attempt or '-'}",
        f"target={runtime.target or '-'}",
        f"state_key={runtime.state_key or '-'}",
        f"cluster={runtime.cluster}",
        f"region={runtime.region}",
        f"caller_account={identity.account or '-'}",
        f"caller_arn={identity.arn or '-'}",
        f"caller_identity_ok={'yes' if identity.ok else 'no'}",
    ]


def render_inventory(runtime: Runtime, report: Report) -> str:
    lines = identity_header(runtime, report.identity)
    for observation in report.observations:
        lines.append("")
        lines.append(f"== {observation.resource_class} ==")
        lines.append(f"state: {observation.state}")
        lines.append(f"identity: {observation.identity}")
        lines.append(f"attribution: {observation.attribution}")
        lines.append(f"detail: {observation.detail}")
        lines.extend(observation.raw)
    for observation in report.durable:
        lines.append("")
        lines.append(f"== {observation.resource_class} (durable, not residue) ==")
        lines.append(f"state: {observation.state}")
        lines.append(f"detail: {observation.detail}")
        lines.extend(observation.raw)
    lines.append("")
    lines.append("limitations:")
    for limitation in LIMITATIONS:
        lines.append(f"  - {limitation}")
    return "\n".join(lines) + "\n"


def render_verdict(runtime: Runtime, report: Report) -> str:
    lines = [
        f"attempt={runtime.attempt or '-'}",
        f"target={runtime.target or '-'}",
        f"state_key={runtime.state_key or '-'}",
        f"cluster={runtime.cluster}",
        f"region={runtime.region}",
        f"caller_account={report.identity.account or '-'}",
        f"caller_identity: {'OK' if report.identity.ok else 'FAILED'} ({report.identity.detail})",
    ]
    for observation in report.observations:
        lines.append(f"{observation.resource_class}: {observation.state} ({observation.detail})")
    for observation in report.durable:
        retained = "retained" if observation.state == PRESENT else "not observed"
        lines.append(f"{observation.resource_class}: {retained} (excluded from the residue verdict)")
    if report.ok:
        lines.append("verdict: ABSENT (every required disposable class is independently ABSENT)")
    else:
        failed = ", ".join(f"{o.resource_class}:{o.state}" for o in report.failed)
        lines.append(f"verdict: NOT ABSENT ({failed})")
    return "\n".join(lines) + "\n"


def observation_json(observation: Observation, expectation: str) -> dict[str, Any]:
    """One class row in the promotion-verifiable verdict document.

    `expectation` is the durable/residue distinction: a disposable class must
    be ABSENT, a durable prerequisite must be PRESENT. The release gate reads
    the class, expectation and state; it never re-derives them.
    """
    return {
        "class": observation.resource_class,
        "expectation": expectation,
        "state": observation.state,
        "identity": observation.identity,
        "attribution": observation.attribution,
        "detail": observation.detail,
        "queries": [" ".join(query) for query in observation.queries],
    }


def render_json(runtime: Runtime, report: Report) -> str:
    classes = [observation_json(observation, "absent") for observation in report.observations]
    classes.extend(observation_json(observation, "present") for observation in report.durable)

    document = {
        "schema": 1,
        "policy": POLICY_NAME,
        "provider": "aws",
        "candidate": runtime.candidate,
        "attempt": runtime.attempt,
        "target": runtime.target,
        "scope": {
            "cluster": runtime.cluster,
            "region": runtime.region,
            "account": runtime.account,
            "caller_arn": report.identity.arn,
        },
        "required_classes": [row["class"] for row in classes],
        "classes": classes,
        "state_key": runtime.state_key,
        "caller_identity": {
            "ok": report.identity.ok,
            "account": report.identity.account,
            "arn": report.identity.arn,
            "detail": report.identity.detail,
        },
        "verdict": "ABSENT" if report.ok else "NOT ABSENT",
    }
    return json.dumps(document, indent=2, sort_keys=True) + "\n"


def collect(runtime: Runtime, runner: Runner, directory: str) -> Report:
    os.makedirs(directory, exist_ok=True)
    report = evaluate(runtime, runner)
    with open(os.path.join(directory, "aws-inventory.txt"), "w", encoding="utf-8") as handle:
        handle.write(render_inventory(runtime, report))
    with open(os.path.join(directory, "aws-inventory-verdict.txt"), "w", encoding="utf-8") as handle:
        handle.write(render_verdict(runtime, report))
    with open(os.path.join(directory, "aws-inventory-verdict.json"), "w", encoding="utf-8") as handle:
        handle.write(render_json(runtime, report))
    return report


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def add_runtime_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--account", default="")
    parser.add_argument("--registry-prefix", default=None)
    parser.add_argument("--base-domain", default=None)
    parser.add_argument(
        "--retention",
        default="none",
        choices=["none", "final-snapshot"],
        help="the target's declared destroy_retention",
    )
    parser.add_argument("--attempt", default="")
    parser.add_argument("--target", default="")
    parser.add_argument("--state-key", default="")
    parser.add_argument(
        "--candidate",
        default=None,
        help="the candidate document this run qualifies; without it the structured "
        "verdict is diagnostic and cannot satisfy promotion",
    )


def runtime_of(arguments: argparse.Namespace) -> Runtime:
    candidate = None
    if getattr(arguments, "candidate", None):
        candidate = load_candidate(arguments.candidate)
    return Runtime(
        cluster=arguments.cluster,
        region=arguments.region,
        account=arguments.account,
        registry_prefix=arguments.registry_prefix,
        base_domain=arguments.base_domain,
        retention=arguments.retention,
        attempt=arguments.attempt,
        target=arguments.target,
        state_key=arguments.state_key,
        candidate=candidate,
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    collect_parser = subparsers.add_parser("collect", help="read the provider and write the verdict")
    collect_parser.add_argument("--dir", required=True)
    add_runtime_arguments(collect_parser)
    collect_parser.add_argument("--bound", type=float, default=30.0)
    collect_parser.add_argument("--aws-command", default="aws")

    collect_parser.add_argument("--prior", required=True, help="independent pre-teardown capture from this attempt")
    capture_parser = subparsers.add_parser("capture", help="capture independent identities before teardown")
    add_runtime_arguments(capture_parser)
    capture_parser.add_argument("--prior", required=True)
    capture_parser.add_argument("--initial", action="store_true", help="capture before provisioning, when an EKS issuer may not exist yet")
    capture_parser.add_argument("--bound", type=float, default=30.0)
    capture_parser.add_argument("--aws-command", default="aws")
    arguments = parser.parse_args(argv)

    try:
        runtime = runtime_of(arguments)
    except (OSError, ValueError) as error:
        print(f"absence: {error}", file=sys.stderr)
        return 2
    runner = subprocess_runner(arguments.bound, arguments.aws_command)
    if arguments.command == "capture":
        try:
            capture(runtime, runner, arguments.prior, initial=arguments.initial)
        except (OSError, ValueError, ShapeError) as error:
            print(f"absence: identity capture failed: {error}", file=sys.stderr)
            return 1
        return 0
    try:
        runtime = replace(runtime, prior=load_prior(arguments.prior, runtime))
    except (OSError, ValueError) as error:
        runtime = replace(runtime, prior_error=str(error))
    report = collect(runtime, runner, arguments.dir)
    for observation in report.observations:
        print(f"  {observation.resource_class}: {observation.state} ({observation.detail})", flush=True)
    for observation in report.durable:
        state = "retained" if observation.state == PRESENT else "not observed"
        print(f"  {observation.resource_class}: {state} (durable, excluded)", flush=True)
    if report.ok:
        print("  independent inventory: ABSENT", flush=True)
        return 0
    print("  independent inventory: NOT ABSENT; teardown is not complete", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
