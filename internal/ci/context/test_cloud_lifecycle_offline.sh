#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../qualification_assertions.sh
. "$(cd "$(dirname "$0")/.." && pwd)/qualification_assertions.sh"
# shellcheck source=../lib/stray_terraform_state.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/stray_terraform_state.sh"

root="$(git rev-parse --show-toplevel)"
export REPO_ROOT="$root"
# 2c's database setup step runs inside the deploy lifecycle and takes its image from the
# operator: a digest-pinned public Postgres, since Sol publishes no setup image of its own.
export SOL_SETUP_POSTGRES_IMAGE="postgres@sha256:ca0bd484cb98bf4b24eb1010e73fb3fcbd6714d240fbc1a10eea5b7dbecb641d"
sol="$(realpath "${1:-$root/_build/default/cli/bin/main.exe}")"
real_sol="$sol"
record_emitter="$(realpath "${2:-$root/_build/default/cli/test/print_release_record.exe}")"
tmp="$(mktemp -d)"
heredocs_open=$(grep -cE "^cat >.*<<'EOF'" "$0")
heredocs_close=$(grep -cE '^EOF$' "$0")
if [ "$heredocs_open" != "$heredocs_close" ]; then
  echo "generator heredocs are unbalanced: $heredocs_open opened, $heredocs_close closed" >&2
  echo "a generated file is likely running past its terminator, so a fixture is corrupt" >&2
  exit 1
fi
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/work/sol" "$tmp/markers"
mkdir -p "$tmp/work/app/payments/charge_svc" "$tmp/work/app/comms/notify_worker"
printf 'FROM scratch\n' >"$tmp/work/app/payments/charge_svc/Dockerfile"
printf 'FROM scratch\n' >"$tmp/work/app/comms/notify_worker/Dockerfile"
cp "$root"/internal/ci/lifecycle_fakes/* "$tmp/bin/"

cat >"$tmp/bin/sol" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
real_sol="${SOL_LIFECYCLE_REAL_SOL:?}"
workspace="${SOL_LIFECYCLE_WORKSPACE:?}"
command="${1:-}"
subcommand="${2:-}"
if [ "$command" = cloud ] && { [ "$subcommand" = apply ] || [ "$subcommand" = plan ]; }; then
  target="${3:?target required}"
  shift 3
  refs=()
  if grep -Eq '^[[:space:]]+charge_svc:' "$workspace/sol.yml"; then
    refs+=(--image-ref charge_svc=registry.example.test/charge-svc@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
  fi
  if grep -Eq '^[[:space:]]+notify_worker:' "$workspace/sol.yml"; then
    refs+=(--image-ref notify_worker=registry.example.test/notify-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
  fi
  if [ "$subcommand" = apply ]; then
    exec env POSTGRES_URL=postgresql://lifecycle:offline@localhost:5432/test \
      "$real_sol" deploy "$target" --image-tag offline-test --registry registry.example.test "${refs[@]}" "$@"
  else
    exec "$real_sol" plan "$target" "${refs[@]}" "$@"
  fi
fi
exec "$real_sol" "$@"
EOF
chmod +x "$tmp/bin/sol"

cat >"$tmp/work/sol.yml" <<'EOF'
project: lifecycle-test
resources:
  app_db:
    type: postgres
services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
    language: ocaml
  notify_worker:
    type: worker
    path: app/comms/notify_worker
    language: ocaml
EOF
cat >"$tmp/work/sol/environments.yml" <<'EOF'
prod:
  targets:
    aws/us-east-1:
      # ADR 0003: a production-profile target makes terraform_vars inject the
      # Ready/Production invariant rds_deletion_protection=true, which is exactly
      # the policy the Destroy policy must override after PrepareDestroy (finding 15).
      profile: production-single-region
      shape: durable
      base_domain: example.test
      dns_zone_ownership: sol
      cluster_name: lifecycle-test
      letsencrypt_email: ops@example.test
      cluster_endpoint_cidr: 203.0.113.0/24
      alert_receiver_type: webhook
      alert_receiver_url: https://alerts.example.test/lifecycle
      alert_owner: platform@example.test
      alert_runbook_url: https://runbooks.example.test/lifecycle
      state_bucket: lifecycle-state
      aws:
        state_lock_table: lifecycle-lock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
      resources:
        app_db:
          size: small
      secrets:
        payments/charge_svc:
          POSTGRES_URL:
            authority: sol
          SOL_API_KEY:
            authority: sol
          KAFKA_SASL_PASSWORD:
            authority: sol
          KAFKA_SSL_CA_CERT:
            authority: sol
        comms/notify_worker:
          POSTGRES_URL:
            authority: sol
          SOL_API_KEY:
            authority: sol
          KAFKA_SASL_PASSWORD:
            authority: sol
          KAFKA_SSL_CA_CERT:
            authority: sol
    gcp/us-central1:
      shape: local
      base_domain: qual.example.test
      dns_zone_ownership: sol
      cluster_name: sol-qual
      letsencrypt_email: ops@example.test
      state_bucket: sol-qualification-tfstate
      kube_context: lifecycle-test
      destroy_retention: none
      gcp:
        project_id: sol-qualification
        provisioner_impersonator: user:qualification-operator@example.test
      resources:
        app_db:
          omit: true
      secrets:
        payments/charge_svc:
          POSTGRES_URL:
            authority: sol
          SOL_API_KEY:
            authority: sol
        comms/notify_worker:
          POSTGRES_URL:
            authority: sol
          SOL_API_KEY:
            authority: sol
EOF




for generated in "$tmp/bin/aws" "$tmp/bin/terraform" "$tmp/bin/kubectl" "$tmp/bin/gcloud"; do
  [ -e "$generated" ] || continue
  if ! bash -n "$generated" 2>/dev/null; then
    echo "the generated $(basename "$generated") stub is not valid shell:" >&2
    bash -n "$generated" 2>&1 | head -3 >&2
    exit 1
  fi
done



export PATH="$tmp/bin:$PATH"
export SOL_LIFECYCLE_REAL_SOL="$real_sol"
export SOL_LIFECYCLE_WORKSPACE="$tmp/work"
sol="$tmp/bin/sol"
export SOL_HOME="$root"
export XDG_DATA_HOME="$tmp/xdg-data"
export TF_VAR_db_password=offline-only
export KUBECONFIG=/ambient/forbidden
export FAIL_MARKER_DIR="$tmp/markers"
export SOL_WHOAMI_RETRY_INTERVAL_S=0
export INSTALLATION_PRESENT=1
export KUBECONFIG_LOG="$tmp/kubeconfigs"
export RDS_PREPARED_FILE="$tmp/markers/rds-prepared"
export STATE_RM_FILE="$tmp/markers/state-rm"
export GCP_SQL_PREPARED_FILE="$tmp/markers/gcp-sql-prepared"
export GKE_PREPARED_FILE="$tmp/markers/gke-prepared"
export PLATFORM_INSTALLED_FILE="$tmp/markers/platform-installed"

run_apply() {
  (cd "$tmp/work" && LIFECYCLE_LOG="$1" "$sol" cloud apply prod/aws/us-east-1) >"$1.out" 2>&1
}

run_destroy() {
  (cd "$tmp/work" && DESTROYING=1 LIFECYCLE_LOG="$1" "$sol" destroy prod/aws/us-east-1 --apply) \
    >"$1.out" 2>&1
}

for phase in cloud outputs cloud-verify access platform-init prerequisites crds deescalate rbac platform; do
  rm -f "$tmp/markers/$phase"
  if [ "$phase" = access ]; then rm -f "$FAIL_MARKER_DIR/bootstrap-window"; fi
  log="$tmp/$phase.log"
  if (export FAIL_ON="$phase"; export ACCESS_FAIL=always; run_apply "$log"); then
    echo "cloud apply unexpectedly survived injected $phase failure" >&2
    exit 1
  fi
  if [ "$phase" = prerequisites ] || [ "$phase" = crds ]; then
    if grep -F 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* apply ' | grep -v -- '-target=' >/dev/null; then
      echo "FND-0010: a failed cert-manager gate ($phase) still ran the full platform apply:" >&2
      cat "$log.out" >&2
      exit 1
    fi
  fi
  assert_contains "the apply reported its credential principal" "$log.out" \
  "credentials: arn:aws:iam::111122223333:role/harness-qualification" || {
  echo "INFRA-039: the apply did not report the principal its credentials belong to" >&2
  exit 1
}
if [ "$phase" = access ]; then
  if ! grep -qF 'provisioner_bootstrap_admin=false' "$log"; then
    echo "INFRA-061 A: a failed whoami gate never removed the bootstrap access:" >&2
    cat "$log.out" >&2
    exit 1
  fi
  if [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null || true)" != "false" ]; then
    echo "INFRA-061 A: the bootstrap window is still open after the gate failed:" >&2
    cat "$log.out" >&2
    exit 1
  fi
fi
sts_log="$tmp/sts-unassumable.log"
if (export FAIL_ON=""; export WHOAMI_REFUSE=1; export STS_ASSUME_FAIL=1; run_apply "$sts_log"); then
  echo "a refusal with an unassumable role was accepted as de-escalation:" >&2
  cat "$sts_log.out" >&2
  exit 1
fi
grep -qF 'could not be assumed' "$sts_log.out" || {
  echo "the run failed, but not because the role could not be assumed:" >&2
  cat "$sts_log.out" >&2
  exit 1
}

successor_log="$tmp/successor-denied.log"
rm -f "$FAIL_MARKER_DIR/bootstrap-window" "$tmp/markers/access"
if (export FAIL_ON=""; export SUCCESSOR_DENIED=1; run_apply "$successor_log"); then
  echo "the run claimed a completed handoff although the durable cluster-access" >&2
  echo "identity was denied the authority the lifecycle needs next:" >&2
  cat "$successor_log.out" >&2
  exit 1
fi
grep -qF 'was not demonstrated to hold the authority' "$successor_log.out" || {
  echo "the run failed, but not because the successor's authority was undemonstrated:" >&2
  cat "$successor_log.out" >&2
  exit 1
}
if grep -qF 'de-escalation verified as' "$successor_log.out"; then
  echo "the run reported a verified de-escalation without demonstrating the successor:" >&2
  cat "$successor_log.out" >&2
  exit 1
fi
transient_log="$tmp/access-transient.log"
rm -f "$tmp/markers/access"
if ! (export FAIL_ON=access; export ACCESS_FAIL=once; run_apply "$transient_log"); then
  echo "a transient access failure failed the run instead of being retried through:" >&2
  cat "$transient_log.out" >&2
  exit 1
fi
grep -qF 'not reachable yet' "$transient_log.out" || {
  echo "the run survived an injected access failure without ever retrying, so this scenario" >&2
  echo "did not exercise the retry path at all:" >&2
  cat "$transient_log.out" >&2
  exit 1
}

if ! (export FAIL_ON=""; run_apply "$log"); then
    cat "$log" >&2
    cat "$log.out" >&2
    echo "cloud apply did not resume after injected $phase failure" >&2
    exit 1
  fi
done

can_i_log="$tmp/can-i-indeterminate.log"
rm -f "$FAIL_MARKER_DIR/bootstrap-window"
if (export FAIL_ON=""; export CAN_I_FAIL=1; run_apply "$can_i_log"); then
  echo "a non-authorization can-i failure was accepted as de-escalation:" >&2
  cat "$can_i_log.out" >&2
  exit 1
fi
grep -qF 'no usable answer' "$can_i_log.out" || {
  echo "the run failed, but not because the capability probe was indeterminate:" >&2
  cat "$can_i_log.out" >&2
  exit 1
}

indeterminate_window_log="$tmp/window-indeterminate.log"
rm -f "$FAIL_MARKER_DIR/bootstrap-window"
if (export FAIL_ON=""; export CAN_I_INDETERMINATE_WHEN_OPEN=1; run_apply "$indeterminate_window_log"); then
  echo "an indeterminate window probe did not stop the run:" >&2
  cat "$indeterminate_window_log.out" >&2
  exit 1
fi
grep -qF 'indeterminate probe' "$indeterminate_window_log.out" || {
  echo "the run did not report why the window could not be established:" >&2
  cat "$indeterminate_window_log.out" >&2
  exit 1
}
if grep -qF 'platform-apply' "$indeterminate_window_log.out"; then
  echo "the run reached the platform install despite an indeterminate window probe:" >&2
  cat "$indeterminate_window_log.out" >&2
  exit 1
fi
if [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null || true)" != "false" ]; then
  echo "the indeterminate-window failure left the bootstrap window open:" >&2
  cat "$indeterminate_window_log.out" >&2
  exit 1
fi

rm -f "$tmp/markers/readiness"
log="$tmp/readiness-transient.log"
if ! (export FAIL_ON=readiness; run_apply "$log"); then
  cat "$log.out" >&2
  echo "a transient unmet readiness sample failed the install instead of being waited out" >&2
  exit 1
fi
grep -F 'awaiting platform readiness' "$log.out" >/dev/null || {
  echo "an unmet readiness sample was not reported while waiting:" >&2
  cat "$log.out" >&2
  exit 1
}
grep -F 'lifecycle phase: Ready' "$log.out" >/dev/null || {
  echo "the install did not reach Ready after a transient unmet readiness sample:" >&2
  cat "$log.out" >&2
  exit 1
}

log="$tmp/readiness-persistent.log"
if (export FAIL_READINESS_ALWAYS=1 SOL_PLATFORM_READINESS_TIMEOUT_S=0; run_apply "$log"); then
  echo "cloud apply succeeded although the platform never became ready" >&2
  exit 1
fi
grep -F 'platform readiness Unobservable' "$log.out" >/dev/null || {
  echo "a platform readiness probe failure was not reported as unobservable:" >&2
  cat "$log.out" >&2
  exit 1
}
if grep -F 'platform readiness Unmet' "$log.out" >/dev/null; then
  echo "an unobservable readiness probe was reported as a confirmed unmet condition:" >&2
  cat "$log.out" >&2
  exit 1
fi

log="$tmp/storage-class-wrong.log"
if (export STORAGE_CLASS_WRONG=1 SOL_PLATFORM_READINESS_TIMEOUT_S=0; run_apply "$log"); then
  echo "cloud apply reached Ready although the default StorageClass was not the platform's" >&2
  cat "$log.out" >&2
  exit 1
fi
grep -F 'default StorageClass' "$log.out" >/dev/null || {
  echo "a wrong default StorageClass did not name the unmet check:" >&2
  cat "$log.out" >&2
  exit 1
}
grep -F 'ebs.csi.aws.com' "$log.out" >/dev/null || {
  echo "the unmet storage check did not name the driver the platform requires:" >&2
  cat "$log.out" >&2
  exit 1
}
if grep -F 'lifecycle phase: Ready' "$log.out" >/dev/null; then
  echo "a wrong default StorageClass still reported Ready:" >&2
  cat "$log.out" >&2
  exit 1
fi

log="$tmp/success.log"
(export FAIL_ON=""; run_apply "$log")
grep -F 'key=sol/prod/aws/us-east-1/cloud.tfstate' "$log" >/dev/null
grep -F 'key=sol/prod/aws/us-east-1/platform.tfstate' "$log" >/dev/null
grep -F -- '-target=module.platform.helm_release.cert_manager' "$log" >/dev/null
grep -F 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* apply ' | grep -v -- '-target=' >/dev/null
grep -F -- '-var=deploy_role_arn=arn:aws:iam::111122223333:role/sol-deploy' "$log" >/dev/null
grep -F 'env KUBE_CONFIG_PATH=' "$log" >/dev/null
grep -F 'env KUBE_CONFIG_PATHS=' "$log" >/dev/null
full_apply_line="$(grep -nF 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* apply ' | grep -v -- '-target=' | head -1 | cut -d: -f1 || true)"
deescalate_line="$(grep -nF -- 'provisioner_bootstrap_admin=false' "$log" | head -1 | cut -d: -f1 || true)"
if [ -z "$full_apply_line" ] || [ -z "$deescalate_line" ] || [ "$full_apply_line" -ge "$deescalate_line" ]; then
  echo "the platform install must complete before provisioner de-escalation" >&2
  exit 1
fi
while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"

# Operational duration overrides are validated through one shared parser before
# any cloud mutation. A malformed or unbounded value refuses and names the
# setting instead of silently selecting a different policy.
for bad in abc inf -1 nan; do
  readiness_log="$tmp/readiness-override-$bad.log"
  if (export FAIL_ON="" SOL_PLATFORM_READINESS_TIMEOUT_S="$bad"; run_apply "$readiness_log"); then
    echo "an apply accepted SOL_PLATFORM_READINESS_TIMEOUT_S=$bad" >&2
    cat "$readiness_log.out" >&2
    exit 1
  fi
  assert_contains "the refusal names the readiness override" "$readiness_log.out" \
    "SOL_PLATFORM_READINESS_TIMEOUT_S=\"$bad\" is not a non-negative number of seconds" || exit 1
  if grep -E '^terraform .* apply( |$)' "$readiness_log" >/dev/null 2>&1; then
    echo "terraform apply ran despite the refused SOL_PLATFORM_READINESS_TIMEOUT_S=$bad" >&2
    cat "$readiness_log" >&2
    exit 1
  fi
done
echo "REFAC-115: a malformed or unbounded readiness override refuses before the apply"

for bad in abc inf -1 nan; do
  whoami_log="$tmp/whoami-override-$bad.log"
  rm -f "$FAIL_MARKER_DIR/bootstrap-window" "$tmp/markers/access"
  if (export FAIL_ON="" SOL_WHOAMI_RETRY_INTERVAL_S="$bad"; run_apply "$whoami_log"); then
    echo "an apply accepted SOL_WHOAMI_RETRY_INTERVAL_S=$bad" >&2
    cat "$whoami_log.out" >&2
    exit 1
  fi
  assert_contains "the refusal names the whoami override" "$whoami_log.out" \
    "SOL_WHOAMI_RETRY_INTERVAL_S=\"$bad\" is not a non-negative number of seconds" || exit 1
  if grep -F 'terraform ' "$whoami_log" | grep 'cloud/[a-z]*/platform.* apply ' \
      | grep -v -- '-target=' >/dev/null; then
    echo "the platform apply ran despite the refused SOL_WHOAMI_RETRY_INTERVAL_S=$bad" >&2
    cat "$whoami_log" >&2
    exit 1
  fi
