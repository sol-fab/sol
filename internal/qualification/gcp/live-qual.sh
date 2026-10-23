#!/usr/bin/env bash
# live-* runs against a real provider target; stubbed-* runs the same suite on stubbed provider calls.
set -euo pipefail
umask 077
trap '' PIPE

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
TFVARS="$ROOT/internal/qualification/gcp/qual.tfvars"
OBSERVER="${OBSERVER:-$ROOT/internal/qualification/gcp/observer.py}"
# The structural transaction predicate shared with the AWS application rows. The
# harness owns the transport (port-forward, HTTP exchange, polling, evidence);
# transaction.py owns every predicate over the response bodies.
TRANSACTION="$ROOT/internal/qualification/transaction.py"
export TRANSACTION
# The shared candidate-bound database-CA family owner (#1510). It is a harness
# executable, distinct from the installed candidate's own sol.
SOL_QUALIFICATION_CA="${SOL_QUALIFICATION_CA:-$ROOT/_build/default/internal/tooling/sol_qualification/bin/qualification_database_ca.exe}"

TARGET_FILE="$WORKSPACE/sol/environments.local.yml"

ROW="${ROW:-qual}"
PROVIDER=gcp
ATTEMPT="${ATTEMPT:-}"
TARGET="${TARGET:-$ROW-$ATTEMPT/gcp/us-central1}"
TARGET_ENV="${TARGET%%/*}"
TARGET_KEY="${TARGET#*/}"
STATE_KEY="sol/$TARGET/cloud.tfstate/default.tfstate"
TARGET_MARK="# Written by internal/qualification/gcp/live-qual.sh for $TARGET; each phase rewrites it for the target that phase needs, and it is removed after a verified teardown."
# Destruction never issues a certificate, but `sol destroy` still feeds the platform
# root's required letsencrypt_email variable while it destroys that root. A teardown
# target may therefore declare a non-deliverable contact from the reserved .invalid
# domain instead of requiring the install-time ACME address (#1400).
TEARDOWN_LE_EMAIL="teardown@invalid"

# The namespaces this row is configured to exercise; the cold-start boundary derives the
# per-unit namespaces from the candidate and requires this declared set to be covered.
APP_NS="${APP_NS:-pluto-payments}"
WORKER_NS="${WORKER_NS:-pluto-comms}"
COLD_START_REQUIRED_NAMESPACES="${COLD_START_REQUIRED_NAMESPACES:-$APP_NS $WORKER_NS}"

PROJECT="${PROJECT:-sol-qualification}"
REGION="${REGION:-us-central1}"
export PROJECT REGION
BASE_DOMAIN="${BASE_DOMAIN:-qual-gcp.sol-fab.dev}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-2700}"
DELEGATION_WAIT_MINUTES="${DELEGATION_WAIT_MINUTES:-25}"
LOG_DIR="${LOG_DIR:-/tmp/sol-gcp-qual-$ATTEMPT}"
export LOG_DIR
RUN_KUBECONFIG="$LOG_DIR/run-kubeconfig.yaml"
# The attempt-owned kubeconfig the destroy destination establishes and probes through.
ATTEMPT_KUBECONFIG="$RUN_KUBECONFIG"
APP_BUILD_CONTEXT="$LOG_DIR/app-build-context"
export KUBECONFIG="$RUN_KUBECONFIG"
STATE_BUCKET="${STATE_BUCKET:-sol-qualification-tfstate}"
CLUSTER_ISSUER="${CLUSTER_ISSUER:-letsencrypt-staging}"
case "$CLUSTER_ISSUER" in
  *production) ATTEMPT_CLAIM=production ;;
  *) ATTEMPT_CLAIM=mechanism-only ;;
esac
export CLUSTER_ISSUER ATTEMPT_CLAIM
APP_TAG="${APP_TAG:-qual-$(date -u +%Y%m%d-%H%M%S)}"
export APP_TAG
# The database setup Job's image, pinned by digest. It is public, so there is nothing to
# publish -- only a digest to name. Without it the deploy cannot run the database setup step,
# so it can neither deliver the class credentials nor fail closed on a missing one (#1402).
# The setup image comes from the installed release's own bundle (share/sol/<version>/
# setup-image), which is the only place a release may take it from: an explicit
# SOL_SETUP_POSTGRES_IMAGE is refused for an installed release, so the harness must not set one
# (#1427).

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

# `say`, `refuse`, `ca_qualify` and the database-contract pins are the shared
# functions in lib/shared.sh.

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

# Provider identity and the shared phase bodies. The hooks this provider must supply
# are checked here, in the process that will call them, before any phase runs.
PROVIDER=gcp
# shellcheck source=/dev/null
source "$ROOT/internal/qualification/lib/shared.sh"
# shellcheck source=/dev/null
source "$ROOT/internal/qualification/lib/hooks.sh"
# shellcheck source=/dev/null
source "$ROOT/internal/qualification/lib/phases.sh"
# shellcheck source=/dev/null
source "$ROOT/internal/qualification/provider-gcp.sh"
require_provider_hooks || exit 1
case "${1:-}" in
  prepare | cloud | app | destroy | stop)
    sol_under_test_resolve
    ;;
esac


mkdir -p "$LOG_DIR"
SAY_LOG="$LOG_DIR/harness.log"
case "${1:-}" in
  cloud)
    attempt_begin 1
    ;;
  prepare | app | destroy | identity)
    attempt_begin 0
    ;;
esac
say "environment: work tree $ROOT, revision $(git -C "$ROOT" rev-parse --short HEAD)"
case "${1:-}" in
  prepare | cloud | app | destroy | stop)
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

# The same cold-deploy contract as AWS: the deploy must stop at the immutable-artifact
# gate, not merely reconcile the environment. `Deployment incomplete.` is the product's
# marker that it refused at the right place rather than failing somewhere else.
pending_artifacts_refused() {
  grep -qF 'Deployment incomplete.' "$LOG_DIR"/cloud-apply*.log 2>/dev/null
}

# A deploy that refused at the installation boundary applies nothing, so teardown must stay
# disarmed for a target this run never touched. Once the durable/cluster phase ran -- or the
# environment was reconciled -- disposable resources exist that this run owns, so cleanup is
# armed even if a later phase failed.
cloud_mutated() {
  environment_reconciled ||
    grep -qF 'lifecycle phase: CloudBootstrap' "$LOG_DIR"/cloud-apply*.log 2>/dev/null
}


owns_target_file() {
  if [ ! -s "$TARGET_FILE" ]; then return 0; fi
  head -1 "$TARGET_FILE" | grep -qF "live-qual.sh"
}

remove_target() {
  if owns_target_file; then rm -f "$TARGET_FILE"; fi
}

write_target() {
  local le_email="${LE_EMAIL:-$TEARDOWN_LE_EMAIL}"
  mkdir -p "$(dirname "$TARGET_FILE")"
  if [ -f "$TARGET_FILE" ] && ! owns_target_file; then
    say "REFUSING: $TARGET_FILE exists and was not written by this harness; move it aside first."
    exit 2
  fi
  if [ -z "${LE_EMAIL:-}" ]; then
    say "no LE_EMAIL given: the teardown target declares the non-deliverable contact $le_email; no certificate is created on this path"
  fi
  cat >"$TARGET_FILE" <<YAML
$TARGET_MARK
$TARGET_ENV:
  targets:
    $TARGET_KEY:
      cluster_name: $CLUSTER
      base_domain: $BASE_DOMAIN
      dns_zone_ownership: sol
      # No profile is selected at any phase. This row qualifies the application path and
      # claims nothing the production profile's guarantees would promise; the profile is
      # AWS-qualified, so selecting it on GCP could only be refused by its preflight. The
      # *shape* is still declared: the platform publishes the authenticated Kafka
      # credential the row's units read, and write_app_target declares the same shape.
      shape: durable
      letsencrypt_email: $le_email
      cluster_issuer: $CLUSTER_ISSUER
      terraform_var_file: $TFVARS

      state_bucket: $STATE_BUCKET

      kube_context: $(app_kube_context)

      gcp:
        project_id: $PROJECT
        provisioner_impersonator: $IMPERSONATOR

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


# The expected universe of the absence verdict: every class the inventory must
# decide, and whether the target must leave it absent or leave it present.
#
# The probe calls in `inventory` declare the provider read; this table declares
# the obligation. Keeping the two apart is what makes a skipped probe a failed
# verdict instead of silence: `inventory_reconcile` requires exactly one row per
# entry, and `verify_absent` refuses a row it cannot interpret. Adding a class
# to the table without a probe, or a probe without the table, fails closed.
#
#   absent   the target must leave no attributable resource in the class
#   present  a durable prerequisite that teardown must not remove
#   scope    the project, region and caller every read below is taken under
INVENTORY_CLASSES=(
  "scope-caller|scope"
  "scope-project|scope"
  "scope-region|scope"
  "gke-cluster|absent"
  "sql-instance|absent"
  "network|absent"
  "subnetwork|absent"
  "router|absent"
  "nat|absent"
  "address-regional|absent"
  "address-global|absent"
  "disks|absent"
  "forwarding-rules|absent"
  "artifact-registry|absent"
  "kafka-secret|absent"
  "service-account-provisioner|absent"
  "service-account-loki|absent"
  "service-account-thanos|absent"
  "custom-role|absent"
  "role-binding|absent"
  "impersonator-binding|absent"
  "peering|absent"
  "state-bucket|present"
  "dns-zone|present"
)

# The release teardown policy this document is eligible under. The promotion
# gate loads `internal/tooling/release/teardown-policy.v1.json`; a document
# naming another policy is not promotion-eligible. Keep this value in sync with
# that file; `internal/ci/test_teardown_policy.py` guards the class universe.
TEARDOWN_POLICY_NAME="sol-teardown-v1"

inventory_expectation() {
  local wanted="$1" entry
  for entry in "${INVENTORY_CLASSES[@]}"; do
    if [ "${entry%%|*}" = "$wanted" ]; then
      printf '%s\n' "${entry#*|}"
      return 0
    fi
  done
  return 1
}

# One evidence row per class. A diagnostic is collapsed to one clipped line so
# the TSV stays a table: `head` over two files emits `==> file <==` headers and
# blank lines, which is how a row used to spill across four lines.
inventory_detail() {
  printf '%s' "$1" | tr '\t\n' '  ' | cut -c1-140
}

provider_detail() {
  local err="$1" out="$2"
  if [ -s "$err" ]; then
    head -n1 "$err"
  elif [ -s "$out" ]; then
    head -n1 "$out"
  fi
}

# The only writer. The expectation comes from the declared universe, never from
# the caller, so exactly one place answers "absent or present".
verdict_row() {
  local class="$1" state="$2" detail="${3:-}" expect
  case "$state" in
    PRESENT | ABSENT | UNKNOWN) ;;
    *)
      detail="the inventory produced '$state', which is not a class verdict"
      state=UNKNOWN
      ;;
  esac
  if ! expect="$(inventory_expectation "$class")"; then
    detail="$(inventory_detail "not a class the inventory declares")"
    printf '%s\tUNKNOWN\t-\t%s\n' "$class" "$detail" >>"$INVENTORY_TSV"
    say "    $class: UNKNOWN ($detail)"
    return 0
  fi
  detail="$(inventory_detail "$detail")"
  printf '%s\t%s\t%s\t%s\n' "$class" "$state" "$expect" "$detail" >>"$INVENTORY_TSV"
  say "    $class: $state${detail:+ ($detail)}"
}

