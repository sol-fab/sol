#!/usr/bin/env bash

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/internal/ci/check_destroy_completeness.py"

if [ ! -f "$guard" ]; then
  echo "test_destroy_completeness_check: guard is missing: $guard" >&2
  exit 1
fi

python3 -c 'import hcl2' 2>/dev/null || {
  echo "test_destroy_completeness_check: the guard cannot run without its dependencies," >&2
  echo "  which would read as a rejection. Run: bash internal/tooling/scripts/prepare-guard-tools.sh" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$(cd "$(dirname "$0")/../.." && pwd)"

mk() {
  mkdir -p "$tmp/$1/platform/cloud/$2/cluster"
  printf '%s\n' "$3" >"$tmp/$1/platform/cloud/$2/cluster/$4"
}

export SOL_PROVIDERS=$'aws\tpresent\ngcp\tpresent'

fail=0
expect_reject() {
  if python3 "$guard" "$tmp/$1" >/dev/null 2>&1; then
    echo "test_destroy_completeness_check: guard ACCEPTED a target root with $2." >&2
    fail=1
  fi
}
expect_accept() {
  if ! python3 "$guard" "$tmp/$1" >/dev/null 2>&1; then
    echo "test_destroy_completeness_check: guard REJECTED a repaired target root ($2)." >&2
    fail=1
  fi
}

mk newprovider azure 'resource "aws_ecr_repository" "services" {
  name = "x"
}' main.tf
SOL_PROVIDERS=$'aws\tpresent\ngcp\tpresent\nazure\tnot_implemented' expect_reject newprovider "a new provider's root that the hard-coded list never named"

mk noprinter aws '' empty.tf
if env -u SOL_PROVIDERS python3 "$guard" "$tmp/noprinter" >/dev/null 2>&1; then
  echo "test_destroy_completeness_check: guard PASSED with no provider list." >&2
  fail=1
fi

mk ecr aws 'resource "aws_ecr_repository" "services" {
  name                 = "x"
  image_tag_mutability = "MUTABLE"
}' main.tf
mk ecr gcp '' empty.tf
expect_reject ecr "an ECR repository lacking force_delete"

mk pd aws 'resource "aws_s3_bucket" "loki" {
  bucket        = "x"
  force_destroy = true

  lifecycle {
    prevent_destroy = true
  }
}' main.tf
mk pd gcp '' empty.tf
expect_reject pd "prevent_destroy in a target root"

mk gcpbucket aws '' empty.tf
mk gcpbucket gcp 'resource "google_storage_bucket" "loki" {
  name          = "x"
  force_destroy = false
}' main.tf
expect_reject gcpbucket "a GCP bucket with force_destroy = false"

mk fixed aws 'resource "aws_ecr_repository" "services" {
  name         = "x"
  force_delete = true
}

resource "aws_s3_bucket" "loki" {
  bucket        = "x"
  force_destroy = true
}' main.tf
mk fixed gcp 'resource "google_storage_bucket" "loki" {
  name          = "x"
  force_destroy = true

  soft_delete_policy {
    retention_duration_seconds = var.gcs_soft_delete_retention_seconds
  }
}' main.tf
expect_accept fixed "both providers repaired"

mk abandon aws '' empty.tf
mk abandon gcp 'resource "google_service_networking_connection" "sql" {
  network = "x"

  deletion_policy = "ABANDON"
}' main.tf
expect_reject abandon "an ABANDON deletion_policy with no residue probe"

mk skip aws 'resource "aws_cloudwatch_log_group" "x" {
  name         = "x"
  skip_destroy = true
}' main.tf
mk skip gcp '' empty.tf
expect_reject skip "a skip_destroy with no residue probe"

mk abandonok aws '' empty.tf
mk abandonok gcp 'resource "google_service_networking_connection" "sql" {
  network = "x"

  deletion_policy = "ABANDON"
}' main.tf
mkdir -p "$tmp/abandonok/cli/lib/cloud"
printf '%s\n' 'let relinquished_residue_probes = [ "google_service_networking_connection.sql", probe ]' \
  >"$tmp/abandonok/cli/lib/cloud/sol_cli_gcp_destruction.ml"
expect_accept abandonok "an ABANDON its provider's residue code probes for"

mk abandonother aws '' empty.tf
mk abandonother gcp 'resource "google_service_networking_connection" "other" {
  network = "x"

  deletion_policy = "ABANDON"
}' main.tf
mkdir -p "$tmp/abandonother/cli/lib/cloud"
printf '%s\n' 'let relinquished_residue_probes = [ "google_service_networking_connection.sql", probe ]' \
  >"$tmp/abandonother/cli/lib/cloud/sol_cli_gcp_destruction.ml"
expect_reject abandonother "an ABANDON whose address no residue probe names"

