#!/usr/bin/env bash
# AWS mechanics for the provider-backed secret scenario. Every read is independent of
# Sol; every mutation goes through Sol except the disposable authority cleanup that is
# explicitly part of the teardown contract.
set -uo pipefail

aws_region() { jq -r '.region' "$LOG_DIR/target-facts.json"; }
aws_cluster() { jq -r '.cluster' "$LOG_DIR/target-facts.json"; }
aws_account() {
  local account
  account="$(jq -r '.account // empty' "$LOG_DIR/target-facts.json")"
  if [ -z "$account" ] && [ -s "$LOG_DIR/aws-identity.json" ]; then
    account="$(jq -r '.Account // empty' "$LOG_DIR/aws-identity.json")"
  fi
  printf '%s' "$account"
}
aws_base_domain() { jq -r '.base_domain // empty' "$LOG_DIR/target-facts.json"; }
aws_retention() { jq -r '.destroy_retention // "none"' "$LOG_DIR/target-facts.json"; }

hook_preflight() {
  require_env QUAL_WORKLOAD_IDENTITY
  for tool in aws kubectl docker jq curl; do
    command -v "$tool" >/dev/null 2>&1 || scenario_die "required tool $tool is not installed"
  done
  if ! aws sts get-caller-identity --output json >"$LOG_DIR/aws-identity.json" 2>"$LOG_DIR/aws-identity.err"; then
    scenario_die "aws sts get-caller-identity failed; see aws-identity.err"
  fi
  if aws eks describe-cluster --name "$(aws_cluster)" --region "$(aws_region)" \
      >"$LOG_DIR/aws-existing-cluster.json" 2>/dev/null; then
    scenario_die "cluster $(aws_cluster) already exists; this scenario requires a fresh target"
  fi
  # The add-on version is selected from the EKS catalog; refuse before creating anything
  # if the live catalog does not serve the pinned build in this region.
  aws eks describe-addon-versions --addon-name aws-secrets-store-csi-driver-provider \
    --region "$(aws_region)" \
    --query "addons[].addonVersions[?addonVersion=='v3.1.4-eksbuild.3'].addonVersion" \
    --output text >"$LOG_DIR/ascp-catalog.txt" 2>"$LOG_DIR/ascp-catalog.err" ||
    scenario_die "could not read the EKS add-on catalog; see ascp-catalog.err"
  grep -q 'v3.1.4-eksbuild.3' "$LOG_DIR/ascp-catalog.txt" ||
    scenario_die "the EKS catalog in $(aws_region) does not serve v3.1.4-eksbuild.3"
  aws secretsmanager list-secrets --region "$(aws_region)" --max-items 1 --output json \
    >"$LOG_DIR/aws-secret-list.json" 2>"$LOG_DIR/aws-secret-list.err" ||
    scenario_die "the caller cannot list Secrets Manager authorities; see aws-secret-list.err"
  printf 'identity=%s\n' "$(jq -r '.Arn' "$LOG_DIR/aws-identity.json")" >"$LOG_DIR/preflight.txt"
}

hook_cluster_exists() {
  aws eks describe-cluster --name "$(aws_cluster)" --region "$(aws_region)" >/dev/null 2>&1
}

hook_after_deploy() {
  local version
  version="$(aws eks describe-addon --cluster-name "$(aws_cluster)" --region "$(aws_region)" \
    --addon-name aws-secrets-store-csi-driver-provider \
    --query 'addon.addonVersion' --output text 2>"$LOG_DIR/addon.err")" || {
    scenario_die "could not read the ASCP add-on; see addon.err"
  }
  [ "$version" = "v3.1.4-eksbuild.3" ] ||
    scenario_die "ASCP add-on is $version, expected the pinned v3.1.4-eksbuild.3"
  kubectl get csidriver secrets-store.csi.k8s.io >/dev/null 2>&1 ||
    scenario_die "the secrets-store CSI driver is not installed"
  printf 'ascp_addon_version=%s\ncsi_driver=secrets-store.csi.k8s.io\n' "$version" \
    >"$LOG_DIR/runtime-mechanism.txt"
}

