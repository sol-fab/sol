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
  local secret_status cluster_status rds_status vpc_status verdict=PASS
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

# Read-only confirmation that the dedicated probe repository exists and is addressable
# with the caller's credentials. Push permission is exercised only in prepare.
hook_registry_preflight() {
  local repo="${QUAL_PROBE_REPOSITORY:-secret-qual-probe}"
  if aws ecr describe-repositories --repository-names "$repo" --region "$(aws_region)" \
      >"$LOG_DIR/registry-repository.json" 2>"$LOG_DIR/registry-repository.err"; then
    printf 'registry_repository=PASS name=%s\n' "$repo"
  elif grep -q 'RepositoryNotFoundException' "$LOG_DIR/registry-repository.err" 2>/dev/null; then
    printf 'registry_repository=MISSING name=%s\n' "$repo"
    return 1
  else
    printf 'registry_repository=UNKNOWN name=%s\n' "$repo"
    return 1
  fi
}

# Granular AWS plan preflight. Every line is PASS, FAIL, or UNKNOWN; common.sh turns
# any non-PASS required line into plan_preflight=BLOCKED. Nothing here mutates a
# provider or writes a remote object.
aws_plan_emit() { printf '%s\n' "$*" >>"${PLAN_FILE:?}"; }

aws_plan_role_arn() { jq -r --arg key "$1" '.aws[$key] // empty' "$LOG_DIR/target-facts.json"; }

