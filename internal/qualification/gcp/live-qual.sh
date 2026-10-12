#!/usr/bin/env bash
set -euo pipefail
trap '' PIPE

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
TFVARS="$ROOT/internal/qualification/gcp/qual-gcp.tfvars"
OBSERVER="${OBSERVER:-$ROOT/internal/qualification/gcp/observer.py}"

TARGET_FILE="$WORKSPACE/sol/environments.local.yml"

ROW="${ROW:-qual}"
PROVIDER=gcp
ATTEMPT="${ATTEMPT:-}"
TARGET="${TARGET:-$ROW-$ATTEMPT/gcp/us-central1}"
TARGET_ENV="${TARGET%%/*}"
TARGET_KEY="${TARGET#*/}"
STATE_KEY="sol/$TARGET/cloud.tfstate/default.tfstate"
TARGET_MARK="# Written by internal/qualification/gcp/live-qual.sh for $TARGET; each phase rewrites it for the target that phase needs, and it is removed after a verified teardown."

PROJECT="${PROJECT:-sol-qualification}"
REGION="${REGION:-us-central1}"
export PROJECT REGION
BASE_DOMAIN="${BASE_DOMAIN:-qual-gcp.sol-fab.dev}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-2700}"
DELEGATION_WAIT_MINUTES="${DELEGATION_WAIT_MINUTES:-25}"
LOG_DIR="${LOG_DIR:-/tmp/sol-gcp-qual-$ATTEMPT}"
export LOG_DIR
RUN_KUBECONFIG="$LOG_DIR/run-kubeconfig.yaml"
export KUBECONFIG="$RUN_KUBECONFIG"
STATE_BUCKET="${STATE_BUCKET:-sol-qualification-tfstate}"
PROFILE_NAME="${PROFILE_NAME:-production-single-region}"
CLUSTER_ISSUER="${CLUSTER_ISSUER:-letsencrypt-staging}"
APP_TAG="${APP_TAG:-qual-$(date -u +%Y%m%d-%H%M%S)}"
export APP_TAG

case "${1:-}" in
  cloud | platform | app)
    CLUSTER="${CLUSTER:?Set CLUSTER to a unique cluster name for this run, e.g. sol-qual-gcp-5}"
    IMPERSONATOR="${IMPERSONATOR:?Set IMPERSONATOR to the calling identity, e.g. user:you@example.com}"
    LE_EMAIL="${LE_EMAIL:?Set LE_EMAIL to an ACME contact address}"
    ;;
  destroy | verify | "")
    if [ -n "${1:-}" ]; then
      CLUSTER="${CLUSTER:?Set CLUSTER to the cluster name to check}"
      IMPERSONATOR="${IMPERSONATOR:?Set IMPERSONATOR to the calling identity, e.g. user:you@example.com}"
    fi
    ;;
esac

ZONE_NAME="$(printf '%s' "$BASE_DOMAIN" | tr '.' '-')"
ZONE_LABEL="${BASE_DOMAIN%%.*}"

say() {
  local line
  printf -v line '[%(%H:%M:%S)T] %s' -1 "$*"
  if [ -n "${SAY_LOG:-}" ]; then
    printf '%s\n' "$line" >>"$SAY_LOG" 2>/dev/null || true
  fi
  printf '%s\n' "$line" 2>/dev/null || true
}

dns_ns() {
  local name="$1" out
  out="$(curl -s -H 'accept: application/dns-json' \
      "https://dns.google/resolve?name=$name&type=NS" 2>/dev/null \
    | python3 -c "import sys,json;print('\n'.join(sorted(a.get('data','') for a in json.load(sys.stdin).get('Answer',[]))))" 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else dig +short NS "$name" 2>/dev/null || true; fi
}

assert_environment() {
  local top
  top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "✗ $ROOT is not inside a git work tree — refusing to run." >&2
    echo "  A qualification run is identified by the revision it ran from, so it needs one." >&2
    exit 2
  }
  if [ "$(cd "$top" && pwd -P)" != "$(cd "$ROOT" && pwd -P)" ]; then
    echo "✗ refusing: the harness lives in $ROOT but its work tree's top level is $top." >&2
    exit 2
  fi
  local canonical
  canonical="$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{ if (!found) { print $2; found = 1 } }')"
  if [ "$(cd "$canonical" && pwd -P)" = "$(cd "$ROOT" && pwd -P)" ] && [ "${ALLOW_CANONICAL:-0}" != "1" ]; then
    echo "✗ refusing to run in the canonical checkout ($ROOT)." >&2
    echo "  Run from a worktree, or set ALLOW_CANONICAL=1 if you own this checkout." >&2
    exit 2
  fi
}
assert_environment

source "$ROOT/internal/qualification/sol-under-test.sh"
source "$ROOT/internal/qualification/candidate-binding.sh"
source "$ROOT/internal/qualification/attempt.sh"
case "${1:-}" in
  cloud | app | destroy | stop)
    sol_under_test_resolve
    ;;
esac

disposable_state_present() {
  gcloud storage objects describe "gs://$STATE_BUCKET/$STATE_KEY" --project "$PROJECT" \
    >/dev/null 2>&1
}

mkdir -p "$LOG_DIR"
SAY_LOG="$LOG_DIR/harness.log"
case "${1:-}" in
  cloud)
    attempt_begin 1
    ;;
  app | destroy | identity)
    attempt_begin 0
    ;;
esac
say "environment: work tree $ROOT, revision $(git -C "$ROOT" rev-parse --short HEAD)"
case "${1:-}" in
  cloud | app | destroy | stop)
    sol_under_test_record_identity "$LOG_DIR"
    say "sol-under-test: release $SOL_BUNDLE_VERSION at $SOL_INSTALL"
    say "  migration runner: $SOL_RUNNER_IMAGE"
    ;;
esac
echo "$$" >"$LOG_DIR/run.pid"
ps -o pgid= -p "$$" 2>/dev/null | tr -d " " >"$LOG_DIR/run.pgid" || true
DB_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
export TF_VAR_db_password="$DB_PASSWORD"

KEEP=0
BUNDLE_ATTEMPTED=0
BUNDLE_OK=0
INSTALL_STATE=none
APP_STATE=none
CLOUD_APPLIED=0
TEARDOWN_ATTEMPTED=0
TERMINATION_SIGNAL=""

run() {
  local name="$1"; local rc=0; shift
  say "phase: $name"
  ( cd "$WORKSPACE" && timeout "$PHASE_TIMEOUT" "$@" ) >"$LOG_DIR/$name.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$rc" = 124 ]; then
      say "FAILED: $name  (THE HARNESS ENDED IT after ${PHASE_TIMEOUT}s, not Sol: this deadline killed a phase that was still working, so the log above ends mid-step. Raise PHASE_TIMEOUT for a cold run.)"
    else
      say "FAILED: $name  (exit $rc; last 40 lines; full log $LOG_DIR/$name.log)"
    fi
    tail -n 40 "$LOG_DIR/$name.log" || true
    return 1
  fi
  say "ok: $name"
}

# The whole-target deploy reconciles the durable installation inline (DEC-057 §2), and on an
# account whose installation is not established it offers to set it up through one
# interactive confirmation. The run drives that confirmation through a pty with a single
# 'y'; an account whose installation is already established is deployed to without a
# prompt, and the extra 'y' is left unread. A deploy also verifies immutable --image-ref
# manifests before it applies anything, so the bootstrap deploy names a tag: the Artifact
# Registry repositories it is about to create are where the app phase later pushes the
# digests this run pins. Its exit status is returned rather than fatal, because the deploy
# is expected to stop at the workloads those digests belong to.
bootstrap_deploy() {
  local name="$1"
  say "phase: $name"
  local command="exec '$SOL' deploy '$TARGET' --registry '$(app_registry)' --image-tag '$APP_TAG'"
  local rc=0
  if command -v script >/dev/null 2>&1; then
    ( cd "$WORKSPACE" && printf 'y\n' | timeout "$PHASE_TIMEOUT" script -qec "$command" /dev/null ) \
      >"$LOG_DIR/$name.log" 2>&1 || rc=$?
  else
    ( cd "$WORKSPACE" && timeout "$PHASE_TIMEOUT" bash -c "$command" ) \
      >"$LOG_DIR/$name.log" 2>&1 || rc=$?
  fi
  if [ "$rc" != 0 ]; then
    say "note: $name exited $rc (expected once the substrate is reconciled; last 40 lines; full log $LOG_DIR/$name.log)"
    tail -n 40 "$LOG_DIR/$name.log" || true
  fi
  return "$rc"
}

# `sol deploy` prints this once the durable installation and the environment are
# reconciled, before it moves on to the workloads. It is the signal that the bootstrap
# deploy reached the substrate even when the workload stage later stops on images that do
# not exist yet.
environment_reconciled() {
  grep -qF "The environment for $TARGET is reconciled." "$LOG_DIR"/cloud-apply*.log 2>/dev/null
}

# A deploy that refused at the installation boundary applies nothing, so teardown must stay
# disarmed for a target this run never touched. Once the durable/cluster phase ran -- or the
# environment was reconciled -- disposable resources exist that this run owns, so cleanup is
# armed even if a later phase failed.
cloud_mutated() {
  environment_reconciled ||
    grep -qF 'lifecycle phase: CloudBootstrap' "$LOG_DIR"/cloud-apply*.log 2>/dev/null
}

platform_credential_missing() {
  grep -qF 'the platform install cannot start' "$LOG_DIR/cloud-apply.log" 2>/dev/null &&
    grep -qF 'redpanda-users' "$LOG_DIR/cloud-apply.log" 2>/dev/null
}

