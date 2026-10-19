#!/usr/bin/env python3
"""Drift guard for the release teardown policy.

Promotion decides the required teardown class universe from
`internal/tooling/release/teardown-policy.v1.json`, not from the evidence
document. That only stays correct if the policy and the provider inventories
declare the same classes. This test is the boundary between them:

  * AWS `absence.RESIDUE_CLASSES` plus its durable prerequisite;
  * GCP `INVENTORY_CLASSES` in `gcp/live-qual.sh`, with `scope` mapped to the
    `present` disposition the evidence uses.

The gate itself must not import either producer; this test may, because it
establishes that the two independent declarations still agree. A change to a
producer's universe fails here until the policy is deliberately updated.
"""

from __future__ import annotations

import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "internal" / "tooling" / "release"))
sys.path.insert(0, str(REPO / "internal" / "qualification" / "aws"))

import absence  # noqa: E402
import promotion  # noqa: E402

checks = 0
failures = 0


def check(label: str, condition: bool) -> None:
    global checks, failures
    checks += 1
    if condition:
        print(f"  [OK]   {label}")
    else:
        print(f"  [FAIL] {label}")
        failures += 1


def policy_classes(policy: dict, provider: str) -> dict[str, str]:
    return {
        row["class"]: row["expectation"]
        for row in policy["providers"][provider]["classes"]
    }


def gcp_inventory_classes() -> dict[str, str]:
    text = (REPO / "internal" / "qualification" / "gcp" / "live-qual.sh").read_text()
    block = text.split("INVENTORY_CLASSES=(", 1)[1].split("\n)", 1)[0]
    rows = re.findall(r'"([^"|]+)\|([^"]+)"', block)
    return {
        name: ("present" if expectation == "scope" else expectation)
        for name, expectation in rows
    }


def main() -> int:
    policy = promotion.load_teardown_policy()
    check("the policy is schema 1", policy.get("schema") == 1)
    check("the policy is named", policy.get("policy") == "sol-teardown-v1")
    check(
        "the policy binds the AWS account and region",
        policy["providers"]["aws"]["scope_fields"] == ["account", "region"],
    )
    check(
        "the policy binds the GCP project and region",
        policy["providers"]["gcp"]["scope_fields"] == ["project", "region"],
    )

    aws_expected = {name: "absent" for name in absence.RESIDUE_CLASSES}
    aws_expected["durable-hosted-zone"] = "present"
    aws_policy = policy_classes(policy, "aws")
    check(
        "the AWS policy matches every residue class plus the durable prerequisite",
        aws_policy == aws_expected,
    )
    check(
        "the AWS policy has 18 disposable classes and one durable class",
        sum(1 for expected in aws_policy.values() if expected == "absent") == 18
        and sum(1 for expected in aws_policy.values() if expected == "present") == 1,
    )

    gcp_expected = gcp_inventory_classes()
    gcp_policy = policy_classes(policy, "gcp")
    check("the GCP inventory declares 23 classes", len(gcp_expected) == 23)
    check(
        "the GCP policy matches every inventory class and its expectation",
        gcp_policy == gcp_expected,
    )
    check(
        "the GCP policy has 18 disposable classes",
        sum(1 for expected in gcp_policy.values() if expected == "absent") == 18,
    )
    for scope in ("scope-caller", "scope-project", "scope-region"):
        check(f"the GCP policy requires {scope} to be present", gcp_policy.get(scope) == "present")
    for durable in ("state-bucket", "dns-zone"):
        check(f"the GCP policy requires {durable} to be present", gcp_policy.get(durable) == "present")

    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
