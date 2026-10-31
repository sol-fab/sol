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

# AWS: scheduler.amazonaws.com is a scheduler-only trust principal, not the workload
# trust, and the policy names the intended alias rather than the whole account.
require('resource "aws_iam_role" "scheduler"', aws, "AWS scheduler role")
require('identifiers = ["scheduler.amazonaws.com"]', aws, "AWS scheduler trust")
require("function:${each.value.function_name}:live", aws, "AWS scoped invoke target")
require('resource "aws_iam_role_policy" "scheduler"', aws, "AWS scheduler policy")
require("lambda:InvokeFunction", aws, "AWS invoke action")
require('output "scheduler_role_arns"', aws_out, "AWS scheduler output")

# GCP: the job IAM binding is the scoped grant; the scheduler service account is
# distinct from the runtime service account.
require('resource "google_service_account" "scheduler"', gcp, "GCP scheduler account")
require('resource "google_cloud_run_v2_job_iam_member" "scheduler"', gcp, "GCP job grant")
require('role     = "roles/run.jobsExecutor"', gcp, "GCP scoped job role")
require("name     = each.value.function_name", gcp, "GCP job target")
require('output "scheduler_service_accounts"', gcp_out, "GCP scheduler output")

# Runtime identity must not gain scheduler trust.
workload_trust = aws.split('data "aws_iam_policy_document" "workload_trust"', 1)[1]
workload_trust = workload_trust.split("resource ", 1)[0]
if "scheduler.amazonaws.com" in workload_trust:
    raise SystemExit("runtime workload trust must not include the scheduler service")

print("scheduler authorization scoping passed")