# ---------------------------------------------------------------------------
# provider scope
#
# Every read below observes one project, in one region, as one caller. Until
# those three are established, "the provider returned no resource" says nothing
# about this target: a project that does not exist, a switched account or an
# unreadable region answers NOT_FOUND for every class. Scope is its own
# observation, and a scope failure makes every disposable class UNKNOWN rather
# than running the probes against a scope the run cannot name.
#
# The limit, stated rather than implied: this binds the reads to the project the
# run was told to use and records it. It does not prove that project is the one
# the operator meant; that identity comes from the target declaration.
# ---------------------------------------------------------------------------
INVENTORY_SCOPE_OK=0

inventory_state() {
  awk -F'\t' -v c="$1" '$1 == c { state = $2 } END { print state }' "$INVENTORY_TSV"
}

# The identity record is only about the target it was taken from. A shared
# LOG_DIR can hold an earlier attempt's record, and a pre-teardown file from
# another cluster or project must never attribute a resource to this one.
inventory_identity_scope() {
  printf 'attempt=%s cluster=%s project=%s region=%s' \
    "${ATTEMPT:--}" "$CLUSTER" "$PROJECT" "$REGION"
}

inventory_scope() {
  local caller="" project="" region=""
  INVENTORY_SCOPE_OK=0
  printf '# %s\n' "$(inventory_identity_scope)" >>"$INVENTORY_IDENTITIES_TSV"

  if gcloud auth list --filter=status:ACTIVE --format='value(account)' \
      >"$LOG_DIR/inventory-scope-caller.log" 2>"$LOG_DIR/inventory-scope-caller.stderr"; then
    caller="$(head -n1 "$LOG_DIR/inventory-scope-caller.log")"
  fi
  if [ -n "$caller" ]; then
    verdict_row scope-caller PRESENT "the reads are taken as $caller"
  else
    verdict_row scope-caller UNKNOWN "no active caller identity: $(provider_detail "$LOG_DIR/inventory-scope-caller.stderr" "$LOG_DIR/inventory-scope-caller.log")"
  fi

  if gcloud projects describe "$PROJECT" --format='value(projectId)' \
      >"$LOG_DIR/inventory-scope-project.log" 2>"$LOG_DIR/inventory-scope-project.stderr"; then
    project="$(head -n1 "$LOG_DIR/inventory-scope-project.log")"
  fi
  if [ "$project" = "$PROJECT" ]; then
    verdict_row scope-project PRESENT "the provider answered for project $PROJECT"
  else
    verdict_row scope-project UNKNOWN "project $PROJECT was not readable as itself (answer '$project'): $(provider_detail "$LOG_DIR/inventory-scope-project.stderr" "$LOG_DIR/inventory-scope-project.log")"
  fi

  if gcloud compute regions describe "$REGION" --project "$PROJECT" --format='value(name)' \
      >"$LOG_DIR/inventory-scope-region.log" 2>"$LOG_DIR/inventory-scope-region.stderr"; then
    region="$(head -n1 "$LOG_DIR/inventory-scope-region.log")"
  fi
  if [ "$region" = "$REGION" ]; then
    verdict_row scope-region PRESENT "the provider answered for region $REGION"
  else
    verdict_row scope-region UNKNOWN "region $REGION was not readable as itself (answer '$region'): $(provider_detail "$LOG_DIR/inventory-scope-region.stderr" "$LOG_DIR/inventory-scope-region.log")"
  fi

  printf 'project\t%s\n' "$PROJECT" >>"$LOG_DIR/inventory-$INVENTORY_MODE.identity"
  printf 'region\t%s\n' "$REGION" >>"$LOG_DIR/inventory-$INVENTORY_MODE.identity"
  printf 'caller\t%s\n' "${caller:--}" >>"$LOG_DIR/inventory-$INVENTORY_MODE.identity"
  if [ "$(inventory_state scope-caller)" = PRESENT ] \
    && [ "$(inventory_state scope-project)" = PRESENT ] \
    && [ "$(inventory_state scope-region)" = PRESENT ]; then
    INVENTORY_SCOPE_OK=1
  fi
  say "inventory scope: caller ${caller:--}, project $PROJECT, region $REGION; established=$INVENTORY_SCOPE_OK"
}

# No probe ran, and no probe result can be trusted: every class the verdict
# decides is UNKNOWN for the same reason, so the failure names the scope.
inventory_scope_unestablished() {
  local entry class
  for entry in "${INVENTORY_CLASSES[@]}"; do
    class="${entry%%|*}"
    case "${entry#*|}" in scope) continue ;; esac
    verdict_row "$class" UNKNOWN "the project, region or caller scope was not established, so this class was not read"
  done
}

# ---------------------------------------------------------------------------
# classification primitives
#
# One rule per operation, because absence does not mean the same thing for a
# read of a named resource and for an enumeration:
#
#   describe     the command asks about exactly one named resource. Its own
#                not-found answer can establish absence; a successful command
#                with an empty field cannot, and neither can an authority,
#                availability or parent-resource failure.
#   enumerate    the command lists a whole class. Absence requires the list to
#                have completed with a shape this harness can decode and no
#                attributable row. A filtered projection is never accepted:
#                attribution is applied here, in this process.
# ---------------------------------------------------------------------------

# Failures that are about authority, scope or availability, never about the
# resource. Checked before any not-found token: gcloud reports a denied read as
# "denied on resource (or it may not exist)", and a project that does not exist
# as NOT_FOUND while naming the project, not the resource.
provider_authority_failure() {
  grep -qiE 'PERMISSION_DENIED|does not have permission|UNAUTHENTICATED|API has not been used|has not been used in project|SERVICE_DISABLED|is not enabled|RESOURCE_EXHAUSTED|quota exceeded' "$1" "$2"
}

# A bare `404` is deliberately not a not-found token: it also appears in
# endpoint and transport diagnostics that name nothing about the resource.
#
# This is the single classifier for a failed *named* read, and it is the only place
# that decides which answer a failure gives. Authority/availability outranks every
# not-found token: gcloud reports a denied read as "denied on resource (or it may not
# exist)", and a project that does not exist as NOT_FOUND while naming the project,
# not the resource. `provider_authority_failure` answers the narrower question used by
# enumeration (is this failure about authority at all); both read one rule.
provider_failure_class() {
  if provider_authority_failure "$1" "$2"; then
    printf 'authority'
    return 0
  fi
  if grep -qiE '(NOT_FOUND|not[_. -]?found|does not exist|No URLs matched)' "$1" "$2"; then
    printf 'absent'
    return 0
  fi
  printf 'unknown'
}

# `--parent CLASS:IDENTITY` declares that this resource lives inside another
# class this inventory observes separately (a NAT inside its router). A not-found
# that names only the parent is then decided from the parent's own observation
# instead of being read as absence of the child: an absent parent implies an
# absent child, a present parent makes the failing read ambiguous.
provider_describe() {
  local class="$1" subject="$2"; shift 2
  local parent_class="" parent_identity=""
  if [ "${1:-}" = "--parent" ]; then
    parent_class="${2%%:*}"
    parent_identity="${2#*:}"
    shift 2
  fi
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" diagnostic
  if "$@" >"$out" 2>"$err"; then
    if [ -n "$(tr -d '[:space:]' <"$out")" ]; then
      verdict_row "$class" PRESENT "the named read answered for $subject"
    else
      verdict_row "$class" UNKNOWN "the named read succeeded but returned no value for $subject; a successful command with no field is not an absence"
    fi
  else
    case "$(provider_failure_class "$err" "$out")" in
      authority)
        verdict_row "$class" UNKNOWN "the read failed on authority or availability, not on the resource: $(provider_detail "$err" "$out")"
        ;;
      absent)
        diagnostic="$(cat "$err" "$out" 2>/dev/null)"
        if [ -n "$parent_identity" ] \
          && [ -n "$(inventory_text_mentions "$parent_identity" "$diagnostic")" ] \
          && [ -z "$(inventory_text_mentions "$subject" "$diagnostic")" ]; then
          case "$(inventory_state "$parent_class")" in
            ABSENT)
              verdict_row "$class" ABSENT "the provider named the parent ($parent_class $parent_identity), which is independently absent, so $subject cannot exist"
              ;;
            PRESENT)
              verdict_row "$class" UNKNOWN "the provider named the parent ($parent_class $parent_identity) while the parent is present, so which resource is missing is ambiguous: $(provider_detail "$err" "$out")"
              ;;
            *)
              verdict_row "$class" UNKNOWN "the provider named the parent ($parent_class $parent_identity) and the parent's own state is not established: $(provider_detail "$err" "$out")"
              ;;
          esac
        else
          verdict_row "$class" ABSENT "the provider answered that $subject does not exist: $(provider_detail "$err" "$out")"
        fi
        ;;
      *)
        verdict_row "$class" UNKNOWN "the read failed without establishing that $subject is absent: $(provider_detail "$err" "$out")"
        ;;
    esac
  fi
}