hook_assert_projection() {
  grep -Eq 'provider:[[:space:]]*"?aws"?' "$LOG_DIR/spc.yaml" ||
    scenario_die "the SecretProviderClass does not select provider aws"
  grep -Eq 'usePodIdentity:[[:space:]]*"?true"?' "$LOG_DIR/spc.yaml" ||
    scenario_die "the SecretProviderClass does not use EKS Pod Identity"
}

aws_secret_arn() {
  aws secretsmanager describe-secret --secret-id "$1" --region "$(aws_region)" \
    --query ARN --output text
}

hook_assert_authorization() {
  local mode="$1" arn decision
  arn="$(aws_secret_arn "$AUTHORITY_REFERENCE")" ||
    scenario_die "could not read the probe authority ARN"
  decision="$(aws iam simulate-principal-policy \
    --policy-source-arn "$QUAL_WORKLOAD_IDENTITY" \
    --action-names secretsmanager:GetSecretValue \
    --resource-arns "$arn" \
    --query 'EvaluationResults[0].EvalDecision' --output text 2>"$LOG_DIR/authorization-simulate.err")" || {
    scenario_die "iam:SimulatePrincipalPolicy failed; see authorization-simulate.err"
  }
  case "$mode" in
    allowed)
      [ "$decision" = allowed ] || scenario_die "the workload role cannot read its declared authority: $decision"
      ;;
    revoked)
      case "$decision" in
        implicitDeny | explicitDeny) ;;
        *) scenario_die "the workload role still reads the authority after revocation: $decision" ;;
      esac
      ;;
    restored)
      [ "$decision" = allowed ] ||
        scenario_die "the workload role did not regain the authority: $decision"
      ;;
    *) scenario_die "unknown authorization mode $mode" ;;
  esac
  printf 'mode=%s\ndecision=%s\nresource=%s\n' "$mode" "$decision" "$arn" \
    >>"$LOG_DIR/authorization.json"
}

hook_authority_metadata() {
  local ref="$1"
  aws secretsmanager describe-secret --secret-id "$ref" --region "$(aws_region)" \
    >"$LOG_DIR/authority-describe.json" 2>"$LOG_DIR/authority-describe.err" ||
    scenario_die "could not describe the provider authority; see authority-describe.err"
  aws secretsmanager list-secret-version-ids --secret-id "$ref" --region "$(aws_region)" \
    >"$LOG_DIR/authority-versions.json" 2>"$LOG_DIR/authority-versions.err" ||
    scenario_die "could not list the provider authority versions; see authority-versions.err"
}

hook_delete_authority() {
  aws secretsmanager delete-secret --secret-id "$1" --region "$(aws_region)" \
    --force-delete-without-recovery
}

# The authoritative AWS residue inventory needs an independent pre-teardown identity
# capture. Capture on the last inventory-before-teardown pass, after the workload exists.
aws_capture_prior() {
  local account
  account="$(aws_account)"
  [ -n "$account" ] || { printf 'full-inventory-capture=UNKNOWN no account\n'; return 1; }
  python3 "$ROOT/internal/qualification/aws/absence.py" capture \
    --cluster "$(aws_cluster)" --region "$(aws_region)" --account "$account" \
    --prior "$LOG_DIR/aws-absence-prior.json" \
    --registry-prefix "$QUAL_REGISTRY" --base-domain "$(aws_base_domain)" \
    --retention "$(aws_retention)" --attempt "$ATTEMPT" --target "$SOL_TARGET" \
    --candidate "$SOL_CANDIDATE" \
    ${QUAL_QUALIFIER_ARN:+--qualifier-arn "$QUAL_QUALIFIER_ARN"} \
    >"$LOG_DIR/aws-absence-capture.txt" 2>&1
}