supply_platform_credential() {
  local source
  if [ -n "${KAFKA_SASL_PASSWORD:-}" ]; then
    source="operator-supplied"
  else
    source="generated-for-this-run"
    KAFKA_SASL_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
  fi
  if ! kubectl create secret generic redpanda-users -n redpanda \
      --from-literal="users.txt=sol-workloads:$KAFKA_SASL_PASSWORD:SCRAM-SHA-256" \
      >"$LOG_DIR/platform-credential.log" 2>&1; then
    say "  could not create the platform's documented prerequisite Secret redpanda/redpanda-users"
    say "  (see $LOG_DIR/platform-credential.log); the harness stands in for the operator and will not proceed without it"
    return 1
  fi
  {
    printf 'platform_credential: redpanda/redpanda-users\n'
    printf 'platform_credential_username: sol-workloads\n'
    printf 'platform_credential_source: %s\n' "$source"
    printf 'platform_credential_value: never recorded\n'
  } >>"$LOG_DIR/prerequisites.txt"
  say "supplied the documented pre-platform Secret redpanda/redpanda-users ($source); its value is never recorded"
}

owns_target_file() {
  if [ ! -s "$TARGET_FILE" ]; then return 0; fi
  head -1 "$TARGET_FILE" | grep -qF "live-qual.sh"
}

remove_target() {
  if owns_target_file; then rm -f "$TARGET_FILE"; fi
}

write_target() {
  mkdir -p "$(dirname "$TARGET_FILE")"
  if [ -f "$TARGET_FILE" ] && ! owns_target_file; then
    say "REFUSING: $TARGET_FILE exists and was not written by this harness; move it aside first."
    exit 2
  fi
  cat >"$TARGET_FILE" <<YAML
$TARGET_MARK
$TARGET_ENV:
  targets:
    $TARGET_KEY:
      cluster_name: $CLUSTER
      base_domain: $BASE_DOMAIN
      dns_zone_ownership: sol
      profile: $PROFILE_NAME
      letsencrypt_email: $LE_EMAIL
      cluster_issuer: $CLUSTER_ISSUER
      terraform_var_file: $TFVARS

      state_bucket: $STATE_BUCKET

      kube_context: $(app_kube_context)

      gcp:
        project_id: $PROJECT
        provisioner_impersonator: $IMPERSONATOR

      destroy_retention: none

      # This target selects a profile, and a profiled target requires an authority for every
      # key its units need. The production profile's Kafka is authenticated, so each unit the
      # row includes needs these two declared; the platform supplies them, so the authority is
      # sol. The same declaration the example's own profile target makes.
      secrets:
        payments/orders_svc:
          KAFKA_SASL_PASSWORD:
            authority: sol
          KAFKA_SSL_CA_CERT:
            authority: sol
        comms/fulfilment_worker:
          KAFKA_SASL_PASSWORD:
            authority: sol
          KAFKA_SSL_CA_CERT:
            authority: sol
        demo_ts/order_svc:
          KAFKA_SASL_PASSWORD:
            authority: sol
          KAFKA_SSL_CA_CERT:
            authority: sol
        demo_ts/fulfillment_worker:
          KAFKA_SASL_PASSWORD:
            authority: sol
          KAFKA_SSL_CA_CERT:
            authority: sol

      resources:
        app_db:
          size: small
        events: {}
      services:
        orders_svc: {}
        fulfilment_worker: {}
        order_svc: {}
        fulfillment_worker: {}
        charge_svc:
          omit: true
        notify_worker:
          omit: true
        checkout_svc:
          omit: true
YAML
  say "wrote target $TARGET ($TARGET_FILE)"
}

cloud_vars() {
  printf '%s\n' \
    "--var-file=$TFVARS" \
    "--var=cluster_name=$CLUSTER" \
    "--var=base_domain=$BASE_DOMAIN"
}

destroy_vars() {
  local zone_var="create_dns_zone=false"
  [ "${KEEP_DNS_ZONE:-1}" = "0" ] && zone_var="create_dns_zone=true"
  printf '%s\n' \
    "--var-file=$TFVARS" \
    "--var=cluster_name=$CLUSTER" \
    "--var=base_domain=$BASE_DOMAIN" \
    "--var=$zone_var" \
    "--var=provisioner_impersonators=[\"$IMPERSONATOR\"]"
}


provider_probe() {
  local class="$1" expect="$2"; shift 2
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" verdict
  if "$@" >"$out" 2>"$err"; then
    if [ -n "$(tr -d '[:space:]' <"$out")" ]; then verdict=PRESENT; else verdict=ABSENT; fi
  elif grep -qiE '(not[_. -]?found|does not exist|404|No URLs matched)' "$err" "$out"; then
    verdict=ABSENT
  else
    verdict=UNKNOWN
  fi
  printf '%s\t%s\t%s\t%s\n' \
    "$class" "$verdict" "$expect" "$(head -1 "$err" "$out" 2>/dev/null | cut -c1-100)" >>"$INVENTORY_TSV"
  say "    $class: $verdict"
}

verdict_row() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$INVENTORY_TSV"
  say "    $1: $2${4:+ ($4)}"
}

PROVISIONER_SA_VERDICT=""
probe_service_account() {
  local class="$1" email="$2"
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" verdict detail=""
  gcloud iam service-accounts describe "$email" --project "$PROJECT" --format='value(email)' \
    >"$LOG_DIR/inventory-$class.describe.log" 2>&1 || true
  if gcloud iam service-accounts list --project "$PROJECT" --format='value(email)' \
       >"$out" 2>"$err"; then
    if grep -qxF "$email" "$out"; then
      verdict=PRESENT; detail="active in the project's service-account list"
    else
      verdict=ABSENT
      if grep -qE 'PERMISSION_DENIED|NOT_FOUND|Unknown service account' \
           "$LOG_DIR/inventory-$class.describe.log" 2>/dev/null; then
        detail="not in the active list, and its describe is unreadable (deleted identity) — see the raw logs"
      else
        detail="absent from the active list"
      fi
    fi
  else
    verdict=UNKNOWN; detail="the authoritative service-account list could not be read"
  fi
  PROVISIONER_SA_VERDICT="$verdict"
  verdict_row "$class" "$verdict" absent "$detail"
}

probe_impersonator_binding() {
  local class="$1" identity_verdict="$2" email="$3"
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" verdict detail=""
  if [ "$identity_verdict" = "ABSENT" ]; then
    gcloud iam service-accounts get-iam-policy "$email" --project "$PROJECT" \
      --flatten='bindings[].members' --filter="bindings.members=$IMPERSONATOR" \
      --format='value(bindings.role)' >"$LOG_DIR/inventory-$class.policy.log" 2>&1 || true
    verdict=ABSENT
    detail="the identity the grant is on is not active, so it cannot be impersonated (raw policy read kept)"
  elif [ "$identity_verdict" = "PRESENT" ]; then
    if gcloud iam service-accounts get-iam-policy "$email" --project "$PROJECT" \
         --flatten='bindings[].members' --filter="bindings.members=$IMPERSONATOR" \
         --format='value(bindings.role)' >"$out" 2>"$err"; then
      if [ -n "$(tr -d '[:space:]' <"$out")" ]; then
        verdict=PRESENT; detail="the impersonator still holds a role on the identity"
      else
        verdict=ABSENT; detail="the identity is active and no impersonator binding remains on it"
      fi
    else
      verdict=UNKNOWN; detail="the identity is active and its policy could not be read"
    fi
  else
    verdict=UNKNOWN; detail="the identity's own state could not be determined"
  fi
  verdict_row "$class" "$verdict" absent "$detail"
}

probe_custom_role() {
  local class="$1" role_id="$2"
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" verdict detail="" line marker
  if gcloud iam roles describe "$role_id" --project "$PROJECT" --format='value(name,deleted)' \
       >"$out" 2>"$err"; then
    line="$(head -1 "$out")"
    marker="$(printf '%s' "$line" | cut -s -f2 | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    case "$marker" in
      true)  verdict=ABSENT; detail="provider-deleted (kept in GCP's undelete window): $line" ;;
      *)     verdict=PRESENT; detail="an active custom role of this name exists: $line" ;;
    esac
  elif grep -qiE '(not[_. -]?found|does not exist|was not found|404|No URLs matched)' "$err" "$out"; then
    verdict=ABSENT; detail="not found"
  else
    verdict=UNKNOWN; detail="the role read failed without saying not-found"
  fi
  verdict_row "$class" "$verdict" absent "$detail"
}

GCP_ROLE_ID="sol_$(printf '%s' "$CLUSTER" | tr '-' '_')_cluster_access"
GCP_PROVISIONER_SA="$CLUSTER-provisioner@$PROJECT.iam.gserviceaccount.com"

