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
    "platform/cloud/gcp/cluster/kafka.tf",
    "platform/cloud/aws/cluster/main.tf",
    "platform/cloud/aws/cluster/variables.tf",
    "platform/cloud/aws/cluster/kafka.tf",
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

    # The same missing ownership obligation must fail at every local-module depth.
    for depth in (0, 1, 2):
        tmp = scratch()
        directory = tmp / "platform/cloud/aws/cluster"
        for index in range(depth):
            child = directory / "nested"
            child.mkdir()
            (directory / f"module_{index}.tf").write_text(
                f'module "nested" {{ source = "./nested" }}\n'
            )
            directory = child
        (directory / "uncovered.tf").write_text(
            'resource "aws_eip" "uncovered" { domain = "vpc" }\n'
        )
        cases.append((f"an uncovered native resource at module depth {depth}", tmp))

    # Moving an already covered resource must require a correctly qualified
    # recovery address; the old root mapping cannot authorize a module import.
    tmp = scratch()
    module = tmp / "platform/cloud/aws/cluster/nested"
    module.mkdir()
    source = tmp / "platform/cloud/aws/cluster/main.tf"
    text = source.read_text()
    start = text.index('resource "aws_db_subnet_group" "main" {')
    end = text.index('\n}', start) + 2
    (module / "main.tf").write_text(text[start:end] + "\n")
    source.write_text(text[:start] + text[end:] + '\nmodule "nested" { source = "./nested" }\n')
    result = run(tmp)
    if result.returncode == 0 or "module.nested.aws_db_subnet_group.main" not in result.stderr:
        failures.append("moving a resource into a module did not require its qualified ownership mapping")
    mutate(tmp, "cli/lib/cloud/sol_cli_resource_identity.ml",
           '"aws_db_subnet_group.main[0]"', '"module.nested.aws_db_subnet_group.main[0]"')
    result = run(tmp)
    if result.returncode != 0:
        failures.append("an explicitly qualified module recovery mapping was rejected:\n" + result.stderr)
    mutate(tmp, "platform/cloud/aws/cluster/main.tf",
           'module "nested" { source = "./nested" }',
           'module "nested" { source = "./nested" count = 1 }')
    cases.append(("Direct recovery beneath an indexed module without an instance policy", tmp))

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