done
echo "REFAC-115: a malformed or unbounded whoami override refuses before the platform apply"

credential_log="$tmp/platform-credential-absent.log"
rm -f "$PLATFORM_INSTALLED_FILE"
if (export FAIL_ON=""; export PLATFORM_CREDENTIAL_ABSENT=1; run_apply "$credential_log"); then
  cat "$credential_log.out" >&2
  echo "cloud apply succeeded although an operator-supplied platform credential was absent" >&2
  exit 1
fi
grep -F 'redpanda-users' "$credential_log.out" >/dev/null || {
  echo "the missing platform credential refusal did not name the Secret:" >&2
  cat "$credential_log.out" >&2
  exit 1
}
grep -F -- 'create secret generic redpanda-users -n redpanda' "$credential_log.out" \
  >/dev/null || {
  echo "the refusal did not show how the operator supplies the credential out of band:" >&2
  cat "$credential_log.out" >&2
  exit 1
}
if grep -F 'terraform ' "$credential_log" | grep 'cloud/[a-z]*/platform.* apply ' \
    | grep -v -- '-target=' >/dev/null; then
  echo "the whole-root platform apply ran although the operator-supplied credential was absent:" >&2
  cat "$credential_log" >&2
  exit 1
grep -F 'lifecycle-test-deploy' "$credential_log.out" >/dev/null || {
  echo "the missing platform credential refusal did not say how to reach the cluster:" >&2
  cat "$credential_log.out" >&2
  exit 1
}
fi
grep -F 'the platform install cannot start:' "$credential_log.out" >/dev/null || {
  echo "the apply did not report the missing credential as the install's own error:" >&2
  cat "$credential_log.out" >&2
  exit 1
}
if grep -qF '[platform-apply] FAILED' "$credential_log.out"; then
  echo "the missing credential reached the platform apply and was reported as a timeout:" >&2
  cat "$credential_log.out" >&2
  exit 1
fi
if ! grep -F -- 'provisioner_bootstrap_admin=false' "$credential_log" >/dev/null; then
  echo "the missing-credential refusal left the bootstrap window open:" >&2
  grep -nE 'provisioner_bootstrap_admin|redpanda-users' "$credential_log" >&2 || true
  exit 1
fi

unverifiable_log="$tmp/platform-credential-unverifiable.log"
rm -f "$PLATFORM_INSTALLED_FILE"
if (export FAIL_ON=""; export PLATFORM_CREDENTIAL_UNVERIFIABLE=1; run_apply "$unverifiable_log"); then
  cat "$unverifiable_log.out" >&2
  echo "cloud apply succeeded although the credential check could not reach the cluster" >&2
  exit 1
fi
grep -F 'could not establish whether the operator-supplied Secret' \
  "$unverifiable_log.out" >/dev/null || {
  echo "a failed credential check was not distinguished from an absent Secret:" >&2
  cat "$unverifiable_log.out" >&2
  exit 1
}
if grep -F 'is absent from namespace' "$unverifiable_log.out" >/dev/null; then
  echo "an unverifiable credential check was reported as a positively absent Secret:" >&2
  cat "$unverifiable_log.out" >&2
  exit 1
fi
if grep -F 'terraform ' "$unverifiable_log" | grep 'cloud/[a-z]*/platform.* apply ' \
    | grep -v -- '-target=' >/dev/null; then
  echo "the whole-root platform apply ran although the credential check failed:" >&2
  cat "$unverifiable_log" >&2
  exit 1
fi

fresh_log="$tmp/phase-fresh.log"
rm -f "$PLATFORM_INSTALLED_FILE"
if ! (export FAIL_ON=""; export FRESH_TARGET=1; run_apply "$fresh_log"); then
  cat "$fresh_log" >&2
  cat "$fresh_log.out" >&2
  echo "cloud apply did not complete a first install" >&2
  exit 1
fi
grep -F 'lifecycle phase: PlatformInstalling' "$fresh_log.out" >/dev/null || {
  echo "a first install did not report PlatformInstalling:" >&2
  cat "$fresh_log.out" >&2
  exit 1
}
grep -F 'lifecycle phase: Ready' "$fresh_log.out" >/dev/null || {
  echo "a completed install did not report Ready:" >&2
  cat "$fresh_log.out" >&2
  exit 1
}

update_log="$tmp/phase-update.log"
if ! (export FAIL_ON=""; export FRESH_TARGET=1; run_apply "$update_log"); then
  cat "$update_log" >&2
  cat "$update_log.out" >&2
  echo "cloud apply did not complete a re-apply" >&2
  exit 1
fi
grep -F 'lifecycle phase: PlatformUpdating' "$update_log.out" >/dev/null || {
  echo "a re-apply of an installed target did not report PlatformUpdating:" >&2
  cat "$update_log.out" >&2
  exit 1
}
grep -F 'lifecycle phase: PlatformInstalling' "$update_log.out" >/dev/null && {
  echo "a re-apply of an installed target was misclassified as PlatformInstalling" >&2
  exit 1
}

bootstrap_log="$tmp/phase-bootstrap.log"
if (export OUTPUT_ABSENT=1; run_apply "$bootstrap_log"); then
  echo "an apply with no cloud substrate reported success and must not" >&2
  exit 1
fi
grep -F 'lifecycle phase: CloudBootstrap' "$bootstrap_log.out" >/dev/null || {
  echo "a target with no cloud substrate did not report CloudBootstrap:" >&2
  cat "$bootstrap_log.out" >&2
  exit 1
}

plan() {
  local log="$1"
  shift
  (cd "$tmp/work" && env LIFECYCLE_LOG="$log" "$@" "$sol" cloud plan prod/aws/us-east-1) \
    >"$log.out" 2>&1
}

no_plan_mutation() {
  local log="$1"
  if grep -Eq 'terraform .*( apply | destroy )|kubectl (apply|delete|create|patch|replace|scale|annotate|label|set )|aws .*( create-| delete-| modify-| put-| terminate-| run-)' "$log"; then
    echo "cloud plan mutated or attempted a mutation:" >&2
    cat "$log" >&2
    exit 1
  fi
}

log="$tmp/plan-absent.log"
if ! plan "$log" OUTPUT_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan on an absent target must exit zero with Deferred phases" >&2
  exit 1
fi
grep -F 'requires cloud substrate to exist' "$log.out" >/dev/null
no_plan_mutation "$log"

log="$tmp/plan-rbac.log"
if ! plan "$log" RBAC_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan before provisioner RBAC must exit zero with Deferred phases" >&2
  exit 1
fi
grep -F 'requires provisioner platform RBAC established by an earlier apply' "$log.out" >/dev/null
if grep -F 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* plan ' >/dev/null; then
  echo "cloud plan planned the platform before its provisioner RBAC existed" >&2
  exit 1
fi
no_plan_mutation "$log"

log="$tmp/plan-auth.log"
if plan "$log" AUTH_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan must exit non-zero when the provisioner cannot authenticate" >&2
  exit 1
fi
grep -F 'could not authenticate to the cluster as the platform provisioner' "$log.out" >/dev/null
no_plan_mutation "$log"

log="$tmp/plan-prereq.log"
if ! plan "$log" CRDS_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan with CRDs not established must exit zero with a Deferred substrate" >&2
  exit 1
fi
grep -F 'requires cert-manager CRDs to be Established' "$log.out" >/dev/null
grep -F -- '-target=module.platform.helm_release.cert_manager' "$log" >/dev/null
if grep -F 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* plan ' | grep -v -- '-target=' >/dev/null; then
  echo "cloud plan previewed CRD-dependent platform before its CRDs were Established" >&2
  exit 1
fi
no_plan_mutation "$log"

log="$tmp/plan-full.log"
if ! plan "$log"; then
  cat "$log.out" >&2
  echo "cloud plan on an established target must exit zero" >&2
  exit 1
fi
grep -F -- '-target=module.platform.helm_release.cert_manager' "$log" >/dev/null
if grep -F 'terraform ' "$log" | grep 'cloud/[a-z]*/platform.* plan ' \
    | grep -v -- '-target=' >/dev/null; then
  echo "cloud plan planned the whole-root platform although no installation window is open:" >&2
  cat "$log" >&2
  exit 1
fi
grep -F 'requires the installation window that `sol deploy` opens' "$log.out" >/dev/null || {
  echo "cloud plan did not report the whole-root platform deferred on the installation window:" >&2
  cat "$log.out" >&2
  exit 1
}
grep -F 'DEFERRED' "$log.out" >/dev/null || {
  echo "cloud plan did not report the deferred whole-root platform phase:" >&2
  cat "$log.out" >&2
  exit 1
}
no_plan_mutation "$log"

window_log="$tmp/plan-window-open.log"
if ! (export WINDOW_OPEN=1; plan "$window_log"); then
  cat "$window_log.out" >&2
  echo "cloud plan failed while the installation window was open" >&2
  exit 1
fi
grep -F 'terraform ' "$window_log" | grep 'cloud/[a-z]*/platform.* plan ' \
  | grep -v -- '-target=' >/dev/null || {
  echo "cloud plan did not plan the whole-root platform while the window was open:" >&2
  cat "$window_log" >&2
  exit 1
}
if grep -F 'DEFERRED' "$window_log.out" >/dev/null; then
  echo "cloud plan deferred a phase while the installation window was open:" >&2
  cat "$window_log.out" >&2
  exit 1
fi
no_plan_mutation "$window_log"

retry_fail_log="$tmp/retry-platform-failure.log"
rm -f "$FAIL_MARKER_DIR/platform"
if (export FAIL_ON=platform; run_apply "$retry_fail_log"); then
  echo "the injected platform failure did not fail the apply" >&2
  cat "$retry_fail_log.out" >&2
  exit 1
fi
retry_plan_log="$tmp/retry-plan.log"
if ! plan "$retry_plan_log"; then
  cat "$retry_plan_log.out" >&2
  echo "cloud plan after a failed platform install must exit zero, not fail on authorization" >&2
  exit 1
fi
if grep -Fi 'forbidden' "$retry_plan_log.out" >/dev/null; then
  echo "cloud plan after a failed platform install surfaced an authorization failure:" >&2
  cat "$retry_plan_log.out" >&2
  exit 1
fi
grep -F 'requires the installation window that `sol deploy` opens' \
  "$retry_plan_log.out" >/dev/null || {
  echo "the retry plan did not name the installation window as the deferred prerequisite:" >&2
  cat "$retry_plan_log.out" >&2
  exit 1
}
retry_resume_log="$tmp/retry-resume.log"
if ! (export FAIL_ON=""; run_apply "$retry_resume_log"); then
  cat "$retry_resume_log.out" >&2
  echo "cloud apply did not resume after the failed platform install" >&2
  exit 1
fi
grep -F 'lifecycle phase: Ready' "$retry_resume_log.out" >/dev/null || {
  echo "the resumed apply did not reach Ready:" >&2
  cat "$retry_resume_log.out" >&2
  exit 1
}
grep -F -- 'provisioner_bootstrap_admin=true' "$retry_resume_log" >/dev/null || {
  echo "the resumed apply did not reopen the temporary installation window:" >&2
  cat "$retry_resume_log" >&2
  exit 1
}

log="$tmp/plan-fail.log"
rm -f "$tmp/markers/plan"

cred_log="$tmp/credentials.log"
if (export FAIL_CREDENTIALS=1; run_apply "$cred_log"); then
  echo "credential failure: apply survived unresolvable credentials" >&2
  exit 1
fi
assert_contains "credentials named the operation" "$cred_log.out" \
  'cannot resolve AWS credentials before applying' || {
  echo "credential failure: the error does not name the operation:" >&2
  cat "$cred_log.out" >&2
  exit 1
}
assert_contains "credentials stated nothing changed" "$cred_log.out" \
  'Nothing has been changed' || {
  echo "credential failure: the error does not state that nothing was changed" >&2
  cat "$cred_log.out" >&2
  exit 1
}
assert_not_contains "no apply stage ran" "$cred_log.out" '[terraform-apply] ok' || {
  echo "credential failure: an apply stage ran despite unresolvable credentials" >&2
  exit 1
}

if plan "$log" FAIL_ON=plan; then
  cat "$log.out" >&2
  echo "cloud plan must exit non-zero when a plannable phase fails" >&2
  exit 1
fi

while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"

gcp_log="$tmp/gcp-plan.log"
rm -f "$tmp/markers/gcp-prepare" "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE"
if ! (cd "$tmp/work" && LIFECYCLE_LOG="$gcp_log" "$sol" cloud plan prod/gcp/us-central1) \
  >"$gcp_log.out" 2>&1
then
  cat "$gcp_log.out" >&2
  echo "cloud plan on GCP failed" >&2
  exit 1
fi
grep -F 'kubectl --context lifecycle-test get deployment -A -o json' "$gcp_log" >/dev/null || {
  echo "GCP plan did not inspect the live target workload set:" >&2
  cat "$gcp_log" >&2
  exit 1
}
grep -E -- '-chdir=[^ ]*cloud/gcp/cluster plan ' "$gcp_log" >/dev/null || {
  echo "GCP target plan did not plan its infrastructure:" >&2
  cat "$gcp_log" >&2
  exit 1
}
if grep -E -- '-chdir=[^ ]*cloud/gcp/cluster apply ' "$gcp_log" >/dev/null; then
  echo "read-only GCP target plan unexpectedly applied infrastructure:" >&2
  grep -E -- '-chdir=[^ ]*cloud/gcp/cluster apply ' "$gcp_log" >&2
  exit 1
