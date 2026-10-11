#!/usr/bin/env python3
"""A workload can reach the managed database Sol provisioned, and only on that path (FND-0075).

The invariant, stated semantically: a workload whose target declares a Sol-managed database gets
egress to the network range required to reach that database, on the database port — derived from
the placement Sol owns, never declared by an application author, and never widened beyond it.

That means, structurally: both providers enforce NetworkPolicy (otherwise the contract is not
exercised at all, which is how the GCP row passed while AWS hung); each cluster root derives the
range from the resource it created and publishes it; each platform root mirrors the variable; the
shared module publishes it as a cluster fact with a read grant narrow enough to fetch that one
object; and the deploy applies the allowance only when the fact carries ranges, only to those
ranges, and only on the database port. A target that provisions a database but publishes no
ranges is refused rather than deployed without egress: an absent or unreadable fact and a
target with no managed database must not look alike.
"""

from __future__ import annotations

import pathlib
import re
import sys

FILES = {
    "aws_cluster": "platform/cloud/aws/cluster/main.tf",
    "aws_outputs": "platform/cloud/aws/cluster/outputs.tf",
    "gcp_cluster": "platform/cloud/gcp/cluster/main.tf",
    "gcp_outputs": "platform/cloud/gcp/cluster/outputs.tf",
    "aws_platform": "platform/cloud/aws/platform/main.tf",
    "gcp_platform": "platform/cloud/gcp/platform/main.tf",
    "module_facts": "platform/cloud/modules/platform/platform_network_facts.tf",
    "substrate": "cli/lib/deploy/sol_cli_substrate.ml",
    "egress_doc": "cli/lib/workspace/sol_cli_manifest_yaml.ml",
}


def read(root: pathlib.Path, key: str) -> str:
    path = root / FILES[key]
    if not path.exists():
        raise SystemExit(f"cannot read {FILES[key]}")

    return path.read_text()


def check(root: pathlib.Path) -> list[str]:
    problems: list[str] = []
    aws_cluster = read(root, "aws_cluster")
    gcp_cluster = read(root, "gcp_cluster")
    aws_outputs = read(root, "aws_outputs")
    gcp_outputs = read(root, "gcp_outputs")
    facts = read(root, "module_facts")
    substrate = read(root, "substrate")
    egress_doc = read(root, "egress_doc")

    if 'enableNetworkPolicy = "true"' not in aws_cluster:
        problems.append(
            "platform/cloud/aws/cluster/main.tf: the VPC CNI no longer enables the network policy "
            "agent, so a rendered policy would not be enforced"
        )
    if 'datapath_provider = "ADVANCED_DATAPATH"' not in gcp_cluster:
        problems.append(
            "platform/cloud/gcp/cluster/main.tf: enforcement is off, which is how a GCP row can "
            "pass the same contract while a workload cannot reach its database"
        )
    if "module.vpc.private_subnets_cidr_blocks" not in aws_outputs:
        problems.append(
            "platform/cloud/aws/cluster/outputs.tf: the range the database lives in is not derived "
            "from the subnets Sol placed it in"
        )
    if "sql_peering" not in gcp_outputs:
        problems.append(
            "platform/cloud/gcp/cluster/outputs.tf: the range Cloud SQL's private address comes "
            "from is not derived from the peering range Sol created"
        )
    for provider in ("aws", "gcp"):
        platform = read(root, f"{provider}_platform")
        if "database_egress_cidrs" not in platform:
            problems.append(
                f"platform/cloud/{provider}/platform/main.tf: the derived range is not passed to "
                "the shared module, so nothing publishes it to the cluster"
            )

    if "sol-platform-network" not in facts:
        problems.append(
            "platform/cloud/modules/platform/platform_network_facts.tf: the range is not "
            "published as a cluster fact, so the deploy cannot know it"
        )
    if "resource_names" not in facts:
        problems.append(
            "platform/cloud/modules/platform/platform_network_facts.tf: the read grant is not "
            "scoped to the fact object, so it reaches other configmaps"
        )
    if not re.search(r'verbs\s*=\s*\["get"\]', facts):
        problems.append(
            "platform/cloud/modules/platform/platform_network_facts.tf: the read grant is wider "
            "than fetching the fact"
        )

    if "platform_network_fact" not in substrate:
        problems.append(
            "cli/lib/deploy/sol_cli_substrate.ml: the deploy does not read the published fact, so "
            "no allowance is ever applied"
        )
    if "if cidrs = [] then Ok None else" not in substrate:
        problems.append(
            "cli/lib/deploy/sol_cli_substrate.ml: the fact is not treated as absent when it "
            "carries no ranges, which would apply an empty allowance where there is no database"
        )
    if "manages_database" not in substrate or "no route to it" not in substrate:
        problems.append(
            "cli/lib/deploy/sol_cli_substrate.ml: an absent or unreadable fact is not "
            "distinguished from a target that provisions no database. A target with a managed "
            "database must refuse the substrate rather than deploy the workloads with no route "
            "to it (FND-0075)."
        )

    start = egress_doc.find("let managed_database_egress_doc")
    allowance = egress_doc[start : egress_doc.find("\n;;\n", start)] if start != -1 else ""
    if allowance == "":
        problems.append("cli/lib/workspace/sol_cli_manifest_yaml.ml: no egress allowance is built")
    else:
        if '~kind:"NetworkPolicy"' not in allowance:
            problems.append(
                "cli/lib/workspace/sol_cli_manifest_yaml.ml: the allowance is not a NetworkPolicy"
            )
        if '"ipBlock"' not in allowance or "Y.string cidr" not in allowance:
            problems.append(
                "cli/lib/workspace/sol_cli_manifest_yaml.ml: the allowance does not name the "
                "ranges as ipBlocks carrying the ranges it was given, so it cannot be scoped to "
                "what Sol provisioned"
            )
        if "app_selector name" not in allowance:
            problems.append(
                "cli/lib/workspace/sol_cli_manifest_yaml.ml: the allowance does not select the "
                "workloads that need it. An empty podSelector makes the namespace "
                "egress-default-deny for every pod in it, which breaks everything that is not an "
                "application workload -- observed live when a verification Job could no longer "
                "resolve the service it was checking"
            )
        if '"ports"' not in allowance or "Y.int port" not in allowance:
            problems.append(
                "cli/lib/workspace/sol_cli_manifest_yaml.ml: the allowance names no port, which "
                "permits every port to those ranges instead of the database's"
            )

    return problems


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    try:
        problems = check(root)
    except SystemExit as error:
        print(f"check_managed_database_egress: {error}")
        return 1

    if problems:
        print("check_managed_database_egress: the managed-database egress contract is broken:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(
        "check_managed_database_egress: both providers enforce policy, each derives the range it "
        "provisioned and publishes it, the read grant is scoped to that one fact, and the deploy "
        "allows exactly those ranges on the database port"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