hook_absence() {
  local secret_status cluster_status rds_status vpc_status verdict=ABSENT
  secret_status="$(aws secretsmanager describe-secret --secret-id "$1" --region "$(aws_region)" \
    >/dev/null 2>"$LOG_DIR/absence-secret.err" && echo PRESENT || echo ABSENT)"
  if grep -q 'ResourceNotFoundException' "$LOG_DIR/absence-secret.err" 2>/dev/null; then
    secret_status=ABSENT
  elif [ "$secret_status" = ABSENT ]; then
    secret_status=UNKNOWN
  fi
  cluster_status="$(aws eks describe-cluster --name "$(aws_cluster)" --region "$(aws_region)" \
    >/dev/null 2>"$LOG_DIR/absence-cluster.err" && echo PRESENT || echo ABSENT)"
  if grep -q 'ResourceNotFoundException' "$LOG_DIR/absence-cluster.err" 2>/dev/null; then
    cluster_status=ABSENT
  elif [ "$cluster_status" = ABSENT ]; then
    cluster_status=UNKNOWN
  fi
  if aws rds describe-db-instances --region "$(aws_region)" --output json \
      >"$LOG_DIR/absence-rds.json" 2>"$LOG_DIR/absence-rds.err"; then
    rds_status="$(python3 - "$LOG_DIR/absence-rds.json" "$(aws_cluster)" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8")).get("DBInstances", [])
cluster = sys.argv[2]
for item in items:
    tags = {t.get("Key"): t.get("Value") for t in item.get("TagList", [])}
    if tags.get("sol-cluster") == cluster or tags.get("kubernetes.io/cluster/" + cluster) == "owned":
        print("PRESENT")
        raise SystemExit
print("ABSENT")
PY
)"
  else
    rds_status=UNKNOWN
  fi
  if aws ec2 describe-vpcs --region "$(aws_region)" \
      --filters "Name=tag:kubernetes.io/cluster/$(aws_cluster),Values=owned" \
      --output json >"$LOG_DIR/absence-vpc.json" 2>"$LOG_DIR/absence-vpc.err"; then
    if [ "$(jq '.Vpcs | length' "$LOG_DIR/absence-vpc.json")" = 0 ]; then
      vpc_status=ABSENT
    else
      vpc_status=PRESENT
    fi
  else
    vpc_status=UNKNOWN
  fi
  for status in "$secret_status" "$cluster_status" "$rds_status" "$vpc_status"; do
    [ "$status" = ABSENT ] || verdict=FAIL
  done
  local full_status=UNKNOWN
  if [ ! -s "$LOG_DIR/aws-absence-prior.json" ]; then
    printf 'full-inventory=UNKNOWN prior identity capture is missing\n'
    verdict=FAIL
  elif python3 "$ROOT/internal/qualification/aws/absence.py" collect \
      --dir "$LOG_DIR/aws-absence" --prior "$LOG_DIR/aws-absence-prior.json" \
      --cluster "$(aws_cluster)" --region "$(aws_region)" --account "$(aws_account)" \
      --registry-prefix "$QUAL_REGISTRY" --base-domain "$(aws_base_domain)" \
      --retention "$(aws_retention)" --attempt "$ATTEMPT" --target "$SOL_TARGET" \
      --candidate "$SOL_CANDIDATE" \
      ${QUAL_QUALIFIER_ARN:+--qualifier-arn "$QUAL_QUALIFIER_ARN"} \
      >"$LOG_DIR/aws-absence-collect.txt" 2>&1; then
    full_status=ABSENT
    printf 'full-inventory=ABSENT\n'
    cat "$LOG_DIR/aws-absence/aws-inventory-verdict.txt"
  else
    full_status=NOT-ABSENT
    printf 'full-inventory=NOT-ABSENT\n'
    cat "$LOG_DIR/aws-absence/aws-inventory-verdict.txt" 2>/dev/null || true
    verdict=FAIL
  fi
  {
    printf 'absence=%s\n' "$verdict"
    printf 'secret=%s\n' "$secret_status"
    printf 'cluster=%s\n' "$cluster_status"
    printf 'rds=%s\n' "$rds_status"
    printf 'vpc=%s\n' "$vpc_status"
    printf 'full_inventory=%s\n' "$full_status"
  } >"$LOG_DIR/absence-detail.txt"
  cat "$LOG_DIR/absence-detail.txt"
  [ "$verdict" = PASS ]
}