fi
while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"

# The workspace's recorded UID evidence: owned_workloads.tsv is the one source for the
# identities the fake reports as live and the record this seeds carries, so the removal match
# cannot be accidental.
seeded_configmaps="$tmp/seeded-release"
mkdir -p "$seeded_configmaps"
own_args=()
while IFS=$'\t' read -r resource namespace name uid; do
  case "$resource" in "" | \#*) continue ;; esac
  own_args+=(--own "$resource:$namespace:$name:$uid")
done <"$root/internal/ci/lifecycle_fakes/owned_workloads.tsv"
"$record_emitter" --workspace work --out "$seeded_configmaps" "${own_args[@]}" >/dev/null

release_log="$tmp/release-destroy.log"
if ! (cd "$tmp/work" && DESTROYING=1 WORKSPACE_PODS=1 \
        FAKE_CONFIGMAP_DIR="$seeded_configmaps" LIFECYCLE_LOG="$release_log" \
        "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$release_log.out" 2>&1
then
  cat "$release_log.out" >&2
  echo "destroy with deployed workloads failed (FND-0077)" >&2
  exit 1
fi
grep -F 'Releasing the application workloads' "$release_log.out" >/dev/null || {
  echo "the destroy did not report releasing the workloads:" >&2
  cat "$release_log.out" >&2
  exit 1
}
if grep -F -- '--all-namespaces' "$release_log" >/dev/null; then
  echo "the destroy read the cluster rather than the declared namespaces:" >&2
  grep -F 'kubectl' "$release_log" >&2
  exit 1
fi
for namespace in work-payments work-comms; do
  for kind in deployment cronjob job rollout; do
    grep -F "get $kind -n $namespace" "$release_log" >/dev/null || {
      echo "the destroy did not read $kind workloads in $namespace:" >&2
      grep -F 'kubectl' "$release_log" >&2
      exit 1
    }
  done
  grep -F "wait --for=delete pod -n $namespace" "$release_log" >/dev/null || {
    echo "the destroy did not wait for $namespace's pods to go:" >&2
    grep -F 'kubectl' "$release_log" >&2
    exit 1
  }
done
if grep -F 'could not be released' "$release_log.out" >/dev/null; then
  echo "a cluster that does not serve the Rollouts custom resource failed the release" >&2
  echo "instead of releasing the workload kinds that are there (FND-0079):" >&2
  cat "$release_log.out" >&2
  exit 1
fi
grep -F 'delete deployment/charge-svc -n work-payments' "$release_log" >/dev/null || {
  echo "the destroy did not delete the workload it found:" >&2
  grep -F 'kubectl' "$release_log" >&2
  exit 1
}
if grep -F 'delete deployment,cronjob,job' "$release_log" >/dev/null; then
  echo "the destroy selected the workload objects by a label they do not carry (FND-0077):" >&2
  grep -F 'kubectl' "$release_log" >&2
  exit 1
fi
delete_line="$(grep -n -m1 'delete deployment/charge-svc -n work-payments' "$release_log" | cut -d: -f1)"
wait_line="$(grep -n -m1 'wait --for=delete pod -n work-payments' "$release_log" | cut -d: -f1)"
if [ -z "$delete_line" ] || [ -z "$wait_line" ] || [ "$delete_line" -ge "$wait_line" ]; then
  echo "the destroy waited for the pods before it removed the workloads that own them (delete=$delete_line wait=$wait_line):" >&2
  grep -nE 'delete deployment/charge-svc|wait --for=delete pod -n work-payments' "$release_log" >&2
  exit 1
fi
substrate_line="$(
  grep -nE -- '-chdir=[^ ]*cloud/gcp/cluster destroy ' "$release_log" | head -1 | cut -d: -f1
)"
if [ -z "$substrate_line" ] || [ "$wait_line" -ge "$substrate_line" ]; then
  echo "the pods were not gone before the substrate was destroyed (wait=$wait_line substrate=$substrate_line):" >&2
  grep -nE 'delete deployment/charge-svc|wait --for=delete pod|cloud/gcp/cluster .* destroy ' "$release_log" >&2
  exit 1
fi