inventory() {
  local mode="$1"
  INVENTORY_TSV="$LOG_DIR/inventory-$mode.tsv"
  : >"$INVENTORY_TSV"
  {
    printf 'attempt\t%s\n' "${ATTEMPT:--}"
    printf 'row\t%s\n' "${ROW:-}"
    printf 'target\t%s\n' "${TARGET:-}"
    printf 'state_key\t%s\n' "${STATE_KEY:-}"
    printf 'cluster\t%s\n' "${CLUSTER:-}"
  } >"$LOG_DIR/inventory-$mode.identity" 2>/dev/null || true
  say "inventory ($mode): attempt ${ATTEMPT:--}, target $TARGET, state key $STATE_KEY, cluster $CLUSTER; provider reads only, no mutation"

  provider_probe gke-cluster    absent  gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" --format='value(name)'
  provider_probe sql-instance   absent  gcloud sql instances describe "$CLUSTER-postgres" --project "$PROJECT" --format='value(name)'
  provider_probe network        absent  gcloud compute networks describe "$CLUSTER" --project "$PROJECT" --format='value(name)'
  provider_probe subnetwork     absent  gcloud compute networks subnets describe "$CLUSTER-nodes" --region "$REGION" --project "$PROJECT" --format='value(name)'
  provider_probe router         absent  gcloud compute routers describe "$CLUSTER-router" --region "$REGION" --project "$PROJECT" --format='value(name)'
  provider_probe nat            absent  gcloud compute routers nats describe "$CLUSTER-nat" --router "$CLUSTER-router" --region "$REGION" --project "$PROJECT" --format='value(name)'
  provider_probe address-regional absent gcloud compute addresses list --project "$PROJECT" --filter="name~$CLUSTER" --format='value(name)'
  provider_probe address-global absent  gcloud compute addresses list --global --project "$PROJECT" --filter="name~$CLUSTER" --format='value(name)'
  # GKE's CSI disks are named `pvc-<uuid>`, so a `name` filter matches none of them and a
  # destroyed cluster's volumes read as absent while they survive. The GKE-managed cluster
  # label is what attributes a disk to this run.
  provider_probe disks          absent  gcloud compute disks list --project "$PROJECT" --filter="labels.goog-k8s-cluster-name=$CLUSTER" --format='value(name)'
  provider_probe forwarding-rules absent gcloud compute forwarding-rules list --project "$PROJECT" --filter="name~$CLUSTER" --format='value(name)'
  provider_probe artifact-registry absent gcloud artifacts repositories describe "$CLUSTER" --location "$REGION" --project "$PROJECT" --format='value(name)'
  probe_service_account service-account-provisioner "$GCP_PROVISIONER_SA"
  provider_probe service-account-loki        absent gcloud iam service-accounts describe "$CLUSTER-loki@$PROJECT.iam.gserviceaccount.com" --project "$PROJECT" --format='value(email)'
  provider_probe service-account-thanos      absent gcloud iam service-accounts describe "$CLUSTER-thanos@$PROJECT.iam.gserviceaccount.com" --project "$PROJECT" --format='value(email)'
  probe_custom_role custom-role "$GCP_ROLE_ID"
  provider_probe role-binding   absent  gcloud projects get-iam-policy "$PROJECT" --flatten='bindings[].members' --filter="bindings.members=serviceAccount:$GCP_PROVISIONER_SA" --format='value(bindings.role)'
  probe_impersonator_binding impersonator-binding "$PROVISIONER_SA_VERDICT" "$GCP_PROVISIONER_SA"
  provider_probe peering        absent  gcloud compute networks peerings list --project "$PROJECT" --filter="name~servicenetworking" --format='value(name)'
  provider_probe state-bucket   present gcloud storage buckets describe "gs://$STATE_BUCKET" --project "$PROJECT" --format='value(name)'
  provider_probe dns-zone       present gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" --format='value(name,dnsName)'

}

verify_absent() {
  local rc=0 class verdict expect detail
  inventory post
  while IFS=$'\t' read -r class verdict expect detail; do
    case "$expect:$verdict" in
      absent:ABSENT)   say "  ✓ $class absent" ;;
      present:PRESENT) say "  ✓ $class present (durable prerequisite)" ;;
      absent:PRESENT)  say "  ✗ $class still exists (PRESENT) — $detail"; rc=1 ;;
      present:ABSENT)  say "  ✗ $class is MISSING — a disposable destroy removed a durable prerequisite"; rc=1 ;;
      absent:UNKNOWN)  say "  ✗ $class: could NOT determine absence (UNKNOWN) — $detail"; rc=1 ;;
      present:UNKNOWN) say "  ✗ $class: could NOT be read (UNKNOWN) — $detail"; rc=1 ;;
    esac
  done <"$INVENTORY_TSV"
  return "$rc"
}

sol_data_dir() {
  if [ -n "${SOL_DATA_DIR:-}" ]; then printf '%s\n' "$SOL_DATA_DIR"; return; fi
  if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/sol\n' "$XDG_DATA_HOME"; return; fi
  printf '%s/.local/share/sol\n' "${HOME:-/root}"
}

capture_sol_runs() {
  local src="$1/runs" n
  if [ ! -d "$src" ]; then
    say "  sol runs: no run directory at $src (recorded as absent, not as an error)"
    return 0
  fi
  mkdir -p "$LOG_DIR/sol-runs"
  n="$(find "$src" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  cp -a "$src/." "$LOG_DIR/sol-runs/" 2>/dev/null || true
  say "  sol runs: copied $n director(ies) from $src"
}