# `attributable` receives (class, stdout-file), prints one attributable identity
# per line, and exits non-zero when the document is not the shape the class
# requires. Exit 0 with no output means "the enumeration completed and nothing
# in it belongs to this target".
provider_enumerate() {
  local class="$1" attributable="$2"; shift 2
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr"
  local found detail identity
  if "$@" >"$out" 2>"$err"; then
    if found="$("$attributable" "$class" "$out" 2>"$LOG_DIR/inventory-$class.shape.stderr")"; then
      if [ -n "$found" ]; then
        while IFS= read -r identity; do
          [ -n "$identity" ] || continue
          inventory_remember_identity "$class" "$identity"
        done <<<"$found"
        verdict_row "$class" PRESENT "$(printf '%s' "$found" | tr '\n' ' ' | cut -c1-120)live resource(s) attributable to this target"
      else
        verdict_row "$class" ABSENT "the enumeration completed in the bound scope and no row is attributable to this target"
      fi
    else
      verdict_row "$class" UNKNOWN "the read succeeded but its shape is not one this class can decode: $(provider_detail "$LOG_DIR/inventory-$class.shape.stderr" "$out")"
    fi
  elif provider_authority_failure "$err" "$out"; then
    verdict_row "$class" UNKNOWN "the read failed on authority or availability, not on the resource: $(provider_detail "$err" "$out")"
  else
    verdict_row "$class" UNKNOWN "the read did not complete an enumeration: $(provider_detail "$err" "$out")"
  fi
}

# ---------------------------------------------------------------------------
# attribution
#
# A row belongs to the target only by an identity the target declares: its
# cluster name as a delimited name component, its GKE cluster label, a load
# balancer address this run observed, the target VPC's self-link, or the same
# identity recorded by the pre-teardown inventory. Names are matched by
# component, so `sol-a` is not matched by `sol-alpha`.
# ---------------------------------------------------------------------------
# The whole needle must appear at a component boundary. Splitting the value and
# comparing the pieces would never match a hyphenated cluster name: `test-cluster`
# appears in `test-cluster-router` as one string, not as `test`/`cluster`.
inventory_text_mentions() {
  local needle="$1" value="${2:-}" before after rest
  [ -n "$needle" ] || return 0
  [ -n "$value" ] || return 0
  rest="$value"
  while [[ "$rest" == *"$needle"* ]]; do
    before="${rest%%"$needle"*}"
    rest="${rest#*"$needle"}"
    after="${rest:0:1}"
    if [[ ! "$before" =~ [A-Za-z0-9]$ ]] && [[ ! "$after" =~ ^[A-Za-z0-9] ]]; then
      printf 'match\n'
      return 0
    fi
  done
}

inventory_name_mentions() { inventory_text_mentions "$CLUSTER" "${1:-}"; }

# The load balancer addresses this run already observed. They supplement, never
# replace, discovery: a GKE-created forwarding rule or address is named
# `k8s2-...`/`a<hex>` and carries no cluster name.
inventory_recorded_ips() {
  local file
  for file in "$LOG_DIR/app-load-balancer.txt" "$LOG_DIR/app-ingresses.txt"; do
    [ -s "$file" ] || continue
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$file" || true
  done | sort -u
}

inventory_ip_recorded() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "${INVENTORY_RECORDED_IPS:-}" | grep -qxF -- "$1"
}

# An identity the pre-teardown inventory attributed to this class. A post
# enumeration that no longer matches it by name must still account for it.
inventory_prior_identity() {
  local class="$1" identity="$2"
  [ -n "${INVENTORY_PRIOR_IDENTITIES:-}" ] || return 1
  [ -s "$INVENTORY_PRIOR_IDENTITIES" ] || return 1
  [ -n "$identity" ] || return 1
  awk -F'\t' -v c="$class" -v i="$identity" \
    '$1 == c && $2 == i { found = 1 } END { exit !found }' "$INVENTORY_PRIOR_IDENTITIES"
}

inventory_remember_identity() {
  # Both inventories record what they attribute: the pre file is also the input
  # a post inventory must account for, and the post file is the evidence that it
  # did.
  [ -n "${INVENTORY_IDENTITIES_TSV:-}" ] || return 0
  printf '%s\t%s\n' "$1" "$2" >>"$INVENTORY_IDENTITIES_TSV"
}

# Decode a JSON array with jq. A document that is not an array, or a filter
# that cannot decode it, is a shape failure: an empty answer from a command
# whose output the harness cannot read is not an absence.
inventory_json_rows() {
  local out="$1" shape="$2" program="$3"
  # The attribution fields are part of the shape. A document that drops
  # `IPAddress`, `network` or `name` would otherwise decode to empty strings and
  # read as "nothing attributable", which is a false absence: it is UNKNOWN.
  jq -e "$shape" "$out" >/dev/null 2>&1 || return 1
  jq -r "$program" "$out" 2>/dev/null || return 1
}

attribute_addresses() {
  local class="$1" out="$2" name address rows
  rows="$(inventory_json_rows "$out" \
    'type == "array" and all(.[]; has("name"))' \
    '.[] | [.name, (.address // "")] | @tsv')" || return 1
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r name address; do
    [ -n "$name" ] || return 1
    if [ -n "$(inventory_name_mentions "$name")" ] \
      || inventory_ip_recorded "$address" \
      || inventory_prior_identity "$class" "$name"; then
      printf '%s\n' "$name"
    fi
  done <<<"$rows"
  return 0
}

attribute_forwarding_rules() {
  local class="$1" out="$2" name address network subnetwork rows
  rows="$(inventory_json_rows "$out" \
    'type == "array" and all(.[]; has("name") and has("IPAddress"))' \
    '.[] | [.name, (.IPAddress // ""), (.network // ""), (.subnetwork // "")] | @tsv')" || return 1
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r name address network subnetwork; do
    [ -n "$name" ] || return 1
    if [ -n "$(inventory_name_mentions "$name")" ] \
      || inventory_ip_recorded "$address" \
      || [ -n "$(inventory_name_mentions "$network")" ] \
      || [ -n "$(inventory_name_mentions "$subnetwork")" ] \
      || inventory_prior_identity "$class" "$name"; then
      printf '%s\n' "$name"
    fi
  done <<<"$rows"
  return 0
}

attribute_disks() {
  local class="$1" out="$2" name label rows
  rows="$(inventory_json_rows "$out" \
    'type == "array" and all(.[]; has("name") and ((.labels // {}) | type == "object"))' \
    '.[] | [.name, (.labels["goog-k8s-cluster-name"] // "")] | @tsv')" || return 1
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r name label; do
    [ -n "$name" ] || return 1
    if [ "$label" = "$CLUSTER" ] \
      || [ -n "$(inventory_name_mentions "$name")" ] \
      || inventory_prior_identity "$class" "$name"; then
      printf '%s\n' "$name"
    fi
  done <<<"$rows"
  return 0
}

attribute_kafka_secret() {
  local class="$1" out="$2"
  inventory_json_rows "$out" \
    'type == "array" and all(.[]; (.name | type == "string") and (.name | test("^projects/[^/]+/secrets/[^/]+$")))' \
    '.[] | select((.name | split("/") | last) == "sol-kafka-'"$CLUSTER"'") | .name'
}

attribute_peerings() {
  local class="$1" out="$2" name network rows
  rows="$(inventory_json_rows "$out" \
    'type == "array" and all(.[]; has("name") and has("network"))' \
    '.[] | [.name, (.network // "")] | @tsv')" || return 1
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r name network; do
    [ -n "$name" ] || return 1
    if [ -n "$(inventory_name_mentions "$network")" ] \
      || inventory_prior_identity "$class" "$name"; then
      printf '%s\n' "$name"
    fi
  done <<<"$rows"
  return 0
}

# A policy is one object, not a filtered projection: the whole binding list is
# read and membership is decided here, so a filter that stops matching cannot
# turn a live binding into an empty result.
inventory_policy_members() {
  local out="$1"
  jq -e 'type == "object" and all((.bindings // [])[]; ((.members // []) | type) == "array")' \
    "$out" >/dev/null 2>&1 || return 1
  jq -r '(.bindings // [])[] | (.members // [])[]' "$out" 2>/dev/null || return 1
}

attribute_project_role_binding() {
  local class="$1" out="$2" members member
  members="$(inventory_policy_members "$out")" || return 1
  while IFS= read -r member; do
    if [ "$member" = "serviceAccount:$GCP_PROVISIONER_SA" ]; then
      printf '%s\n' "$member"
    fi
  done <<<"$members"
  return 0
}

