#!/usr/bin/env python3
"""Fail-closed scheduler authorization contract.

These assertions pin the security-relevant shape of the Terraform roots before a live
plan exists: dedicated scheduler principals, scheduler trust, and invocation scoped to
the intended function/job. They do not claim provider behavior; the lifecycle adapter
must still verify the live grant.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def text(path):
    return (ROOT / path).read_text()


def require(fragment, haystack, what):
    if fragment not in haystack:
        raise SystemExit(f"{what}: missing {fragment!r}")


aws = text("platform/cloud/aws/authorization/main.tf")
aws_out = text("platform/cloud/aws/authorization/outputs.tf")
gcp = text("platform/cloud/gcp/authorization/main.tf")
gcp_out = text("platform/cloud/gcp/authorization/outputs.tf")
gcp_scheduler = text("cli/lib/cloud/sol_cli_gcp_scheduler.ml")

# AWS: scheduler.amazonaws.com is a scheduler-only trust principal, not the workload
# trust, and the policy names the intended alias rather than the whole account.
require('resource "aws_iam_role" "scheduler"', aws, "AWS scheduler role")
require('identifiers = ["scheduler.amazonaws.com"]', aws, "AWS scheduler trust")
require("function:${each.value.function_name}:live", aws, "AWS scoped invoke target")
require('resource "aws_iam_role_policy" "scheduler"', aws, "AWS scheduler policy")
require("lambda:InvokeFunction", aws, "AWS invoke action")
require('output "scheduler_role_arns"', aws_out, "AWS scheduler output")

# GCP: the scheduler service account is distinct from the runtime service account.
# The Cloud Run Job does not exist when the authorization root applies, so the
# scoped executor grant belongs to the scheduler deploy after the job is created.
require('resource "google_service_account" "scheduler"', gcp, "GCP scheduler account")
require('output "scheduler_service_accounts"', gcp_out, "GCP scheduler output")
if 'resource "google_cloud_run_v2_job_iam_member" "scheduler"' in gcp:
    raise SystemExit("GCP job grant must not be created before the Cloud Run Job exists")
require('"add-iam-policy-binding"', gcp_scheduler, "GCP job grant command")
require('"roles/run.jobsExecutor"', gcp_scheduler, "GCP scoped job role")
require('r.job', gcp_scheduler, "GCP job target")

# Runtime identity must not gain scheduler trust.
workload_trust = aws.split('data "aws_iam_policy_document" "workload_trust"', 1)[1]
workload_trust = workload_trust.split("resource ", 1)[0]
if "scheduler.amazonaws.com" in workload_trust:
    raise SystemExit("runtime workload trust must not include the scheduler service")

print("scheduler authorization scoping passed")