capture_state_object() {
  local name="$1"
  local key="$2"
  local out="$LOG_DIR/state/$name.tfstate"
  mkdir -p "$LOG_DIR/state"
  if gcloud storage cat "gs://$STATE_BUCKET/$key" --project "$PROJECT" \
      >"$out" 2>"$LOG_DIR/state/$name.stderr"; then
    if [ "$(head -c2 "$out" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
      gzip -dc "$out" >"$out.json" 2>/dev/null || true
      say "  state $name: captured (gzip); readable copy $name.tfstate.json"
    else
      say "  state $name: captured"
    fi
  elif grep -qiE 'not.?found|404|No URLs matched|No such object' "$LOG_DIR/state/$name.stderr"; then
    say "  state $name: no object (the root has never been applied) — recorded as absent"
  else
    say "  state $name: COULD NOT READ (UNKNOWN) — see $LOG_DIR/state/$name.stderr"
  fi
}

capture_terraform_state() {
  say "capturing Terraform state (read-only backend reads)"
  capture_state_object cloud    "sol/$TARGET/cloud.tfstate/default.tfstate"
  capture_state_object platform "sol/$TARGET/platform.tfstate/default.tfstate"
  capture_state_object durable  "bootstrap/gcp/default.tfstate"
}

artifact_status() { if [ -s "$1" ]; then printf 'present (%s bytes)\n' "$(wc -c <"$1" | tr -d ' ')"; else printf 'MISSING\n'; fi; }

bundle_manifest() {
  local m="$LOG_DIR/evidence-manifest.txt" f
  if [ -d "$LOG_DIR/platform-failure" ]; then
    printf 'platform failure evidence: platform-failure/ (%s files)\n' \
      "$(ls "$LOG_DIR/platform-failure" 2>/dev/null | wc -l)"
  fi
  if [ -s "$LOG_DIR/kubeconfig-waiter.tsv" ]; then
    printf 'run kubeconfig waiter: kubeconfig-waiter.tsv (%s polls; every transition and exit)\n' \
      "$(($(wc -l <"$LOG_DIR/kubeconfig-waiter.tsv") - 1))"
  fi
  if [ -s "$RUN_KUBECONFIG" ]; then
    printf 'run credentials: run-kubeconfig.yaml\n'
  else
    printf 'run credentials: NOT ESTABLISHED\n'
  fi
  if [ -s "$LOG_DIR/platform-failure/capture-summary.txt" ]; then
    printf 'platform failure capture: platform-failure/capture-summary.txt\n'
  fi
  {
    printf 'evidence bundle: %s\n' "$LOG_DIR"
    printf 'attempt: %s  row: %s\n' "${ATTEMPT:--}" "${ROW:-}"
    printf 'target: %s  state_key: %s\n' "$TARGET" "$STATE_KEY"
    printf 'project: %s  region: %s  revision: %s\n' \
      "$PROJECT" "$REGION" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'cluster: %s\n\n' "$CLUSTER"
    printf 'sol run evidence .......... %s run director(ies)\n' "$(find "$LOG_DIR/sol-runs" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
    printf 'terraform state (cloud) ... %s\n' "$(artifact_status "$LOG_DIR/state/cloud.tfstate")"
    printf 'terraform state (platform)  %s\n' "$(artifact_status "$LOG_DIR/state/platform.tfstate")"
    printf 'terraform state (durable) . %s\n' "$(artifact_status "$LOG_DIR/state/durable.tfstate")"
    printf 'inventory (pre-teardown) .. %s\n' "$(artifact_status "$LOG_DIR/inventory-pre.tsv")"
    printf 'inventory (post-teardown) . %s\n' "$(artifact_status "$LOG_DIR/inventory-post.tsv")"
    printf '\nphase transcripts:\n'
    for f in "$LOG_DIR"/*.log; do [ -e "$f" ] || continue; printf '  %s\n' "$(basename "$f")"; done
  } >"$m"
  say "evidence manifest: $m"
}

verify_bundle() {
  local missing=0 member
  # What the claims are decided on: what the provider held before teardown, that
  # it is gone after, and the transcripts of what this run did. Terraform state
  # snapshots are evidence, not requirements: no row claims them, and the capture
  # records per object whether the backend held one, held none, or was unreadable.
  local required=( "inventory-pre.tsv" "evidence-manifest.txt" )
  [ "$TEARDOWN_ATTEMPTED" = "1" ] && required+=( "inventory-post.tsv" )
  case "$INSTALL_STATE" in
    failed)    ;;
    succeeded) required+=( "ready-phases.txt" ) ;;
    none) : ;;
  esac
  case "$APP_STATE" in
    failed)    required+=( "app-pods-all.txt" ) ;;
    succeeded)
      required+=( "alpha-rows.txt" "app-transaction-ocaml.txt" "app-transaction-ts.txt" "app-deploy.log" )
      ;;
    none) : ;;
  esac
  [ "${IDENTITY_STATE:-none}" = "ran" ] && required+=( "identity/identity.tsv" )
  for member in "${required[@]}"; do
    if [ ! -s "$LOG_DIR/$member" ]; then
      say "  ✗ bundle member missing or empty: $member"
      missing=1
    fi
  done
  if [ -z "$(find "$LOG_DIR/sol-runs" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
    say "  ✗ bundle member missing: sol-runs/ (no Sol run directory was copied)"
    missing=1
  fi
  if [ "$missing" = "0" ]; then
    BUNDLE_OK=1
  else
    BUNDLE_OK=0
    say "  the evidence bundle is INCOMPLETE — this attempt is not a conformant run"
  fi
  return "$missing"
}

freeze_evidence() {
  say "freezing the evidence bundle (before any teardown)"
  BUNDLE_ATTEMPTED=1
  capture_terraform_state
  capture_sol_runs "$(sol_data_dir)"
  bundle_manifest
}

finalise_bundle() {
  verify_bundle || true
}

capture_pre_teardown_inventory() {
  say "capturing the pre-teardown provider inventory (attribution evidence)"
  inventory pre
  say "  pre-teardown inventory: $INVENTORY_TSV"
}

destroy() {
  TEARDOWN_ATTEMPTED=1
  local vars
  mapfile -t vars < <(destroy_vars)
  say "teardown: sol destroy $TARGET"
  ( cd "$WORKSPACE" && "$SOL" destroy "$TARGET" --apply "${vars[@]}" ) \
    >"$LOG_DIR/destroy.log" 2>&1 || say "  (destroy exited non-zero; the verification below decides)"
  if verify_absent; then
    say "teardown verified: absent"
    TEARDOWN_OK=1
  else
    say "teardown NOT verified: resources remain — see $LOG_DIR/inventory-*.tsv and inventory-*.log"
    TEARDOWN_OK=0
  fi
  bundle_manifest
  verify_bundle || true
}

cleanup() {
  local rc=$?
  stop_cluster_kubeconfig_waiter
  if [ "$KEEP" = "1" ]; then
    say "not tearing down: ${KEEP_REASON:-the delegation boundary is deliberate, not a leak}"
    say "logs: $LOG_DIR"
    return "$rc"
  fi
  # A signal can arrive while the deploy is still running, before its exit status is seen:
  # decide from the log whether it already mutated the provider, so a target this run never
  # touched is never torn down.
  local mutated=0
  if [ "$CLOUD_APPLIED" = "1" ] || cloud_mutated; then mutated=1; fi
  if [ "$TEARDOWN_ATTEMPTED" = "0" ] && [ "$mutated" = "1" ]; then
    destroy || true
  fi
  say "logs: $LOG_DIR"
  if plan_only; then
    remove_target
    return "$rc"
  fi
  if [ "$TEARDOWN_OK" = "1" ]; then
    remove_target
  elif [ "$mutated" = "0" ]; then
    remove_target
  else
    say "KEEPING $TARGET_FILE — teardown was not verified, and destroy requires this file."
  fi
  if [ "$TEARDOWN_ATTEMPTED" = "1" ] && [ "$TEARDOWN_OK" != "1" ]; then rc=1; fi
  if [ "$BUNDLE_ATTEMPTED" = "1" ] && [ "$BUNDLE_OK" != "1" ]; then rc=1; fi
  return "$rc"
}
TEARDOWN_OK=0

on_terminate() {
  if [ -n "$TERMINATION_SIGNAL" ]; then return 0; fi
  TERMINATION_SIGNAL="$1"
  say "received SIG$1: finishing the current step, then tearing down and verifying absence"
  exit 1
}

trap cleanup EXIT
trap 'on_terminate TERM' TERM
trap 'on_terminate INT' INT

plan_only() { [ "${PLAN_ONLY:-0}" = "1" ]; }

phase_cloud() {
  write_target
  run cloud-check "$SOL" check || return 1
  local vars; mapfile -t vars < <(cloud_vars)

  if plan_only; then
    run cloud-plan "$SOL" plan "$TARGET" "${vars[@]}" || return 1
    say "PLAN_ONLY=1: no infrastructure mutation requested; durable setup skipped"
    return 0
  fi

  start_cluster_kubeconfig_waiter
  local deploy_rc=0
  bootstrap_deploy cloud-apply || deploy_rc=$?
  if cloud_mutated; then CLOUD_APPLIED=1; fi
  if [ "$deploy_rc" != 0 ] && platform_credential_missing; then
    say "the whole-target deploy stopped at the platform's documented credential prerequisite; supplying it and resuming"
    if supply_platform_credential; then
      deploy_rc=0
      bootstrap_deploy cloud-apply-resume || deploy_rc=$?
      if cloud_mutated; then CLOUD_APPLIED=1; fi
    fi
  fi
  # The whole-target deploy reconciles the durable installation inline and is expected to
  # stop at the workloads whose digests the app phase has not published yet: their Artifact
  # Registry repositories did not exist when this phase began. What decides the phase is
  # the reconciled environment.
  if ! environment_reconciled; then
    INSTALL_STATE=failed
    say "the whole-target deploy did not reconcile the environment -- capturing the discriminator before any teardown"
    capture_pre_teardown_inventory
    freeze_evidence
    capture_platform_failure_evidence

    finalise_bundle
    return 1
  fi
  INSTALL_STATE=succeeded

  capture_ready_evidence

  if [ ! -s "$LOG_DIR/nameservers.txt" ] && ! gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" \
    --format='value(nameServers)' >"$LOG_DIR/nameservers.txt" 2>"$LOG_DIR/nameservers.err"; then
    say "could not read the zone's nameservers — the delegation half cannot proceed"
    capture_pre_teardown_inventory
    freeze_evidence
    finalise_bundle
    return 1
  fi
  say "authoritative nameservers for $BASE_DOMAIN (paste these at Squarespace as NS records named 'qual-gcp'):"
  tr ';' '\n' <"$LOG_DIR/nameservers.txt" | sed 's/^/    /' 2>/dev/null || true

  capture_pre_teardown_inventory
  freeze_evidence
  finalise_bundle

  local deadline=$(( $(date +%s) + DELEGATION_WAIT_MINUTES * 60 ))
  say "waiting up to ${DELEGATION_WAIT_MINUTES}m for the delegation to resolve (Ctrl-C to continue later)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ns_now="$(dns_ns "$BASE_DOMAIN")"
    if [ -n "$ns_now" ]; then
      say "delegation observed: $(printf '%s' "$ns_now" | tr '\n' ' ')"
      KEEP=1
      return 0
    fi
    sleep 15
  done
  say "delegation not observed within ${DELEGATION_WAIT_MINUTES}m."
  say "This is 'waiting on an external prerequisite', not a Sol failure: finish the NS"
  say "records at Squarespace, then run: CLUSTER=$CLUSTER ... live-qual.sh destroy"
  KEEP=1
  return 0
}

cluster_describable() {
  local name
  name="$(gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" \
      --format='value(name)' 2>/dev/null)" && [ -n "$name" ]
}

kube_capture() {
  local name="$1"; shift
  timeout "${KUBE_CAPTURE_TIMEOUT_S:-30}" "$@" >"$LOG_DIR/$name.log" 2>&1 || true
  say "  captured $name.log ($(wc -l <"$LOG_DIR/$name.log" | tr -d ' ') lines)"
}

kubeconfig_has_cluster() {
  local server="${3:-}"
  if [ -n "$server" ]; then
    python3 "$OBSERVER" kubeconfig --file "${1:-}" --cluster "${2:-}" --server "$server" \
      >/dev/null 2>&1
  else
    python3 "$OBSERVER" kubeconfig --file "${1:-}" --cluster "${2:-}" >/dev/null 2>&1
  fi
}

current_endpoint() {
  gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" \
    --format='value(endpoint)' 2>/dev/null | tr -d '\r' || true
}

cluster_kubeconfig_waiter() {
  local parent=$$ status polls=0 expected=""
  local journal="$LOG_DIR/kubeconfig-waiter.tsv"
  local deadline
  deadline=$(( $(date +%s) + ${CLUSTER_WAIT_TIMEOUT_S:-1800} ))
  printf 'timestamp\tpoll\tcluster_status\taction\toutcome\n' >"$journal" 2>/dev/null || true
  note() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$polls" "$1" "$2" "$3" \
      >>"$journal" 2>/dev/null || true
  }
  while :; do
    polls=$((polls + 1))
    if ! kill -0 "$parent" 2>/dev/null; then
      note "-" "parent-gone" "the run ended before credentials existed"
      exit 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      note "-" "timeout" "no credentials after ${CLUSTER_WAIT_TIMEOUT_S:-1800}s"
      say "run kubeconfig waiter: TIMEOUT after ${CLUSTER_WAIT_TIMEOUT_S:-1800}s ($journal)"
      exit 0
    fi
    expected="$(current_endpoint)"
    # Without a readable endpoint there is nothing to bind the credential to: a
    # file that only names the cluster may be an earlier run's, for a cluster of
    # the same name that no longer exists (sol-fab/sol#1287).
    if [ -n "$expected" ] && kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER" "$expected"; then
      note "-" "established" "credentials for $CLUSTER at $expected exist"
      say "run kubeconfig: ready ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
      exit 0
    fi
    status="$(gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" \
      --format='value(status)' 2>/dev/null | tr -d '\r' || true)"
    case "$status" in
      RUNNING)
        kubeconfig_for_cluster || true
        expected="$(current_endpoint)"
        if [ -n "$expected" ] && kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER" "$expected"; then
          note "$status" "credentials-established" "context pinned to $CLUSTER"
          say "run kubeconfig: established while the cluster became RUNNING ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
          exit 0
        fi
        note "$status" "generation-incomplete" "will retry"
        ;;
      "")
        note "unreadable" "poll-failed" "no status yet: cluster absent, or the read failed"
        ;;
      *)
        note "$status" "waiting" "cluster not RUNNING yet"
        ;;
    esac
    sleep "${CLUSTER_KUBECONFIG_POLL_S:-10}"
  done
}

start_cluster_kubeconfig_waiter() {
  cluster_kubeconfig_waiter &
  KUBECONFIG_WAITER_PID=$!
  say "run kubeconfig waiter: pid $KUBECONFIG_WAITER_PID, polling every ${CLUSTER_KUBECONFIG_POLL_S:-10}s"
}

stop_cluster_kubeconfig_waiter() {
  if [ -n "${KUBECONFIG_WAITER_PID:-}" ] && kill -0 "$KUBECONFIG_WAITER_PID" 2>/dev/null; then
    kill -TERM "$KUBECONFIG_WAITER_PID" 2>/dev/null || true
    wait "$KUBECONFIG_WAITER_PID" 2>/dev/null || true
    endpoint="$(current_endpoint)"
    if [ -n "$endpoint" ] && [ -s "$RUN_KUBECONFIG" ] &&
      kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER" "$endpoint"; then
      printf '%s\t-\t-\tstopped-by-run\tcredentials existed; the run ended\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG_DIR/kubeconfig-waiter.tsv" 2>/dev/null || true
    else
      printf '%s\t-\t-\tSTOPPED-WITHOUT-CREDENTIALS\tthe run ended before credentials existed\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG_DIR/kubeconfig-waiter.tsv" 2>/dev/null || true
    fi
  fi
  KUBECONFIG_WAITER_PID=""
}

kube_capture_evidence() {
  local dir="$1" endpoint server_args=()
  endpoint="$(current_endpoint)"
  if [ -n "$endpoint" ]; then server_args=(--server "$endpoint"); fi
  if ! python3 "$OBSERVER" capture --dir "$dir" --kubeconfig "$RUN_KUBECONFIG" \
      --cluster "$CLUSTER" --attempt "$ATTEMPT" "${server_args[@]}" \
      --bound "${KUBE_CAPTURE_TIMEOUT_S:-30}"; then
    say "  platform-failure evidence: the observer could not run at all — recorded, not interpreted"
    printf 'observer.py could not run: no Kubernetes evidence was collected for this failure.\n' \
      >>"$dir/CAPTURE-UNAVAILABLE.txt" 2>/dev/null || true
  fi
  return 0
}

capture_platform_failure_evidence() {
  local dir="$LOG_DIR/platform-failure"
  if ! mkdir -p "$dir" 2>/dev/null; then
    say "  platform-failure evidence: DISABLED (cannot create $dir) — the run continues unobserved"
    return 0
  fi
  if ! kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER" "$(current_endpoint)"; then
    kubeconfig_for_cluster || true
  fi
  local credentials=yes
  if ! kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER" "$(current_endpoint)"; then
    credentials=no
    say "  platform-failure evidence: NO CREDENTIALS for $CLUSTER — every read is recorded, none is evidence"
  fi
  say "capturing read-only Kubernetes evidence for the platform-apply failure (credentials: $credentials)"
  kube_capture_evidence "$dir"
  say "  platform-failure evidence: $dir ($(ls "$dir" 2>/dev/null | wc -l) files, summary in capture-summary.txt)"
}

kubeconfig_for_cluster() {
  gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT" \
    >"$LOG_DIR/kubeconfig.log" 2>&1 || true
  local context
  context="$(kubectl config get-contexts -o name 2>/dev/null | grep -F -- "$CLUSTER" | head -1 || true)"
  if [ -n "$context" ]; then
    kubectl config use-context "$context" >>"$LOG_DIR/kubeconfig.log" 2>&1 || true
    say "  kubeconfig: using context $context (pinned to this run's cluster)"
  else
    say "  kubeconfig: no context matching $CLUSTER is present — observations may not target it"
  fi
}

kubeconfig_server_for_cluster() {
  python3 "$OBSERVER" server --file "${1:-}" --cluster "${2:-}" 2>/dev/null || printf -- '-\n'
}

capture_provisioner_bindings() {
  kube_capture bindings-provisioner-cluster kubectl get clusterrolebinding \
    sol-platform-provisioner-cluster -o json
  kube_capture bindings-provisioner-rolebindings kubectl get rolebinding -A \
    --field-selector metadata.name=sol-platform-provisioner -o json
  kube_capture bindings-provisioner-subjects kubectl get clusterrolebinding,rolebinding -A \
    -o custom-columns=KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name,SUBJECTS:.subjects[*].name
}

capture_ready_evidence() {
  say "capturing Ready-path evidence (the platform install returned success)"
  capture_provisioner_bindings
  grep -E 'lifecycle phase|bootstrap-access-remove|Provisioned endpoints|^Done' \
    "$LOG_DIR/cloud-apply.log" >"$LOG_DIR/ready-phases.txt" 2>/dev/null || true
  say "  phase lines: $LOG_DIR/ready-phases.txt"
  if ! cluster_describable; then
    say "  cluster is not describable — no cluster-side evidence to capture"
    return 0
  fi
  kubeconfig_for_cluster
  local endpoint
  endpoint="$(current_endpoint)"
  if [ -n "$endpoint" ] && ! kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER" "$endpoint"; then
    say "  the run credential does not address this cluster's current endpoint ($endpoint):"
    say "  the Ready-path cluster reads are not taken through a replaced cluster of the same name"
    return 0
  fi
  kube_capture ready-pods kubectl get pods -A -o wide
  kube_capture ready-startupapicheck-status kubectl -n cert-manager get job cert-manager-startupapicheck -o json
  kube_capture ready-startupapicheck-logs kubectl -n cert-manager logs \
    job/cert-manager-startupapicheck --all-containers --tail=-1
  if grep -q '"succeeded": 1' "$LOG_DIR/ready-startupapicheck-status.log" 2>/dev/null; then
    say "  startupapicheck: Succeeded (the check ran and passed)"
  else
    say "  startupapicheck: not observed as Succeeded — read $LOG_DIR/ready-startupapicheck-status.log"
  fi
}

phase_destroy() {
  write_target
  CLOUD_APPLIED=1
  capture_pre_teardown_inventory
  freeze_evidence
  finalise_bundle
  destroy
}

app_registry() { printf '%s-docker.pkg.dev/%s/%s' "$REGION" "$PROJECT" "$CLUSTER"; }

app_kube_context() { printf 'gke_%s_%s_%s' "$PROJECT" "$REGION" "$CLUSTER"; }

app_services() { printf '%s\n' orders_svc fulfilment_worker order_svc fulfillment_worker; }

app_helpers() {
  printf '%s\n' say app_registry app_kube_context app_services app_k8s_name app_context_path \
    app_image_ref build_app_images push_app_images app_image_ref_args app_ingress_summary \
    app_load_balancer_address app_orders_transaction
}

app_postgres_url() {
  local state="$LOG_DIR/state/cloud.tfstate.json"
  [ -s "$state" ] || state="$LOG_DIR/state/cloud.tfstate"
  [ -s "$state" ] || return 1
  jq -r '.outputs.postgres_url.value // empty' "$state" 2>/dev/null
}

# 2b: the cluster root's postgres_url output is the *deploy's* input — the database setup
# step derives <target>-ddl-creds / <target>-dml-creds from it. The harness records the
# source redacted and never feeds the value to `sol secret set`.
app_capture_database_source() {
  capture_state_object cloud "sol/$TARGET/cloud.tfstate/default.tfstate"
  local url
  if ! url="$(app_postgres_url)" || [ -z "$url" ]; then
    say "could not read the cluster root's postgres_url output, so the deploy's database setup has no master"
    return 1
  fi
  {
    printf 'database master source: the cluster root postgres_url output (never recorded in the clear)\n'
  } >"$LOG_DIR/app-runtime-secrets.txt" 2>&1
  say "the deploy's database master is the platform's own output; the harness holds no POSTGRES_URL"
  say "  database master source: $LOG_DIR/app-runtime-secrets.txt"
}

app_class_credential_name() { printf '%s' "$TARGET" | tr '[:upper:]/' '[:lower:]-'; }

# 2b: the migration Job reads <target>-ddl-creds and a consuming unit reads
# <target>-dml-creds, both written by the deploy's database setup step. Assert the delivered
# form exists and that the consumer did not also receive an operator's master copy.
app_verify_database_delivery() {
  local name secrets ddl dml consumer
  name="$(app_class_credential_name)"
  secrets="$(kubectl get secret -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
  ddl="$(printf '%s\n' "$secrets" | awk -v n="$name-ddl-creds" '$2 == n { print $1 }' | head -1)"
  dml="$(printf '%s\n' "$secrets" | awk -v n="$name-dml-creds" '$2 == n { print $1 }' | head -1)"
  if [ -z "$ddl" ]; then
    say "app: the migration Job's $name-ddl-creds class Secret is absent"
    return 1
  fi
  if [ -z "$dml" ]; then
    say "app: no consuming namespace carries the $name-dml-creds class Secret"
    return 1
  fi
  consumer="orders-svc-secrets"
  if kubectl get secret "$consumer" -n pluto-payments -o jsonpath='{.data.POSTGRES_URL}' 2>/dev/null |
    grep -q .; then
    say "app: $consumer still carries POSTGRES_URL; the unit is not reading the class Secret"
    return 1
  fi
  {
    printf 'database_delivery: %s (migration Job), %s@%s (unit consumer)\n' \
      "$name-ddl-creds" "$name-dml-creds" "$dml"
    printf 'database_delivery_assertion: the consumer unit Secret carries no POSTGRES_URL\n'
  } >>"$LOG_DIR/prerequisites.txt"
  say "app: the deploy delivered the database as $name-ddl-creds / $name-dml-creds; the consumer's unit Secret carries no master copy"
}

app_secret_failure() {
  grep -qF 'does not hold the required non-empty secret key(s)' "$1" 2>/dev/null
}

app_read_platform_password() {
  local password
  if [ -n "${KAFKA_SASL_PASSWORD:-}" ]; then
    printf '%s' "$KAFKA_SASL_PASSWORD"
    return 0
  fi
  password="$(kubectl get secret redpanda-users -n redpanda -o jsonpath='{.data.users\.txt}' 2>/dev/null |
    base64 -d 2>/dev/null | sed -n 's/^sol-workloads:\([^:]*\):.*/\1/p' | head -1)"
  [ -n "$password" ] || return 1
  printf '%s' "$password"
}

app_read_kafka_ca() {
  kubectl get secret redpanda-default-cert -n redpanda -o jsonpath='{.data.ca\.crt}' 2>/dev/null |
    base64 -d 2>/dev/null
}

app_domains() {
  local service path domain
  for service in $(app_services); do
    if path="$(app_context_path "$service")"; then
      domain="${path#app/}"
      printf '%s\n' "${domain%%/*}"
    fi
  done | sort -u
}

app_secret_set() {
  local key="$1" domain
  for domain in $(app_domains); do
    if ! run "app-secret-$key-$domain" bash -c \
      "printf '%s' \"\$SOL_SECRET_VALUE\" | exec '$SOL' secret set '$key' --target '$TARGET' --domain '$domain'"; then
      return 1
    fi
  done
}

# Production secrets are operator-supplied: Sol's deploy verifies the Kafka inputs a TLS
# contract Job declares and fails closed. The database is *not* one of them: the deploy
# delivers it from the target's binding (2b), so the harness neither holds nor sets a
# POSTGRES_URL.
app_supply_secrets() {
  local password ca
  if ! password="$(app_read_platform_password)"; then
    say "app: could not establish KAFKA_SASL_PASSWORD: set it in the environment, or ensure redpanda/redpanda-users exists"
    return 1
  fi
  ca="$(app_read_kafka_ca)"
  if [ -z "$ca" ]; then
    say "app: could not read the Redpanda CA from redpanda/redpanda-default-cert"
    return 1
  fi
  export SOL_SECRET_VALUE="$password"
  app_secret_set KAFKA_SASL_PASSWORD || return 1
  export SOL_SECRET_VALUE="$ca"
  app_secret_set KAFKA_SSL_CA_CERT || return 1
  unset SOL_SECRET_VALUE
  {
    printf 'platform_secret_keys: KAFKA_SASL_PASSWORD KAFKA_SSL_CA_CERT\n'
    printf 'secret_values: never recorded\n'
    printf 'database_delivery: delivered by the deploy from the target binding; no operator copy\n'
  } >>"$LOG_DIR/prerequisites.txt"
  say "app: supplied the Kafka platform secrets through sol secret set; the database is delivered by the deploy"
}

app_k8s_name() { printf '%s' "$1" | tr '_' '-'; }

app_context_path() {
  case "$1" in
    orders_svc) printf 'app/payments/orders_svc' ;;
    fulfilment_worker) printf 'app/comms/fulfilment_worker' ;;
    order_svc) printf 'app/demo_ts/order_svc' ;;
    fulfillment_worker) printf 'app/demo_ts/fulfillment_worker' ;;
    *) return 1 ;;
  esac
}

