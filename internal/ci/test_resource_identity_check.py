#!/usr/bin/env python3
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "internal/ci/check_resource_identity.py"
COPIED = [
    "cli/lib/cloud/sol_cli_resource_identity.ml",
    "platform/cloud/gcp/cluster/main.tf",
    "platform/cloud/gcp/cluster/variables.tf",
    "platform/cloud/aws/cluster/main.tf",
    "platform/cloud/aws/cluster/variables.tf",
    "platform/cloud/modules/platform/main.tf",
    "platform/cloud/modules/platform/cert_manager_issuer.tf",
]


def scratch():
    tmp = Path(tempfile.mkdtemp())
    for relative in COPIED:
        source = ROOT / relative
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(source, target)
    return tmp


def run(tmp):
    return subprocess.run(
        [sys.executable, str(GUARD), str(tmp)], capture_output=True, text=True
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
        failures.append("the real tree was rejected:\n" + result.stderr)

    cases = []

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/main.tf",
        'resource "google_container_cluster" "main" {',
        'resource "google_container_cluster" "a_new_thing_terraform_would_own" {',
    )
    cases.append(("a directly managed resource with no registry entry", tmp))

    sql_entry = (
        '      "google_sql_database_instance.postgres[0]"\n'
        '      direct\n'
        '      ~resource_class:"Cloud SQL instance"\n'
        '      ~observed_as:(cluster_name ^ "-postgres")\n'
        '      ~identity:(cluster_name ^ "-postgres")\n'
        '      ~import_identity:(cluster_name ^ "-postgres")'
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_resource_identity.ml",
        sql_entry,
        sql_entry.replace('\n      ~import_identity:(cluster_name ^ "-postgres")', ""),
    )
    cases.append(("a Direct entry whose import identity was removed", tmp))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_resource_identity.ml",
        sql_entry,
        sql_entry.replace('~observed_as:(cluster_name ^ "-postgres")', '~observed_as:""'),
    )
    cases.append(("a Direct entry the inventory could not map back to", tmp))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_resource_identity.ml",
        '"google_sql_database_instance.postgres[0]"',
        '"google_sql_database_instance.postgres"',
    )
    cases.append(("a Direct entry on a counted resource with no instance key (#1476)", tmp))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_resource_identity.ml",
        '"google_compute_network.main"',
        '"google_compute_network.a_resource_no_root_declares"',
    )
    cases.append(("a stale entry naming a resource Sol does not have", tmp))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_resource_identity.ml",
        '"aws_db_instance.postgres[0]"',
        '"aws_db_instance.a_database_no_root_declares[0]"',
    )
    cases.append(("a counted entry naming a resource no root declares", tmp))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_resource_identity.ml",
        '{ terraform_type = "kubernetes_"; ownership = in_cluster }',
        '{ terraform_type = "kubernetes_object_"; ownership = in_cluster }',
    )
    cases.append(("a class-level rule that no longer covers the in-cluster family", tmp))

    for label, tmp in cases:
        result = run(tmp)
        if result.returncode == 0:
            failures.append(f"the guard accepted {label}")
        else:
            print(f"  rejected: {label}")

    shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        for failure in failures:
            print(f"test_resource_identity_check: {failure}", file=sys.stderr)
        return 1
    print(
        "test_resource_identity_check: the guard accepts the real tree and rejects an unregistered "
        "directly managed resource, a Direct entry without an import identity or an observed name, "
        "a Direct entry on a counted resource with no instance key, "
        "a stale entry, and a class-level rule that stopped covering its family"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