attribute_impersonator_binding() {
  local class="$1" out="$2" members member
  members="$(inventory_policy_members "$out")" || return 1
  while IFS= read -r member; do
    if [ "$member" = "$IMPERSONATOR" ]; then
      printf '%s\n' "$member"
    fi
  done <<<"$members"
  return 0
}

# ---------------------------------------------------------------------------
# class probes whose read is not a plain describe or enumeration
# ---------------------------------------------------------------------------
PROVISIONER_SA_VERDICT=""
probe_service_account() {
  local class="$1" email="$2"
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" verdict detail
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
  verdict_row "$class" "$verdict" "$detail"
}

probe_impersonator_binding() {
  local class="$1" identity_verdict="$2" email="$3"
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" found
  case "$identity_verdict" in
    ABSENT)
      # The grant lives on an identity that is not active, so it cannot be
      # impersonated; the raw policy read is kept as evidence.
      gcloud iam service-accounts get-iam-policy "$email" --project "$PROJECT" --format=json \
        >"$LOG_DIR/inventory-$class.policy.log" 2>&1 || true
      verdict_row "$class" ABSENT "the identity the grant is on is not active, so it cannot be impersonated (raw policy read kept)"
      ;;
    PRESENT)
      if gcloud iam service-accounts get-iam-policy "$email" --project "$PROJECT" --format=json \
           >"$out" 2>"$err"; then
        if ! found="$(attribute_impersonator_binding "$class" "$out")"; then
          verdict_row "$class" UNKNOWN "the identity is active and its policy shape is not one this class can decode"
        elif [ -n "$found" ]; then
          verdict_row "$class" PRESENT "the impersonator still holds a role on the identity"
        else
          verdict_row "$class" ABSENT "the identity is active and no impersonator binding remains on it"
        fi
      elif provider_authority_failure "$err" "$out"; then
        verdict_row "$class" UNKNOWN "the identity is active and its policy read failed on authority: $(provider_detail "$err" "$out")"
      else
        verdict_row "$class" UNKNOWN "the identity is active and its policy could not be read: $(provider_detail "$err" "$out")"
      fi
      ;;
    *)
      verdict_row "$class" UNKNOWN "the identity's own state could not be determined"
      ;;
  esac
}

probe_custom_role() {
  local class="$1" role_id="$2"
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" line marker
  if gcloud iam roles describe "$role_id" --project "$PROJECT" --format='value(name,deleted)' \
       >"$out" 2>"$err"; then
    line="$(head -n1 "$out")"
    marker="$(printf '%s' "$line" | cut -s -f2 | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    case "$marker" in
      true)  verdict_row "$class" ABSENT "provider-deleted (kept in GCP's undelete window): $line" ;;
      *)     verdict_row "$class" PRESENT "an active custom role of this name exists: $line" ;;
    esac
  else
    case "$(provider_failure_class "$err" "$out")" in
      authority)
        verdict_row "$class" UNKNOWN "the role read failed on authority or availability: $(provider_detail "$err" "$out")"
        ;;
      absent)
        verdict_row "$class" ABSENT "the provider answered that $role_id does not exist: $(provider_detail "$err" "$out")"
        ;;
      *)
        verdict_row "$class" UNKNOWN "the role read failed without establishing that $role_id is absent: $(provider_detail "$err" "$out")"
        ;;
    esac
  fi
}

GCP_ROLE_ID="sol_$(printf '%s' "$CLUSTER" | tr '-' '_')_cluster_access"
GCP_PROVISIONER_SA="$CLUSTER-provisioner@$PROJECT.iam.gserviceaccount.com"

inventory() {
  local mode="$1"
  INVENTORY_MODE="$mode"
  INVENTORY_TSV="$LOG_DIR/inventory-$mode.tsv"
  INVENTORY_IDENTITIES_TSV="$LOG_DIR/inventory-$mode.identities.tsv"
  INVENTORY_PRIOR_IDENTITIES=""
  INVENTORY_RECORDED_IPS="$(inventory_recorded_ips)"
  : >"$INVENTORY_TSV"
  : >"$INVENTORY_IDENTITIES_TSV"
  # A post-teardown enumeration must account for the identities the pre-teardown
  # one attributed, not only for the rows its own name rules still match. This
  # supplements discovery; it never replaces it.
  if [ "$mode" = post ] && [ -s "$LOG_DIR/inventory-pre.identities.tsv" ]; then
    if [ "$(head -n1 "$LOG_DIR/inventory-pre.identities.tsv")" = "# $(inventory_identity_scope)" ]; then
      INVENTORY_PRIOR_IDENTITIES="$LOG_DIR/inventory-pre.identities.tsv"
    else
      say "  the pre-teardown identity record belongs to another attempt or scope; it is not used for attribution"
    fi
  fi
  {
    printf 'attempt\t%s\n' "${ATTEMPT:--}"
    printf 'row\t%s\n' "${ROW:-}"
    printf 'target\t%s\n' "${TARGET:-}"
    printf 'state_key\t%s\n' "${STATE_KEY:-}"
    printf 'cluster\t%s\n' "${CLUSTER:-}"
  } >"$LOG_DIR/inventory-$mode.identity" 2>/dev/null || true
  say "inventory ($mode): attempt ${ATTEMPT:--}, target $TARGET, state key $STATE_KEY, cluster $CLUSTER; provider reads only, no mutation"

  inventory_scope
  if [ "$INVENTORY_SCOPE_OK" = 1 ]; then
    provider_describe gke-cluster "$CLUSTER" \
      gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" --format='value(name)'
    provider_describe sql-instance "$CLUSTER-postgres" \
      gcloud sql instances describe "$CLUSTER-postgres" --project "$PROJECT" --format='value(name)'
    provider_describe network "$CLUSTER" \
      gcloud compute networks describe "$CLUSTER" --project "$PROJECT" --format='value(name)'
    provider_describe subnetwork "$CLUSTER-nodes" \
      gcloud compute networks subnets describe "$CLUSTER-nodes" --region "$REGION" --project "$PROJECT" --format='value(name)'
    provider_describe router "$CLUSTER-router" \
      gcloud compute routers describe "$CLUSTER-router" --region "$REGION" --project "$PROJECT" --format='value(name)'
    provider_describe nat "$CLUSTER-nat" --parent "router:$CLUSTER-router" \
      gcloud compute routers nats describe "$CLUSTER-nat" --router "$CLUSTER-router" --region "$REGION" --project "$PROJECT" --format='value(name)'
    # The enumerations below list the whole class in the bound project and
    # attribute in this process. A server-side name filter is not used: GKE
    # creates `pvc-<uuid>` disks and `k8s2-...`/`a<hex>` load-balancer resources
    # whose names do not contain the cluster, so an empty filtered result would
    # read as absence while the resource survives.
    provider_enumerate address-regional attribute_addresses \
      gcloud compute addresses list --project "$PROJECT" --format=json
    provider_enumerate address-global attribute_addresses \
      gcloud compute addresses list --global --project "$PROJECT" --format=json
    provider_enumerate disks attribute_disks \
      gcloud compute disks list --project "$PROJECT" --format=json
    provider_enumerate forwarding-rules attribute_forwarding_rules \
      gcloud compute forwarding-rules list --project "$PROJECT" --format=json
    provider_describe artifact-registry "$CLUSTER" \
      gcloud artifacts repositories describe "$CLUSTER" --location "$REGION" --project "$PROJECT" --format='value(name)'
    # The parent secret remains residue even if every version is disabled or
    # pending destruction. Successful parent absence covers its versions.
    provider_enumerate kafka-secret attribute_kafka_secret \
      gcloud secrets list --project "$PROJECT" --format=json
    probe_service_account service-account-provisioner "$GCP_PROVISIONER_SA"
    provider_describe service-account-loki "$CLUSTER-loki@$PROJECT.iam.gserviceaccount.com" \
      gcloud iam service-accounts describe "$CLUSTER-loki@$PROJECT.iam.gserviceaccount.com" --project "$PROJECT" --format='value(email)'
    provider_describe service-account-thanos "$CLUSTER-thanos@$PROJECT.iam.gserviceaccount.com" \
      gcloud iam service-accounts describe "$CLUSTER-thanos@$PROJECT.iam.gserviceaccount.com" --project "$PROJECT" --format='value(email)'
    probe_custom_role custom-role "$GCP_ROLE_ID"
    provider_enumerate role-binding attribute_project_role_binding \
      gcloud projects get-iam-policy "$PROJECT" --format=json
    probe_impersonator_binding impersonator-binding "$PROVISIONER_SA_VERDICT" "$GCP_PROVISIONER_SA"
    provider_enumerate peering attribute_peerings \
      gcloud compute networks peerings list --project "$PROJECT" --format=json
    provider_describe state-bucket "gs://$STATE_BUCKET" \
      gcloud storage buckets describe "gs://$STATE_BUCKET" --project "$PROJECT" --format='value(name)'
    provider_describe dns-zone "$ZONE_NAME" \
      gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" --format='value(name,dnsName)'
  else
    inventory_scope_unestablished
  fi

  inventory_reconcile
}

# The expected universe and the emitted rows must agree exactly. A class the
# probes never wrote is an UNKNOWN row, not an omission: the verdict must fail
# on it and the evidence must say which class was never observed.
inventory_reconcile() {
  local rc=0 entry class seen declared
  for entry in "${INVENTORY_CLASSES[@]}"; do
    class="${entry%%|*}"
    seen="$(awk -F'\t' -v c="$class" '$1 == c { n++ } END { print n + 0 }' "$INVENTORY_TSV")"
    case "$seen" in
      1) ;;
      0)
        verdict_row "$class" UNKNOWN "the inventory never observed this class; its absence is not established"
        say "  ✗ $class: the class was not observed"
        rc=1
        ;;
      *)
        say "  ✗ $class: observed $seen times; the inventory is not one observation per class"
        rc=1
        ;;
    esac
  done
  while IFS= read -r class; do
    [ -n "$class" ] || continue
    if ! declared="$(inventory_expectation "$class")"; then
      say "  ✗ $class: an inventory row for a class the verdict does not declare"
      rc=1
    fi
  done < <(cut -f1 "$INVENTORY_TSV" | sort -u)
  return "$rc"
}