app_image_ref() { printf '%s/pluto/%s:%s' "$(app_registry)" "$(app_k8s_name "$1")" "$APP_TAG"; }

write_app_target() {
  mkdir -p "$(dirname "$TARGET_FILE")"
  if [ -f "$TARGET_FILE" ] && ! owns_target_file; then
    say "REFUSING: $TARGET_FILE exists and was not written by this harness; move it aside first."
    exit 2
  fi
  cat >"$TARGET_FILE" <<YAML
$TARGET_MARK
$TARGET_ENV:
  targets:
    $TARGET_KEY:
      cluster_name: $CLUSTER
      base_domain: $BASE_DOMAIN
      letsencrypt_email: $LE_EMAIL
      cluster_issuer: $CLUSTER_ISSUER
      terraform_var_file: $TFVARS

      state_bucket: $STATE_BUCKET

      gcp:
        project_id: $PROJECT
        provisioner_impersonator: $IMPERSONATOR

      kube_context: $(app_kube_context)

      destroy_retention: none

      resources:
        app_db:
          size: small
        events: {}

      services:
        orders_svc: {}
        fulfilment_worker: {}
        order_svc: {}
        fulfillment_worker: {}
        charge_svc:
          omit: true
        notify_worker:
          omit: true
        checkout_svc:
          omit: true
YAML
  say "wrote the app target $TARGET ($TARGET_FILE)"
  say "  no profile is selected: this row qualifies the application path, and the profile's"
  say "  guarantees are not claimed by it (the production profile refuses gcp today)"
  say "  orders_svc/fulfilment_worker (OCaml) and order_svc/fulfillment_worker (TypeScript)"
  say "  are the alpha scenario this row exercises in both language namespaces; the legacy"
  say "  charge_svc/notify_worker pair and checkout_svc (ingress_host outside any zone Sol"
  say "  can issue for) are omitted, so the omitted ones are not silently deployed unverified"
}

