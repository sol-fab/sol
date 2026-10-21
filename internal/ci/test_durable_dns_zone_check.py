#!/usr/bin/env python3
"""Mutation test for check_durable_dns_zone.

Every case here is a way the durable-zone contract has broken, or could break: a zone with no
durable owner, an owner without durable state, a target that owns what it should only read, a
target that reads unconditionally, a row that silently creates its own zone, record authority
wider than the delegated zone, a harness that would apply a destructive plan anyway, and an
absence verifier that would call the retained zone residue. Each mutation must be rejected for
its own reason, so the guard cannot pass by rejecting everything.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "internal/ci/check_durable_dns_zone.py"
COPIED_FILES = [
    "internal/ci/lib/tfconfig.py",
    "internal/qualification/aws/live-qual.sh",
    "internal/qualification/aws/qual.tfvars",
    "internal/qualification/gcp/live-qual.sh",
    "internal/qualification/gcp/qual.tfvars",
    "cli/lib/cloud/sol_cli_aws_absence.ml",
    "cli/lib/cloud/sol_cli_gcp_absence.ml",
    "cli/lib/cloud/sol_cli_installation_stage.ml",
    "cli/lib/cloud/sol_cli_terraform_plan.ml",
]
COPIED_DIRS = [
    "platform/cloud/aws/bootstrap",
    "platform/cloud/aws/cluster",
    "platform/cloud/gcp/bootstrap",
    "platform/cloud/gcp/cluster",
]


def scratch():
    tmp = Path(tempfile.mkdtemp())
    for relative in COPIED_FILES:
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / relative, target)
    for relative in COPIED_DIRS:
        shutil.copytree(ROOT / relative, tmp / relative)
    shutil.copy(GUARD, tmp / "internal/ci/check_durable_dns_zone.py")
    return tmp


def run(tmp):
    return subprocess.run(
        [sys.executable, str(tmp / "internal/ci/check_durable_dns_zone.py"), str(tmp)],
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
        "platform/cloud/aws/bootstrap/main.tf",
        'resource "aws_route53_zone" "qualification" {',
        'resource "aws_route53_zone" "qualification_renamed" {',
    )
    cases.append(("aws-durable-zone-dropped", tmp, "declares no aws_route53_zone.qualification"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/aws/bootstrap/main.tf",
        "  count = var.manage_dns_zone ? 1 : 0\n",
        "",
    )
    cases.append(("aws-durable-zone-not-gated", tmp, "manage_dns_zone"))

    tmp = scratch()
    mutate(tmp, "platform/cloud/aws/bootstrap/main.tf", '  backend "s3" {}\n\n', "")
    cases.append(("aws-durable-root-has-no-backend", tmp, "backend"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/aws/cluster/main.tf",
        """resource "aws_route53_zone" "main" {
  name  = var.base_domain
  count = var.create_route53_zone ? 1 : 0""",
        """resource "aws_route53_zone" "main" {
  name  = var.base_domain""",
    )
    cases.append(("aws-target-owns-the-zone-unconditionally", tmp, "create_route53_zone"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/aws/cluster/main.tf",
        """data "aws_route53_zone" "existing" {
  count = var.create_route53_zone ? 0 : 1""",
        """data "aws_route53_zone" "existing_removed" {
  count = var.create_route53_zone ? 0 : 1""",
    )
    cases.append(("aws-target-stops-reading-the-existing-zone", tmp, "reads no existing zone"))

    tmp = scratch()
    mutate(
        tmp,
        "internal/qualification/aws/qual.tfvars",
        "create_route53_zone = false",
        "create_route53_zone = true",
    )
    cases.append(("aws-row-creates-its-own-zone", tmp, "create_route53_zone = false"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/aws/cluster/main.tf",
        "    resources = [local.route53_zone_arn]",
        '    resources = ["arn:aws:route53:::hostedzone/*"]',
    )
    cases.append(("aws-record-authority-widened", tmp, "hostedzone/*"))

    tmp = scratch()
    # A harness that never reconciles the target leaves the durable installation unowned;
    # remove every whole-target deploy, not just the first, since any of them reconciles it.
    harness = tmp / "internal/qualification/aws/live-qual.sh"
    harness.write_text(harness.read_text().replace("deploy '$TARGET'", "plan '$TARGET'"))
    cases.append(
        (
            "aws-harness-delegates-to-whole-target-deploy",
            tmp,
            "whole-target `sol deploy",
        )
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_installation_stage.ml",
        "allows = [ Create; Update; Read; No_op ]",
        "allows = [ Create; Update; Read; No_op; Delete ]",
    )
    cases.append(("durable-root-policy-allows-delete", tmp, "must refuse delete, replace"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_aws_absence.ml",
        '      { resource_class = "Route 53 hosted zone"',
        '      { resource_class = "route53 thing"',
    )
    cases.append(("aws-absence-stops-declaring-the-zone", tmp, "Route 53 hosted zone"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/bootstrap/main.tf",
        'resource "google_dns_managed_zone" "qualification" {',
        'resource "google_dns_managed_zone" "qualification_renamed" {',
    )
    cases.append(("gcp-durable-zone-dropped", tmp, "declares no google_dns_managed_zone.qualification"))

    tmp = scratch()
    mutate(
        tmp,
        "internal/qualification/gcp/qual.tfvars",
        "create_dns_zone = false",
        "create_dns_zone = true",
    )
    cases.append(("gcp-row-creates-its-own-zone", tmp, "create_dns_zone = false"))

    for name, tmp, expected in cases:
        result = run(tmp)
        if result.returncode == 0:
            failures.append(f"{name}: accepted a broken tree")
        elif expected not in (result.stdout + result.stderr):
            failures.append(
                f"{name}: rejected, but not for the contract it breaks "
                f"(wanted {expected!r}):\n{result.stdout}{result.stderr}"
            )

    if failures:
        print("test_durable_dns_zone_check: FAILED")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print(
        "test_durable_dns_zone_check: the guard accepts the real tree and rejects "
        f"{len(cases)} mutations for their own reasons"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