# Project the rows `verify_absent` already decided into one durable, candidate-
# bound document. This is a projection, not a second decision: the states and
# the overall verdict come from the same `inventory post` result and the same
# `INVENTORY_CLASSES` table the loop above reads. Promotion verifies this
# document; it never re-observes the provider.
write_inventory_verdict() {
  local rc="$1" json="$LOG_DIR/gcp-inventory-verdict.json" text="$LOG_DIR/gcp-inventory-verdict.txt"
  local candidate_json="null" caller="" scope="" required="" classes="" rows="$INVENTORY_TSV"
  local verdict_word

  if [ -n "${SOL_CANDIDATE:-}" ] && [ -f "$SOL_CANDIDATE" ]; then
    candidate_json="$(jq -c '{version, revision, bundle_sha256, runner_image}' "$SOL_CANDIDATE" 2>/dev/null || printf 'null')"
    if ! printf '%s' "$candidate_json" | jq -e '
      (.version | type == "string" and length > 0) and
      (.revision | test("^[0-9a-f]{40}$")) and
      (.bundle_sha256 | test("^[0-9a-f]{64}$")) and
      (.runner_image | test("@sha256:[0-9a-f]{64}$"))
    ' >/dev/null 2>&1; then
      say "  ✗ the candidate document does not name the four-field identity; the teardown verdict cannot be promotion-eligible"
      candidate_json="null"
      rc=1
    fi
  else
    say "  ✗ the candidate document is not readable; the teardown verdict cannot be promotion-eligible"
    candidate_json="null"
    rc=1
  fi

  caller="$(head -n1 "$LOG_DIR/inventory-scope-caller.log" 2>/dev/null || true)"
  scope="$(jq -n \
    --arg cluster "${CLUSTER:-}" \
    --arg project "${PROJECT:-}" \
    --arg region "${REGION:-}" \
    --arg caller "$caller" \
    --arg state_key "${STATE_KEY:-}" \
    '{cluster: $cluster, project: $project, region: $region, caller: $caller, state_key: $state_key}')"
  required="$(for entry in "${INVENTORY_CLASSES[@]}"; do
    printf '%s\n' "${entry%%|*}"
  done | jq -R -s 'split("\n") | map(select(length > 0))')"

  if [ ! -f "$rows" ]; then
    say "  ✗ the post-teardown inventory rows are missing; the teardown verdict records no observations"
    rows="/dev/null"
    rc=1
  fi
  classes="$(jq -R -s '
    split("\n") | map(select(length > 0) | split("\t")) |
    map({
      class: .[0],
      state: .[1],
      expectation: (if .[2] == "scope" then "present" else .[2] end),
      detail: (.[3] // "")
    })
  ' "$rows")"

  if [ "$rc" = "0" ]; then verdict_word="ABSENT"; else verdict_word="NOT ABSENT"; fi
  if ! jq -n \
    --argjson schema 1 \
    --arg policy "$TEARDOWN_POLICY_NAME" \
    --arg provider gcp \
    --argjson candidate "$candidate_json" \
    --arg attempt "${ATTEMPT:-}" \
    --arg target "${TARGET:-}" \
    --argjson scope "$scope" \
    --argjson required_classes "$required" \
    --argjson classes "$classes" \
    --arg verdict "$verdict_word" \
    '{
      schema: $schema,
      policy: $policy,
      provider: $provider,
      candidate: $candidate,
      attempt: $attempt,
      target: $target,
      scope: $scope,
      required_classes: $required_classes,
      classes: $classes,
      verdict: $verdict
    }' >"$json"; then
    say "  ✗ the teardown verdict JSON could not be written at $json"
    return 1
  fi

  {
    printf 'attempt=%s\n' "${ATTEMPT:--}"
    printf 'target=%s\n' "${TARGET:--}"
    printf 'state_key=%s\n' "${STATE_KEY:--}"
    printf 'cluster=%s\n' "${CLUSTER:-}"
    printf 'project=%s\n' "${PROJECT:-}"
    printf 'region=%s\n' "${REGION:-}"
    printf 'caller=%s\n' "${caller:--}"
    printf 'provider=gcp\n'
    printf 'policy=%s\n' "$TEARDOWN_POLICY_NAME"
    while IFS=$'\t' read -r class verdict expect detail; do
      [ -n "$class" ] || continue
      printf '%s: %s (%s)\n' "$class" "$verdict" "${detail:-no detail}"
    done <"$rows"
    printf 'verdict: %s\n' "$verdict_word"
  } >"$text" || {
    say "  ✗ the teardown verdict text could not be written at $text"
    return 1
  }
  # A candidate/rows failure is a failure of the teardown verdict too: the
  # artifact is written for diagnosis, but the run must not report success.
  if [ "$rc" != "0" ]; then
    return 1
  fi
  return 0
}

verify_absent() {
  local rc=0 class verdict expect detail
  if ! inventory post; then
    say "  ✗ the inventory did not produce one observation for every declared class"
    rc=1
  fi
  while IFS=$'\t' read -r class verdict expect detail; do
    case "$expect:$verdict" in
      absent:ABSENT)   say "  ✓ $class absent" ;;
      present:PRESENT) say "  ✓ $class present (durable prerequisite)" ;;
      scope:PRESENT)   say "  ✓ $class verified (the reads are bound to it)" ;;
      scope:ABSENT)    say "  ✗ $class could not be established — the inventory does not know what it read"; rc=1 ;;
      scope:UNKNOWN)   say "  ✗ $class could not be established (UNKNOWN) — $detail"; rc=1 ;;
      absent:PRESENT)  say "  ✗ $class still exists (PRESENT) — $detail"; rc=1 ;;
      present:ABSENT)  say "  ✗ $class is MISSING — a disposable destroy removed a durable prerequisite"; rc=1 ;;
      absent:UNKNOWN)  say "  ✗ $class: could NOT determine absence (UNKNOWN) — $detail"; rc=1 ;;
      present:UNKNOWN) say "  ✗ $class: could NOT be read (UNKNOWN) — $detail"; rc=1 ;;
      *)
        say "  ✗ $class: the verdict cannot interpret '$verdict' against '$expect'${detail:+ — $detail}"
        rc=1
        ;;
    esac
  done <"$INVENTORY_TSV"
  if ! write_inventory_verdict "$rc"; then
    say "  ✗ the teardown verdict did not establish a promotion-eligible result"
    rc=1
  fi
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
      2>"$LOG_DIR/state/$name.stderr" | \
      python3 "$ROOT/internal/qualification/state-evidence.py" >"$out"; then
    say "  state $name: captured (credential-free metadata only)"
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
    printf 'teardown verdict .......... %s\n' "$(artifact_status "$LOG_DIR/gcp-inventory-verdict.json")"
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
  [ "$TEARDOWN_ATTEMPTED" = "1" ] && required+=( "inventory-post.tsv" "gcp-inventory-verdict.json" )
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
  # An incomplete pre-inventory must not block teardown: cleanup has to stay
  # reachable, and the post-teardown verdict is what decides absence.
  if ! inventory pre; then
    say "  the pre-teardown inventory is incomplete; teardown still runs and the post-teardown verdict decides"
  fi
  say "  pre-teardown inventory: $INVENTORY_TSV"
}

# The Kubernetes destination teardown runs against, selected explicitly instead of
# inherited from whatever kubeconfig survived in the evidence directory.
#
# `sol destroy` releases the target's workloads before it drops the substrate, and that
# release runs in whatever cluster `KUBECONFIG` names. A teardown is a separate invocation
# from the run that provisioned the target, so the file it finds may name a cluster of the
# same name that has since been replaced -- a destroy that trusts it releases the workloads
# against the wrong cluster and records the result as this target's (#1443).
#
# This decides what it can, and records which of the three it was:
#
#   attempted   the declared cluster is readable and the attempt's kubeconfig addresses
#               its current endpoint, so the release runs against this target's cluster;
#   skipped     the provider positively answers that the cluster does not exist, so there
#               is nothing to release from, and no context another cluster could answer is
#               handed to Sol;
#   blocked     the cluster could not be read, or could not be reached with a credential
#               that addresses it -- UNKNOWN, never recorded as a skipped release.
#
# Every branch still runs the destroy and the independent inventory: the release is a
# precondition of destruction, not the absence verdict, which stays the inventory's.
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
    destroy_teardown_run || true
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

phase_prepare() { phase_prepare_run; }

phase_cloud() { phase_cloud_run; }

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

phase_destroy() { phase_destroy_run; }

app_registry() { printf '%s-docker.pkg.dev/%s/%s' "$REGION" "$PROJECT" "$CLUSTER"; }

app_kube_context() { printf 'gke_%s_%s_%s' "$PROJECT" "$REGION" "$CLUSTER"; }