build_app_images() {
  local service path ref
  [ -n "${APP_BUILD_CONTEXT:-}" ] || {
    say "  no candidate build context: refusing to build the application"
    return 1
  }
  for service in $(app_services); do
    path="$(app_context_path "$service")" || return 1
    ref="$(app_image_ref "$service")"
    [ -f "$APP_BUILD_CONTEXT/$path/Dockerfile" ] || {
      say "  candidate $SOL_REVISION has no $path/Dockerfile"
      return 1
    }
    say "  docker build $ref (context: candidate $SOL_REVISION)"
    docker build -f "$APP_BUILD_CONTEXT/$path/Dockerfile" -t "$ref" "$APP_BUILD_CONTEXT" || return 1
  done
}

push_app_images() {
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet || return 1
  local service ref digest
  : >"$LOG_DIR/app-image-refs.txt"
  for service in $(app_services); do
    ref="$(app_image_ref "$service")"
    say "  docker push $ref"
    docker push "$ref" || return 1
    digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$ref" 2>/dev/null || true)"
    case "$digest" in
      *"@sha256:"*) printf '%s=%s\n' "$service" "$digest" >>"$LOG_DIR/app-image-refs.txt" ;;
      *)
        say "  docker inspect reported no immutable digest for $ref"
        return 1
        ;;
    esac
  done
}

app_image_ref_args() {
  local ref out=""
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    out="$out --image-ref $(printf '%q' "$ref")"
  done <"$LOG_DIR/app-image-refs.txt"
  printf '%s' "$out"
}

app_ingress_summary() {
  kubectl get ingress --all-namespaces -o wide >"$LOG_DIR/app-ingresses.txt" 2>&1 || true
  kubectl get certificates --all-namespaces >"$LOG_DIR/app-certificates.txt" 2>&1 || true
}