hook_plan_preflight() {
  local rc=0 account target_account role_key role_arn role_name env workload_identity
  local wi_account wi_path plan_rc=0 plan_ref=""
  target_account="$(jq -r '.account // empty' "$LOG_DIR/target-facts.json")"
  env="$(jq -r '.environment // empty' "$LOG_DIR/target-facts.json")"

  if aws sts get-caller-identity --output json >"$LOG_DIR/aws-identity.json" \
      2>"$LOG_DIR/aws-identity.err"; then
    account="$(jq -r '.Account' "$LOG_DIR/aws-identity.json")"
    aws_plan_emit "aws_credentials=PASS account=$account arn=$(jq -r '.Arn' "$LOG_DIR/aws-identity.json")"
    if [ -n "$account" ] && [ "$account" = "$target_account" ]; then
      aws_plan_emit "aws_account=PASS target=$target_account"
    elif [ -z "$account" ]; then
      aws_plan_emit "aws_account=UNKNOWN caller account is empty"
      rc=1
    else
      aws_plan_emit "aws_account=FAIL caller=$account target=${target_account:-unset}"
      rc=1
    fi
  else
    aws_plan_emit "aws_credentials=UNKNOWN see aws-identity.err"
    aws_plan_emit "aws_account=UNKNOWN cannot read caller identity"
    account=""
    rc=1
  fi

  for role_key in provisioner_role_arn cluster_access_role_arn deploy_role_arn operator_role_arn; do
    role_arn="$(aws_plan_role_arn "$role_key")"
    role_name="${role_arn##*/}"
    if [ -z "$role_arn" ]; then
      aws_plan_emit "aws_role_${role_key}=FAIL target declares no $role_key"
      rc=1
    elif aws iam get-role --role-name "$role_name" --output json \
        >"$LOG_DIR/plan-role-${role_key}.json" 2>"$LOG_DIR/plan-role-${role_key}.err"; then
      aws_plan_emit "aws_role_${role_key}=PASS name=$role_name"
    elif grep -Eq 'NoSuchEntity|not exist' "$LOG_DIR/plan-role-${role_key}.err" 2>/dev/null; then
      aws_plan_emit "aws_role_${role_key}=FAIL name=$role_name does not exist"
      rc=1
    else
      aws_plan_emit "aws_role_${role_key}=UNKNOWN name=$role_name see plan-role-${role_key}.err"
      rc=1
    fi
  done

  local authz_arn authz_name authz_trust authz_verified=0
  authz_arn="$(aws_plan_role_arn reconciler_role_arn)"
  authz_name="${authz_arn##*/}"
  authz_trust="$(jq -r '.aws.reconciler_trust_principal_arn // empty' "$LOG_DIR/target-facts.json")"
  if [ -z "$authz_arn" ]; then
    aws_plan_emit "reconciler_role=FAIL target declares no aws.reconciler_role_arn"
    rc=1
  elif aws iam get-role --role-name "$authz_name" --output json \
      >"$LOG_DIR/plan-role-authorization.json" 2>"$LOG_DIR/plan-role-authorization.err"; then
    authz_verified=1
    aws_plan_emit "reconciler_role=PASS arn=$authz_arn"
  elif grep -Eq 'NoSuchEntity|not exist' "$LOG_DIR/plan-role-authorization.err" 2>/dev/null; then
    aws_plan_emit "reconciler_role=FAIL arn=$authz_arn does not exist; bootstrap it before grants apply"
    rc=1
  else
    aws_plan_emit "reconciler_role=UNKNOWN arn=$authz_arn see plan-role-authorization.err"
    rc=1
  fi
  if [ -z "$authz_trust" ]; then
    aws_plan_emit "reconciler_trust=FAIL target declares no aws.reconciler_trust_principal_arn"
    rc=1
  elif [ "$authz_verified" != 1 ]; then
    aws_plan_emit "reconciler_trust=UNKNOWN principal=$authz_trust role was not verified"
    rc=1
  elif python3 - "$LOG_DIR/plan-role-authorization.json" "$authz_trust" "$authz_arn" <<'PY'
import json
import sys
import urllib.parse

role = json.load(open(sys.argv[1], encoding="utf-8")).get("Role", {})
if role.get("Arn") != sys.argv[3]:
    raise SystemExit("the role ARN does not match the target declaration")
if role.get("Path") != "/sol/authorization/":
    raise SystemExit("the reconciler role is not at /sol/authorization/")
document = role.get("AssumeRolePolicyDocument", {})
if isinstance(document, str):
    try:
        document = json.loads(urllib.parse.unquote(document))
    except json.JSONDecodeError:
        pass
if sys.argv[2] not in json.dumps(document):
    raise SystemExit("the trust policy does not name the declared principal")
PY
  then
    aws_plan_emit "reconciler_trust=PASS principal=$authz_trust"
  else
    aws_plan_emit "reconciler_trust=FAIL principal=$authz_trust is not in the role trust policy"
    rc=1
  fi

  workload_identity="${QUAL_WORKLOAD_IDENTITY:-}"
  if [ -z "$workload_identity" ]; then
    aws_plan_emit "workload_identity=FAIL QUAL_WORKLOAD_IDENTITY is unset"
    rc=1
  elif [[ "$workload_identity" =~ ^arn:aws:iam::([0-9]{12}):role/(.+)$ ]]; then
    wi_account="${BASH_REMATCH[1]}"
    wi_path="${BASH_REMATCH[2]}"
    if [ "$wi_account" != "$target_account" ]; then
      aws_plan_emit "workload_identity=FAIL account=$wi_account target=$target_account"
      rc=1
    elif [[ "$wi_path" != sol/"$env"/* ]]; then
      aws_plan_emit "workload_identity=FAIL path=$wi_path expected=sol/$env/..."
      rc=1
    else
      aws_plan_emit "workload_identity=PASS arn=$workload_identity"
    fi
  else
    aws_plan_emit "workload_identity=FAIL not an IAM role ARN: $workload_identity"
    rc=1
  fi

  local state_bucket state_lock
  state_bucket="$(jq -r '.state_bucket // empty' "$LOG_DIR/target-facts.json")"
  state_lock="$(jq -r '.aws.state_lock_table // empty' "$LOG_DIR/target-facts.json")"
  if [ -n "$state_bucket" ] && aws s3api head-bucket --bucket "$state_bucket" \
      >"$LOG_DIR/plan-state-bucket.txt" 2>"$LOG_DIR/plan-state-bucket.err"; then
    aws_plan_emit "state_bucket=PASS bucket=$state_bucket"
  else
    aws_plan_emit "state_bucket=UNKNOWN bucket=${state_bucket:-unset} see plan-state-bucket.err"
    rc=1
  fi
  if [ -n "$state_lock" ] && aws dynamodb describe-table --table-name "$state_lock" \
      --region "$(aws_region)" >"$LOG_DIR/plan-state-lock.json" 2>"$LOG_DIR/plan-state-lock.err"; then
    aws_plan_emit "state_lock=PASS table=$state_lock"
  elif [ -n "$state_lock" ] && grep -Eq 'ResourceNotFoundException|not exist' \
      "$LOG_DIR/plan-state-lock.err" 2>/dev/null; then
    aws_plan_emit "state_lock=FAIL table=$state_lock does not exist"
    rc=1
  else
    aws_plan_emit "state_lock=UNKNOWN table=${state_lock:-unset} see plan-state-lock.err"
    rc=1
  fi
  local state_key state_fresh=PASS state_fresh_detail=""
  if [ -n "$state_bucket" ]; then
    for state_key in "sol/$SOL_TARGET/cloud.tfstate" "sol/$SOL_TARGET/platform.tfstate"; do
      if aws s3api head-object --bucket "$state_bucket" --key "$state_key" \
          >/dev/null 2>"$LOG_DIR/plan-state-object.err"; then
        state_fresh=FAIL
        state_fresh_detail="prior state object exists: $state_key"
        break
      elif grep -Eq '404|Not Found|NoSuchKey' "$LOG_DIR/plan-state-object.err" 2>/dev/null; then
        :
      else
        state_fresh=UNKNOWN
        state_fresh_detail="cannot read $state_key"
        break
      fi
    done
    if [ "$state_fresh" = PASS ]; then
      aws_plan_emit "state_fresh=PASS cloud/platform state keys are absent"
    else
      aws_plan_emit "state_fresh=${state_fresh} ${state_fresh_detail}"
      rc=1
    fi
  else
    aws_plan_emit "state_fresh=UNKNOWN no state bucket"
    rc=1
  fi

  if aws eks describe-cluster --name "$(aws_cluster)" --region "$(aws_region)" \
      >"$LOG_DIR/plan-existing-cluster.json" 2>"$LOG_DIR/plan-cluster.err"; then
    aws_plan_emit "cluster_fresh=FAIL cluster=$(aws_cluster) already exists"
    rc=1
  elif grep -q 'ResourceNotFoundException' "$LOG_DIR/plan-cluster.err" 2>/dev/null; then
    aws_plan_emit "cluster_fresh=PASS cluster=$(aws_cluster) is absent"
  else
    aws_plan_emit "cluster_fresh=UNKNOWN see plan-cluster.err"
    rc=1
  fi

  if aws eks describe-addon-versions --addon-name aws-secrets-store-csi-driver-provider \
      --region "$(aws_region)" \
      --query "addons[].addonVersions[?addonVersion=='v3.1.4-eksbuild.3'].addonVersion" \
      --output text >"$LOG_DIR/ascp-catalog.txt" 2>"$LOG_DIR/ascp-catalog.err"; then
    if grep -q 'v3.1.4-eksbuild.3' "$LOG_DIR/ascp-catalog.txt"; then
      aws_plan_emit "ascp_catalog=PASS version=v3.1.4-eksbuild.3"
    else
      aws_plan_emit "ascp_catalog=FAIL version=v3.1.4-eksbuild.3 is not served in $(aws_region)"
      rc=1
    fi
  else
    aws_plan_emit "ascp_catalog=UNKNOWN see ascp-catalog.err"
    rc=1
  fi

  if aws secretsmanager list-secrets --region "$(aws_region)" --max-items 1 --output json \
      >"$LOG_DIR/aws-secret-list.json" 2>"$LOG_DIR/aws-secret-list.err"; then
    aws_plan_emit "secrets_read=PASS"
  else
    aws_plan_emit "secrets_read=UNKNOWN see aws-secret-list.err"
    rc=1
  fi

  if [ -n "${QUAL_PROBE_REPOSITORY:-}" ]; then
    if aws ecr describe-repositories --repository-names "$QUAL_PROBE_REPOSITORY" \
        --region "$(aws_region)" >"$LOG_DIR/registry-repository.json" \
        2>"$LOG_DIR/registry-repository.err"; then
      aws_plan_emit "registry_repository=PASS name=$QUAL_PROBE_REPOSITORY"
    elif grep -q 'RepositoryNotFoundException' "$LOG_DIR/registry-repository.err" 2>/dev/null; then
      aws_plan_emit "registry_repository=FAIL name=$QUAL_PROBE_REPOSITORY does not exist"
      rc=1
    else
      aws_plan_emit "registry_repository=UNKNOWN name=$QUAL_PROBE_REPOSITORY"
      rc=1
    fi
    if aws ecr get-authorization-token --region "$(aws_region)" \
        --query 'authorizationData[0].authorizationToken' --output text \
        >"$LOG_DIR/registry-auth.txt" 2>"$LOG_DIR/registry-auth.err"; then
      aws_plan_emit "registry_auth=PASS"
    else
      aws_plan_emit "registry_auth=UNKNOWN see registry-auth.err"
      rc=1
    fi
  else
    aws_plan_emit "registry_repository=FAIL QUAL_PROBE_REPOSITORY is unset"
    aws_plan_emit "registry_auth=UNKNOWN repository is unset"
    rc=1
  fi

  # The scenario calls SimulatePrincipalPolicy for effective-access evidence. Use the
  # deploy role, not the not-yet-created workload role, so this tests the API permission.
  local deploy_arn deploy_name
  deploy_arn="$(aws_plan_role_arn deploy_role_arn)"
  deploy_name="${deploy_arn##*/}"
  if [ -n "$deploy_arn" ] && aws iam simulate-principal-policy \
      --policy-source-arn "$deploy_arn" \
      --action-names secretsmanager:GetSecretValue \
      --resource-arns "arn:aws:secretsmanager:$(aws_region):$target_account:secret:*" \
      --query 'EvaluationResults[0].EvalDecision' --output text \
      >"$LOG_DIR/plan-simulate.txt" 2>"$LOG_DIR/plan-simulate.err"; then
    aws_plan_emit "iam_simulate=PASS role=$deploy_name"
  else
    aws_plan_emit "iam_simulate=UNKNOWN role=$deploy_name see plan-simulate.err"
    rc=1
  fi

  # Read-only permission preflight for the authoritative absence inventory; --initial
  # permits a target whose cluster does not exist yet.
  if python3 "$ROOT/internal/qualification/aws/absence.py" capture \
      --cluster "$(aws_cluster)" --region "$(aws_region)" --account "$target_account" \
      --prior "$LOG_DIR/plan-absence-prior.json" --registry-prefix "$QUAL_REGISTRY" \
      --base-domain "$(aws_base_domain)" --retention "$(aws_retention)" \
      --attempt "$ATTEMPT" --target "$SOL_TARGET" --candidate "$SOL_CANDIDATE" \
      --initial >"$LOG_DIR/plan-absence-capture.txt" 2>&1; then
    aws_plan_emit "absence_read=PASS"
  else
    aws_plan_emit "absence_read=UNKNOWN see plan-absence-capture.txt"
    rc=1
  fi

  # A fresh target also has no leftover probe authority. Resolve the provider reference
  # through the installed candidate's plan, never by reimplementing the naming rule.
  if [ "${SCENARIO_CANDIDATE_STATUS:-FAIL}" != PASS ]; then
    aws_plan_emit "target_plan=UNKNOWN candidate is not ready"
    rc=1
  elif ( cd "${WORKSPACE:?}" && "$SOL" plan "$SOL_TARGET" --out "$LOG_DIR/plan.json" ) \
      >"$LOG_DIR/plan.log" 2>&1; then
    if python3 - "$LOG_DIR/plan.json" "$LOG_DIR/plan-service.json" "$QUAL_UNIT" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
name = sys.argv[3].split("/", 1)[1]
service = next((s for s in plan.get("services", []) if s.get("source_name") == name), None)
if service is None:
    raise SystemExit(f"plan does not contain {name}")
json.dump(service, open(sys.argv[2], "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
    then
      plan_ref="$(jq -r --arg k "$QUAL_PROBE_KEY" '.secret_sources[]? | select(.key == $k) | .reference' \
        "$LOG_DIR/plan-service.json" 2>/dev/null || true)"
    else
      plan_ref=""
    fi
    if [ -z "$plan_ref" ]; then
      aws_plan_emit "target_plan=FAIL plan carries no provider reference for $QUAL_PROBE_KEY"
      rc=1
    else
      aws_plan_emit "target_plan=PASS reference=$plan_ref"
      if aws secretsmanager describe-secret --secret-id "$plan_ref" --region "$(aws_region)" \
          >/dev/null 2>"$LOG_DIR/plan-authority.err"; then
        aws_plan_emit "probe_authority_absent=FAIL prior authority exists: $plan_ref"
        rc=1
      elif grep -q 'ResourceNotFoundException' "$LOG_DIR/plan-authority.err" 2>/dev/null; then
        aws_plan_emit "probe_authority_absent=PASS"
      else
        aws_plan_emit "probe_authority_absent=UNKNOWN see plan-authority.err"
        rc=1
      fi
    fi
  else
    aws_plan_emit "target_plan=UNKNOWN see plan.log"
    rc=1
  fi
  return "$rc"
}
