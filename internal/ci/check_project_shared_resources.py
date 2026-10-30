#!/usr/bin/env python3
"""Target destruction must not delete project-wide resources.

A target's Terraform state is scoped to that target, but the provider resources a root
declares are not necessarily: the project's default compute service account is shared by
everything in the project. An older revision of the GCP cluster root *managed* it, so any
state written then holds it, and an ordinary destroy would delete it for every other user
of the project. The current configuration only reads it (a data source), and this guard
keeps that true.

Reading a data source and managing a resource are distinguishable in Terraform's state by
`mode`, which is how the distinction was checked: a state entry for
`google_compute_default_service_account.default` is a `data` record and an ordinary destroy
does not touch it. A guard cannot see state, so this one holds the config-side invariant that
makes the state-side fact true.

The class list is deliberately explicit rather than heuristic: a resource is project-wide
here because it is documented as shared, not because its name looks shared.
"""
import re
import sys
from pathlib import Path

NAME = "check_project_shared_resources"

PROJECT_WIDE = {
    "google_compute_default_service_account": (
        "the project's default compute service account is shared by everything in the project"
    ),
}

ROOTS = ["platform/cloud/gcp/cluster", "platform/cloud/aws/cluster"]


def text_of_any_root(root):
    parts = []
    for relative in ROOTS:
        directory = root / relative
        if directory.exists():
            parts.extend(tf.read_text() for tf in sorted(directory.glob("*.tf")))
    return "\n".join(parts)
RESOURCE = re.compile(r'^resource\s+"(?P<type>[a-z0-9_]+)"\s+"(?P<name>[a-z0-9_]+)"', re.M)
REMOVED = re.compile(
    r"removed\s*\{\s*from\s*=\s*(?P<address>[a-z0-9_]+\.[a-z0-9_]+)\s*"
    r"lifecycle\s*\{\s*destroy\s*=\s*false\s*\}",
    re.S,
)


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(".")
    problems = []
    declared = {}
    relinquished = set()
    for relative in ROOTS:
        directory = root / relative
        if not directory.exists():
            continue
        for tf in sorted(directory.glob("*.tf")):
            text = tf.read_text()
            for match in RESOURCE.finditer(text):
                declared[f'{match.group("type")}.{match.group("name")}'] = relative
            for match in REMOVED.finditer(text):
                relinquished.add(match.group("address"))
    for address, where in sorted(declared.items()):
        resource_type = address.split(".")[0]
        reason = PROJECT_WIDE.get(resource_type)
        if reason is None:
            continue
        problems.append(
            f"{where} declares a managed resource for {address}: {reason}, so a target's "
            "destroy would delete a resource that is not that target's to delete. Read it "
            "with a data source instead, or relinquish it with `removed { lifecycle { "
            "destroy = false } }`."
        )
    # A dedicated node service account is the least-privilege replacement for the
    # project-shared default. Require the dedicated identity and its explicit use; the
    # default account must not be managed, and there is no reason to read it.
    cluster_text = text_of_any_root(root)
    if re.search(r'^resource\s+"google_service_account"\s+"node"', cluster_text, re.M) is None:
        problems.append(
            "the GCP cluster root declares no dedicated google_service_account.node: nodes "
            "must not run as the project's shared default Compute service account."
        )
    if re.search(
        r'node_config\s*\{[^}]*service_account\s*=\s*'
        r'google_service_account\.node\.email',
        cluster_text,
    ) is None:
        problems.append(
            "the GCP node pool does not set service_account = google_service_account.node.email; "
            "a default or literal identity would reintroduce the shared node identity."
        )
    if re.search(
        r'resource\s+"google_service_account"\s+"node"[\s\S]*?'
        r'account_id\s*=\s*"default"',
        cluster_text,
    ):
        problems.append(
            "the dedicated node service account still uses the shared default account id."
        )
    if re.search(r'^data\s+"google_compute_default_service_account"', cluster_text, re.M):
        problems.append(
            "the GCP cluster root still reads the project's shared default Compute service "
            "account; a dedicated node identity does not need it."
        )
    if problems:
        for problem in problems:
            print(f"{NAME}: {problem}", file=sys.stderr)
        return 1
    print(
        f"{NAME}: {len(declared)} declared resource(s) checked; no target manages a "
        "project-wide resource, and GKE nodes use a dedicated identity"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