mk prevent aws '' empty.tf
mk prevent gcp 'resource "google_compute_address" "x" {
  name            = "x"
  deletion_policy = "PREVENT"
}' main.tf
expect_reject prevent "deletion_policy = \"PREVENT\""

mk skipvar aws '' empty.tf
mk skipvar gcp 'resource "google_compute_address" "x" {
  name         = "x"
  skip_destroy = var.skip_it
}' main.tf
expect_reject skipvar "a variable-driven skip_destroy"

mk dpvar aws '' empty.tf
mk dpvar gcp 'resource "google_compute_address" "x" {
  name            = "x"
  deletion_policy = var.policy
}' main.tf
expect_reject dpvar "a variable-driven deletion_policy"

mk skipdel aws 'resource "aws_s3_bucket" "loki" {
  bucket        = "x"
  force_destroy = true
  skip_delete   = true
}' main.tf
mk skipdel gcp '' empty.tf
expect_reject skipdel "a skip_delete = true with no residue probe"

mk dpdelete aws '' empty.tf
mk dpdelete gcp 'resource "google_compute_address" "x" {
  name            = "x"
  deletion_policy = "DELETE"
}' main.tf
expect_accept dpdelete "deletion_policy = \"DELETE\""

mk skipfalse aws 'resource "aws_s3_bucket" "loki" {
  bucket        = "x"
  force_destroy = true
  skip_delete   = false
}' main.tf
mk skipfalse gcp '' empty.tf
expect_accept skipfalse "skip_delete = false"

mk softnone aws '' empty.tf
mk softnone gcp 'resource "google_storage_bucket" "loki" {
  name          = "x"
  force_destroy = true
}' main.tf
expect_reject softnone "a GCS bucket with no soft_delete_policy"

mk softlit aws '' empty.tf
mk softlit gcp 'resource "google_storage_bucket" "loki" {
  name          = "x"
  force_destroy = true

  soft_delete_policy {
    retention_duration_seconds = 604800
  }
}' main.tf
expect_reject softlit "a GCS bucket with a literal soft-delete retention"

if python3 "$guard" "$tmp/does-not-exist" >/dev/null 2>&1; then
  echo "test_destroy_completeness_check: guard ACCEPTED a nonexistent root." >&2
  fail=1
fi

# Reorganization must not hide an undeletable resource from the existing guard.
for depth in 0 1 2; do
  name="module_depth_$depth"
  mk "$name" aws '' main.tf
  directory="$tmp/$name/platform/cloud/aws/cluster"
  for ((index=0; index<depth; index++)); do
    mkdir -p "$directory/nested"
    printf '%s\n' 'module "nested" { source = "./nested" }' >"$directory/module.tf"
    directory="$directory/nested"
  done
  printf '%s\n' 'resource "aws_ecr_repository" "unremovable" { name = "x" }' >"$directory/main.tf"
  expect_reject "$name" "an unremovable resource at local-module depth $depth"
  printf '%s\n' 'resource "aws_ecr_repository" "unremovable" { name = "x" force_delete = true }' >"$directory/main.tf"
  expect_accept "$name" "a removable resource at local-module depth $depth"
done

for shape in missing cycle outside expression; do
  mk "source_$shape" aws '' main.tf
  directory="$tmp/source_$shape/platform/cloud/aws/cluster"
  case "$shape" in
    missing) source='./missing' ;;
    cycle) source='./' ;;
    outside) source='../../../../../outside' ;;
    expression) source='${var.module_source}' ;;
  esac
  printf 'module "broken" { source = "%s" }\n' "$source" >"$directory/module.tf"
  expect_reject "source_$shape" "an uninspectable $shape local module"
done

# Unsupported source formats cannot silently remove a resource from coverage.
mk jsonmodule aws 'module "nested" { source = "./nested" }' main.tf
mkdir -p "$tmp/jsonmodule/platform/cloud/aws/cluster/nested"
: >"$tmp/jsonmodule/platform/cloud/aws/cluster/nested/variables.tf"
printf '%s\n' '{"resource":{"aws_ecr_repository":{"unremovable":{"name":"x"}}}}' \
  >"$tmp/jsonmodule/platform/cloud/aws/cluster/nested/main.tf.json"
expect_reject jsonmodule "an uninspected Terraform JSON resource in a local module"

mk symlinkfile aws '' main.tf
printf '%s\n' 'resource "aws_ecr_repository" "outside" { name = "x" force_delete = true }' >"$tmp/outside.tf"
ln -s "$tmp/outside.tf" "$tmp/symlinkfile/platform/cloud/aws/cluster/external.tf"
expect_reject symlinkfile "a source file outside shipped assets"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "test_destroy_completeness_check: guard rejects ECR-without-force-delete, prevent_destroy, deletion_policy = \"PREVENT\", GCP force_destroy = false, unprobed or unclassifiable relinquished deletion (ABANDON, skip_destroy, skip_delete, variable-driven forms) and undeclared or literal GCS soft delete; accepts the repaired shapes."