# The namespaces this row's units deploy into, for the per-namespace observations below.
# The namespaces the target's selected units declare, taken from the candidate-bound
# application contract -- the build context candidate-binding.sh materialized from the
# candidate revision -- and never from the working tree, app_namespaces, or the
# hardcoded app_context_path map. The boundary is only as good as its selection: a set
# that omits a unit's namespace, or that silently selected nothing, would pass
# vacuously (the #1492/#1488 reader-reimplementation defect class).
candidate_unit_dirs() {
  local unit dir
  for unit in $(cold_start_services); do
    for dir in "$APP_BUILD_CONTEXT"/app/*/"$unit"; do
      if [ -f "$dir/Dockerfile" ]; then
        printf '%s\n' "${dir#"$APP_BUILD_CONTEXT"/app/}"
        break
      fi
    done
  done
}

# Fails closed when the selection cannot cover every selected unit and the namespaces
# this row is configured to exercise.
cold_start_namespaces() {
  local prefix="${APP_NS%-*}" expected=0 found=0 names unit ns
  if [ ! -d "$APP_BUILD_CONTEXT" ]; then
    refuse "REFUSING: no candidate-bound build context at $APP_BUILD_CONTEXT, so the namespaces the"
    refuse "target's selected units declare cannot be derived from the candidate's own contract"
    return 1
  fi
  for unit in $(cold_start_services); do expected=$((expected + 1)); done
  names="$(candidate_unit_dirs | while IFS= read -r address; do
    printf '%s-%s
' "$prefix" "$(app_k8s_name "${address%%/*}")"
  done | sort -u)"
  found="$(candidate_unit_dirs | grep -c .)"
  if [ "$found" != "$expected" ]; then
    refuse "REFUSING: $found of $expected selected units resolve to a candidate-bound directory, so"
    refuse "the declared namespace set would omit a consumer (COLD_START_SERVICES='$(cold_start_services | tr '
' ' ')')"
    return 1
  fi
  if [ -z "$names" ]; then
    refuse "REFUSING: the selected units declare no namespace, so the boundary assertion would look"
    refuse "nowhere and pass vacuously"
    return 1
  fi
  for ns in $COLD_START_REQUIRED_NAMESPACES; do
    if ! printf '%s
' "$names" | grep -qxF "$ns"; then
      refuse "REFUSING: the derived namespace set ($(printf '%s' "$names" | tr '
' ' ')) does not cover"
      refuse "$ns, which this row is configured to exercise; the assertion would not be looking"
      refuse "where the row claims"
      return 1
    fi
  done
  printf '%s
' "$names"
}


app_helpers() {
  printf '%s\n' say app_registry app_kube_context app_services app_k8s_name app_context_path \
    app_image_ref build_app_images push_app_images app_image_ref_args app_ingress_summary \
    app_load_balancer_address app_stop_port_forward app_wait_port_forward app_orders_transaction
}

app_postgres_url() {
  local state="$LOG_DIR/state/cloud.tfstate"
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
# **Read where the deploy says it wrote** (sol-database-identity: ...), rather than
# reproducing the naming rule here (#1424). The bootstrap deploy declares the same
# identity before the migration step, so the migration namespace is known then too;
# the final deploy's declaration wins when both exist.
app_database_field() {
  app_database_declaration | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1
}

# The deploy declares the delivered Kafka credential's Secret name in its own
# output; the row reads that declaration rather than reproducing the naming rule.
app_kafka_credential_name() {
  grep -h 'Kafka: delivered the managed credential to ' "$LOG_DIR"/app-deploy.log 2>/dev/null \
    | tail -1 | sed -n 's/.*credential to \([^ ]*\) in .*/\1/p'
}

app_verify_kafka_delivery() {
  local state="$LOG_DIR/state/cloud.tfstate" public credential
  credential="$(app_kafka_credential_name)"
  if [ -z "$credential" ]; then
    say "app: the deploy declared no delivered Kafka credential; the projection cannot be read"
    return 1
  fi
  public="$(jq -ce '.outputs.kafka_authority.value | select(type == "object")' "$state")" || return 1
  # Value-free: projections through the run kubeconfig, Secret metadata only, and the
  # OCaml order transaction as the behavioral authentication/consumption evidence.
  # The Kafka consumer set is still harness-owned and NOT candidate-derived: the
  # candidate's specimen declares database consumers, not the Kafka resource
  # identity, so there is nothing in it to match these units against. This is a
  # known gap, not an intentional design; it is tracked separately from the
  # database delivery assertion above.
  printf '%s' "$public" | python3 "$ROOT/internal/qualification/kafka-delivery.py" \
    --provider gcp --cluster "$CLUSTER" --region "$REGION" --project "$PROJECT" \
    --secret-kubeconfig "$RUN_KUBECONFIG" \
    --credential-secret "$credential" \
    --transaction "$LOG_DIR/app-transaction-ocaml.txt" \
    --behavioral-consumer pluto-comms/fulfilment-worker \
    --consumer pluto-payments/orders-svc --consumer pluto-comms/fulfilment-worker \
    $(app_namespaces) >"$LOG_DIR/kafka-delivery.json"
}

# The candidate's specimen is the consumer authority: it declares every workload that
# consumes the target database, the Secret each reads `POSTGRES_URL` from, and the
# containers that consume it. The row reads those names; it neither enumerates a
# namespace map of its own nor reconstructs the unit Secret name (#1492 class).
#
# ADR 0007's claim is causal -- the unit reads the class credential, not the master --
# so the second half asserts the rendered routing (the pod's `secretKeyRef`), not the
# presence of a master copy in some other Secret. Refusal does not assert that no
# unreferenced Secret anywhere still holds POSTGRES_URL; that is a different claim.




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
      # The installation the cloud phase created is durable and Sol-owned, and the app
      # deploy re-establishes it before it deploys: without this the deploy refuses with
      # "the target declares no dns_zone_ownership" and never reaches the app path.
      dns_zone_ownership: sol
      # The durable shape matches the installation the cloud phase created: its Kafka is
      # authenticated, so the included units require the platform's Kafka credential and
      # the target must map an authority for it.
      shape: durable
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

app_ingress_summary() {
  kubectl get ingress --all-namespaces -o wide >"$LOG_DIR/app-ingresses.txt" 2>&1 || true
  kubectl get certificates --all-namespaces >"$LOG_DIR/app-certificates.txt" 2>&1 || true
}

