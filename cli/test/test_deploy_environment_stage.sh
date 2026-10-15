#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
sol="$(realpath "${1:-$root/_build/default/cli/bin/main.exe}")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "test_deploy_environment_stage: $what: expected $expected, got $actual" >&2
    fail=1
  fi
}
check_contains() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *)
      echo "test_deploy_environment_stage: $what: expected to find '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}
check_absent() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "test_deploy_environment_stage: $what: did not expect '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}
check_file_contains() {
  local what="$1" needle="$2" path="$3"
  local text=""
  [ -e "$path" ] && text="$(cat "$path")"
  check_contains "$what" "$needle" "$text"
}
check_file_absent() {
  local what="$1" needle="$2" path="$3"
  local text=""
  [ -e "$path" ] && text="$(cat "$path")"
  check_absent "$what" "$needle" "$text"
}

mkdir -p "$tmp/bin" "$tmp/work/sol" "$tmp/work/app/payments/charge_svc" "$tmp/markers" "$tmp/xdg"
cp "$root"/internal/ci/lifecycle_fakes/* "$tmp/bin/"

cat >"$tmp/bin/docker" <<EOF
#!/bin/sh
printf 'docker %s\n' "\$*" >>"\$LIFECYCLE_LOG"
printf '{"schemaVersion":2}\n'
exit 0
EOF
chmod +x "$tmp/bin/docker"

printf 'FROM scratch\n' >"$tmp/work/app/payments/charge_svc/Dockerfile"
cat >"$tmp/work/sol.yml" <<'EOF'
project: environment-stage-test
resources:
  app_db:
    type: postgres
services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
    language: ocaml
EOF

cat >"$tmp/work/sol/environments.yml" <<'EOF'
prod:
  dns_zone_ownership: sol
  targets:
    aws/us-east-1:
      profile: production-single-region
      shape: durable
      base_domain: example.test
      cluster_name: lifecycle-test
      letsencrypt_email: ops@example.test
      cluster_endpoint_cidr: 203.0.113.0/24
      state_bucket: lifecycle-state
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
      aws:
        state_lock_table: lifecycle-lock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
      resources:
        app_db:
          size: small
prod/missing-alerts:
  profile: production-single-region
  shape: durable
EOF

export SOL_HOME="$root"
export XDG_DATA_HOME="$tmp/xdg"
export PATH="$tmp/bin:/usr/bin:/bin"
export TF_VAR_db_password=offline-only
export KUBECONFIG=/ambient/forbidden
export FAIL_MARKER_DIR="$tmp/markers"
export SOL_WHOAMI_RETRY_INTERVAL_S=0
export KUBECONFIG_LOG="$tmp/kubeconfigs"
export PLATFORM_INSTALLED_FILE="$tmp/markers/platform-installed"
export SOL_QUALIFICATION_CAPTURE_DIR="$tmp"
export LIFECYCLE_LOG="$tmp/lifecycle.log"
export INSTALLATION_PRESENT=1
export POSTGRES_URL=postgresql://user:pass@localhost:5432/db
export SOL_API_KEY=environment-stage-test-key

reset_run() {
  rm -rf "$tmp/xdg/sol" "$tmp/lifecycle.log" "$tmp/kubeconfigs" "$tmp/markers"
  mkdir -p "$tmp/markers"
}

run_deploy() {
  local target="$1"
  shift
  reset_run
  set +e
  output="$(
    cd "$tmp/work" &&
      timeout 300 "$sol" deploy "$target" --image-tag deadbeef \
        --registry registry.example.test/environment-stage "$@" 2>&1 </dev/null
  )"
  rc=$?
  set -e
}

run_deploy_with() {
  local target="$1" extra_path="$2"
  shift 2
  reset_run
  set +e
  output="$(
    cd "$tmp/work" &&
      PATH="$extra_path" timeout 300 "$sol" deploy "$target" --image-tag deadbeef \
        --registry registry.example.test/environment-stage "$@" 2>&1 </dev/null
  )"
  rc=$?
  set -e
}

log=""
lifecycle_log() {
  cat "$tmp/lifecycle.log" 2>/dev/null || true
}

image_ref="charge_svc=registry.example.test/environment-stage/charge-svc@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

run_deploy prod/aws/us-east-1 --image-ref "$image_ref"
check "a first run whose profile preflight is unmet refuses" 1 "$rc"
check_contains \
  "the cheap, knowable blocker is reported" \
  "preflight found" \
  "$output"
check_contains "the refusal changes nothing" "Nothing was changed." "$output"
check_absent \
  "a knowable blocker stops the run before it provisions anything" \
  "terraform" \
  "$(lifecycle_log)"
check_absent \
  "a knowable blocker stops the run before it reaches the provider" \
  "aws " \
  "$(lifecycle_log)"

sed -i 's|^      state_bucket: lifecycle-state$|      state_bucket: lifecycle-state\n      alert_receiver_type: webhook\n      alert_receiver_url: https://alerts.example.test/hook\n      alert_owner: ops@example.test\n      alert_runbook_url: https://runbooks.example.test/prod|' \
  "$tmp/work/sol/environments.yml"

SOL_SETUP_POSTGRES_IMAGE= run_deploy prod/aws/us-east-1 --image-ref "$image_ref"
check "a missing setup image refuses" 1 "$rc"
check_contains "the refusal names the setup image" "SOL_SETUP_POSTGRES_IMAGE" "$output"
check_absent "a missing setup image never reaches Terraform" "terraform" "$(lifecycle_log)"
export SOL_SETUP_POSTGRES_IMAGE="postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

run_deploy prod/aws/us-east-1 --image-ref "$image_ref"
check_contains "the profile preflight passes before provisioning" \
  "Profile: production-single-region/v1 (preflight passed)" "$output"
check_contains \
  "a target with no destination is reported as the first run" \
  "This target names no Kubernetes destination Sol can reach from here" \
  "$output"
check_contains \
  "deploy reconciles the whole target's environment" \
  "Reconciling the whole target prod/aws/us-east-1" \
  "$output"
check_file_contains \
  "the run provisions the environment's cluster root" \
  "cloud/aws/cluster" \
  "$tmp/lifecycle.log"
check_file_contains "the run plans the environment" " plan " "$tmp/lifecycle.log"
check_file_contains "the run applies the environment" " apply " "$tmp/lifecycle.log"
check_file_contains \
  "the environment stage reaches the platform" \
  "cloud/aws/platform" \
  "$tmp/lifecycle.log"
check_contains \
  "the run reports the environment provisioned" \
  "The environment for prod/aws/us-east-1 is reconciled." \
  "$output"
check_file_contains \
  "the run establishes its own deploy-identity cluster access" \
  "eks update-kubeconfig" \
  "$tmp/lifecycle.log"
check_file_contains \
  "and it is the deploy identity, not the provisioning one" \
  "--role-arn arn:aws:iam::111122223333:role/sol-deploy" \
  "$tmp/lifecycle.log"
check_contains \
  "the run names the ephemeral identity it deploys as" \
  "role/sol-deploy (this run, ephemeral)" \
  "$output"
check \
  "the deploy identity is the last role this run configured" \
  "sol-deploy" \
  "$(cat "$tmp/markers/kubeconfig-role" 2>/dev/null || true)"
check_file_contains \
  "the run reaches the deploy's own prerequisites with that access" \
  "kubectl" \
  "$tmp/lifecycle.log"
check_contains \
  "the deploy stops for the next real prerequisite, not for the destination" \
  "error:" \
  "$output"
check_absent \
  "a provisioned environment is never reported as still needing a separate cloud apply" \
  "create it — network, cluster, database and platform — with:" \
  "$output"

# **#1413: a target whose images are not published yet provisions the registry it needs, then
# stops before any workload moves. The provision is reported as a completed step, not as a
# failed deploy.** The workload-issuer prerequisite is made unavailable so that a run which
# (incorrectly) continued past the artifact gate would reach it and be caught below.
OIDC_ISSUER_UNAVAILABLE=1 run_deploy prod/aws/us-east-1
check "a cold target with no published digests exits 1" 1 "$rc"
check_contains \
  "the run reports a completed provision and a pending artifact, not a failed deploy" \
  "Deployment incomplete" "$output"
check_contains \
  "and names the repository the operator must publish to" \
  "registry.example.test/environment-stage/work/charge-svc" "$output"
check_contains \
  "and the re-run that will apply it" \
  "sol deploy prod/aws/us-east-1" "$output"
check_file_contains \
  "the cold run still reconciles the environment (its registry)" \
  "cloud/aws/cluster" "$tmp/lifecycle.log"
check_absent \
  "the cold run never claims the preflight passed" \
  "(preflight passed)" "$output"
check_absent \
  "and never reaches the workload prerequisites" \
  "could not establish the target's trusted Kubernetes workload issuer" "$output"
check_absent \
  "the pending run never reports a successful deployment" \
  "service(s) deployed" "$output"
check_absent \
  "and records no release" \
  "sol-release" "$tmp/lifecycle.log"

OIDC_ISSUER_UNAVAILABLE=1 run_deploy prod/aws/us-east-1 --image-ref "$image_ref"
check_contains \
  "an unavailable issuer refuses an svc deployment" \
  "error: could not establish the target's trusted Kubernetes workload issuer:" \
  "$output"
check_contains \
  "the refusal explains the target capability requirement" \
  "deployments containing a svc require a target that establishes workload identity" \
  "$output"

run_deploy prod/aws/us-east-1 --image-ref "$image_ref" --dry-run
check_absent \
  "a dry run never provisions the environment" \
  "terraform" \
  "$(lifecycle_log)"
check_contains \
  "a dry run names the environment stage it will not drive" \
  "reconcile it — network, cluster, database and platform — with:" \
  "$output"
check_contains \
  "and the command that does" \
  "sol deploy prod/aws/us-east-1" \
  "$output"
check "a dry run with no destination exits 1" 1 "$rc"

echo "test_deploy_environment_stage: the environment stage provisions, and the deploy reaches its own cluster."
exit "$fail"
