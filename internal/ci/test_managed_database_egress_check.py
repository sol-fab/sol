#!/usr/bin/env python3
"""Mutation test for check_managed_database_egress.

Each case is a way the managed-database contract can regress: enforcement switched off on either
provider (which is how the GCP row passed while AWS hung), a range no longer derived, a range
published without a database, no publication, a read grant that reaches every configmap or may
write, an allowance applied with no ranges, one that names no port, one that is not scoped to
ranges at all, one widened to every workload instead of the declared consumers, or a malformed
fact defaulted instead of refused.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "internal/ci/check_managed_database_egress.py"
COPIED = [
    "platform/cloud/aws/cluster/main.tf",
    "platform/cloud/aws/cluster/outputs.tf",
    "platform/cloud/gcp/cluster/main.tf",
    "platform/cloud/gcp/cluster/outputs.tf",
    "platform/cloud/aws/platform/main.tf",
    "platform/cloud/gcp/platform/main.tf",
    "platform/cloud/modules/platform/platform_network_facts.tf",
    "cli/lib/deploy/sol_cli_substrate.ml",
    "cli/lib/deploy/sol_cli_deploy_run.ml",
    "cli/lib/workspace/sol_cli_manifest_yaml.ml",
]


def scratch():
    tmp = Path(tempfile.mkdtemp())
    for relative in COPIED:
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / relative, target)
    guard = tmp / "internal/ci/check_managed_database_egress.py"
    guard.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(GUARD, guard)
    return tmp


def run(tmp):
    return subprocess.run(
        [sys.executable, str(tmp / "internal/ci/check_managed_database_egress.py"), str(tmp)],
        capture_output=True,
        text=True,
    )


def mutate(tmp, relative, old, new):
    path = tmp / relative
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"mutation anchor not found in {relative}: {old!r}")
    path.write_text(text.replace(old, new, 1))


def main():
    failures = []
    result = run(scratch())
    if result.returncode != 0:
        failures.append("the real tree was rejected:\n" + result.stdout + result.stderr)

    cases = []

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/main.tf",
        '  datapath_provider = "ADVANCED_DATAPATH"\n',
        "",
    )
    cases.append(("gcp-stops-enforcing", tmp, "enforcement is off"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/aws/cluster/main.tf",
        '        enableNetworkPolicy = "true"',
        '        enableNetworkPolicy = "false"',
    )
    cases.append(("aws-stops-enforcing", tmp, "no longer enables the network policy"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/aws/cluster/outputs.tf",
        "var.create_rds ? module.vpc.private_subnets_cidr_blocks : []",
        "[]",
    )
    cases.append(("aws-range-not-derived", tmp, "not derived from the subnets"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/outputs.tf",
        "${google_compute_global_address.sql_peering.address}/${google_compute_global_address.sql_peering.prefix_length}",
        "0.0.0.0/0",
    )
    cases.append(("gcp-range-widened", tmp, "not derived from the peering range"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/outputs.tf",
        "value = var.create_database ? [",
        "value = [",
    )
    mutate(tmp, "platform/cloud/gcp/cluster/outputs.tf", "  ] : []", "  ]")
    cases.append(
        ("gcp-publishes-a-range-without-a-database", tmp, "advertises an allowance")
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_substrate.ml",
        "match spec.db_ca_target with\n    | None -> None",
        "match Some () with\n    | None -> None",
    )
    cases.append(("all-workloads-widened-to-the-database", tmp, "not scoped to the units"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_deploy_run.ml",
        "~workloads:(Sol_cli_substrate.managed_database_workloads plan)",
        "~workloads:[]",
    )
    cases.append(
        (
            "deploy-gate-drops-the-declared-consumers",
            tmp,
            "does not pass the plan's declared consumers",
        )
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_substrate.ml",
        "carries database-egress-cidrs but no",
        "carries database-egress-cidrs and possibly",
    )
    cases.append(
        ("malformed-fact-port-error-removed", tmp, "defaulted instead of refused")
    )

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/platform/main.tf",
        "  database_egress_cidrs                   = var.database_egress_cidrs\n",
        "",
    )
    cases.append(("range-not-passed-to-the-module", tmp, "not passed to the shared module"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/modules/platform/platform_network_facts.tf",
        "    resource_names = [kubernetes_config_map.network_facts.metadata[0].name]\n",
        "",
    )
    cases.append(("read-grant-unscoped", tmp, "not scoped to the fact object"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/modules/platform/platform_network_facts.tf",
        '    verbs          = ["get"]',
        '    verbs          = ["get", "update"]',
    )
    cases.append(("read-grant-widened", tmp, "wider than fetching the fact"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_substrate.ml",
        "if cidrs = []\n       then Ok None",
        "if false\n       then Ok None",
    )
    cases.append(("empty-fact-still-applied", tmp, "carries no ranges"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_substrate.ml",
        "no route to it",
        "every route open",
    )
    cases.append(("managed-database-absent-fact-accepted", tmp, "must refuse the substrate"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/workspace/sol_cli_manifest_yaml.ml",
        '"port", Y.int port; "protocol", Y.string "TCP"',
        '"port", Y.int 5432; "protocol", Y.string "TCP"',
    )
    cases.append(("allowance-port-hardcoded", tmp, "names no port"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/workspace/sol_cli_manifest_yaml.ml",
        'Y.map [ "ipBlock", Y.map [ "cidr", Y.string cidr ] ]',
        'Y.map [ "ipBlock", Y.map [ "cidr", Y.string "0.0.0.0/0" ] ]',
    )
    cases.append(("allowance-not-scoped", tmp, "cannot be scoped"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/workspace/sol_cli_manifest_yaml.ml",
        '''          [ "podSelector", Y.map [ "matchLabels", app_selector name ]
          ; "policyTypes", Y.list [ Y.string "Egress" ]''',
        '''          [ "podSelector", Y.map []
          ; "policyTypes", Y.list [ Y.string "Egress" ]''',
    )
    cases.append(("allowance-selects-the-whole-namespace", tmp, "does not select the workloads"))

    for name, tmp, expected in cases:
        result = run(tmp)
        if result.returncode == 0:
            failures.append(f"{name}: accepted a broken tree")
        elif expected not in (result.stdout + result.stderr):
            failures.append(
                f"{name}: rejected, but not for its own reason (wanted {expected!r}):\n"
                f"{result.stdout}{result.stderr}"
            )

    if failures:
        print("test_managed_database_egress_check: FAILED")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print(
        "test_managed_database_egress_check: the guard accepts the real tree and rejects "
        f"{len(cases)} mutations for their own reasons"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