# The same destroy with no seeded record: no recorded UID evidence means the workloads are
# retained and reported, never deleted (docs/architecture/ownership.md) — and the substrate
# destroy still proceeds, because Sol retaining an object it cannot prove it owns must not
# block tearing down the target.
retain_log="$tmp/release-retain-destroy.log"
if ! (cd "$tmp/work" && DESTROYING=1 WORKSPACE_PODS=1 \
        LIFECYCLE_LOG="$retain_log" \
        "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$retain_log.out" 2>&1
then
  cat "$retain_log.out" >&2
  echo "destroy with no recorded evidence failed instead of retaining the workloads" >&2
  exit 1
fi
grep -F 'retaining' "$retain_log.out" >/dev/null || {
  echo "the destroy did not report that it retained workloads it cannot prove it owns:" >&2
  cat "$retain_log.out" >&2
  exit 1
}
grep -F 'deployment/charge-svc' "$retain_log.out" >/dev/null || {
  echo "the retained workloads were not named for the operator:" >&2
  cat "$retain_log.out" >&2
  exit 1
}
if grep -E 'delete (deployment|rollout|cronjob|job)/' "$retain_log" >/dev/null; then
  echo "the destroy deleted a workload without recorded UID evidence:" >&2
  grep -F 'kubectl' "$retain_log" >&2
  exit 1
fi
grep -E -- 'cloud/gcp/cluster destroy ' "$retain_log" >/dev/null || {
  echo "the destroy did not proceed to the substrate after retaining the workloads:" >&2
  grep -F 'terraform' "$retain_log" >&2
  exit 1
}

rollout_log="$tmp/rollout-destroy.log"
if ! (cd "$tmp/work" && DESTROYING=1 WORKSPACE_PODS=1 ROLLOUT_SERVED=1 \
        FAKE_CONFIGMAP_DIR="$seeded_configmaps" LIFECYCLE_LOG="$rollout_log" \
        "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$rollout_log.out" 2>&1
then
  cat "$rollout_log.out" >&2
  echo "destroy with a progressive-delivery Rollout failed (FND-0079)" >&2
  exit 1
fi
grep -F 'rollout/charge-canary' "$rollout_log" >/dev/null || {
  echo "the destroy did not remove the Rollout it found (FND-0079):" >&2
  grep -F 'kubectl' "$rollout_log" >&2
  exit 1
}
if grep -F 'could not be released' "$rollout_log.out" >/dev/null; then
  echo "the release failed on a cluster that serves the Rollouts custom resource (FND-0079):" >&2
  cat "$rollout_log.out" >&2
  exit 1
fi
rollout_delete_line="$(grep -n -m1 'rollout/charge-canary' "$rollout_log" | cut -d: -f1)"
rollout_wait_line="$(grep -n -m1 'wait --for=delete pod -n work-payments' "$rollout_log" | cut -d: -f1)"
if [ -z "$rollout_delete_line" ] || [ -z "$rollout_wait_line" ] ||
  [ "$rollout_delete_line" -ge "$rollout_wait_line" ]; then
  echo "the Rollout was not removed before its pods were awaited (delete=$rollout_delete_line wait=$rollout_wait_line):" >&2
  grep -nE 'rollout/charge-canary|wait --for=delete pod -n work-payments' "$rollout_log" >&2
  exit 1
fi


rm -f "$FAIL_MARKER_DIR/pods-released"
release_fail_log="$tmp/release-fail-destroy.log"
if (cd "$tmp/work" && DESTROYING=1 WORKSPACE_PODS=1 RELEASE_DELETE_FAILS=1 \
      DATABASE_REFUSES_UNRELEASED=1 \
      FAKE_CONFIGMAP_DIR="$seeded_configmaps" \
      LIFECYCLE_LOG="$release_fail_log" \
      "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$release_fail_log.out" 2>&1
then
  cat "$release_fail_log.out" >&2
  echo "a destroy that cannot establish the release must stop, not finish (DEC-059)" >&2
  exit 1
fi
grep -F 'the application workloads could not be established as released' \
  "$release_fail_log.out" >/dev/null || {
  echo "the destroy did not report why it stopped:" >&2
  cat "$release_fail_log.out" >&2
  exit 1
}
grep -F 'removing the workloads it found failed' "$release_fail_log.out" >/dev/null || {
  echo "the stop did not name the operation that failed (DEC-059):" >&2
  cat "$release_fail_log.out" >&2
  exit 1
}
grep -F -- '--accept-unreleased' "$release_fail_log.out" >/dev/null || {
  echo "the stop did not offer the explicit override:" >&2
  cat "$release_fail_log.out" >&2
  exit 1
}
if grep -E -- 'cloud/gcp/(cluster|platform) destroy ' "$release_fail_log" >/dev/null; then
  echo "the stop destroyed part of the target anyway (DEC-059):" >&2
  grep -F 'terraform' "$release_fail_log" >&2
  exit 1
fi
if grep -F 'verified absence' "$release_fail_log.out" >/dev/null; then
  echo "the stop claimed absence it did not establish:" >&2
  cat "$release_fail_log.out" >&2
  exit 1
fi

rm -f "$FAIL_MARKER_DIR/pods-released"
override_log="$tmp/release-override-destroy.log"
if (cd "$tmp/work" && DESTROYING=1 WORKSPACE_PODS=1 RELEASE_DELETE_FAILS=1 \
      DATABASE_REFUSES_UNRELEASED=1 \
      FAKE_CONFIGMAP_DIR="$seeded_configmaps" \
      LIFECYCLE_LOG="$override_log" \
      "$sol" destroy prod/gcp/us-central1 --apply --accept-unreleased) \
  >"$override_log.out" 2>&1
then
  cat "$override_log.out" >&2
  echo "a destroy whose database drop was refused must not report success (DEC-059)" >&2
  exit 1
fi
grep -E -- 'cloud/gcp/cluster destroy ' "$override_log" >/dev/null || {
  echo "the override did not proceed to the substrate destroy:" >&2
  grep -F 'terraform' "$override_log" >&2
  exit 1
}
grep -F 'are not released' "$override_log.out" >/dev/null || {
  echo "the override did not record that it destroyed with the workloads unreleased:" >&2
  cat "$override_log.out" >&2
  exit 1
}
grep -F 'is being accessed by other users' "$override_log.out" >/dev/null || {
  echo "the scenario did not reproduce FND-0077's refusal:" >&2
  cat "$override_log.out" >&2
  exit 1
}
if grep -F 'verified absence' "$override_log.out" >/dev/null; then
  echo "the override claimed absence although the database refused to drop:" >&2
  cat "$override_log.out" >&2
  exit 1
fi

rm -f "$FAIL_MARKER_DIR/pods-released"
unreachable_log="$tmp/release-unreachable-destroy.log"
if ! (cd "$tmp/work" && DESTROYING=1 WORKSPACE_PODS=1 CLUSTER_UNREACHABLE=1 \
        LIFECYCLE_LOG="$unreachable_log" \
        "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$unreachable_log.out" 2>&1
then
  cat "$unreachable_log.out" >&2
  echo "a release that could not reach the cluster must not block the destroy (DEC-059)" >&2
  exit 1
fi
grep -F 'the cluster could not be reached' "$unreachable_log.out" >/dev/null || {
  echo "an unreachable cluster was not recorded as a degradation:" >&2
  cat "$unreachable_log.out" >&2
  exit 1
}
grep -E -- 'cloud/gcp/cluster destroy ' "$unreachable_log" >/dev/null || {
  echo "the destroy did not proceed to the substrate with no reachable cluster (DEC-059):" >&2
  grep -F 'terraform' "$unreachable_log" >&2
  exit 1
}

rm -f "$FAIL_MARKER_DIR/pods-released"
unreadable_state_log="$tmp/state-unreadable-destroy.log"
if (cd "$tmp/work" && DESTROYING=1 STATE_LIST_FAILS=1 \
      LIFECYCLE_LOG="$unreadable_state_log" \
      "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$unreadable_state_log.out" 2>&1
then
  cat "$unreadable_state_log.out" >&2
  echo "a destroy whose state cannot be listed must refuse, not proceed (BUG-094)" >&2
  exit 1
fi
grep -F 'terraform state list failed with exit 1' "$unreadable_state_log.out" >/dev/null || {
  echo "the refusal did not carry the command that failed (BUG-094):" >&2
  cat "$unreadable_state_log.out" >&2
  exit 1
}
grep -F 'not an absence' "$unreadable_state_log.out" >/dev/null || {
  echo "the unreadable listing was not distinguished from an absent one (BUG-094):" >&2
  cat "$unreadable_state_log.out" >&2
  exit 1
}
if grep -E -- 'cloud/gcp/(cluster|platform) destroy ' "$unreadable_state_log" >/dev/null; then
  echo "the refusal destroyed part of the target anyway (BUG-094):" >&2
  grep -F 'terraform' "$unreadable_state_log" >&2
  exit 1
fi

unreadable_apply_log="$tmp/state-unreadable-apply.log"
rm -f "$FAIL_MARKER_DIR/access" "$FAIL_MARKER_DIR/bootstrap-window"
if (cd "$tmp/work" && STATE_LIST_FAILS=1 LIFECYCLE_LOG="$unreadable_apply_log" \
      "$sol" cloud apply prod/gcp/us-central1) >"$unreadable_apply_log.out" 2>&1
then
  cat "$unreadable_apply_log.out" >&2
  echo "an apply whose state cannot be listed must refuse, not plan as if nothing is there" >&2
  exit 1
fi
grep -F 'terraform state list failed with exit 1' "$unreadable_apply_log.out" >/dev/null || {
  echo "the apply did not carry the command that failed (BUG-094):" >&2
  cat "$unreadable_apply_log.out" >&2
  exit 1
}
if grep -F 'requires cloud substrate to exist' "$unreadable_apply_log.out" >/dev/null; then
  echo "the apply reported the unknown state as a confirmed absence (BUG-094):" >&2
  cat "$unreadable_apply_log.out" >&2
  exit 1
fi

gcp_destroy_log="$tmp/gcp-destroy.log"
if ! (cd "$tmp/work" && DESTROYING=1 LIFECYCLE_LOG="$gcp_destroy_log" \
        "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$gcp_destroy_log.out" 2>&1
then
  cat "$gcp_destroy_log.out" >&2
  echo "destroy on GCP failed" >&2
  exit 1
fi
grep -E -- '-chdir=[^ ]*cloud/gcp/cluster ' "$gcp_destroy_log" \
  | grep -F -- '-target=google_sql_database_instance.postgres' \
  | grep -F -- '-var=sql_deletion_protection=false' >/dev/null || {
  echo "GCP destroy did not lift Cloud SQL's guard through a targeted apply:" >&2
  grep -F 'cloud/gcp/cluster' "$gcp_destroy_log" >&2
  exit 1
}
grep -F 'verify preparation: Cloud SQL and GKE deletion protection disabled' \
  "$gcp_destroy_log.out" >/dev/null || {
  echo "GCP destroy did not verify that the preparation landed:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
}
for override in sql_deletion_protection=false gke_deletion_protection=false; do
  grep -E -- '-chdir=[^ ]*cloud/gcp/cluster ' "$gcp_destroy_log" \
    | grep -F ' destroy ' \
    | grep -F -- "-var=$override" >/dev/null || {
    echo "the GCP destroy did not carry the Destroy policy's $override override:" >&2
    grep -E ' destroy ' "$gcp_destroy_log" >&2
    exit 1
  }
done
authority_line="$(grep -n -- '-var=provisioner_bootstrap_admin=true' "$gcp_destroy_log" | head -1 | cut -d: -f1 || true)"
platform_destroy_line="$(grep -nE -- '^terraform -chdir=[^ ]*cloud/gcp/platform destroy ' "$gcp_destroy_log" | head -1 | cut -d: -f1 || true)"
release_line="$(grep -n -- '-var=provisioner_bootstrap_admin=false' "$gcp_destroy_log" | head -1 | cut -d: -f1 || true)"
substrate_destroy_line="$(grep -nE -- '^terraform -chdir=[^ ]*cloud/gcp/cluster destroy ' "$gcp_destroy_log" | head -1 | cut -d: -f1 || true)"
for phase in "authority acquisition:authority_line" \
  "platform teardown:platform_destroy_line" \
  "authority release:release_line" \
  "substrate destroy:substrate_destroy_line"; do
  label="${phase%%:*}"
  variable="${phase##*:}"
  if [ -z "$(eval printf '%s' "\$$variable")" ]; then
    echo "the destroy never reached the $label (no such command in the lifecycle log):" >&2
    grep -nE -- 'terraform|refused|degrad' "$gcp_destroy_log" >&2 || true
    exit 1
  fi
done
if [ "$authority_line" -ge "$platform_destroy_line" ] ||
   [ "$platform_destroy_line" -ge "$release_line" ] ||
   [ "$release_line" -ge "$substrate_destroy_line" ]; then
  echo "the destroy ran its phases out of order: acquire=$authority_line platform=$platform_destroy_line release=$release_line substrate=$substrate_destroy_line" >&2
  exit 1
fi
if grep -F 'refused before apply' "$gcp_destroy_log.out" >/dev/null; then
  echo "the destroy refused its own permitted authority create:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
fi
if grep -F 'a preparation degraded and destruction continued' "$gcp_destroy_log.out" >/dev/null; then
  echo "the destroy degraded although its authority acquisition was permitted:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
fi

assert_contains "the GCP destroy read its own state postcondition" "$gcp_destroy_log.out" \
  'terraform state (disposable root): empty -- Terraform destroyed every resource it manages' || exit 1
assert_contains "the GCP provider inventory reported each class it checked" "$gcp_destroy_log.out" \
  'absent: GKE cluster' || exit 1
assert_contains "FND-0070: and the class an orphan was found in would be reported as PRESENT" \
  "$gcp_destroy_log.out" 'absent: Cloud SQL instance' || exit 1
grep -E 'gcloud .* services vpc-peerings list' "$gcp_destroy_log" >/dev/null || {
  echo "REFAC-094: the GCP residue (peering) query is missing from the destroy log" >&2
  exit 1
}
grep -E 'gcloud .* sql instances list' "$gcp_destroy_log" >/dev/null || {
  echo "FND-0070: the provider inventory did not list the Cloud SQL class" >&2
  exit 1
}
grep -F 'by observing the provider directly' "$gcp_destroy_log.out" >/dev/null || {
  echo "FND-0070: the destroy did not say that provider observation, not state, is the authority:" >&2
  exit 1
}
for managed in 'gcloud container clusters describe' 'gcloud sql instances describe' \
               'gcloud compute networks describe' 'gcloud artifacts repositories describe' \
               'gcloud compute addresses describe'; do
  if grep -F "$managed" "$gcp_destroy_log" >/dev/null; then
    echo "REFAC-094: the GCP destroy still re-queries a Terraform-managed resource: $managed" >&2
    exit 1
  fi
done

gcp_durable_invocations="$(grep -E -- '-chdir=[^ ]*bootstrap' "$gcp_destroy_log" || true)"
if [ -n "$gcp_durable_invocations" ]; then
  echo "INFRA-096: the GCP destroy ran terraform against the durable installation root:" >&2
  printf '%s\n' "$gcp_durable_invocations" >&2
  exit 1
fi
for durable_zone in 'google_dns_managed_zone.qualification'; do
  if grep -F "$durable_zone" "$gcp_destroy_log" >/dev/null; then
    echo "FEAT-107: the GCP destroy planned against the durable zone $durable_zone:" >&2
    grep -F "$durable_zone" "$gcp_destroy_log" >&2
    exit 1
  fi
done
if ! grep -F 'external: Terraform state bucket' "$gcp_destroy_log.out" >/dev/null; then
  echo "INFRA-096: the GCP destroy did not report the state backend as a durable prerequisite:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
fi
if ! grep -F 'external: DNS managed zone' "$gcp_destroy_log.out" >/dev/null; then
  echo "INFRA-096: the GCP destroy did not report the delegated zone as a durable prerequisite:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
fi
if grep -F 'present after destroy: Terraform state bucket' "$gcp_destroy_log.out" >/dev/null; then
  echo "INFRA-096: the GCP destroy counted the installation's state backend as this target's residue:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
fi
grep -F 'retention: none' "$gcp_destroy_log.out" >/dev/null || {
  echo "the GCP destroy did not say what it kept:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
}
assert_contains "the GCP retention claim names what was actually checked" "$gcp_destroy_log.out" \
  'there is no GCP snapshot surface to observe' || exit 1
assert_contains "INFRA-077: the GCP none claim names the soft-delete setting" "$gcp_destroy_log.out" \
  'observability buckets were created with soft delete off' || exit 1
if grep -F 'no residual billable artifacts' "$gcp_destroy_log.out" >/dev/null; then
  echo "the GCP destroy claimed no residual billable artifacts, which nothing observed:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
fi
grep -F 'gcloud auth application-default print-access-token' "$gcp_destroy_log" >/dev/null || {
  echo "GCP did not resolve its credentials through the provider's mechanism:" >&2
  grep -F 'gcloud ' "$gcp_destroy_log" >&2
  exit 1
}
grep -F 'credentials: Google Application Default Credentials resolved' \
  "$gcp_destroy_log.out" >/dev/null || {
  echo "the GCP destroy did not report the credentials it resolved:" >&2
  cat "$gcp_destroy_log.out" >&2
  exit 1
}

refuse_log="$tmp/gcp-refuse.log"
rm -f "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE" "$FAIL_MARKER_DIR/bootstrap-window"
refuse_rc=0
(cd "$tmp/work" && PLAN_CREATES_MISSING_CLUSTER=1 DESTROYING=1 \
   LIFECYCLE_LOG="$refuse_log" "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$refuse_log.out" 2>&1 || refuse_rc=$?
if [ "$refuse_rc" -ne 0 ]; then
  echo "a destroy that reached absence with a degraded preparation must exit 0, not $refuse_rc:" >&2
  cat "$refuse_log.out" >&2
  exit 1
fi
grep -F 'refused before apply' "$refuse_log.out" >/dev/null || {
  echo "the refused plan was not the reason the reconciliation did not run:" >&2
  cat "$refuse_log.out" >&2
  exit 1
}
grep -F 'a preparation degraded and destruction continued' "$refuse_log.out" >/dev/null || {
  echo "the degradation was not reported:" >&2
  cat "$refuse_log.out" >&2
  exit 1
}
if ! grep -E -- '-chdir=[^ ]*cloud/gcp/cluster ' "$refuse_log" | grep -F ' destroy ' >/dev/null; then
  echo "the substrate destroy did not run after a refused reconciliation:" >&2
  cat "$refuse_log" >&2
  exit 1
fi
grep -F 'absent: Cloud SQL instance' "$refuse_log.out" >/dev/null || {
  echo "the provider inventory did not report what it checked, per class:" >&2
  cat "$refuse_log.out" >&2
  exit 1
}

orphan_log="$tmp/gcp-orphan.log"
rm -f "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE" "$FAIL_MARKER_DIR/bootstrap-window"
orphan_rc=0
(cd "$tmp/work" && PLAN_CREATES_MISSING_CLUSTER=1 DESTROYING=1 ORPHAN_SQL_PRESENT=1 \
   LIFECYCLE_LOG="$orphan_log" "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$orphan_log.out" 2>&1 || orphan_rc=$?
if [ "$orphan_rc" -eq 0 ]; then
  echo "FND-0070: a destroy whose provider still holds a resource Terraform never adopted exited 0:" >&2
  cat "$orphan_log.out" >&2
  exit 1
fi
grep -F 'PRESENT: Cloud SQL instance' "$orphan_log.out" >/dev/null || {
  echo "FND-0070: the orphaned Cloud SQL instance was not reported as PRESENT:" >&2
  cat "$orphan_log.out" >&2
  exit 1
}
grep -F 'sol-qual-postgres' "$orphan_log.out" >/dev/null || {
  echo "FND-0070: the orphan was not named for the operator:" >&2
  cat "$orphan_log.out" >&2
  exit 1
}
grep -F 'own cluster name' "$orphan_log.out" >/dev/null || {
  echo "FND-0070: the inventory did not explain why the orphan is attributable to this target:" >&2
  cat "$orphan_log.out" >&2
  exit 1
}
grep -F 'Destruction did not converge' "$orphan_log.out" >/dev/null || {
  echo "FND-0070: the destroy did not report non-convergence:" >&2
  cat "$orphan_log.out" >&2
  exit 1
}
if grep -F 'reached verified absence' "$orphan_log.out" >/dev/null; then
  echo "FND-0070: a destroy with a standing orphan still claimed verified absence:" >&2
  cat "$orphan_log.out" >&2
  exit 1
fi
if [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null)" != "false" ]; then
  echo "the bootstrap window was not removed after the refused reconciliation:" >&2
  grep -nE 'bootstrap|refused' "$refuse_log" >&2 || true
  exit 1
fi

gcp_access_log="$tmp/gcp-access-failure.log"
rm -f "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE" "$FAIL_MARKER_DIR/access" \
  "$FAIL_MARKER_DIR/bootstrap-window"
# The release's existence observation asks for cluster access before teardown does, so the
# injected one-shot get-credentials failure lands there: the destroy must refuse (it cannot
# establish whether the declared namespaces exist, and it does not fall back to a weaker read),
# report what it could not establish, and leave the target standing. A re-run then proceeds,
# because a transient access failure is recoverable by re-running, and the window (modelled
# open) is closed by an apply.
if (cd "$tmp/work" && FAIL_ON=access WINDOW_OPEN=1 DESTROYING=1 LIFECYCLE_LOG="$gcp_access_log" \
      "$sol" destroy prod/gcp/us-central1 --apply) \
    >"$gcp_access_log.out" 2>&1
then
  cat "$gcp_access_log.out" >&2
  echo "a destroy whose namespace existence could not be established claimed success:" >&2
  exit 1
fi
grep -F 'establishing whether the namespace exists failed' "$gcp_access_log.out" >/dev/null || {
  echo "the cluster access failure was not reported as the unestablished existence read:" >&2
  cat "$gcp_access_log.out" >&2
  exit 1
}
grep -F -- '--accept-unreleased' "$gcp_access_log.out" >/dev/null || {
  echo "a refused release did not leave the operator the documented override:" >&2
  cat "$gcp_access_log.out" >&2
  exit 1
}
if grep -F 'reached verified absence' "$gcp_access_log.out" >/dev/null; then
  echo "a destroy that destroyed nothing claimed verified absence:" >&2
  cat "$gcp_access_log.out" >&2
  exit 1
fi
if ! (cd "$tmp/work" && WINDOW_OPEN=1 DESTROYING=1 LIFECYCLE_LOG="$gcp_access_log" \
        "$sol" destroy prod/gcp/us-central1 --apply) \
    >>"$gcp_access_log.out" 2>&1
then
  cat "$gcp_access_log.out" >&2
  echo "a re-run after a transient access failure did not converge (FND-0077):" >&2
  exit 1
fi
grep -F 'reached verified absence' "$gcp_access_log.out" >/dev/null || {
  echo "GCP teardown succeeded without proving substrate absence:" >&2
  cat "$gcp_access_log.out" >&2
  exit 1
}
grep -F 'could not establish ephemeral cluster access' "$gcp_access_log.out" >/dev/null || {
  echo "the injected get-credentials failure was not the reason the GCP destroy stopped:" >&2
  cat "$gcp_access_log.out" >&2
  exit 1
}
# Anchored on the *first* ask for cluster access, which is the one the injected failure hits.
# Later asks (the release's namespace view, the platform teardown, the de-escalation probe) are
# expected and make the last ask an unstable anchor.
access_line="$(grep -nF 'get-credentials' "$gcp_access_log" | head -1 | cut -d: -f1 || true)"
close_plan_line="$(grep -nE -- '-chdir=[^ ]*cloud/gcp/cluster plan ' "$gcp_access_log" \
  | grep -F -- 'provisioner_bootstrap_admin=false' | tail -1 | cut -d: -f1 || true)"
if [ -z "$access_line" ] || [ -z "$close_plan_line" ] || [ "$close_plan_line" -le "$access_line" ]; then
  echo "a GCP cluster-access failure exited without closing the bootstrap window:" >&2
  grep -nE 'get-credentials|provisioner_bootstrap_admin' "$gcp_access_log" >&2 || true
  exit 1
fi
if [ "$(cat "$FAIL_MARKER_DIR/bootstrap-window" 2>/dev/null)" != "false" ]; then
  echo "the bootstrap window was not closed by an apply after the failed get-credentials:" >&2
  grep -nE 'get-credentials|provisioner_bootstrap_admin' "$gcp_access_log" >&2 || true
  exit 1
fi

autopilot_log="$tmp/gcp-autopilot.log"
rm -f "$FAIL_MARKER_DIR/access" "$FAIL_MARKER_DIR/bootstrap-window"
if (cd "$tmp/work" && STUB_AUTOPILOT=1 LIFECYCLE_LOG="$autopilot_log" \
      "$sol" cloud apply prod/gcp/us-central1) >"$autopilot_log.out" 2>&1
then
  cat "$autopilot_log.out" >&2
  echo "GCP apply continued onto an Autopilot cluster" >&2
  exit 1
fi
grep -F 'GKE Autopilot is not supported by the standard Sol platform profile' "$autopilot_log.out" \
  >/dev/null || {
  echo "the refusal did not carry the support contract:" >&2
  cat "$autopilot_log.out" >&2
  exit 1
}
if grep -qE -- 'terraform.* plan |terraform.* apply ' "$autopilot_log"; then
  echo "an Autopilot substrate was refused only after Terraform had run:" >&2
  grep -nE -- 'terraform.* (plan|apply) ' "$autopilot_log" | head -3 >&2
  exit 1
fi

no_project_log="$tmp/gcp-no-project.log"
rm -f "$FAIL_MARKER_DIR/access" "$FAIL_MARKER_DIR/bootstrap-window"
if (cd "$tmp/work" && OUTPUT_NO_PROJECT=1 LIFECYCLE_LOG="$no_project_log" \
      "$sol" cloud apply prod/gcp/us-central1) >"$no_project_log.out" 2>&1
then
  cat "$no_project_log.out" >&2
  echo "GCP apply succeeded although the cloud root published no project_id" >&2
  exit 1
fi
grep -F 'GCP Terraform output "project_id" is missing or not a string' "$no_project_log.out" \
  >/dev/null || {
  echo "the missing project_id was not the reason the apply stopped:" >&2
  cat "$no_project_log.out" >&2
  exit 1
}

partial_log="$tmp/gcp-partial-state.log"
rm -f "$FAIL_MARKER_DIR/access" "$FAIL_MARKER_DIR/bootstrap-window"
(cd "$tmp/work" && OUTPUT_NO_PROJECT=1 STATE_EMPTY=1 LIFECYCLE_LOG="$partial_log" \
   "$sol" cloud apply prod/gcp/us-central1) >"$partial_log.out" 2>&1 || true
grep -F 'GCP Terraform output "project_id" is missing or not a string' "$partial_log.out" \
  >/dev/null && {
  echo "a state holding no substrate resource was read as a broken output set, so an" >&2
  echo "interrupted apply could never be retried:" >&2
  cat "$partial_log.out" >&2
  exit 1
}
grep -F -- "'apply'" "$partial_log.out" >/dev/null || {
  echo "the interrupted apply never reached Terraform: the presence check stopped it" >&2
  cat "$partial_log.out" >&2
  exit 1
}
if grep -qF 'compute regions describe' "$no_project_log"; then
  echo "the quota was read although the project was never parsed:" >&2
  grep -nF 'compute regions describe' "$no_project_log" >&2
  exit 1
fi

quota_log="$tmp/gcp-disk-quota.log"
rm -f "$FAIL_MARKER_DIR/access" "$FAIL_MARKER_DIR/bootstrap-window"
if (cd "$tmp/work" && STUB_SSD_USAGE=500 LIFECYCLE_LOG="$quota_log" \
      "$sol" cloud apply prod/gcp/us-central1) >"$quota_log.out" 2>&1
then
  cat "$quota_log.out" >&2
  echo "GCP apply succeeded although the region's disk quota was exhausted" >&2
  exit 1
fi
if grep -qF 'is missing or not a string' "$quota_log.out"; then
  echo "the quota scenario never crossed the parser: the stub's payload was not accepted" >&2
  cat "$quota_log.out" >&2
  exit 1
fi
grep -F 'compute regions describe' "$quota_log" >/dev/null || {
  echo "the quota scenario refused without ever reading the provider's quota:" >&2
  cat "$quota_log" >&2
  exit 1
}
grep -F 'SSD_TOTAL_GB 500/500' "$quota_log.out" >/dev/null || {
  echo "the refusal did not name the observed quota and its usage:" >&2
  cat "$quota_log.out" >&2
  exit 1
}
grep -F "declared minimum persistent-disk requirement is 20 GiB" "$quota_log.out" >/dev/null || {
  echo "the refusal did not name Sol's declared requirement:" >&2
  cat "$quota_log.out" >&2
  exit 1
}
if grep -qF 'get-credentials' "$quota_log"; then
  echo "the disk-quota refusal happened after cluster access was already attempted:" >&2
  grep -nF 'get-credentials' "$quota_log" >&2
  exit 1
fi
if grep -qE -- 'chdir=[^ ]*/platform/cloud/[a-z]+/platform[^ ]* apply' "$quota_log"; then
  echo "the disk-quota refusal happened after a platform apply had begun:" >&2
  grep -nE -- 'chdir=[^ ]*' "$quota_log" >&2
  exit 1
fi
if ! grep -qF -- 'provisioner_bootstrap_admin=false' "$quota_log"; then
  echo "the disk-quota refusal left the bootstrap window open:" >&2
  grep -nE 'provisioner_bootstrap_admin|disk quota' "$quota_log" >&2 || true
  exit 1
fi

gcp_apply_access_log="$tmp/gcp-apply-access-failure.log"
rm -f "$FAIL_MARKER_DIR/access"
if (cd "$tmp/work" && FAIL_ON=access LIFECYCLE_LOG="$gcp_apply_access_log" \
      "$sol" cloud apply prod/gcp/us-central1) \
  >"$gcp_apply_access_log.out" 2>&1
then
  cat "$gcp_apply_access_log.out" >&2
  echo "GCP apply succeeded although cluster access could not be established" >&2
  exit 1
fi
grep -F 'could not establish ephemeral cluster access' "$gcp_apply_access_log.out" \
  >/dev/null || {
  echo "the injected get-credentials failure was not the reason the GCP apply stopped:" >&2
  cat "$gcp_apply_access_log.out" >&2
  exit 1
}
access_line="$(grep -nF 'get-credentials' "$gcp_apply_access_log" | tail -1 | cut -d: -f1 || true)"
close_line="$(grep -nE -- '-chdir=[^ ]*cloud/gcp/cluster apply ' "$gcp_apply_access_log" \
  | grep -F -- 'provisioner_bootstrap_admin=false' | tail -1 | cut -d: -f1 || true)"
if [ -z "$access_line" ] || [ -z "$close_line" ] || [ "$close_line" -le "$access_line" ]; then
  echo "a GCP cluster-access failure during apply exited without closing the bootstrap window:" >&2
  grep -nE 'get-credentials|provisioner_bootstrap_admin' "$gcp_apply_access_log" >&2 || true
  exit 1
fi

ecr_log="$tmp/ecr-removal.log"
rm -f "$FAIL_MARKER_DIR/bootstrap-window"
if (export FAIL_ON=""; export ECR_REMOVAL=1; run_apply "$ecr_log"); then
  cat "$ecr_log.out" >&2
  echo "cloud apply went ahead with a plan that deletes an ECR repository" >&2
  exit 1
fi
grep -F 'would delete' "$ecr_log.out" >/dev/null || {
  echo "the ECR refusal did not say what it refused:" >&2
  cat "$ecr_log.out" >&2
  exit 1
}
grep -F 'what a re-apply cannot restore' "$ecr_log.out" >/dev/null || {
  echo "the refusal did not say why it refused:" >&2
  cat "$ecr_log.out" >&2
  exit 1
}
grep -F -- '--confirm-ecr-removal' "$ecr_log.out" >/dev/null || {
  echo "the refusal did not name the flag that confirms it:" >&2
  cat "$ecr_log.out" >&2
  exit 1
}
grep -F 'old-svc' "$ecr_log.out" >/dev/null || {
  echo "the ECR refusal did not name the repository:" >&2
  cat "$ecr_log.out" >&2
  exit 1
}
if grep -E -- '-chdir=[^ ]*cloud/aws/cluster apply ' "$ecr_log" >/dev/null; then
  echo "a refused cloud apply still ran terraform apply:" >&2
  grep -E ' apply ' "$ecr_log" >&2
  exit 1
fi
ecr_confirmed_log="$tmp/ecr-removal-confirmed.log"
if ! (cd "$tmp/work" && FAIL_ON="" ECR_REMOVAL=1 LIFECYCLE_LOG="$ecr_confirmed_log" \
        "$sol" cloud apply prod/aws/us-east-1 --confirm-ecr-removal) \
  >"$ecr_confirmed_log.out" 2>&1
then
  cat "$ecr_confirmed_log.out" >&2
  echo "a confirmed ECR removal was refused" >&2
  exit 1
fi
grep -E -- '-chdir=[^ ]*cloud/aws/cluster apply .*\.tfplan' "$ecr_confirmed_log" >/dev/null || {
  echo "the confirmed cloud apply did not apply the saved plan it read:" >&2
  grep -E ' apply ' "$ecr_confirmed_log" >&2
  exit 1
}

gcp_toolchain_log="$tmp/gcp-toolchain.log"
rm -f "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE"
if (cd "$tmp/work" && NO_AUTH_PLUGIN=1 DESTROYING=1 LIFECYCLE_LOG="$gcp_toolchain_log" \
      "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$gcp_toolchain_log.out" 2>&1
then
  echo "a GCP platform stage ran without gke-gcloud-auth-plugin" >&2
  exit 1
fi
grep -F 'gke-gcloud-auth-plugin' "$gcp_toolchain_log.out" >/dev/null || {
  echo "the missing-plugin failure did not name the plugin:" >&2
  cat "$gcp_toolchain_log.out" >&2
  exit 1
}
if grep -F 'platform-destroy' "$gcp_toolchain_log" >/dev/null; then
  echo "the missing-plugin failure reached the platform stage anyway:" >&2
  exit 1
fi

partial_log="$tmp/gcp-partial.log"
rm -f "$STATE_RM_FILE" "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE"
if ! (cd "$tmp/work" && PARTIAL_INSTALL=1 DESTROYING=1 LIFECYCLE_LOG="$partial_log" \
        "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$partial_log.out" 2>&1
then
  cat "$partial_log.out" >&2
  echo "INFRA-042: a partially installed platform was not destroyable" >&2
  exit 1
fi
grep -F 'platform-destroy' "$partial_log.out" >/dev/null || {
  echo "INFRA-042: the platform destroy stage never ran" >&2
  exit 1
}
grep -F 'platform-destroy-retry' "$partial_log.out" >/dev/null || {
  echo "INFRA-042: the destroy was not retried after the recovery" >&2
  exit 1
}
grep -F 'state-rm module.platform.kubernetes_manifest.letsencrypt_prod' "$partial_log" \
  >/dev/null || {
  echo "INFRA-042: the unserved resource was not the one forgotten:" >&2
  grep -F 'state-rm' "$partial_log" >&2
  exit 1
}
if grep -F 'state-rm module.platform.kubernetes_namespace.cert_manager' "$partial_log" >/dev/null; then
  echo "INFRA-042: a resource whose kind the cluster serves was forgotten too" >&2
  exit 1
fi
grep -F 'CLUSTER DOES NOT SERVE' "$partial_log.out" >/dev/null || true
grep -F 'ClusterIssuer is not served by this cluster' "$partial_log.out" >/dev/null || {
  echo "INFRA-042: the recovery did not say which kind proved the resource absent:" >&2
  cat "$partial_log.out" >&2
  exit 1
}
assert_contains "INFRA-042: the destroy completed after the recovery" "$partial_log.out" \
  'terraform state (disposable root): empty' || {
  echo "INFRA-042: the destroy did not complete after the recovery:" >&2
  cat "$partial_log.out" >&2
  exit 1
}

served_log="$tmp/gcp-partial-served.log"
rm -f "$STATE_RM_FILE"
if (cd "$tmp/work" && PARTIAL_INSTALL=1 CRD_SERVED=1 DESTROYING=1 \
      LIFECYCLE_LOG="$served_log" "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$served_log.out" 2>&1
then
  echo "INFRA-042: a destroy that could not delete a served resource reported success" >&2
  exit 1
fi
if grep -F 'state-rm' "$served_log" >/dev/null; then
  echo "INFRA-042: a resource whose kind the cluster serves was forgotten anyway:" >&2
  grep -F 'state-rm' "$served_log" >&2
  exit 1
fi
grep -F 'Could not remove Service Networking Connection\|API did not recognize' \
  "$served_log.out" >/dev/null || true
rm -f "$STATE_RM_FILE"

stale_platform_log="$tmp/gcp-stale-platform-state.log"
rm -f "$STATE_RM_FILE" "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE"
if ! (cd "$tmp/work" && CLOUD_STATE_EMPTY=1 PARTIAL_INSTALL=1 DESTROYING=1 \
        SUBSTRATE_ABSENT_AT_PROVIDER=1 LIFECYCLE_LOG="$stale_platform_log" \
        "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$stale_platform_log.out" 2>&1
then
  cat "$stale_platform_log.out" >&2
  echo "INFRA-082: a target whose platform state is stale under an absent substrate was not destroyable" >&2
  exit 1
fi
grep -F "the substrate's absence is positively established at the provider" \
  "$stale_platform_log.out" >/dev/null || {
  echo "INFRA-082: the reconciliation did not name the evidence that permitted it:" >&2
  cat "$stale_platform_log.out" >&2
  exit 1
}
grep -F 'Forgotten in state' "$stale_platform_log.out" >/dev/null || {
  echo "INFRA-082: the stale platform state was not accounted for:" >&2
  cat "$stale_platform_log.out" >&2
  exit 1
}
for forgotten in module.platform.kubernetes_manifest.letsencrypt_prod \
                 module.platform.kubernetes_namespace.cert_manager; do
  grep -F "state-rm $forgotten" "$stale_platform_log" >/dev/null || {
    echo "INFRA-082: $forgotten was left in the stale platform state:" >&2
    grep -F 'state-rm' "$stale_platform_log" >&2
    exit 1
  }
done
grep -E -- '-chdir=[^ ]*cloud/gcp/platform show -json' "$stale_platform_log" >/dev/null || {
  echo "INFRA-082: the destroy never examined the platform root's state:" >&2
  grep -E -- '-chdir=[^ ]*' "$stale_platform_log" >&2
  exit 1
}
if grep -E -- '-chdir=[^ ]*cloud/gcp/platform destroy' "$stale_platform_log" >/dev/null; then
  echo "INFRA-082: the destroy ran a platform teardown although the cluster that carried the platform is absent:" >&2
  grep -E -- '-chdir=[^ ]*cloud/gcp/platform destroy' "$stale_platform_log" >&2
  exit 1
fi
if ! grep -E -- '^terraform -chdir=[^ ]*cloud/gcp/cluster destroy ' "$stale_platform_log" >/dev/null; then
  echo "INFRA-082: the destroy did not run the substrate destroy after reconciling:" >&2
  grep -E -- ' destroy ' "$stale_platform_log" >&2
  exit 1
fi
assert_contains "INFRA-082: the reconciled target reported verified absence" \
  "$stale_platform_log.out" 'reached verified absence' || {
  echo "INFRA-082: the reconciled destroy did not report verified absence:" >&2
  cat "$stale_platform_log.out" >&2
  exit 1
}

stale_present_log="$tmp/gcp-stale-platform-state-present.log"
rm -f "$STATE_RM_FILE" "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE"
(cd "$tmp/work" && CLOUD_STATE_EMPTY=1 PARTIAL_INSTALL=1 \
   DESTROYING=1 LIFECYCLE_LOG="$stale_present_log" \
   "$sol" destroy prod/gcp/us-central1 --apply) >"$stale_present_log.out" 2>&1 || true
if grep -F 'state-rm' "$stale_present_log" >/dev/null; then
  echo "INFRA-082: state was forgotten although the provider did not establish the substrate's absence:" >&2
  grep -F 'state-rm' "$stale_present_log" >&2
  exit 1
fi
grep -F 'only a positively established absence permits forgetting' \
  "$stale_present_log.out" >/dev/null || {
  echo "INFRA-082: a substrate the provider still holds did not refuse the reconciliation:" >&2
  cat "$stale_present_log.out" >&2
  exit 1
}
rm -f "$STATE_RM_FILE"

stale_unidentified_log="$tmp/gcp-stale-platform-state-unidentified.log"
cp "$tmp/work/sol/environments.yml" "$tmp/work/target.before-infra082.yml"
grep -v '      cluster_name: sol-qual$' "$tmp/work/target.before-infra082.yml" \
  >"$tmp/work/sol/environments.yml"
rm -f "$STATE_RM_FILE" "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE"
if ! (cd "$tmp/work" && CLOUD_STATE_EMPTY=1 PARTIAL_INSTALL=1 DESTROYING=1 \
        LIFECYCLE_LOG="$stale_unidentified_log" \
        "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$stale_unidentified_log.out" 2>&1
then
  mv "$tmp/work/target.before-infra082.yml" "$tmp/work/sol/environments.yml"
  cat "$stale_unidentified_log.out" >&2
  echo "INFRA-082: a destroy whose substrate could not be identified did not converge" >&2
  exit 1
fi
mv "$tmp/work/target.before-infra082.yml" "$tmp/work/sol/environments.yml"
if grep -F 'state-rm' "$stale_unidentified_log" >/dev/null; then
  echo "INFRA-082: state was forgotten although the substrate's identity was never established:" >&2
  grep -F 'state-rm' "$stale_unidentified_log" >&2
  exit 1
fi
grep -F 'cluster name is neither declared nor resolved' "$stale_unidentified_log.out" >/dev/null || {
  echo "INFRA-082: an unidentifiable substrate did not refuse the reconciliation:" >&2
  cat "$stale_unidentified_log.out" >&2
  exit 1
}
rm -f "$STATE_RM_FILE"

lost_substrate_log="$tmp/gcp-lost-substrate.log"
rm -f "$STATE_RM_FILE" "$GCP_SQL_PREPARED_FILE" "$GKE_PREPARED_FILE"
if ! (cd "$tmp/work" && BOOTSTRAP_BINDING_IN_STATE=1 SUBSTRATE_ABSENT_AT_PROVIDER=1 \
        PARTIAL_INSTALL=1 DESTROYING=1 LIFECYCLE_LOG="$lost_substrate_log" \
        "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$lost_substrate_log.out" 2>&1
then
  cat "$lost_substrate_log.out" >&2
  echo "INFRA-094: a target whose substrate the provider lost was not destroyable" >&2
  exit 1
fi
grep -F "the substrate's absence is positively established at the provider" \
  "$lost_substrate_log.out" >/dev/null || {
  echo "INFRA-094: the reconciliation did not name the evidence that permitted it:" >&2
  cat "$lost_substrate_log.out" >&2
  exit 1
}
grep -F 'cannot exist once the cluster does not' "$lost_substrate_log.out" >/dev/null || {
  echo "INFRA-094: the cloud state the provider outlived was not accounted for:" >&2
  cat "$lost_substrate_log.out" >&2
  exit 1
}
for forgotten in google_container_cluster.main \
                 kubernetes_cluster_role_binding.provisioner_bootstrap_admin \
                 module.platform.kubernetes_manifest.letsencrypt_prod \
                 module.platform.kubernetes_namespace.cert_manager; do
  grep -F "state-rm $forgotten" "$lost_substrate_log" >/dev/null || {
    echo "INFRA-094: $forgotten still represents an object the provider does not have:" >&2
    grep -F 'state-rm' "$lost_substrate_log" >&2
    exit 1
  }
done
prepare_line="$(grep -F -- '-target=google_sql_database_instance.postgres' \
  "$lost_substrate_log" | grep -F ' plan ' | head -1 || true)"
if [ -z "$prepare_line" ]; then
  echo "INFRA-094: the destroy did not prepare the guarded instance that is still standing:" >&2
  grep -F -- '-target=' "$lost_substrate_log" >&2
  exit 1
fi
case "$prepare_line" in
  *'-target=google_container_cluster.main'*)
    echo "INFRA-094: the preparation still targeted a cluster the provider does not have:" >&2
    printf '%s\n' "$prepare_line" >&2
    exit 1
    ;;
esac
if grep -E -- '-chdir=[^ ]*cloud/gcp/platform destroy' "$lost_substrate_log" >/dev/null; then
  echo "INFRA-094: the destroy ran a platform teardown although nothing can be inside the cluster:" >&2
  grep -E -- '-chdir=[^ ]*cloud/gcp/platform destroy' "$lost_substrate_log" >&2
  exit 1
fi
if grep -F 'provisioner_bootstrap_admin=true' "$lost_substrate_log" >/dev/null; then
  echo "INFRA-094: the destroy acquired bootstrap authority for a cluster that does not exist:" >&2
  grep -F 'provisioner_bootstrap_admin=true' "$lost_substrate_log" >&2
  exit 1
fi
if grep -F 'Releasing the application workloads' "$lost_substrate_log.out" >/dev/null; then
  echo "INFRA-094: the destroy tried to release workloads from a cluster that does not exist:" >&2
  exit 1
fi
grep -F 'no workload this target deployed' "$lost_substrate_log.out" >/dev/null || {
  echo "INFRA-094: the destroy did not account for the workloads it could not reach:" >&2
  cat "$lost_substrate_log.out" >&2
  exit 1
}
if ! grep -E -- '^terraform -chdir=[^ ]*cloud/gcp/cluster destroy ' "$lost_substrate_log" >/dev/null; then
  echo "INFRA-094: the destroy did not run the substrate destroy after reconciling:" >&2
  grep -E -- ' destroy ' "$lost_substrate_log" >&2
  exit 1
fi
assert_contains "INFRA-094: the reconciled target reported verified absence" \
  "$lost_substrate_log.out" 'reached verified absence' || {
  echo "INFRA-094: the reconciled destroy did not report verified absence:" >&2
  cat "$lost_substrate_log.out" >&2
  exit 1
}
rm -f "$STATE_RM_FILE"

gcp_nocred_log="$tmp/gcp-nocred.log"
if (cd "$tmp/work" && DESTROYING=1 FAIL_CREDENTIALS=1 LIFECYCLE_LOG="$gcp_nocred_log" \
      "$sol" destroy prod/gcp/us-central1 --apply) \
  >"$gcp_nocred_log.out" 2>&1
then
  echo "a GCP destroy with unresolvable credentials proceeded instead of failing closed" >&2
  exit 1
fi
grep -F 'still standing and may still be billing' "$gcp_nocred_log.out" >/dev/null || {
  echo "the GCP credential failure did not say the target may still be billing:" >&2
  cat "$gcp_nocred_log.out" >&2
  exit 1
}
if grep -F 'cloud/gcp/cluster' "$gcp_nocred_log" | grep -F ' destroy ' >/dev/null; then
  echo "a GCP destroy with unresolvable credentials reached terraform anyway:" >&2
  exit 1
fi
while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"

rm -f "$RDS_PREPARED_FILE"
log="$tmp/destroy-established.log"
if ! run_destroy "$log"; then
  cat "$log.out" >&2
  echo "destroy on an established target must succeed" >&2
  exit 1
fi
if grep -F 'auth can-i create namespaces' "$log" >/dev/null; then
  echo "FND-0076: the destroy ran the apply-path successor probe, which cannot hold while tearing down:" >&2
  grep -F 'auth can-i create' "$log" >&2
  exit 1
fi
if grep -F 'could not be verified' "$log.out" >/dev/null; then
  echo "FND-0076: a healthy teardown warned that de-escalation could not be verified:" >&2
  cat "$log.out" >&2
  exit 1
fi
grep -F -- '-target=aws_db_instance.postgres' "$log" | grep -F 'rds_deletion_protection=false' \
  | grep -F 'rds_skip_final_snapshot=false' >/dev/null
snapshot_line="$(grep -F -- '-target=aws_db_instance.postgres' "$log" | head -1)"
snapshot_id="$(printf '%s\n' "$snapshot_line" | grep -oE 'rds_final_snapshot_identifier=[^ ]+' | cut -d= -f2)"
case "$snapshot_id" in
  lifecycle-test-postgres-final-*) : ;;
  *)
    echo "RDS final snapshot identifier was not the expected unique per-attempt name: $snapshot_id" >&2
    exit 1
    ;;
esac
grep -F 'verify preparation: RDS deletion protection disabled' "$log.out" >/dev/null
grep -F "final snapshot $snapshot_id confirmed" "$log.out" >/dev/null
grep -F 'aws ec2 describe-volumes' "$log" >/dev/null
for gone in 'ec2 describe-volumes --volume-ids' 'ecr describe-repositories --repository-names' \
             'rds describe-db-instances --db-instance-identifier' \
             'ec2 describe-addresses --public-ips'; do
  if grep -F "$gone" "$log" >/dev/null; then
    echo "REFAC-093: the destroy re-queried a Terraform-managed resource by identity: $gone" >&2
    exit 1
  fi
done
grep -F 'ECR repository' "$log.out" >/dev/null || {
  echo "FND-0070: the AWS inventory did not account for the ECR class at all" >&2
  exit 1
}
grep -F 'load balancer' "$log.out" >/dev/null || {
  echo "the AWS inventory did not account for the load-balancer class at all" >&2
  exit 1
}
if ! grep -F 'external: Route 53 hosted zone' "$log.out" >/dev/null; then
  echo "the destroy did not report the delegated hosted zone as the durable prerequisite:" >&2
  cat "$log.out" >&2
  exit 1
fi
if grep -F 'present after destroy: Route 53 hosted zone' "$log.out" >/dev/null; then
  echo "the delegated hosted zone was counted as this target's residue:" >&2
  cat "$log.out" >&2
  exit 1
fi

durable_invocations="$(grep -E -- '-chdir=[^ ]*bootstrap' "$log" || true)"
if [ -n "$durable_invocations" ]; then
  echo "INFRA-096: the destroy ran terraform against the durable installation root:" >&2
  printf '%s\n' "$durable_invocations" >&2
  exit 1
fi
if grep -E 'bootstrap/(aws|gcp)/default\.tfstate|prefix=bootstrap' "$log" >/dev/null; then
  echo "INFRA-096: the destroy addressed the installation's own state:" >&2
  grep -E 'bootstrap/(aws|gcp)/default\.tfstate|prefix=bootstrap' "$log" >&2
  exit 1
fi
for durable_zone in 'aws_route53_zone.qualification'; do
  if grep -F "$durable_zone" "$log" >/dev/null; then
    echo "INFRA-096/FEAT-107: a target destroy planned against the durable zone $durable_zone:" >&2
    grep -F "$durable_zone" "$log" >&2
    exit 1
  fi
  if grep -F "$durable_zone" "$log.out" >/dev/null; then
    echo "FEAT-107: the destroy claimed the durable zone $durable_zone as this target's:" >&2
    grep -F "$durable_zone" "$log.out" >&2
    exit 1
  fi
done
if ! grep -F 'external: Terraform state bucket' "$log.out" >/dev/null; then
  echo "INFRA-096: the destroy did not report the state backend as a durable prerequisite:" >&2
  cat "$log.out" >&2
  exit 1
fi
if grep -F 'present after destroy: Terraform state bucket' "$log.out" >/dev/null; then
  echo "INFRA-096: the destroy counted the installation's state backend as this target's residue:" >&2
  cat "$log.out" >&2
  exit 1
fi
if grep -F 'load balancer could not be observed' "$log.out" >/dev/null; then
  echo "the load-balancer probe could not run, so an AWS destroy can never" >&2
  echo "establish residue absence:" >&2
  cat "$log.out" >&2
  exit 1
fi

for residual in ebs; do
  residual_log="$tmp/destroy-residual-$residual.log"
  if (export AWS_RESIDUAL_KIND="$residual"; run_destroy "$residual_log"); then
    echo "AWS destroy verification accepted residual $residual infrastructure" >&2
    exit 1
  fi
  case "$residual" in
    ebs) expected='present after destroy' ;;
  esac
  grep -F "$expected" "$residual_log.out" >/dev/null || {
    echo "AWS residual $residual did not report its failed absence check" >&2
    cat "$residual_log.out" >&2
    exit 1
  }
  grep -F 'vol-residual' "$residual_log.out" >/dev/null || {
    echo "AWS residual $residual was not named for the operator" >&2
    cat "$residual_log.out" >&2
    exit 1
  }
  if grep -F 'reached verified absence' "$residual_log.out" >/dev/null; then
    echo "AWS residual $residual still produced a verified-absence claim" >&2
    exit 1
  fi
done
prepare_line_no="$(grep -n -- '-target=aws_db_instance.postgres' "$log" | head -1 | cut -d: -f1)"
destroy_line_no="$(grep -n 'cloud/aws/cluster.* destroy ' "$log" | head -1 | cut -d: -f1)"
if [ -z "$destroy_line_no" ] || [ "$prepare_line_no" -ge "$destroy_line_no" ]; then
  echo "RDS destroy preparation did not run before the destroy" >&2
  cat "$log" >&2
  exit 1
fi

admin_plan_line="$(grep 'cloud/aws/cluster.* plan ' "$log" | grep -F 'provisioner_bootstrap_admin=true' | head -1 || true)"
case "$admin_plan_line" in
  *'rds_deletion_protection=false'*) : ;;
  *)
    echo "the post-prepare bootstrap-admin apply did not carry the Destroy policy" >&2
    cat "$log" >&2
    exit 1
    ;;
esac
last_protection="$(printf '%s\n' "$admin_plan_line" | grep -oE 'rds_deletion_protection=[a-z]+' | tail -1)"
if [ "$last_protection" != "rds_deletion_protection=false" ]; then
  echo "Ready policy overrode the Destroy policy after PrepareDestroy ($last_protection)" >&2
  cat "$log" >&2
  exit 1
fi

log2="$tmp/destroy-established-2.log"
if ! run_destroy "$log2"; then
  cat "$log2.out" >&2
  echo "a second destroy attempt must also succeed" >&2
  exit 1
fi
snapshot_line2="$(grep -F -- '-target=aws_db_instance.postgres' "$log2" | head -1)"
snapshot_id2="$(printf '%s\n' "$snapshot_line2" | grep -oE 'rds_final_snapshot_identifier=[^ ]+' | cut -d= -f2)"
if [ "$snapshot_id" = "$snapshot_id2" ]; then
  echo "two destroy attempts minted the same RDS final snapshot identifier: $snapshot_id" >&2
  exit 1
fi

log_retain="$tmp/destroy-retention-default.log"
if ! run_destroy "$log_retain"; then
  cat "$log_retain.out" >&2
  echo "a default destroy must still succeed" >&2
  exit 1
fi
retain_line="$(grep -F -- '-target=aws_db_instance.postgres' "$log_retain" | head -1)"
case "$retain_line" in
  *'rds_skip_final_snapshot=false'*) : ;;
  *)
    echo "the default destroy did not retain the final snapshot; prepare saw: $retain_line" >&2
    exit 1
    ;;
esac
assert_contains "the default destroy reports what it retained" "$log_retain.out" \
  'retention: final snapshot' || exit 1
retained_id="$(printf '%s\n' "$retain_line" | grep -oE 'rds_final_snapshot_identifier=[^ ]+' | cut -d= -f2)"
if [ -z "$retained_id" ]; then
  echo "the default destroy did not name a final snapshot identifier:" >&2
  cat "$log_retain.out" >&2
  exit 1
fi
assert_contains "the retained snapshot was observed, not assumed" "$log_retain.out" \
  "final snapshot $retained_id observed available" || exit 1
assert_contains "the retention observation names how to remove it" "$log_retain.out" \
  'delete-db-snapshot' || exit 1
assert_not_contains "the destroy does not re-query the managed database by identity" "$log_retain.out" \
  'aws rds describe-db-instances --db-instance-identifier' || exit 1
assert_not_contains "the destroy does not re-query the managed cluster by identity" "$log_retain.out" \
  'aws eks describe-cluster' || exit 1
assert_contains "FND-0070: the destroy observes the provider's classes independently of state" \
  "$log_retain.out" 'absent: RDS instance' || exit 1

missing_snapshot_log="$tmp/destroy-retention-missing.log"
rm -f "$RDS_PREPARED_FILE"
if (export RDS_SNAPSHOT_MISSING=1; run_destroy "$missing_snapshot_log"); then
  echo "a destroy whose promised final snapshot does not exist must fail" >&2
  cat "$missing_snapshot_log.out" >&2
  exit 1
fi
assert_contains "the missing final snapshot was reported" "$missing_snapshot_log.out" \
  'final-snapshot NOT observed' || exit 1
assert_contains "the missing snapshot failure names the guarantee" "$missing_snapshot_log.out" \
  'the target declared it keeps its final snapshot' || exit 1
assert_contains "the missing snapshot is a violation, not a degradation" \
  "$missing_snapshot_log.out" 'the destruction postcondition is violated' || exit 1

pending_snapshot_log="$tmp/destroy-retention-pending.log"
rm -f "$RDS_PREPARED_FILE"
if (export RDS_SNAPSHOT_PENDING=1 SOL_DESTROY_SNAPSHOT_INTERVAL_S=0; run_destroy "$pending_snapshot_log"); then
  echo "a destroy whose final snapshot never becomes available must fail" >&2
  cat "$pending_snapshot_log.out" >&2
  exit 1
fi
assert_contains "a snapshot still creating is not a met guarantee" "$pending_snapshot_log.out" \
  'the retention guarantee is not established while it has not reached available' || exit 1

creating_log="$tmp/destroy-retention-creating.log"
rm -f "$RDS_PREPARED_FILE" "$FAIL_MARKER_DIR/snapshot-creating"
if ! (export RDS_SNAPSHOT_CREATING_ONCE=1 SOL_DESTROY_SNAPSHOT_INTERVAL_S=0; \
      run_destroy "$creating_log"); then
  echo "a destroy whose final snapshot needed a second observation must succeed" >&2
  cat "$creating_log.out" >&2
  exit 1
fi
assert_contains "the promised snapshot was observed once it settled" "$creating_log.out" \
  'observed available' || exit 1

invalid_interval_log="$tmp/destroy-invalid-interval.log"
rm -f "$RDS_PREPARED_FILE" "$FAIL_MARKER_DIR/snapshot-creating"
if (export SOL_DESTROY_SNAPSHOT_INTERVAL_S=soon; run_destroy "$invalid_interval_log"); then
  echo "a destroy accepted an unparseable SOL_DESTROY_SNAPSHOT_INTERVAL_S" >&2
  exit 1
fi
assert_contains "an unparseable interval is refused, naming the variable" \
  "$invalid_interval_log.out" 'SOL_DESTROY_SNAPSHOT_INTERVAL_S' || exit 1

mismatch_log="$tmp/destroy-snapshot-mismatch.log"
if (cd "$tmp/work" && DESTROYING=1 RDS_SNAPSHOT_MISMATCH=1 \
      LIFECYCLE_LOG="$mismatch_log" "$sol" destroy prod/aws/us-east-1 --apply) \
      >"$mismatch_log.out" 2>&1; then
  echo "a destroy whose prepared snapshot identity does not match the provider's must fail" >&2
  cat "$mismatch_log.out" >&2
  exit 1
fi
assert_contains "the snapshot mismatch was reported" "$mismatch_log.out" \
  'final snapshot identifier is' || exit 1
assert_contains "the retention guarantee is named as the blocker" "$mismatch_log.out" \
  'destruction is blocked' || exit 1
assert_contains "the guarantee is identified" "$mismatch_log.out" \
  'destroy_retention is final-snapshot' || exit 1
if grep -E -- '-chdir=[^ ]*cloud/aws/cluster ' "$mismatch_log" | grep -F ' destroy ' >/dev/null; then
  echo "the substrate destroy ran although the retention guarantee could not be prepared:" >&2
  cat "$mismatch_log" >&2
  exit 1
fi

envs_file="$tmp/work/sol/environments.yml"
awk '{ print } /^    aws\/us-east-1:[[:space:]]*$/ { print "      destroy_retention: none" }' \
  "$envs_file" >"$tmp/work/envs.with-retention.yml"
mv "$tmp/work/envs.with-retention.yml" "$envs_file"
if ! grep -qE '^      destroy_retention:[[:space:]]*none[[:space:]]*$' "$envs_file"; then
  echo "the retention scenario did not get destroy_retention into the AWS target:" >&2
  cat "$envs_file" >&2
  exit 1
fi

log_none="$tmp/destroy-retention-none.log"
if ! run_destroy "$log_none"; then
  cat "$log_none.out" >&2
  echo "a destroy with destroy_retention: none must succeed" >&2
  exit 1
fi
none_line="$(grep -F -- '-target=aws_db_instance.postgres' "$log_none" | head -1)"
if [ -z "$none_line" ]; then
  echo "the prepare stage did not run for a destroy_retention: none target" >&2
  exit 1
fi
case "$none_line" in
  *'rds_skip_final_snapshot=true'*) : ;;
  *)
    echo "destroy_retention: none did not skip the final snapshot; prepare saw: $none_line" >&2
    exit 1
    ;;
esac
case "$none_line" in
  *'rds_final_snapshot_identifier='*)
    echo "destroy_retention: none still named a snapshot to keep: $none_line" >&2
    exit 1
    ;;
esac
assert_contains "preparation established that the snapshot will be skipped" "$log_none.out" \
  'final snapshot skipped (skip_final_snapshot=true)' || exit 1
assert_contains "the disposable destroy reports retaining nothing" "$log_none.out" \
  'retention: none' || exit 1
assert_contains "the disposable destroy names what it checked for residue" "$log_none.out" \
  "no manual or automated snapshot for this target's database" || exit 1
if grep -F 'no residual billable artifacts' "$log_none.out" >/dev/null; then
  echo "the disposable destroy claimed no residual billable artifacts without observing any:" >&2
  cat "$log_none.out" >&2
  exit 1
fi

residue_log="$tmp/destroy-retention-residue.log"
rm -f "$RDS_PREPARED_FILE"
if (export RDS_SNAPSHOT_RESIDUE=1; run_destroy "$residue_log"); then
  echo "a retain-nothing destroy that left a snapshot must fail" >&2
  cat "$residue_log.out" >&2
  exit 1
fi
assert_contains "the residual snapshot was reported by name" "$residue_log.out" \
  'leaked-manual' || exit 1
assert_contains "the residue failure names how many remain" "$residue_log.out" \
  'retain-nothing NOT observed' || exit 1

managed_log="$tmp/destroy-no-managed-queries.log"
rm -f "$RDS_PREPARED_FILE"
if ! run_destroy "$managed_log"; then
  cat "$managed_log.out" >&2
  echo "REFAC-094: the baseline AWS destroy failed" >&2
  exit 1
fi
grep -F 'aws ec2 describe-volumes' "$managed_log" >/dev/null || {
  echo "REFAC-094: the AWS residue (EBS) query is missing from the destroy log" >&2
  exit 1
}
for managed in 'aws eks describe-cluster' 'aws eks describe-addon' \
               'aws rds describe-db-instances --db-instance-identifier'; do
  if grep -F "$managed" "$managed_log" >/dev/null; then
    echo "REFAC-094: the AWS destroy still re-queries a Terraform-managed resource by identity: $managed" >&2
    exit 1
  fi
done

residue_state_log="$tmp/destroy-state-residue.log"
rm -f "$RDS_PREPARED_FILE"
if (export STATE_RESIDUE_AFTER_DESTROY=1; run_destroy "$residue_state_log"); then
  echo "a destroy that left the state representing a resource must fail" >&2
  cat "$residue_state_log.out" >&2
  exit 1
fi
assert_contains "the state residue was reported, by address" "$residue_state_log.out" \
  'STILL REPRESENTS module.eks.aws_eks_cluster.this[0], aws_db_instance.postgres[0]' || exit 1

destroy_tri_log="$tmp/destroy-can-i-indeterminate.log"
rm -f "$FAIL_MARKER_DIR/bootstrap-window"
if ! (cd "$tmp/work" && DESTROYING=1 CAN_I_FAIL=1 LIFECYCLE_LOG="$destroy_tri_log" \
      "$sol" destroy prod/aws/us-east-1 --apply) >"$destroy_tri_log.out" 2>&1; then
  echo "the destroy was blocked by the de-escalation probe, which must never strand a target:" >&2
  cat "$destroy_tri_log.out" >&2
  exit 1
fi
grep -qF 'effective removal could not be verified' "$destroy_tri_log.out" || {
  echo "the destroy completed but never reported that the removal could not be verified:" >&2
  cat "$destroy_tri_log.out" >&2
  exit 1
}
grep -qF 'no usable answer' "$destroy_tri_log.out" || {
  echo "the destroy warning did not name the indeterminate probe:" >&2
  cat "$destroy_tri_log.out" >&2
  exit 1
}

rm -f "$RDS_PREPARED_FILE"
log="$tmp/destroy-absent.log"
if ! (export OUTPUT_ABSENT=1; run_destroy "$log"); then
  cat "$log.out" >&2
  echo "destroy on an absent target must still succeed" >&2
  exit 1
fi
grep -F 'prepare: cloud substrate is absent, nothing to prepare' "$log.out" >/dev/null
if grep -F -- '-target=aws_db_instance.postgres' "$log" >/dev/null; then
  echo "destroy attempted RDS preparation on an absent cloud substrate" >&2
  exit 1
fi

rm -f "$RDS_PREPARED_FILE"
log="$tmp/destroy-no-rds.log"
if ! (export RDS_ABSENT=1; run_destroy "$log"); then
  cat "$log.out" >&2
  echo "destroy on a target with no RDS instance must still succeed" >&2
  exit 1
fi
grep -F 'prepare: no RDS instance for this target, nothing to prepare' "$log.out" >/dev/null
if grep -F -- '-target=aws_db_instance.postgres' "$log" >/dev/null; then
  echo "destroy attempted RDS preparation when no RDS instance exists" >&2
  exit 1
fi

rm -f "$RDS_PREPARED_FILE"
rm -f "$PLATFORM_INSTALLED_FILE"
log="$tmp/destroy-partial-install.log"
if ! run_destroy "$log"; then
  cat "$log.out" >&2
  echo "destroy on a partially installed target must succeed (invariant 6)" >&2
  exit 1
fi
grep -F 'lifecycle phase: PreparingDestroy' "$log.out" >/dev/null || {
  echo "destroy on a partially installed target did not enter the destruction phase:" >&2
  cat "$log.out" >&2
  exit 1
}
grep -F 'lifecycle phase: Destroying' "$log.out" >/dev/null || {
  echo "destroy did not report Destroying while tearing the cloud substrate down:" >&2
  cat "$log.out" >&2
  exit 1
}

if ! grep -lF 'provisioner-bootstrap-access-remove' "$tmp"/*.out >/dev/null 2>&1 &&
   ! grep -lF 'provisioner-bootstrap-access-remove' ./*.out >/dev/null 2>&1; then
  echo "DEC-040 canary: this harness never entered the bootstrap-access-removal phase," >&2
  echo "so it exercised no de-escalation transition at all -- the unit cases would be" >&2
  echo "carrying the whole load without anything here noticing." >&2
  exit 1
fi

if ! grep -lF 'whoami shape: parsed' "$tmp"/*.out >/dev/null 2>&1; then
  echo "DEC-040 canary: the whoami shape gate never reported a parsed response, so either it" >&2
  echo "did not run or it rejected the emulated shape -- the fixtures would be going" >&2
  echo "unvalidated against anything." >&2
  exit 1
fi

ops="$XDG_DATA_HOME/sol/operations"
pre_log="$tmp/infra076-pre.log"
if ! (export FAIL_ON=""; run_apply "$pre_log"); then
  cat "$pre_log.out" >&2
  echo "INFRA-076: the baseline apply failed" >&2
  exit 1
fi
aws_key="$(ls -t "$ops" 2>/dev/null | grep '^aws-' | head -1 || true)"
if [ -z "$aws_key" ] || [ ! -s "$ops/$aws_key/latest" ]; then
  echo "INFRA-076: no operation record for the AWS cloud root under $ops" >&2
  ls -la "$ops" >&2 || true
  exit 1
fi
latest="$ops/$aws_key/$(cat "$ops/$aws_key/latest")"
assert_contains "INFRA-076: the supervisor recorded terraform's outcome" "$latest/exit" 'exited 0' || exit 1

printf 'signaled 9\n' >"$latest/exit"
unresolved_log="$tmp/infra076-unresolved.log"
if (export FAIL_ON=""; run_apply "$unresolved_log"); then
  cat "$unresolved_log.out" >&2
  echo "INFRA-076: an apply proceeded past an unresolved previous operation" >&2
  exit 1
fi
assert_contains "INFRA-076: the unresolved operation is named" "$unresolved_log.out" \
  'refusing to apply: the previous Terraform operation against this state is unresolved' || exit 1
assert_not_contains "INFRA-076: no terraform apply ran" "$unresolved_log.out" '[terraform-apply]' || exit 1

accept_log="$tmp/infra076-accept.log"
if (cd "$tmp/work" && FAIL_ON="" LIFECYCLE_LOG="$accept_log" \
      "$sol" cloud apply prod/aws/us-east-1 --accept-unresolved) >"$accept_log.out" 2>&1; then
  echo "INFRA-076: deploy accepted a bypass for an unresolved Terraform operation" >&2
  exit 1
fi
assert_not_contains "INFRA-076: unresolved operation did not reach terraform apply" \
  "$accept_log.out" '[terraform-apply]' || exit 1
[ ! -e "$latest/acknowledged" ] || {
  echo "INFRA-076: refusal recorded an acknowledgement for an unresolved operation" >&2
  exit 1
}

sleep 60 &
live_pid=$!
running="$ops/$aws_key/99999999T000000Z-running"
mkdir -p "$running"
printf 'host=%s\nsupervisor_pid=%s\nsupervisor_start=\nstarted_at=%s\nroot=%s\n' \
  "$(hostname)" "$live_pid" "$(date +%s)" "$(sed -n 's/^root=//p' "$latest/meta")" >"$running/meta"
printf '%s\n' "$(basename "$running")" >"$ops/$aws_key/latest"
running_log="$tmp/infra076-running.log"
if (export FAIL_ON=""; run_apply "$running_log"); then
  kill "$live_pid" 2>/dev/null || true
  cat "$running_log.out" >&2
  echo "INFRA-076: an apply raced a running previous operation" >&2
  exit 1
fi
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
assert_contains "INFRA-076: the running operation is reported" "$running_log.out" \
  'is still running and holds its lock' || exit 1

printf 'exited 0\n' >"$latest/exit"
platform_key=""
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  dir="$ops/$candidate/$(cat "$ops/$candidate/latest" 2>/dev/null || true)"
  if [ -f "$dir/meta" ] &&
     grep -qxE "root=$XDG_DATA_HOME/sol/terraform/aws-platform-[0-9a-f]{16}/platform/cloud/aws/platform" "$dir/meta"; then
    platform_key="$candidate"
    break
  fi
done < <(ls -t "$ops" 2>/dev/null)
if [ -z "$platform_key" ] || [ ! -s "$ops/$platform_key/latest" ]; then
  echo "AUDIT-POST-004: no operation record for the AWS platform root under $ops" >&2
  ls -la "$ops" >&2 || true
  exit 1
fi

sleep 60 &
platform_live_pid=$!
platform_running="$ops/$platform_key/99999999T000000Z-platform-running"
mkdir -p "$platform_running"
printf 'host=%s\nsupervisor_pid=%s\nsupervisor_start=\nstarted_at=%s\nroot=%s\n' \
  "$(hostname)" "$platform_live_pid" "$(date +%s)" \
  "$(sed -n 's/^root=//p' "$ops/$platform_key/$(cat "$ops/$platform_key/latest")/meta")" \
  >"$platform_running/meta"
printf '%s\n' "$(basename "$platform_running")" >"$ops/$platform_key/latest"
platform_running_log="$tmp/infra076-platform-running.log"
rm -f "$RDS_PREPARED_FILE"
if (export FAIL_ON=""; run_destroy "$platform_running_log"); then
  kill "$platform_live_pid" 2>/dev/null || true
  cat "$platform_running_log.out" >&2
  echo "AUDIT-POST-004: a destroy raced a running platform operation" >&2
  exit 1
fi
kill "$platform_live_pid" 2>/dev/null || true
wait "$platform_live_pid" 2>/dev/null || true
assert_contains "AUDIT-POST-004: the running platform operation is reported" \
  "$platform_running_log.out" 'is still running and holds its lock' || exit 1
if [ -e "$platform_running_log" ] && grep -q 'terraform' "$platform_running_log"; then
  echo "AUDIT-POST-004: the refusal of a running platform operation still ran terraform" >&2
  cat "$platform_running_log" >&2
  exit 1
fi

printf 'signaled 9\n' >"$platform_running/exit"
printf '%s\n' "$(basename "$platform_running")" >"$ops/$platform_key/latest"
platform_unresolved_log="$tmp/infra076-platform-unresolved.log"
rm -f "$RDS_PREPARED_FILE"
if ! (export FAIL_ON=""; run_destroy "$platform_unresolved_log"); then
  cat "$platform_unresolved_log.out" >&2
  echo "AUDIT-POST-004: an unresolved platform operation stopped a destroy" >&2
  exit 1
fi
assert_contains "AUDIT-POST-004: the unresolved platform operation is reported" \
  "$platform_unresolved_log.out" \
  'the previous Terraform operation against this state is unresolved' || exit 1

printf 'exited 0\n' >"$platform_running/exit"
printf '%s\n' "$(basename "$platform_running")" >"$ops/$platform_key/latest"
platform_resolved_log="$tmp/infra076-platform-resolved.log"
rm -f "$RDS_PREPARED_FILE"
if ! (export FAIL_ON=""; run_destroy "$platform_resolved_log"); then
  cat "$platform_resolved_log.out" >&2
  echo "AUDIT-POST-004: a resolved platform operation stopped a destroy" >&2
  exit 1
fi
if grep -qF 'the previous Terraform operation against this state is unresolved' \
     "$platform_resolved_log.out"; then
  echo "AUDIT-POST-004: a resolved platform operation was reported as unresolved" >&2
  exit 1
fi

target_file="$tmp/work/sol/environments.yml"
cp "$target_file" "$tmp/work/target.before-bug057.yml"
mkdir -p "$tmp/work/vars" "$tmp/work/app/deep"
: >"$tmp/work/vars/bug057.tfvars"
: >"$tmp/work/app/deep/flag.tfvars"
awk '{ print } /^    aws\/us-east-1:[[:space:]]*$/ { print "      terraform_var_file: vars/bug057.tfvars" }' \
  "$tmp/work/target.before-bug057.yml" >"$target_file"
vlog="$tmp/bug057-target.log"
(cd "$tmp/work/app/deep" && LIFECYCLE_LOG="$vlog" "$sol" cloud plan prod/aws/us-east-1) \
  >"$vlog.out" 2>&1 || true
if ! grep -F -- "-var-file=$tmp/work/vars/bug057.tfvars" "$vlog" >/dev/null; then
  echo "BUG-057: a target's relative terraform_var_file did not resolve from the workspace root:" >&2
  grep -o -- '-var-file=[^ ]*' "$vlog" "$vlog.out" >&2 || cat "$vlog.out" >&2
  exit 1
fi
flog="$tmp/bug057-flag.log"
(cd "$tmp/work/app/deep" && LIFECYCLE_LOG="$flog" "$sol" cloud plan prod/aws/us-east-1 --var-file flag.tfvars) \
  >"$flog.out" 2>&1 || true
if ! grep -F -- "-var-file=$tmp/work/app/deep/flag.tfvars" "$flog" >/dev/null; then
  echo "BUG-057: a relative --var-file did not resolve from the shell's directory:" >&2
  grep -o -- '-var-file=[^ ]*' "$flog" "$flog.out" >&2 || cat "$flog.out" >&2
  exit 1
fi
if grep -F -- "bug057.tfvars" "$flog" >/dev/null; then
  echo "BUG-057: --var-file did not win over the target's terraform_var_file" >&2
  exit 1
fi
mv "$tmp/work/target.before-bug057.yml" "$target_file"

workdirs="$XDG_DATA_HOME/sol/terraform"
for role in aws-cluster aws-platform gcp-cluster gcp-platform; do
  if ! ls -d "$workdirs/$role"-* >/dev/null 2>&1; then
    echo "DEC-050: no working directory for $role under $workdirs" >&2
    ls -la "$workdirs" >&2 || true
    exit 1
  fi
done
chdirs="$(cat "$tmp"/*.log 2>/dev/null | grep -oE -- '-chdir=[^ ]+' | sort -u | sed 's/^-chdir=//')"
[ -n "$chdirs" ] || { echo "DEC-050: no terraform -chdir recorded" >&2; exit 1; }
while IFS= read -r d; do
  case "$d" in
    "$workdirs"/*/platform/cloud/*/*) ;;
    *) echo "DEC-050: terraform ran outside a working directory: $d" >&2; exit 1 ;;
  esac
done <<<"$chdirs"
echo "DEC-050: every terraform -chdir was a working directory ($(wc -l <<<"$chdirs") distinct)"

if ! strays="$(stray_terraform_state "$root/platform" "$tmp/bin/terraform")"; then
  echo "DEC-050: could not scan Sol's assets for stray Terraform state" >&2
  exit 1
fi
if [ -n "$strays" ]; then
  echo "DEC-050: a Terraform run wrote into Sol's assets:" >&2
  printf '%s\n' "$strays" >&2
  exit 1
fi

aws_wd="$(sed -n 's/^root=//p' "$ops/$aws_key/$(cat "$ops/$aws_key/latest")/meta")"
case "$aws_wd" in "$workdirs"/aws-cluster-*/platform/cloud/aws/cluster) ;; *)
  echo "DEC-050: the AWS cloud root's operation record names $aws_wd" >&2; exit 1 ;;
esac
wd_base="${aws_wd%/platform/cloud/aws/cluster}"
[ -e "$aws_wd/.terraform/fake-init" ] || { echo "DEC-050: init did not run in $aws_wd" >&2; exit 1; }

if [ "$(ls -d "$workdirs"/*-cluster-* | wc -l)" -lt 2 ]; then
  echo "DEC-050: expected a cluster working directory per provider" >&2; ls "$workdirs" >&2; exit 1
fi

run_plan_aws() {
  (cd "$tmp/work" && FAIL_ON="" LIFECYCLE_LOG="$1" "$sol" cloud plan prod/aws/us-east-1) >"$1.out" 2>&1
}

printf 'tampered\n' >"$aws_wd/main.tf"
: >"$aws_wd/stale-from-an-older-release.tf"
printf 'platform/cloud/aws/cluster/stale-from-an-older-release.tf\n' >>"$wd_base/.sol-materialized"
printf 'operator notes\n' >"$aws_wd/operator-notes.txt"
refresh_log="$tmp/dec050-refresh.log"
run_plan_aws "$refresh_log" || { cat "$refresh_log.out" >&2; echo "DEC-050: plan failed" >&2; exit 1; }
cmp -s "$aws_wd/main.tf" "$root/platform/cloud/aws/cluster/main.tf" ||
  { echo "DEC-050: a tampered source file survived re-materialization" >&2; exit 1; }
[ ! -e "$aws_wd/stale-from-an-older-release.tf" ] ||
  { echo "DEC-050: a source file the assets no longer have was left in place" >&2; exit 1; }
[ -e "$aws_wd/operator-notes.txt" ] ||
  { echo "DEC-050: a file Sol did not write was removed" >&2; exit 1; }
[ -e "$aws_wd/.terraform/fake-init" ] ||
  { echo "DEC-050: Terraform's own directory was removed" >&2; exit 1; }
echo "DEC-050: re-materialization restores sources, drops stale ones, keeps what Sol did not write"

# An existing provenance record that cannot be read is not a first run: treating
# it as one would leave stale copied sources active while losing the cleanup
# history. The read must fail closed, before Terraform evaluates the directory.
cp "$wd_base/.sol-materialized" "$tmp/dec050-manifest.expected"
mv "$wd_base/.sol-materialized" "$wd_base/.sol-materialized.keep"
mkdir "$wd_base/.sol-materialized"
unreadable_log="$tmp/dec050-unreadable-manifest.log"
if run_plan_aws "$unreadable_log"; then
  cat "$unreadable_log.out" >&2
  echo "DEC-050: a plan proceeded with an unreadable materialization manifest" >&2
  exit 1
fi
assert_contains "DEC-050: the refusal names the manifest" "$unreadable_log.out" \
  ".sol-materialized" || exit 1
if grep -E '^terraform .* plan( |$)' "$unreadable_log" >/dev/null 2>&1; then
  echo "DEC-050: terraform plan ran despite the unreadable manifest:" >&2
  grep -E '^terraform .* plan' "$unreadable_log" >&2
  exit 1
fi
rmdir "$wd_base/.sol-materialized"
mv "$wd_base/.sol-materialized.keep" "$wd_base/.sol-materialized"
cmp -s "$wd_base/.sol-materialized" "$tmp/dec050-manifest.expected" ||
  { echo "DEC-050: the refused run changed the materialization manifest" >&2; exit 1; }
echo "DEC-050: an unreadable materialization manifest refuses before Terraform"

printf '{"version":4,"serial":7,"lineage":"dec050"}\n' >"$aws_wd/errored.tfstate"
cp "$aws_wd/errored.tfstate" "$tmp/errored.expected"
errored_log="$tmp/dec050-errored.log"
if (export FAIL_ON=""; run_apply "$errored_log"); then
  cat "$errored_log.out" >&2
  echo "DEC-050: an apply proceeded past an errored.tfstate in its working directory" >&2
  exit 1
fi
assert_contains "DEC-050: the errored state is named at its working-directory path" \
  "$errored_log.out" "$aws_wd/errored.tfstate" || exit 1
cmp -s "$aws_wd/errored.tfstate" "$tmp/errored.expected" ||
  { echo "DEC-050: a refused apply touched errored.tfstate" >&2; exit 1; }
errored_plan_log="$tmp/dec050-errored-plan.log"
run_plan_aws "$errored_plan_log" || { cat "$errored_plan_log.out" >&2; echo "DEC-050: plan failed" >&2; exit 1; }
errored_accept_log="$tmp/dec050-errored-accept.log"
if (cd "$tmp/work" && FAIL_ON="" LIFECYCLE_LOG="$errored_accept_log" \
      "$sol" cloud apply prod/aws/us-east-1 --accept-unresolved) >"$errored_accept_log.out" 2>&1; then
  echo "DEC-050: deploy accepted an errored Terraform state" >&2
  exit 1
fi
assert_not_contains "DEC-050: errored state did not reach terraform apply" \
  "$errored_accept_log.out" '[terraform-apply]' || exit 1
cmp -s "$aws_wd/errored.tfstate" "$tmp/errored.expected" ||
  { echo "DEC-050: errored.tfstate did not survive a plan and refused deploy" >&2; exit 1; }
rm -f "$aws_wd/errored.tfstate"
echo "DEC-050: errored.tfstate is reported, refuses apply, and survives re-materialization"

ro_home="$tmp/ro-sol-home"
mkdir -p "$ro_home/framework/ocaml/sol-svc/lib" "$ro_home/framework/ocaml/kafka-eio-service/lib"
: >"$ro_home/framework/ocaml/sol-svc/lib/dune"
: >"$ro_home/framework/ocaml/kafka-eio-service/lib/dune"
cp -r "$root/platform" "$ro_home/platform"
find "$ro_home/platform" \( -name .terraform -o -name '*.tfstate' \) -prune -exec rm -rf {} +
chmod -R a-w "$ro_home"
ro_log="$tmp/dec050-readonly.log"
if ! (cd "$tmp/work" && FAIL_ON="" SOL_HOME="$ro_home" LIFECYCLE_LOG="$ro_log" \
        "$sol" cloud plan prod/aws/us-east-1) >"$ro_log.out" 2>&1; then
  chmod -R u+w "$ro_home"
  cat "$ro_log.out" >&2
  echo "DEC-050: sol plan failed against read-only assets" >&2
  exit 1
fi
chmod -R u+w "$ro_home"
grep -q -- "-chdir=$workdirs/" "$ro_log" || { echo "DEC-050: read-only run did not use a working directory" >&2; exit 1; }
echo "DEC-050: sol plan runs against read-only assets"

if ! SOL_DESTROY_SNAPSHOT_INTERVAL_S=abc "$sol" --version >/dev/null 2>&1; then
  echo "REFAC-115: a malformed SOL_DESTROY_SNAPSHOT_INTERVAL_S broke an unrelated command" >&2
  exit 1
fi
interval_log="$tmp/refac115-interval.log"
cp "$tmp/work/sol/environments.yml" "$tmp/work/envs.before-refac115.yml"
awk '/^    aws\/us-east-1:[[:space:]]*$/ { in_aws = 1; print; next }
     /^    [^ ]/ { in_aws = 0 }
     !(in_aws && /^      destroy_retention:[[:space:]]*none[[:space:]]*$/) { print }' \
  "$tmp/work/envs.before-refac115.yml" >"$tmp/work/sol/environments.yml"
retention_region="$(grep -A3 '^    aws/us-east-1:' "$tmp/work/sol/environments.yml" || true)"
case "$retention_region" in
  *'destroy_retention: none'*)
    echo "REFAC-115: could not put the AWS target back on final-snapshot retention" >&2
    exit 1
    ;;