app_load_balancer_address() {
  kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

APP_FORWARD_PID=""
app_stop_port_forward() {
  if [ -n "${APP_FORWARD_PID:-}" ]; then
    kill "$APP_FORWARD_PID" 2>/dev/null || true
    wait "$APP_FORWARD_PID" 2>/dev/null || true
    APP_FORWARD_PID=""
  fi
}

# A port-forward that never announces an endpoint cannot carry the transaction.
# Waiting for the announcement is deterministic in a way that probing a just
# exited child is not: bash may not have reaped it yet, so `kill -0` can still
# succeed for a zombie.
app_wait_port_forward() {
  local log="$1" attempt=0 limit="${APP_PORT_FORWARD_WAIT_ATTEMPTS:-50}"
  while [ "$attempt" -lt "$limit" ]; do
    if grep -q 'Forwarding from ' "$log" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$APP_FORWARD_PID" 2>/dev/null; then
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 0.2
  done
  return 1
}

# ---------------------------------------------------------------------------
# database CA family: shared candidate-bound owner
#
# The application and migration CA predicates are not answered here. They are
# owned by the shared OCaml observer, which reads the candidate's declared
# workload/ConfigMap bindings and the actual migration Job under an independently
# established, read-only Kubernetes identity. This harness owns only lifecycle
# placement, the observation identity, request construction and diagnostic
# capture. A phase exit status is not the family verdict; the report phase
# re-reads the durable captures and verdicts.
# ---------------------------------------------------------------------------

# The database-contract pins are recorded by the shared `record_database_contract_pins`
# in lib/shared.sh; the specimen it keeps carries the candidate's own declaration.

# Read one Kubernetes authority through an explicit kubeconfig/context. The
# principal is Kubernetes' authenticated answer, and the cluster identity is the
# server-returned kube-system UID, not a name or a context alias.
kube_authority_json() {
  local kubeconfig="$1" context="$2" out="$3" principal cluster endpoint err
  err="$LOG_DIR/$(basename "$out").stderr"
  mkdir -p "$LOG_DIR"
  if ! principal="$(kubectl --kubeconfig "$kubeconfig" --context "$context" \
      auth whoami -o jsonpath='{.status.userInfo.username}' 2>"$err")"; then
    say "  could not read the Kubernetes principal through $kubeconfig (context $context); the CA family is unestablished"
    return 1
  fi
  if ! cluster="$(kubectl --kubeconfig "$kubeconfig" --context "$context" \
      get namespace kube-system -o jsonpath='{.metadata.uid}' 2>>"$err")"; then
    say "  could not read the Kubernetes cluster identity through $kubeconfig (context $context); the CA family is unestablished"
    return 1
  fi
  if ! endpoint="$(kubectl --kubeconfig "$kubeconfig" --context "$context" \
      config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>>"$err")"; then
    say "  could not read the Kubernetes endpoint through $kubeconfig (context $context); the CA family is unestablished"
    return 1
  fi
  if [ -z "$principal" ] || [ -z "$cluster" ] || [ -z "$endpoint" ]; then
    say "  the Kubernetes authority through $kubeconfig (context $context) is incomplete; the CA family is unestablished"
    return 1
  fi
  python3 - "$out" "$principal" "$cluster" "$endpoint" <<'PY'
import json, sys
json.dump({"principal": sys.argv[2], "cluster": sys.argv[3], "endpoint": sys.argv[4]},
          open(sys.argv[1], "w"))
PY
}

# The product submits the migration Job as the deploy identity. Record that
# separately from the observation identity so the shared launcher can validate
# the submission receipt without pretending the observer created the Job.
record_gcp_deploy_authority() {
  local endpoint
  endpoint="$(current_endpoint)"
  if [ -n "$endpoint" ] && ! kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER" "$endpoint"; then
    say "app: the run kubeconfig does not address $CLUSTER at its current endpoint ($endpoint); the deploy authority is unestablished"
    return 1
  fi
  kube_authority_json "$RUN_KUBECONFIG" "$(app_kube_context)" \
    "$LOG_DIR/ca-submission-authority.json"
}

authority_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

# The operator owns observer credentials and read-only grants. Qualification
# verifies the authenticated authority and samples the sensitive permissions below;
# it does not acquire credentials or establish an exhaustive authorization boundary.
establish_gcp_ca_observer() {
  local supplied="${GCP_CA_OBSERVER_SOURCE_KUBECONFIG:-}"
  local expected_observer="${GCP_CA_OBSERVER_PRINCIPAL:-}"
  local context observer_principal deploy_principal observer_cluster observer_endpoint
  local deploy_cluster deploy_endpoint namespace verb required_namespaces migration_namespace

  if [ -z "$supplied" ]; then
    say "app: refusing: no independent GCP database-CA observation identity is configured."
    say "     Set GCP_CA_OBSERVER_SOURCE_KUBECONFIG to an operator-established read-only kubeconfig."
    say "     The deploy kubeconfig is never used as a fallback."
    return 1
  fi
  if [ ! -s "$supplied" ]; then
    say "app: GCP_CA_OBSERVER_SOURCE_KUBECONFIG=$supplied is not a readable kubeconfig; the CA family is unestablished"
    return 1
  fi
  if [ -z "$expected_observer" ]; then
    say "app: GCP_CA_OBSERVER_PRINCIPAL is required, so the observed identity is declared rather than inferred"
    return 1
  fi
  # Keep the supplied path: moving a kubeconfig would change relative key/cert paths.
  CA_OBSERVER_KUBECONFIG="$(realpath -- "$supplied")" || return 1
  context="$(kubectl --kubeconfig "$CA_OBSERVER_KUBECONFIG" config current-context)" || return 1
  if [ -z "$context" ]; then
    say "app: the CA observation kubeconfig names no selected context; the CA family is unestablished"
    return 1
  fi
  CA_OBSERVER_CONTEXT="$context"
  # The CA driver's request uses the attempt's CA kubeconfig/context names. The observer
  # is this row's independent qualifier identity, so the same path is the qualifier path.
  CA_KUBECONFIG="$CA_OBSERVER_KUBECONFIG"
  CA_CONTEXT="$CA_OBSERVER_CONTEXT"
  QUALIFIER_KUBECONFIG="$CA_OBSERVER_KUBECONFIG"
  if ! kube_authority_json "$CA_OBSERVER_KUBECONFIG" "$context" "$LOG_DIR/ca-authority.json"; then
    return 1
  fi
  if [ ! -s "$LOG_DIR/ca-submission-authority.json" ]; then
    say "app: the deploy authority was not recorded, so the observation identity cannot be shown to be separate"
    return 1
  fi
  observer_principal="$(authority_field "$LOG_DIR/ca-authority.json" principal)"
  deploy_principal="$(authority_field "$LOG_DIR/ca-submission-authority.json" principal)"
  observer_cluster="$(authority_field "$LOG_DIR/ca-authority.json" cluster)"
  observer_endpoint="$(authority_field "$LOG_DIR/ca-authority.json" endpoint)"
  deploy_cluster="$(authority_field "$LOG_DIR/ca-submission-authority.json" cluster)"
  deploy_endpoint="$(authority_field "$LOG_DIR/ca-submission-authority.json" endpoint)"
  if [ "$observer_principal" != "$expected_observer" ]; then
    say "app: the CA observation identity authenticated as $observer_principal, not the configured observer $expected_observer; the CA family is unestablished"
    return 1
  fi
  if [ "$observer_principal" = "$deploy_principal" ]; then
    say "app: the CA observation identity is the deploy identity ($observer_principal); the claim would not be independent"
    return 1
  fi
  if [ "$observer_cluster" != "$deploy_cluster" ] || [ "$observer_endpoint" != "$deploy_endpoint" ]; then
    say "app: the CA observation identity addresses another Kubernetes cluster or endpoint; the claim would not describe this deployment"
    return 1
  fi

  # The candidate-bound obligation set is the only namespace authority for these
  # checks. A separate app namespace list would let the security checks drift from
  # what the compiled observer actually reads.
  if ! ca_requirements; then return 1; fi
  required_namespaces="$(ca_requirement_namespaces)"
  if [ -z "$required_namespaces" ]; then
    say "app: the candidate-bound obligations name no observation namespace; the CA family is unestablished"
    return 1
  fi
  migration_namespace="$(app_database_field namespace)"
  if [ -z "$migration_namespace" ]; then
    say "app: the deploy declared no migration namespace; the CA family cannot be observed"
    return 1
  fi
  if ! printf '%s\n' "$required_namespaces" | grep -qxF "$migration_namespace"; then
    say "app: the candidate's CA obligations do not cover the deploy's migration namespace $migration_namespace"
    return 1
  fi

  for namespace in $required_namespaces; do
    # Bounded safety probes: secret disclosure, exec/log access and selected
    # changes to the observed objects. Other grants remain the operator's duty.
    for verb in \
      "get secrets" "list secrets" "create pods/exec" "get pods/log" \
      "patch deployments.apps" "patch configmaps" "patch jobs.batch" "delete jobs.batch"; do
      if ! expect_denied "$CA_OBSERVER_KUBECONFIG" "$CA_OBSERVER_CONTEXT" "$namespace" "$verb"; then
        return 1
      fi
    done
  done

  {
    printf 'observation_identity: %s\n' "$observer_principal"
    printf 'configured_observer_principal: %s\n' "$expected_observer"
    printf 'deployment_identity: %s\n' "$deploy_principal"
    printf 'cluster: %s\n' "$observer_cluster"
    printf 'endpoint: %s\n' "$observer_endpoint"
    printf 'namespaces: %s\n' "$(printf '%s' "$required_namespaces" | tr '\n' ' ')"
    printf 'requirement_source: candidate-bound obligations\n'
    printf 'permission_sample: get/list secrets, create pods/exec, get pods/log, patch deployments/configmaps/jobs and delete jobs denied in candidate-bound namespaces\n'
    printf 'auth: operator-supplied kubeconfig\n'
  } >"$LOG_DIR/ca-observer.txt"
  say "app: CA observation identity $observer_principal is the configured observer, passed the permission sample and is separate from the deploy identity"
}

# The compiled owner exposes the candidate-bound observation universe. The harness
# uses this exact namespace set for its bounded negative authorization checks.
ca_requirements() {
  local status=0
  if ! ca_request requirements "" "" ""; then
    say "app: could not build the CA requirements request"
    return 1
  fi
  timeout "$PHASE_TIMEOUT" "$SOL_QUALIFICATION_CA" --phase requirements \
    --request "$LOG_DIR/ca-request-requirements.json" \
    >"$LOG_DIR/ca-requirements.json" 2>"$LOG_DIR/ca-requirements.log" || status=$?
  if [ "$status" != 0 ]; then
    say "app: the shared database-CA owner could not establish the candidate-bound requirements"
    tail -n 20 "$LOG_DIR/ca-requirements.log" || true
    if [ -s "$LOG_DIR/ca-requirements.json" ]; then
      tail -n 20 "$LOG_DIR/ca-requirements.json" || true
    fi
    return 1
  fi
}

ca_requirement_namespaces() {
  python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["namespaces"]))' \
    "$LOG_DIR/ca-requirements.json"
}

expect_denied() {
  local kubeconfig="$1" context="$2" namespace="$3" verb="$4" answer
  local -a verb_args
  read -r -a verb_args <<<"$verb"
  answer="$(kubectl --kubeconfig "$kubeconfig" --context "$context" \
    auth can-i "${verb_args[@]}" -n "$namespace" 2>/dev/null || true)"
  answer="$(printf '%s' "$answer" | tr -d '[:space:]')"
  case "$answer" in
    no) return 0 ;;
    yes)
      say "app: the CA observation identity holds '$verb' in $namespace, which the CA observation permission sample forbids"
      return 1
      ;;
    *)
      say "app: could not establish that '$verb' is denied to the CA observation identity in $namespace"
      return 1
      ;;
  esac
}

# Build the shared driver's request from inputs this row recorded. Nothing here
# is taken from the product's own report.
# The shared database-CA launcher is `ca_qualify` in lib/shared.sh; the provider's
# `ca_request` builds the request it runs. A phase's exit status is not evidence: the
# report phase re-reads the recorded captures and verdicts.