app_load_balancer_address() {
  kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

app_orders_transaction() {
  local ns="$1" service="$2" label="$3" port="$4"
  local transcript="$LOG_DIR/app-transaction-$label.txt"
  local status_file="$LOG_DIR/app-order-status-$label.txt"
  local order_id="ord-$label-$(date -u +%s)-$$"
  kubectl -n "$ns" get pods -o wide >"$LOG_DIR/app-pods-$label.txt" 2>&1 || return 1
  kubectl -n "$ns" get events --sort-by=.lastTimestamp >"$LOG_DIR/app-events-$label.txt" 2>&1 || true
  kubectl -n "$ns" logs -l app.kubernetes.io/component=svc --tail=80 --all-containers=true \
    >"$LOG_DIR/app-svc-$label.log" 2>&1 || true
  kubectl -n "$ns" logs -l app.kubernetes.io/component=worker --tail=80 --all-containers=true \
    >"$LOG_DIR/app-worker-$label.log" 2>&1 || true
  kubectl -n "$ns" port-forward "svc/$service" "$port:80" \
    >"$LOG_DIR/app-port-forward-$label.log" 2>&1 &
  local forwarder=$!
  local attempts="${APP_READBACK_ATTEMPTS:-12}" interval="${APP_READBACK_INTERVAL:-5}"
  local attempt=0
  until curl -fsS -m 5 "localhost:$port/healthz" >"$LOG_DIR/app-health-$label.txt" 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$attempts" ]; then
      say "  $label: the service never answered /healthz over the port-forward"
      kill "$forwarder" 2>/dev/null || true
      return 1
    fi
    sleep "$interval"
  done
  {
    printf 'namespace: %s  service: %s  language: %s\n' "$ns" "$service" "$label"
    printf 'health: %s\n' "$(cat "$LOG_DIR/app-health-$label.txt")"
    printf 'order: '
    curl -fsS -m 30 -X POST "localhost:$port/orders" \
      -H 'Content-Type: application/json' \
      -d "{\"order_id\":\"$order_id\",\"item\":\"widget\",\"quantity\":1}" \
      >"$LOG_DIR/app-order-$label.txt" 2>&1 && cat "$LOG_DIR/app-order-$label.txt" || printf 'FAILED\n'
    printf '\n'
  } >"$transcript" 2>&1
  if ! grep -qF "$order_id" "$LOG_DIR/app-order-$label.txt" 2>/dev/null; then
    say "  $label: the order response did not carry the submitted order id ($order_id)"
    kill "$forwarder" 2>/dev/null || true
    return 1
  fi
  rm -f "$status_file"
  attempt=0
  until grep -qE '"status":"(fulfilled|confirmed)"' "$status_file" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$attempts" ]; then
      say "  $label: the order never reached fulfilled or confirmed in time: $order_id"
      curl -sS -m 20 "localhost:$port/orders/$order_id" >"$status_file" 2>&1 || true
      printf 'final read-back: %s\n' "$(cat "$status_file" 2>/dev/null)" >>"$transcript"
      kill "$forwarder" 2>/dev/null || true
      return 1
    fi
    sleep "$interval"
    curl -fsS -m 20 "localhost:$port/orders/$order_id" >"$status_file" 2>&1 || true
  done
  {
    printf 'read-back: %s\n' "$(cat "$status_file")"
    printf 'the worker effect is visible to the service: %s reached fulfilled or confirmed\n' "$order_id"
  } >>"$transcript" 2>&1
  kill "$forwarder" 2>/dev/null || true
  wait "$forwarder" 2>/dev/null || true
  app_ingress_summary
  app_load_balancer_address >"$LOG_DIR/app-load-balancer.txt" 2>&1 || true
  return 0
}

capture_app_evidence() {
  kubectl get pods --all-namespaces >"$LOG_DIR/app-pods-all.txt" 2>&1 || true
  kubectl get events --all-namespaces --sort-by=.lastTimestamp >"$LOG_DIR/app-events-all.txt" 2>&1 || true
  app_ingress_summary
  app_load_balancer_address >"$LOG_DIR/app-load-balancer.txt" 2>&1 || true
}

phase_app() {
  KEEP=1
  KEEP_REASON="the application row keeps its specimen: capture happens either way, and destroy is a deliberate separate phase"
  APP_STATE=failed
  if [ ! -s "$RUN_KUBECONFIG" ]; then
    say "app: no run kubeconfig in $LOG_DIR — run the cloud phase first, which establishes it"
    exit 2
  fi
  write_app_target
  local pins
  if ! pins="$(sol_candidate_bind_context "$WORKSPACE" "$SOL_REVISION" "$LOG_DIR/app-build-context")"; then
    say "refusing to build the application: it cannot be bound to candidate $SOL_REVISION"
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  APP_BUILD_CONTEXT="$LOG_DIR/app-build-context"
  export APP_BUILD_CONTEXT
  sol_candidate_record_binding "$LOG_DIR" "$SOL_REVISION" "$WORKSPACE" "$APP_BUILD_CONTEXT" "$pins"
  say "app images build from candidate $SOL_REVISION ($WORKSPACE at that revision, framework pinned to it)"
  if ! run app-build bash -c "$(declare -f $(app_helpers)); build_app_images"; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  if ! run app-push bash -c "$(declare -f $(app_helpers)); push_app_images"; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  say "runner: release $SOL_BUNDLE_VERSION names $SOL_RUNNER_IMAGE; the publisher publishes nothing"
  if ! app_capture_database_source; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  image_ref_args="$(app_image_ref_args)"
  if [ -z "$image_ref_args" ]; then
    say "app: no immutable image refs were published, so the profile's artifact guarantee cannot be met"
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  say "app-secrets-bootstrap"
  if ! run app-deploy-bootstrap "$SOL" deploy "$TARGET" --registry "$(app_registry)" $image_ref_args; then
    if app_secret_failure "$LOG_DIR/app-deploy-bootstrap.log"; then
      say "app: the deploy established the namespaces and their scoped RBAC, then refused the absent operator secrets (expected)"
    else
      say "app: the bootstrap deploy did not reach the secret prerequisite"
      capture_app_evidence
      freeze_evidence
      finalise_bundle
      return 1
    fi
  fi
  if ! app_supply_secrets; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  if ! run migrate-apply "$SOL" migrate apply "$TARGET"; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  if ! run app-deploy "$SOL" deploy "$TARGET" --registry "$(app_registry)" $image_ref_args; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  if ! app_verify_database_delivery; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  local rows="$LOG_DIR/alpha-rows.txt"
  : >"$rows"
  if ! run app-transaction-ocaml bash -c \
      "$(declare -f $(app_helpers)); app_orders_transaction pluto-payments orders-svc ocaml 18080"; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  printf 'OCaml\tB1\trun\tPOST /orders accepted the order and the response carried the submitted id\n' >>"$rows"
  printf 'OCaml\tB4\trun\tthe order read back as fulfilled or confirmed through the service\n' >>"$rows"
  printf 'OCaml\tB3\tnot-run\tthe relay row needs Kafka-topic inspection this HTTP phase does not perform\n' >>"$rows"
  if ! run app-transaction-ts bash -c \
      "$(declare -f $(app_helpers)); app_orders_transaction pluto-demo-ts order-svc ts 18081"; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  printf 'TypeScript\tB1\trun\tPOST /orders accepted the order and the response carried the submitted id\n' >>"$rows"
  printf 'TypeScript\tB4\trun\tthe order read back as fulfilled or confirmed through the service\n' >>"$rows"
  printf 'TypeScript\tB3\tnot-run\tthe relay row needs Kafka-topic inspection this HTTP phase does not perform\n' >>"$rows"
  APP_STATE=succeeded
  say "the alpha orders scenario completed in both language namespaces: the OCaml orders-svc in"
  say "pluto-payments and the TypeScript order-svc in pluto-demo-ts each accepted an order and"
  say "read its fulfilment back through the transport; the rows each namespace ran are recorded"
  say "in alpha-rows.txt (B1 and B4 asserted; B3 needs broker inspection this phase does not do)"
  finalise_bundle
}

identity_row() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$IDENTITY_TSV"
  say "    $1: $2${4:+ ($4)}"
}

identity_secret_manager_addon() {
  local json="$LOG_DIR/identity/cluster.json" state interval
  if ! gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" --format=json \
      >"$json" 2>"$LOG_DIR/identity/cluster.stderr"; then
    identity_row "gke-secret-manager-addon" "UNKNOWN" "VERIF-021 mechanism" \
      "the cluster describe failed: identity/cluster.stderr"
    return 0
  fi
  jq -r '.secretManagerConfig // empty' "$json" >"$LOG_DIR/identity/secret-manager-config.json" \
    2>/dev/null || true
  jq -r '.workloadIdentityConfig.workloadPool // empty' "$json" \
    >"$LOG_DIR/identity/workload-pool.txt" 2>/dev/null || true
  state="$(jq -r 'if (.secretManagerConfig.enabled // false) then "enabled" else "disabled" end' "$json" \
    2>/dev/null || true)"
  case "$state" in
    enabled)
      interval="$(jq -r '.secretManagerConfig.rotationConfig.rotationInterval // "unset"' "$json" \
        2>/dev/null || true)"
      identity_row "gke-secret-manager-addon" "PRESENT" "VERIF-021 mechanism" \
        "rotation interval ${interval:-unset}"
      ;;
    disabled)
      identity_row "gke-secret-manager-addon" "ABSENT" "VERIF-021 mechanism" \
        "the cluster reports secretManagerConfig not enabled"
      ;;
    *)
      identity_row "gke-secret-manager-addon" "UNKNOWN" "VERIF-021 mechanism" \
        "the cluster document did not parse"
      ;;
  esac
}

identity_secret_grants() {
  local list="$LOG_DIR/identity/secrets.txt" policy="$LOG_DIR/identity/secret-grants.json" count=0 name short
  if ! gcloud secrets list --project "$PROJECT" --format='value(name)' \
      >"$list" 2>"$LOG_DIR/identity/secrets.stderr"; then
    identity_row "secret-manager-grants" "UNKNOWN" "VERIF-021 authorization" \
      "the secret list could not be read: identity/secrets.stderr"
    return 0
  fi
  : >"$policy"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    short="${name##*/}"
    case "$short" in sol-*) ;; *) continue ;; esac
    if gcloud secrets get-iam-policy "$short" --project "$PROJECT" --format=json \
        >>"$policy" 2>>"$LOG_DIR/identity/secrets.stderr"; then
      count=$((count + 1))
    else
      identity_row "secret-manager-grants" "UNKNOWN" "VERIF-021 authorization" \
        "the policy of $short could not be read: identity/secrets.stderr"
      return 0
    fi
  done <"$list"
  if [ "$count" -gt 0 ]; then
    identity_row "secret-manager-grants" "PRESENT" "VERIF-021 authorization" \
      "$count sol- secret policy(ies) captured; see identity/secret-grants.json"
  else
    identity_row "secret-manager-grants" "ABSENT" "VERIF-021 authorization" \
      "no sol- Secret Manager secret exists in this project yet"
  fi
}