# Read-only target inventory for the shared runner's inventory-before/after files.
# This is provider observation, not a second Sol inventory: the runner owns ordering
# and filenames; the provider owns truth.
hook_inventory() {
  local ref="${AUTHORITY_REFERENCE:-}" rc=0
  printf 'provider=aws\nregion=%s\ncluster=%s\n' "$(aws_region)" "$(aws_cluster)"
  if aws eks describe-cluster --name "$(aws_cluster)" --region "$(aws_region)" \
      >/dev/null 2>"$LOG_DIR/inventory-eks.err"; then
    printf 'eks-cluster=PRESENT\n'
  elif grep -q 'ResourceNotFoundException' "$LOG_DIR/inventory-eks.err" 2>/dev/null; then
    printf 'eks-cluster=ABSENT\n'
  else
    printf 'eks-cluster=UNKNOWN\n'
    rc=1
  fi
  if [ -z "$ref" ]; then
    printf 'probe-authority=NOT-SEEDED\n'
  elif aws secretsmanager describe-secret --secret-id "$ref" --region "$(aws_region)" \
      >/dev/null 2>"$LOG_DIR/inventory-secret.err"; then
    printf 'probe-authority=PRESENT\n'
  elif grep -q 'ResourceNotFoundException' "$LOG_DIR/inventory-secret.err" 2>/dev/null; then
    printf 'probe-authority=ABSENT\n'
  else
    printf 'probe-authority=UNKNOWN\n'
    rc=1
  fi
  if aws rds describe-db-instances --region "$(aws_region)" --output json \
      >"$LOG_DIR/inventory-rds.json" 2>"$LOG_DIR/inventory-rds.err"; then
    printf 'rds-target-owned=%s\n' "$(python3 - "$LOG_DIR/inventory-rds.json" "$(aws_cluster)" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8")).get("DBInstances", [])
cluster = sys.argv[2]
count = 0
for item in items:
    tags = {t.get("Key"): t.get("Value") for t in item.get("TagList", [])}
    if tags.get("sol-cluster") == cluster or tags.get("kubernetes.io/cluster/" + cluster) == "owned":
        count += 1
print(count)
PY
)"
  else
    printf 'rds-target-owned=UNKNOWN\n'
    rc=1
  fi
  if aws ec2 describe-vpcs --region "$(aws_region)" \
      --filters "Name=tag:kubernetes.io/cluster/$(aws_cluster),Values=owned" \
      --output json >"$LOG_DIR/inventory-vpc.json" 2>"$LOG_DIR/inventory-vpc.err"; then
    printf 'vpc-target-owned=%s\n' "$(jq '.Vpcs | length' "$LOG_DIR/inventory-vpc.json")"
  else
    printf 'vpc-target-owned=UNKNOWN\n'
    rc=1
  fi
  if [ "${SCENARIO_OWNS_TARGET:-0}" = 1 ] && [ ! -s "$LOG_DIR/aws-absence-prior.json" ]; then
    if ! aws_capture_prior; then
      printf 'full-inventory-capture=FAIL see aws-absence-capture.txt\n'
      rc=1
    else
      printf 'full-inventory-capture=CAPTURED\n'
    fi
  fi
  return "$rc"
}

# The probe image lives in a dedicated external repository; it is not a Sol target
# resource, so destroy does not remove it. Delete it only when the operator names the
# dedicated repository.
hook_cleanup_extra() {
  [ -n "${QUAL_PROBE_REPOSITORY:-}" ] || return 0
  if aws ecr describe-repositories --repository-names "$QUAL_PROBE_REPOSITORY" \
      --region "$(aws_region)" >/dev/null 2>&1; then
    aws ecr delete-repository --repository-name "$QUAL_PROBE_REPOSITORY" --force \
      --region "$(aws_region)" >/dev/null
  fi
}