app_orders_transaction() {
  local ns="$1" service="$2" label="$3" port="$4"
  local transcript="$LOG_DIR/app-transaction-$label.txt"
  local status_file="$LOG_DIR/app-order-status-$label.txt"
  local status_err="$LOG_DIR/app-order-status-$label.err"
  local order_file="$LOG_DIR/app-order-$label.txt"
  local order_err="$LOG_DIR/app-order-$label.err"
  local order_id="ord-$label-$(date -u +%s)-$$"
  local attempts="${APP_READBACK_ATTEMPTS:-12}" interval="${APP_READBACK_INTERVAL:-5}"
  local attempt=0 curl_rc=0 effect_rc=0 served="" last_kind="none"

  kubectl -n "$ns" get pods -o wide >"$LOG_DIR/app-pods-$label.txt" 2>&1 || return 1
  kubectl -n "$ns" get events --sort-by=.lastTimestamp >"$LOG_DIR/app-events-$label.txt" 2>&1 || true
  kubectl -n "$ns" logs -l app.kubernetes.io/component=svc --tail=80 --all-containers=true \
    >"$LOG_DIR/app-svc-$label.log" 2>&1 || true
  kubectl -n "$ns" logs -l app.kubernetes.io/component=worker --tail=80 --all-containers=true \
    >"$LOG_DIR/app-worker-$label.log" 2>&1 || true

  kubectl -n "$ns" port-forward "svc/$service" "$port:80" \
    >"$LOG_DIR/app-port-forward-$label.log" 2>&1 &
  APP_FORWARD_PID=$!
  # The transport process must not outlive this function on any ordinary exit:
  # a failure before the success path used to leave it running.
  trap app_stop_port_forward EXIT
  trap 'app_stop_port_forward; exit 130' INT
  trap 'app_stop_port_forward; exit 143' TERM

  if ! app_wait_port_forward "$LOG_DIR/app-port-forward-$label.log"; then
    if kill -0 "$APP_FORWARD_PID" 2>/dev/null; then
      say "  $label: the port-forward did not report a forwarding endpoint in time"
    else
      say "  $label: the port-forward exited before reporting a forwarding endpoint"
    fi
    cat "$LOG_DIR/app-port-forward-$label.log" >&2 2>/dev/null || true
    return 1
  fi

  until curl -fsS -m 5 "localhost:$port/healthz" >"$LOG_DIR/app-health-$label.txt" 2>&1; do
    attempt=$((attempt + 1))
    if ! kill -0 "$APP_FORWARD_PID" 2>/dev/null; then
      say "  $label: the port-forward exited before the service answered /healthz"
      cat "$LOG_DIR/app-port-forward-$label.log" >&2 2>/dev/null || true
      return 1
    fi
    if [ "$attempt" -ge "$attempts" ]; then
      say "  $label: the service never answered /healthz over the port-forward"
      return 1
    fi
    sleep "$interval"
  done
  if ! kill -0 "$APP_FORWARD_PID" 2>/dev/null; then
    say "  $label: the port-forward exited before the order was submitted"
    cat "$LOG_DIR/app-port-forward-$label.log" >&2 2>/dev/null || true
    return 1
  fi

  curl_rc=0
  curl -fsS -m 30 -X POST "localhost:$port/orders" \
    -H 'Content-Type: application/json' \
    -d "{\"order_id\":\"$order_id\",\"item\":\"widget\",\"quantity\":1}" \
    >"$order_file" 2>"$order_err" || curl_rc=$?
  {
    printf 'namespace: %s  service: %s  language: %s\n' "$ns" "$service" "$label"
    printf 'health: %s\n' "$(cat "$LOG_DIR/app-health-$label.txt" 2>/dev/null || true)"
    printf 'order (curl exit %s): %s\n' "$curl_rc" "$(cat "$order_file" 2>/dev/null || true)"
    [ "$curl_rc" = 0 ] || printf 'order transport error: %s\n' "$(cat "$order_err" 2>/dev/null || true)"
  } >"$transcript" 2>&1
  if [ "$curl_rc" != 0 ]; then
    say "  $label: POST /orders failed at the transport (curl exit $curl_rc); evidence in $transcript"
    return 1
  fi

  # The response predicate belongs to transaction.py: the body must decode to a
  # JSON object with a nonempty order_id. The equality below binds that identity
  # to the order this harness submitted; it is not a textual substring search.
  if ! served="$(printf '%s' "$(cat "$order_file")" | python3 "$TRANSACTION" order-id 2>>"$transcript")"; then
    say "  $label: the order response was not a usable order identity; evidence in $transcript"
    return 1
  fi
  if [ "$served" != "$order_id" ]; then
    say "  $label: the order response identified $served, not the submitted $order_id"
    return 1
  fi
  printf 'order id: %s\n' "$served" >>"$transcript"

  rm -f "$status_file" "$status_err"
  attempt=0
  while [ "$attempt" -lt "$attempts" ]; do
    attempt=$((attempt + 1))
    curl_rc=0
    curl -fsS -m 20 "localhost:$port/orders/$order_id" >"$status_file" 2>"$status_err" || curl_rc=$?
    printf 'read-back attempt %s (curl exit %s): %s\n' "$attempt" "$curl_rc" \
      "$(cat "$status_file" 2>/dev/null || true)" >>"$transcript"
    if [ "$curl_rc" = 0 ]; then
      effect_rc=0
      printf '%s' "$(cat "$status_file")" | python3 "$TRANSACTION" order-effect "$order_id" \
        2>>"$transcript" || effect_rc=$?
      case "$effect_rc" in
        0)
          {
            printf 'read-back: %s\n' "$(cat "$status_file")"
            printf 'the worker effect is visible to the service: %s reached fulfilled or confirmed\n' "$order_id"
          } >>"$transcript" 2>&1
          app_stop_port_forward
          app_ingress_summary
          app_load_balancer_address >"$LOG_DIR/app-load-balancer.txt" 2>&1 || true
          return 0
          ;;
        1) last_kind="unmet" ;;
        *)
          last_kind="malformed"
          ;;
      esac
    else
      last_kind="transport"
      printf 'read-back transport error: %s\n' \
        "$(cat "$status_err" 2>/dev/null || true)" >>"$transcript"
    fi

    if ! kill -0 "$APP_FORWARD_PID" 2>/dev/null; then
      say "  $label: the port-forward exited before the order read-back completed"
      cat "$LOG_DIR/app-port-forward-$label.log" >&2 2>/dev/null || true
      return 1
    fi
    if [ "$attempt" -lt "$attempts" ]; then
      sleep "$interval"
    fi
  done

  # Timed out. One final read-back is kept for diagnosis, and the failure names
  # whether the bodies were semantic negatives or unusable evidence. An empty,
  # malformed or HTTP-error body is never read as a completed order.
  curl_rc=0
  curl -sS -m 20 "localhost:$port/orders/$order_id" >"$status_file" 2>"$status_err" || curl_rc=$?
  printf 'final read-back (curl exit %s): %s\n' "$curl_rc" \
    "$(cat "$status_file" 2>/dev/null || true)" >>"$transcript"
  case "$last_kind" in
    malformed)
      say "  $label: the order read-back never produced usable JSON evidence: $order_id"
      ;;
    transport)
      say "  $label: the order read-back could not be completed through the transport (curl exit $curl_rc): $order_id"
      ;;
    *)
      say "  $label: the order never reached fulfilled or confirmed in time: $order_id"
      ;;
  esac
  cat "$transcript" >&2 2>/dev/null || true
  return 1
}

capture_app_evidence() {
  kubectl get pods --all-namespaces >"$LOG_DIR/app-pods-all.txt" 2>&1 || true
  kubectl get events --all-namespaces --sort-by=.lastTimestamp >"$LOG_DIR/app-events-all.txt" 2>&1 || true
  app_ingress_summary
  app_load_balancer_address >"$LOG_DIR/app-load-balancer.txt" 2>&1 || true
}

phase_app() { phase_app_run; }

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
  prepare   materialize the candidate-bound build context from the immutable install
            and candidate workspace. The cloud and app phases reuse it and fail closed
            without it; prepare creates no provider state.
  cloud     reconcile the whole target: `sol deploy` establishes the durable
            installation inline (its first-run offer is confirmed through `script`),
            applies the cluster and platform roots, and stops at the workloads whose
            digests the app phase has not published yet. The run starts the
            run-kubeconfig waiter and the API-readiness probe around it. If it fails to establish
            Kafka authority or initialization, the phase fails rather than supplying a
            credential on Sol's behalf. Sol owns provider-backed generation and delivery;
            the app phase compares the authority, broker input and consumer projections.
            On failure it captures the
            Kubernetes evidence, the cert-manager discriminator and the provider
            inventory before any teardown. On success it continues to the delegation
            hand-off and keeps the substrate for the TLS rows.
  app       build and push this row's two images into the target's Artifact Registry, run the
            shared database-CA owner over the workspace's own `migrate apply`, run `sol
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
            unit, which the row asserts before the transaction. The migration and application
            CA claims are observed and decided by the shared OCaml owner under a separate
            operator-established read-only Kubernetes identity
            (GCP_CA_OBSERVER_SOURCE_KUBECONFIG); the deploy kubeconfig is never that observer.
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
  LE_EMAIL       ACME contact address, for the platform's certificates; required by
                 the cloud and app phases. destroy does not need one: without it the
                 teardown target declares a non-deliverable contact, because
                 destruction issues no certificate
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
  WORKSPACE=examples/pluto    TFVARS=internal/qualification/gcp/qual.tfvars
  LOG_DIR=/tmp/sol-gcp-qual-<attempt>   XDG_DATA_HOME
  GCP_CA_OBSERVER_SOURCE_KUBECONFIG        operator-established read-only kubeconfig; its selected
                                           context is used, with no credential acquisition
  GCP_CA_OBSERVER_PRINCIPAL                required authenticated username of the observer
  SOL_QUALIFICATION_CA=_build/default/internal/tooling/sol_qualification/bin/qualification_database_ca.exe

The operator must provision read-only observer credentials. The shared driver checks
list permission for its collection reads, and actual reads must succeed. The harness
samples denial of get/list Secrets, exec/log access, patching Deployments/ConfigMaps/Jobs
and deleting Jobs in candidate-bound namespaces. These probes do not establish a fully
read-only identity or namespace confinement; other grants remain an operator responsibility.
The namespace set comes from the shared owner's requirements, not a separate app list.

The bundle is LOG_DIR: the harness's own narrative (harness.log), phase transcripts,
the run kubeconfig and the waiter journal, the API-readiness samples, the failure
capture and its summary, the provider inventory, the Terraform state snapshots, and
evidence-manifest.txt.
USAGE
}

case "${1:-}" in
  prepare)  phase_prepare ;;
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
