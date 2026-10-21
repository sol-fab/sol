#!/usr/bin/env python3
"""A delegated DNS zone is a durable prerequisite, on every provider (DEC-042/DEC-043).

The zone's authoritative nameservers are baked into a registrar delegation Sol cannot repair
programmatically, so recreating the zone silently breaks resolution. The decided contract --
applied to GCP under HARDEN-004, mirrored for AWS with the same qualification-shaped interim
mechanism -- is that the zone is owned by the durable bootstrap root rather than by
disposable target state, that the target only reads a zone that already exists, and that a
plan which would replace or destroy a durable resource is refused rather than applied.

This guard reads both providers and fails closed: each bootstrap root owns its zone behind a
managing flag and keeps that ownership in a remote backend; each cluster root owns a zone
only when told to create one, reads an existing one otherwise, and carries no wildcard
authority that would hide the difference; each qualification target selects the durable zone;
each qualification harness delegates durable reconciliation to Sol's inline whole-target
deploy; and each absence verifier reports the retained zone as the declared prerequisite
rather than as residue.
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))

import tfconfig

PROVIDERS = {
    "aws": {
        "roots": ("platform/cloud/aws/bootstrap", "platform/cloud/aws/cluster"),
        "harness": "internal/qualification/aws/live-qual.sh",
        "absence": "cli/lib/cloud/sol_cli_aws_absence.ml",
        "target": "internal/qualification/aws/qual.tfvars",
        "zone_type": "aws_route53_zone",
        "zone_name": "qualification",
        "backend": "s3",
        "create_flag": "create_route53_zone",
        "zone_class": "Route 53 hosted zone",
        "forbidden_authority": "hostedzone/*",
    },
    "gcp": {
        "roots": ("platform/cloud/gcp/bootstrap", "platform/cloud/gcp/cluster"),
        "harness": "internal/qualification/gcp/live-qual.sh",
        "absence": "cli/lib/cloud/sol_cli_gcp_absence.ml",
        "target": "internal/qualification/gcp/qual.tfvars",
        "zone_type": "google_dns_managed_zone",
        "zone_name": "qualification",
        "backend": "gcs",
        "create_flag": "create_dns_zone",
        "zone_class": "DNS managed zone",
        "forbidden_authority": "roles/dns.admin",
    },
}
INSTALLATION_POLICY = "cli/lib/cloud/sol_cli_installation_stage.ml"
TERRAFORM_PLAN = "cli/lib/cloud/sol_cli_terraform_plan.ml"


def text_of(directory) -> str:
    return "\n".join(path.read_text() for path in sorted(pathlib.Path(directory).glob("*.tf")))


def resources_of(directory, kinds=("resource", "data")) -> list:
    found = []

    for path in sorted(pathlib.Path(directory).glob("*.tf")):
        found.extend(tfconfig.resources(path, kinds=kinds))

    return found


def attribute_text(resource, key: str) -> str:
    return " ".join(str(value) for value in tfconfig.attributes(resource.body, key))


def check_provider(root: pathlib.Path, provider: str, spec: dict) -> list[str]:
    problems: list[str] = []
    bootstrap, cluster = (root / directory for directory in spec["roots"])
    bootstrap_text = text_of(bootstrap)
    cluster_text = text_of(cluster)

    durable = [
        resource
        for resource in resources_of(bootstrap, kinds=("resource",))
        if resource.type == spec["zone_type"] and resource.name == spec["zone_name"]
    ]

    if not durable:
        problems.append(
            f"{provider}: the durable root declares no {spec['zone_type']}.{spec['zone_name']}, "
            "so the delegated zone has no owner that outlives a target"
        )
    for resource in durable:
        if "manage_dns_zone" not in attribute_text(resource, "count"):
            problems.append(
                f"{provider}: {resource.where} declares a durable zone without gating it on "
                "manage_dns_zone, so a project that has delegated nothing would still own one"
            )

    if f'backend "{spec["backend"]}"' not in bootstrap_text:
        problems.append(
            f"{provider}: the durable root has no {spec['backend']} backend, so the zone's "
            "ownership lives in state that does not outlive the machine that ran it"
        )

    for resource in resources_of(cluster, kinds=("resource",)):
        if resource.type == spec["zone_type"] and (
            f"var.{spec['create_flag']}" not in attribute_text(resource, "count")
        ):
            problems.append(
                f"{provider}: {resource.where} declares a target-owned zone that is not gated on "
                f"{spec['create_flag']}, so a target owns a delegated zone unconditionally"
            )

    existing = [
        resource
        for resource in resources_of(cluster, kinds=("data",))
        if resource.type == spec["zone_type"] and resource.name == "existing"
    ]
    if not existing:
        problems.append(
            f"{provider}: the target root reads no existing zone, so it cannot use the durable "
            "one without owning it"
        )
    for resource in existing:
        if f"var.{spec['create_flag']}" not in attribute_text(resource, "count"):
            problems.append(
                f"{provider}: {resource.where} reads an existing zone unconditionally, so the "
                "target would also read one when it is meant to create its own"
            )

    if ".existing[0]" not in cluster_text:
        problems.append(
            f"{provider}: the target root does not select between the zone it created and the "
            "existing one, so which zone it uses is not declared"
        )

    if spec["forbidden_authority"] in cluster_text:
        problems.append(
            f"{provider}: the target root still grants {spec['forbidden_authority']}, so record "
            "authority is wider than the delegated zone it is meant to serve"
        )

    target = root / spec["target"]
    if not target.exists():
        problems.append(f"{provider}: the qualification target {spec['target']} is missing")
    elif f"{spec['create_flag']} = false" not in target.read_text():
        problems.append(
            f"{provider}: {spec['target']} does not set {spec['create_flag']} = false, so the row "
            "would create its own zone instead of using the durable one"
        )

    harness = (root / spec["harness"]).read_text()
    # The durable installation is reconciled inline by the whole-target deploy (DEC-057 §2);
    # the harness must delegate that to Sol rather than driving the root itself.
    if "deploy '$TARGET'" not in harness:
        problems.append(
            f"{provider}: {spec['harness']} does not reconcile the durable installation "
            "through the whole-target `sol deploy <target>`"
        )

    absence = (root / spec["absence"]).read_text()
    if spec["zone_class"] not in absence:
        problems.append(
            f"{provider}: {spec['absence']} does not declare {spec['zone_class']!r}, so the "
            "retained zone would read as unexpected residue"
        )

    return problems


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    problems: list[str] = []

    for provider, spec in PROVIDERS.items():
        wanted = [
            spec["harness"],
            spec["absence"],
            spec["target"],
            *(f"{directory}/main.tf" for directory in spec["roots"]),
        ]
        missing = [path for path in wanted if not (root / path).exists()]
        if missing:
            problems.append(f"{provider}: cannot read {', '.join(missing)}")

    missing_policy = [
        path for path in (INSTALLATION_POLICY, TERRAFORM_PLAN) if not (root / path).exists()
    ]
    if missing_policy:
        problems.append(f"cannot read {', '.join(missing_policy)}")

    if problems:
        print("check_durable_dns_zone: cannot evaluate the tree:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    for provider, spec in PROVIDERS.items():
        problems.extend(check_provider(root, provider, spec))

    installation_policy = (root / INSTALLATION_POLICY).read_text()
    if "allows = [ Create; Update; Read; No_op ]" not in installation_policy:
        problems.append(
            f"{INSTALLATION_POLICY} must refuse delete, replace and unknown changes in "
            "the durable root"
        )
    if "~policy:durable_root_policy" not in installation_policy:
        problems.append(
            f"{INSTALLATION_POLICY} does not use the durable-root policy when applying "
            "the bootstrap plan"
        )

    terraform_plan = (root / TERRAFORM_PLAN).read_text()
    if "List.mem action rule.allows" not in terraform_plan:
        problems.append(
            f"{TERRAFORM_PLAN} does not enforce the action allowlist for guarded plans"
        )

    if problems:
        print("check_durable_dns_zone: the durable-zone contract is broken:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(
        "check_durable_dns_zone: each provider's delegated zone is owned by its durable root, "
        "only read by the target, refused a destructive plan, and reported as a prerequisite"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