esac
for bad in abc inf -1 nan; do
  if (cd "$tmp/work" && FAIL_ON="" DESTROYING=1 SOL_DESTROY_SNAPSHOT_INTERVAL_S="$bad" \
        LIFECYCLE_LOG="$interval_log" "$sol" destroy prod/aws/us-east-1 --apply) \
      >"$interval_log.out" 2>&1; then
    cat "$interval_log.out" >&2
    echo "REFAC-115: a destroy proceeded with SOL_DESTROY_SNAPSHOT_INTERVAL_S=$bad" >&2
    exit 1
  fi
  assert_contains "REFAC-115: the refusal names the setting" "$interval_log.out" \
    "SOL_DESTROY_SNAPSHOT_INTERVAL_S=\"$bad\" is not a non-negative number of seconds" || exit 1
  if grep -E '^terraform .* destroy( |$)' "$interval_log" >/dev/null 2>&1; then
    echo "REFAC-115: terraform destroy ran despite the refused preparation:" >&2
    grep -E '^terraform .* destroy' "$interval_log" >&2
    exit 1
  fi
done
mv "$tmp/work/envs.before-refac115.yml" "$tmp/work/sol/environments.yml"
echo "REFAC-115: a malformed or unbounded snapshot interval refuses the destroy, and only the destroy"

