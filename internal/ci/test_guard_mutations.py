#!/usr/bin/env python3
"""The shared-resource guard must fail on the change it exists to prevent."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
COPIED = [
    "platform/cloud/gcp/cluster/main.tf",
    "platform/cloud/gcp/cluster/variables.tf",
    "platform/cloud/aws/cluster/main.tf",
]


def scratch():
    tmp = Path(tempfile.mkdtemp(prefix="sol-guard-mutation-"))
    for relative in COPIED:
        source = ROOT / relative
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(source, target)
    return tmp


def mutate(tmp, relative, old, new):
    path = tmp / relative
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"mutation anchor not found in {relative}: {old!r}")
    path.write_text(text.replace(old, new, 1))


def run(tmp):
    return subprocess.run(
        [sys.executable, str(ROOT / "internal/ci/check_project_shared_resources.py"), str(tmp)],
        capture_output=True,
        text=True,
    )


def main():
    cases = []

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/main.tf",
        'account_id   = "${var.cluster_name}-node"',
        'account_id   = "default"',
    )
    cases.append(("a shared default node identity returns", tmp))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/main.tf",
        "service_account = google_service_account.node.email",
        'service_account = "default"',
    )
    cases.append(("the node pool stops using the dedicated identity", tmp))

    failures = 0
    for label, tmp in cases:
        result = run(tmp)
        if result.returncode == 0:
            print(f"test_guard_mutations: guard ACCEPTED a mutation: {label}", file=sys.stderr)
            failures += 1
        else:
            print(f"  rejected: {label}")
    if failures:
        return 1
    print(
        "test_guard_mutations: the guard rejects the change it exists to prevent -- a "
        "project-wide resource managed by a target instead of read, and the shared account "
        "not read at all"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
