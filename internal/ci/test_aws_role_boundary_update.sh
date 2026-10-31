#!/usr/bin/env bash
# Prove with the pinned AWS provider that changing a role's permissions boundary is
# an in-place update, not a replacement. This uses synthetic state and refresh=false;
# it performs no cloud calls.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
cp "$root/platform/cloud/aws/authorization/.terraform.lock.hcl" .
cat > main.tf <<'TF'
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "5.100.0" }
  }
}
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}
resource "aws_iam_role" "role" {
  name                 = "sol-boundary-plan"
  path                 = "/sol/test/"
  permissions_boundary = "arn:aws:iam::123456789012:policy/sol-test-new-boundary"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
TF
cat > terraform.tfstate <<'JSON'
{"version":4,"terraform_version":"1.9.8","serial":1,"lineage":"00000000-0000-0000-0000-000000000001","outputs":{},"resources":[{"mode":"managed","type":"aws_iam_role","name":"role","provider":"provider[\"registry.terraform.io/hashicorp/aws\"]","instances":[{"schema_version":0,"attributes":{"id":"sol-boundary-plan","arn":"arn:aws:iam::123456789012:role/sol/test/sol-boundary-plan","name":"sol-boundary-plan","path":"/sol/test/","permissions_boundary":"arn:aws:iam::123456789012:policy/sol-test-old-boundary","assume_role_policy":"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"lambda.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}","description":"","max_session_duration":3600,"force_detach_policies":false,"managed_policy_arns":[],"inline_policy":[],"tags":null,"tags_all":{},"create_date":"2026-01-01T00:00:00Z","unique_id":"AROATEST"}}]}]}
JSON
terraform init -backend=false -input=false >/dev/null
terraform plan -refresh=false -lock=false -input=false -no-color -out=plan >/dev/null
terraform show -json plan | python3 -c '
import json,sys
p=json.load(sys.stdin)
for r in p.get("resource_changes",[]):
    if r["address"]=="aws_iam_role.role":
        a=r["change"]["actions"]
        assert a==["update"], a
        break
else:
    raise SystemExit("role change not planned")
'
echo "AWS role permissions-boundary update is in place"