if ! ls -d "$XDG_DATA_HOME"/sol/runs/cloud-* >/dev/null 2>&1; then
  echo "INFRA-075 canary: no cloud-* run logs under the isolated" >&2
  echo "XDG_DATA_HOME ($XDG_DATA_HOME), so this harness wrote its runs somewhere else --" >&2
  echo "probably the operator's real Sol home, where they prune real evidence." >&2
  exit 1
fi

# The deploy handoff is how an operator or a harness reaches the cluster this target
# owns, and it comes from Terraform state — so it is live state: reported under
# --check, alongside the other live observations, and omitted entirely when the
# root declares none. An identity-only report carries none of it.
echo
echo "sol target show: the deploy handoff is live state, reported only under --check"
show_target() { (cd "$tmp/work" && LIFECYCLE_LOG="$tmp/target-show.log" "$sol" target show --target=prod/aws/us-east-1 "$@"); }
if ! show_target --check --json >"$tmp/target-check.json" 2>"$tmp/target-check.err"; then
  echo "sol target show --check --json failed in the offline environment:" >&2
  cat "$tmp/target-check.err" >&2
  exit 1
fi
assert_contains "the cloud root's own deploy command is reported as its own field" \
  "$tmp/target-check.json" \
  '"deploy_kubeconfig_command":"aws eks update-kubeconfig --region us-east-1 --name lifecycle-test --alias lifecycle-test-deploy --role-arn arn:aws:iam::111122223333:role/sol-deploy"'
assert_contains "and the context that command writes" \
  "$tmp/target-check.json" '"deploy_kube_context":"lifecycle-test-deploy"'

show_target --json >"$tmp/target-plain.json" 2>/dev/null || true
assert_not_contains "an identity-only report reads no cloud state, so it carries no handoff" \
  "$tmp/target-plain.json" '"deploy_kubeconfig_command":'
assert_not_contains "and no context either" "$tmp/target-plain.json" '"deploy_kube_context":'

OUTPUT_ABSENT=1 show_target --check --json >"$tmp/target-absent.json" 2>/dev/null || true
assert_not_contains "a root that declares no handoff reports none, rather than a default" \
  "$tmp/target-absent.json" '"deploy_kubeconfig_command":'
assert_not_contains "and no context is invented" "$tmp/target-absent.json" '"deploy_kube_context":'