identity_oidc() {
  local issuer="https://container.googleapis.com/v1/projects/$PROJECT/locations/$REGION/clusters/$CLUSTER" code
  printf '%s\n' "$issuer" >"$LOG_DIR/identity/oidc-issuer.txt"
  code="$(curl -sS -m 20 -o "$LOG_DIR/identity/oidc-discovery.json" -w '%{http_code}' \
    "$issuer/.well-known/openid-configuration" 2>"$LOG_DIR/identity/oidc.stderr" || printf '000')"
  printf '%s\n' "$code" >"$LOG_DIR/identity/oidc-discovery.code"
  if [ "$code" = "200" ]; then
    identity_row "cluster-oidc-discovery" "PRESENT" "VERIF-022 issuer discovery" "$issuer (HTTP 200)"
  else
    identity_row "cluster-oidc-discovery" "UNKNOWN" "VERIF-022 issuer discovery" \
      "HTTP $code from $issuer — a non-200 read is never absence"
  fi
}

identity_projected_tokens() {
  local pods="$LOG_DIR/identity/pods.json" volumes="$LOG_DIR/identity/projected-tokens.txt" count
  local selector='.items[] | select(any(.spec.volumes[]?; (.projected.sources // [])[]?.serviceAccountToken != null))'
  if ! kubectl get pods --all-namespaces -o json >"$pods" 2>"$LOG_DIR/identity/pods.stderr"; then
    identity_row "projected-token-volumes" "UNKNOWN" "VERIF-022 mechanism" \
      "the pod list could not be read: identity/pods.stderr"
    return 0
  fi
  if ! count="$(jq -r "[$selector] | length" "$pods" 2>"$LOG_DIR/identity/pods.stderr")"; then
    identity_row "projected-token-volumes" "UNKNOWN" "VERIF-022 mechanism" \
      "the pod document could not be parsed: identity/pods.stderr"
    return 0
  fi
  jq -r "$selector | .metadata.namespace + \"/\" + .metadata.name + \" \" + ([.spec.volumes[]? | (.projected.sources // [])[]?.serviceAccountToken | \"aud=\" + (.audience // \"\") + \" exp=\" + ((.expirationSeconds // 0) | tostring)] | join(\",\"))" \
    "$pods" >"$volumes" 2>>"$LOG_DIR/identity/pods.stderr" || true
  if [ "$count" = "0" ]; then
    identity_row "projected-token-volumes" "ABSENT" "VERIF-022 mechanism" \
      "no deployed pod projects a serviceAccountToken volume; Sol does not render the mechanism yet"
  else
    identity_row "projected-token-volumes" "PRESENT" "VERIF-022 mechanism" \
      "$count pod(s); see identity/projected-tokens.txt"
  fi
}

phase_identity() {
  KEEP=1
  KEEP_REASON="the identity capture is read-only; the specimen is kept for the app and destroy phases"
  if [ ! -s "$RUN_KUBECONFIG" ]; then
    say "identity: no run kubeconfig in $LOG_DIR — run the cloud phase first, which establishes it"
    exit 2
  fi
  mkdir -p "$LOG_DIR/identity"
  IDENTITY_TSV="$LOG_DIR/identity/identity.tsv"
  IDENTITY_STATE=ran
  : >"$IDENTITY_TSV"
  printf 'check\tverdict\tscope\tdetail\n' >"$IDENTITY_TSV"
  say "identity: capturing the managed-secret and projected-token mechanism facts (read-only)"
  identity_secret_manager_addon
  identity_secret_grants
  identity_oidc
  identity_projected_tokens
  {
    printf 'VERIF-021 / VERIF-022 mechanism capture (read-only; the behavioural probes are the procedure step)\n\n'
    awk -F'\t' 'NR>1{printf "%-26s %-8s %-28s %s\n", $1, $2, $3, $4}' "$IDENTITY_TSV"
  } >"$LOG_DIR/identity/summary.txt"
  say "identity: $IDENTITY_TSV"
  freeze_evidence
  finalise_bundle
}

usage() {
  cat <<'USAGE'
live-qual.sh — one GCP qualification specimen, and the evidence it produces

usage: live-qual.sh PHASE

phases
  cloud     reconcile the whole target: `sol deploy` establishes the durable
            installation inline (its first-run offer is confirmed through `script`),
            applies the cluster and platform roots, and stops at the workloads whose
            digests the app phase has not published yet. The run starts the
            run-kubeconfig waiter and the API-readiness probe around it. When it stops at the
            pre-platform `redpanda-users` credential, create the Secret with the
            run's generated or operator-supplied `sol-workloads` SCRAM credential,
            record that it was supplied (never the value) in prerequisites.txt, and
            re-run `sol deploy` to resume -- the same ordered steps the
            production bootstrap guide gives the operator. On failure it captures the
            Kubernetes evidence, the cert-manager discriminator and the provider
            inventory before any teardown. On success it continues to the delegation
            hand-off and keeps the substrate for the TLS rows.
  app       build and push this row's two images into the target's Artifact Registry, apply the
            workspace's migrations, run `sol
            deploy`, and verify the application transaction
            (a charge accepted, the worker consuming it, and the service reading the worker's
            row back out of PostgreSQL) with the pods, events and logs captured either way.
            Sol runs the installed release bundle, which pins its own migration runner by
            digest: the harness publishes nothing for Sol and hands it no runner reference.
            The deploy identity has no registry-write authority (ADR 0002, SEC-011), and Sol
            refuses to run either step without a digest-pinned runner. The deploy is still
            given the target's registry for the
            workspace's own images. The database connection is not an operator input: the
            deploy reads the cluster root's postgres_url output and delivers
            `<target>-ddl-creds` to the migration Job and `<target>-dml-creds` to a consuming
            unit, which the row asserts before the transaction.
            The target it writes selects no profile: this row qualifies the application path,
            and claims nothing the production profile's guarantees would promise.
  identity  capture the managed-secret and projected-token mechanism facts the VERIF-021 and
            VERIF-022 runs need -- the GKE Secret Manager add-on and its rotation interval, the
            Secret Manager grants on the project's sol- secrets, the cluster OIDC issuer discovery
            document, and any rendered projected serviceAccountToken volumes -- as a read-only
            addition to the bundle (identity/identity.tsv). An unreadable read is UNKNOWN, never
            absence or a pass. The behavioural probes are run by the procedure, not here.
  destroy   freeze and destroy an existing target, then verify absence
  stop      SIGTERM the run recorded in LOG_DIR by its own pid, so its trap tears down while any
            Terraform it is running is allowed to finish; then verify absence
  verify    read-only absence check; invokes no teardown

required
  ATTEMPT        a unique identity for this disposable run; the target, state key and
                 evidence directory are bound to it, and a repeated ATTEMPT continues it
  CLUSTER        this run's cluster name (also the name every provider probe filters on)
  IMPERSONATOR   user:<email> the provisioner is impersonated as
  LE_EMAIL       ACME contact address, for the platform's certificates
  SOL_INSTALL    the extracted release prefix holding bin/sol and share/sol/<version>
  SOL_CANDIDATE  the candidate document this run qualifies (the draft's candidate.json); the
                 run verifies the prefix is that candidate before it provisions anything

optional (defaults shown)
  ROW=qual                    the stable logical row label
  TARGET=qual-<attempt>/gcp/us-central1
  CONTINUE_ATTEMPT=0          set 1 to continue an occupied state key for the same ATTEMPT
  PROJECT=sol-qualification   REGION=us-central1
  BASE_DOMAIN=qual-gcp.sol-fab.dev
  PHASE_TIMEOUT=2700          how long one phase may take before the harness ends it
  WORKSPACE=examples/pluto    TFVARS=internal/qualification/gcp/qual-gcp.tfvars
  LOG_DIR=/tmp/sol-gcp-qual-<attempt>   XDG_DATA_HOME

The bundle is LOG_DIR: the harness's own narrative (harness.log), phase transcripts,
the run kubeconfig and the waiter journal, the API-readiness samples, the failure
capture and its summary, the provider inventory, the Terraform state snapshots, and
evidence-manifest.txt.
USAGE
}

case "${1:-}" in
  cloud)    phase_cloud ;;
  app)      phase_app ;;
  identity) phase_identity ;;
  platform)
    say "no platform phase: 'sol deploy' reconciles the whole target and installs the platform, and this harness captures"
    say "its discriminator in the cloud phase. Run: live-qual.sh cloud"
    exit 2
    ;;
  stop)
    stop_rc=0
    if [ -s "$LOG_DIR/run.pid" ]; then
      run_pid="$(cat "$LOG_DIR/run.pid")"
      say "stopping the run in $LOG_DIR (pid $run_pid) with SIGTERM; its own trap tears down and"
      say "the Terraform it is running is allowed to finish rather than being killed in flight"
      kill -TERM "$run_pid" 2>/dev/null || true
      while kill -0 "$run_pid" 2>/dev/null; do
        say "  waiting for the run (and the Terraform it is finishing) to exit..."
        sleep 5
      done
    else
      say "no run.pid in $LOG_DIR — nothing recorded to stop"
    fi
    if verify_absent; then
      say "stop: absence independently verified"
    else
      say "stop: the run did not verify absence — running the destroy path"
      phase_destroy || stop_rc=$?
    fi
    exit "$stop_rc"
    ;;
  destroy)  phase_destroy ;;
  verify)
    KEEP=1
    KEEP_REASON="verify does not mutate; nothing to tear down"
    if verify_absent; then say "verify: absent"; else say "verify: resources remain"; exit 1; fi
    ;;
  *)
    KEEP=1
    KEEP_REASON="no phase was named, so nothing was attempted and nothing is torn down"
    usage
    exit 2
    ;;
esac
