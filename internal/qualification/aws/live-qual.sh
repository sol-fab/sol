#!/usr/bin/env bash
# live-* runs against a real provider target; stubbed-* runs the same suite on stubbed provider calls.
set -uo pipefail
umask 077
trap '' PIPE

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
TARGET_FILE="$WORKSPACE/sol/environments.local.yml"
ROW="${ROW:-qualreg}"
PROVIDER=aws
ATTEMPT="${ATTEMPT:-}"
TARGET="${TARGET:-$ROW-$ATTEMPT/aws/us-east-1}"
TFVARS="${TFVARS:-$ROOT/internal/qualification/aws/qual.tfvars}"
AWS_PROFILE="${AWS_PROFILE:-sol-qual}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:?Set CLUSTER to this the run EKS cluster name}"
DEPLOY_ROLE_ARN="${DEPLOY_ROLE_ARN:?Set DEPLOY_ROLE_ARN to the deploy role the target declares}"
CLUSTER_ACCESS_ROLE_ARN="${CLUSTER_ACCESS_ROLE_ARN:?Set CLUSTER_ACCESS_ROLE_ARN to the cluster-access role the target declares}"
# The publisher is a *separate* principal (SEC-011 / ADR 0002): Sol's deploy identity holds
# no registry-write authority, so publication is never the operator's ambient credential.
# Optional here so the read-only phases (`verify`) and teardown work without a publisher
# session; `app_push_images` refuses to publish until one is named.
PUBLISHER_ROLE_ARN="${PUBLISHER_ROLE_ARN:-}"
OPERATOR_ROLE_ARN="${OPERATOR_ROLE_ARN:-}"
QUALIFIER_ROLE="${QUALIFIER_ROLE:-}"
TRANSPORT="${TRANSPORT:-1}"
APP_NS="${APP_NS:-pluto-payments}"
WORKER_NS="${WORKER_NS:-pluto-comms}"
APP_SERVICE="${APP_SERVICE:-charge-svc}"
APP_PORT="${APP_PORT:-80}"
SCENARIO="${SCENARIO:-charges}"
SVC_UNIT="${SVC_UNIT:-charge_svc}"
WORKER_UNIT="${WORKER_UNIT:-notify_worker}"
# Every workload the target's plan selects needs an immutable artifact; the
# production-single-region profile refuses a mutable tag. The profile qualifies
# OCaml workloads only, and the example target omits the two TypeScript units.
APP_UNITS="${APP_UNITS:-checkout_svc charge_svc notify_worker orders_svc fulfilment_worker}"
LEDGER_PREFIX="${LEDGER_PREFIX:-sol}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-2400}"
APP_TAG="${APP_TAG:-row-$(date -u +%Y%m%d-%H%M%S)}"
LOG_DIR="${LOG_DIR:-/tmp/sol-aws-row-$ATTEMPT}"
export AWS_PROFILE AWS_REGION APP_TAG APP_NS WORKER_NS APP_SERVICE APP_PORT SCENARIO

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
STATE_BUCKET="${STATE_BUCKET:-sol-qual5-$ACCOUNT-tfstate}"
LOCK_TABLE="${LOCK_TABLE:-sol-qual5-tflock}"
BASE_DOMAIN="${BASE_DOMAIN:-qual-aws.sol-fab.dev}"
ECR_REGISTRY="${ECR_REGISTRY:-$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com}"
# The in-cluster database setup step (ADR 0007) needs a digest-pinned image. It is public,
# so the run pins the same digest the offline lifecycle test uses; a Sol-provisioned target's
# deploy refuses to reach the consumers without it (issue #1402).
# The setup image comes from the installed release's own bundle (share/sol/<version>/
# setup-image), which is the only place a release may take it from: an explicit
# SOL_SETUP_POSTGRES_IMAGE is refused for an installed release, so the harness must not set one
# (#1427).
STATE_KEY="$LEDGER_PREFIX/$TARGET/cloud.tfstate"
WORKSPACE_NAME="${WORKSPACE_NAME:-$(basename "$WORKSPACE")}"
RETENTION="${RETENTION:-$(sed -n 's/^ *destroy_retention: *//p' "$TARGET_FILE" 2>/dev/null | head -1)}"
RETENTION="${RETENTION:-none}"
# Qualification mechanism runs on staging by default; production is reserved for the
# attempt intended to be promotion-eligible. The target declares the issuer; the label
# records which claim the evidence supports.
CLUSTER_ISSUER="${CLUSTER_ISSUER:-letsencrypt-staging}"
case "$CLUSTER_ISSUER" in
  *production) ATTEMPT_CLAIM=production ;;
  *) ATTEMPT_CLAIM=mechanism-only ;;
esac
export CLUSTER_ISSUER ATTEMPT_CLAIM
ABSENCE="$ROOT/internal/qualification/aws/absence.py"
export ECR_REGISTRY

mkdir -p "$LOG_DIR"
SAY_LOG="$LOG_DIR/harness.log"

# The candidate-bound application contract `candidate-binding.sh` materializes in `prepare`. The
# cold-start boundary derives the target's declared namespaces from it, so the assertion and the
# images it guards come from the same, candidate-bound tree.
APP_BUILD_CONTEXT="$LOG_DIR/app-build-context"

say() {
  local line
  printf -v line '[%(%H:%M:%S)T] %s' -1 "$*"
  printf '%s\n' "$line" >>"$SAY_LOG" 2>/dev/null || true
  printf '%s\n' "$line" 2>/dev/null || true
}

# A refusal from inside a function whose stdout is captured (a command substitution) must not be
# written to stdout: the message would be captured as the function's value and never reach the
# operator. `refuse` logs like `say` and writes to stderr.
refuse() {
  local line
  printf -v line '[%(%H:%M:%S)T] %s' -1 "$*"
  printf '%s\n' "$line" >>"$SAY_LOG" 2>/dev/null || true
  printf '%s\n' "$line" >&2 || true
}

CLOUD_APPLIED=0
TEARDOWN_ATTEMPTED=0
TERMINATION_SIGNAL=""
PHASE="${1:-}"

# One attempt, one required sequence. The ledger lets `verify` decide promotion
# eligibility from the phases that actually ran in this attempt, instead of from
# the attempt's name alone: a failed app followed by a clean destroy is not a
# qualified sequence.
record_phase_verdict() {
  local status="${1:-$?}"
  case "${PHASE:-}" in
    prepare | cloud | transport | app | destroy | resume | verify | inventory) ;;
    *) return "$status" ;;
  esac
  [ -n "${LOG_DIR:-}" ] || return "$status"
  mkdir -p "$LOG_DIR" 2>/dev/null || return "$status"
  printf 'phase=%s exit=%s at=%s\n' "$PHASE" "$status" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG_DIR/phase-verdicts.txt" 2>/dev/null || true
  return "$status"
}

on_exit() {
  local status=$?
  record_phase_verdict "$status"
  cleanup
  return "$status"
}

cleanup() {
  local rc=$?
  # A signal can arrive while the deploy is still running, before its exit status is seen:
  # decide from the log whether it already mutated the provider, so a target this run never
  # touched is never torn down.
  if [ -n "$TERMINATION_SIGNAL" ] && { [ "$CLOUD_APPLIED" = 1 ] || cloud_mutated; }; then
    say "SIG$TERMINATION_SIGNAL ended the run: tearing down $TARGET and verifying absence"
    phase_destroy || true
  fi
  return "$rc"
}

on_terminate() {
  if [ -n "$TERMINATION_SIGNAL" ]; then return 0; fi
  TERMINATION_SIGNAL="$1"
  say "received SIG$1: finishing the current step, then tearing down and verifying absence"
  exit 1
}

trap on_exit EXIT
trap 'on_terminate TERM' TERM
trap 'on_terminate INT' INT

source "$ROOT/internal/qualification/sol-under-test.sh"
source "$ROOT/internal/qualification/candidate-binding.sh"
source "$ROOT/internal/qualification/attempt.sh"

case "${1:-}" in
  prepare | cloud | app | destroy | resume)
    sol_under_test_resolve
    ;;
esac

usage() {
  cat <<'USAGE'
live-qual.sh — the AWS regression row: the application contract GCP Attempt 28 established

usage: live-qual.sh PHASE      PHASE in: prepare | cloud | transport | app | destroy | verify | resume

required
  ATTEMPT           a unique identity for this disposable run; the target, state key and
                    evidence directory are bound to it, and a repeated ATTEMPT continues it
  CLUSTER           this run's EKS cluster name
  DEPLOY_ROLE_ARN   the deploy identity whose kubeconfig the deploy uses
  SOL_INSTALL       the extracted release prefix holding bin/sol and share/sol/<version>
  SOL_CANDIDATE     the candidate document this run qualifies (the draft's candidate.json);
                    the run verifies the prefix is that candidate before it provisions
  QUALIFIER_ROLE    the qualification-only transport role; required unless TRANSPORT=0
  PUBLISHER_ROLE_ARN  the scoped image-publishing identity. The phases that publish refuse
                    without it: publication is the publisher's own assumed session, never the
                    operator's ambient credentials (SEC-011 / ADR 0002). The read-only phases
                    (prepare, verify) and destroy do not need it.
optional (defaults shown)
  ROW=qualreg                    the stable logical row label
  TARGET=qualreg-<attempt>/aws/us-east-1   CONTINUE_ATTEMPT=0
  ECR_REGISTRY=<account>.dkr.ecr.us-east-1.amazonaws.com
  AWS_PROFILE=sol-qual           AWS_REGION=us-east-1
  TFVARS=internal/qualification/aws/qual.tfvars
  WORKSPACE=examples/pluto
  PHASE_TIMEOUT=2400             LOG_DIR=/tmp/sol-aws-row-<attempt>
  OPERATOR_ROLE_ARN=<unset>      TRANSPORT=1
  RESUME_FROM=<spent attempt>     resume only: the attempt directory whose provisioning inputs
                                 are carried into a new, diagnostic attempt
  APP_NS=pluto-payments          APP_SERVICE=charge-svc
  APP_PORT=80                    SCENARIO=charges
  WORKER_NS=pluto-comms          SVC_UNIT=charge_svc
  WORKER_UNIT=notify_worker
  APP_UNITS="checkout_svc charge_svc notify_worker orders_svc fulfilment_worker"
                                 every workload the target selects is built, published
                                 into the repositories Sol's deploy creates, and pinned
                                 by digest

phases
  prepare    build the application images bound to the candidate; touches no provider state
  cloud      the cold deploy (inline installation, cluster and platform; refuse at the
             artifact gate), then the cold-start boundary as declared-namespace absence, then
             publish the built images through the publisher identity into the repositories Sol
             created, the read-only whole-target plan, the deploy identity's kubeconfig, node
             evidence, and state capture
  transport  establish and verify the qualification-only transport (INFRA-060 / DEC-039)
  app        Sol's work: runtime secrets, migrate apply, deploy with the published digests,
             the transaction
  destroy    supported teardown against *this attempt's* kubeconfig (or none when the cluster
             is absent, so a stale same-named context is never used), then the independent
             inventory
  verify     the independent inventory only; invokes no teardown

The independent inventory (absence.py, read-only) decides teardown from provider reads alone: every
required disposable class -- EKS cluster, RDS instance, subnet group and snapshots, EC2 instances,
VPCs, NAT gateways, elastic IPs, EBS volumes, load balancers, ECR repositories, IAM roles and
policies, S3 buckets, CloudWatch dashboards and log groups -- is read, shape-checked and attributed
to this target, and only an all-ABSENT result passes. A failed, timed-out, unparseable or
wrong-shaped read, or a class that cannot be attributed, is UNKNOWN, and UNKNOWN never becomes
absence. The durable delegated zone is recorded separately and is not residue.

The transaction is the causal path, not a health check: the scenario's POST returns an id, and the
row only passes when the application's own read-back shows the worker's effect (`charges`: the id in
GET /notifications; `orders`: the status reaching fulfilled or confirmed), which cannot happen
unless the worker consumed the Kafka event and wrote PostgreSQL. AWS_PROFILE and TF_VAR_db_password
must be in the environment. The database connection is not an operator input: the deploy reads the
cluster root's own `postgres_url` output and delivers `<target>-ddl-creds` to the migration Job and
`<target>-dml-creds` to a consuming unit, which the row verifies before the transaction.

Kafka delivery is observed value-free. The deploy declares the delivered credential Secret in its
own output; every expected consumer must project that Secret for the SASL password and the broker
CA, and the Secret's metadata must exist in each consumer namespace. The transaction then supplies
the behavioral evidence that the publisher authenticated and the worker consumed. The observer
never reads the broker users Secret or any Secret data, so the qualification identity needs no
broker credential material.

With TRANSPORT=1 the transaction runs through the qualification transport: `transport` establishes
the `sol:qualifiers` capability and verifies its effective surface, and the harness probes the
production identities' surfaces before and after, none of which may hold `pods/portforward`
(DEC-039). The transport identity is recorded separately from the identities under qualification.

Sol runs the installed release bundle: box SOL_INSTALL at the extracted
sol-<version>-linux-x86_64.tar.gz prefix, and Sol resolves its own assets, its Terraform roots and
its digest-pinned migration runner from that bundle. The harness publishes the application images
and nothing else. Sol's deploy identity has no registry-write authority (ADR 0002, SEC-011), and it
refuses to run a migrate or deploy step without a digest-pinned runner.
USAGE
}

run() {
  local name="$1"; shift
  say "$name"
  if ! timeout "$PHASE_TIMEOUT" "$@" >"$LOG_DIR/$name.log" 2>&1; then
    say "FAILED: $name (last 40 lines; full log $LOG_DIR/$name.log)"
    tail -n 40 "$LOG_DIR/$name.log"
    return 1
  fi
}

# The shared database-CA family owner (#1510). It is a harness executable,
# distinct from the installed candidate's own sol.
SOL_QUALIFICATION_CA="${SOL_QUALIFICATION_CA:-$ROOT/_build/default/internal/tooling/sol_qualification/bin/qualification_database_ca.exe}"

# The database-contract pins and the candidate's specimen declaration. Recorded in
# `prepare` from the immutable install and the candidate-bound workspace; no provider
# state. The specimen is kept whole because the delivery assertion names its consumers
# from it: the candidate declares which workloads consume the database and which Secret
# each reads, so the row does not reconstruct those names (#1492 class).
record_database_contract_pins() {
  mkdir -p "$LOG_DIR"
  local bound="$LOG_DIR/database-contract-binding.json"
  if ! python3 "$ROOT/internal/qualification/database-contract-binding.py" \
      --candidate "$SOL_CANDIDATE" --install "$SOL_INSTALL" --workspace "$WORKSPACE" \
      --target "$TARGET" >"$bound"; then
    say "could not bind the candidate's database contract; the CA family cannot be qualified"
    return 1
  fi
  if ! python3 - "$bound" "$LOG_DIR/database-contract-pins.json" \
      "$LOG_DIR/database-contract-specimen.json" <<'PY'
import json, sys
bound = json.load(open(sys.argv[1]))
s = bound["specimen"]["declaration"]
json.dump({"revision": bound["candidate"]["revision"],
           "bundle_digest": bound["candidate"]["bundle_sha256"],
           "definition_digest": bound["definition"]["digest"],
           "specimen_digest": bound["specimen"]["digest"],
           "requested_target": s["requested_target"],
           "target": s["target"]}, open(sys.argv[2], "w"))
json.dump(bound["specimen"], open(sys.argv[3], "w"))
PY
  then
    say "could not record the candidate's specimen; the delivery assertion cannot name its consumers"
    return 1
  fi
}

# The expected Kubernetes authority the CA observations must match. Recorded from
# the read-only qualifier transport, never from the product's own report.
record_authority_for() {
  local output="$1" err="$2" role="$3" kubeconfig="$4" context="$5"
  local principal cluster endpoint
  if ! principal="$(kubectl --kubeconfig "$kubeconfig" --context "$context" \
      auth whoami -o jsonpath='{.status.userInfo.username}' 2>"$err")"; then
    say "could not read the $role principal; provider diagnostics are not copied into this log"
    return 1
  fi
  if ! cluster="$(kubectl --kubeconfig "$kubeconfig" --context "$context" \
      get namespace kube-system -o jsonpath='{.metadata.uid}' 2>>"$err")"; then
    say "could not read the $role cluster identity; provider diagnostics are not copied into this log"
    return 1
  fi
  if ! endpoint="$(kubectl --kubeconfig "$kubeconfig" --context "$context" \
      config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>>"$err")"; then
    say "could not read the $role endpoint; provider diagnostics are not copied into this log"
    return 1
  fi
  python3 - "$output" "$principal" "$cluster" "$endpoint" <<'PY'
import json, sys
json.dump({"principal": sys.argv[2], "cluster": sys.argv[3], "endpoint": sys.argv[4]},
          open(sys.argv[1], "w"))
PY
}

record_ca_authority() {
  # `transport` records from the qualifier; the app phase overrides CA_* when a
  # TRANSPORT=0 run observes through the deploy identity.
  record_authority_for "$LOG_DIR/ca-authority.json" "$LOG_DIR/ca-authority.err" observation \
    "${CA_KUBECONFIG:-$QUALIFIER_KUBECONFIG}" "${CA_CONTEXT:-$CLUSTER-qualifier}"
}

# The migration Job is submitted by the product as the deploy identity; the CA
# observation uses the read-only qualifier. The receipt must agree with the
# authority that submitted it, which is not the observation authority.
record_ca_submission_authority() {
  record_authority_for "$LOG_DIR/ca-submission-authority.json" \
    "$LOG_DIR/ca-submission-authority.err" submission \
    "$DEPLOY_KUBECONFIG" "$CLUSTER-deploy"
}

# Build the driver request for one phase from inputs the row recorded earlier.
# Nothing here is read from the product's own report.
ca_request() {
  local phase="$1" capture="${2:-}" report="${3:-}" binding="${4:-}"
  python3 - "$ROOT" "$SOL_CANDIDATE" "$SOL_INSTALL" "$WORKSPACE" "$LOG_DIR" \
    "$CA_KUBECONFIG" "$CA_CONTEXT" "$ATTEMPT" "$phase" "$capture" "$report" "$binding" \
    "$QUALIFIER_KUBECONFIG" "$LOG_DIR/ca-submission-authority.json" <<'PY'
import json, os, sys
(root, candidate, install, workspace, log, kubeconfig, context, attempt,
 phase, capture, report, binding, qualifier_kubeconfig, submission_authority) = sys.argv[1:15]
request = {
    "repository": root,
    "candidate": candidate,
    "install": install,
    "workspace": workspace,
    "pins": json.load(open(os.path.join(log, "database-contract-pins.json"))),
    "authority": json.load(open(os.path.join(log, "ca-authority.json"))),
    "kubeconfig": kubeconfig,
    "context": context,
    "identity_scope": "qualifier" if kubeconfig == qualifier_kubeconfig else "deploy",
    "attempt": attempt,
    "assessment": "database-ca",
    "scenario": "aws",
    "evidence": os.path.join(log, "ca-evidence"),
    "phase": phase,
    "capture": capture,
    "report": report,
    "binding": binding,
    "migration_capture": os.path.join(log, "ca-migration-capture.json"),
    "application_capture": os.path.join(log, "ca-application-capture.json"),
}
if os.path.exists(submission_authority):
    request["submission_authority"] = json.load(open(submission_authority))
json.dump(request, open(os.path.join(log, "ca-request-" + phase + ".json"), "w"))
PY
}

# Invoke the shared owner for one phase. A phase's exit status is not evidence:
# the report phase re-reads the recorded captures and verdicts.
ca_qualify() {
  local phase="$1" capture="${2:-}" report="${3:-}" binding="${4:-}" status=0
  if [ ! -x "$SOL_QUALIFICATION_CA" ]; then
    say "the shared database-CA qualifier is not built at $SOL_QUALIFICATION_CA"
    return 1
  fi
  if ! ca_request "$phase" "$capture" "$report" "$binding"; then
    say "could not build the database-CA $phase request"
    return 1
  fi
  # The driver bounds its own child and cleanup; this outer watchdog keeps a
  # hung driver from hanging the phase, and names the cleanup responsibility.
  timeout "$PHASE_TIMEOUT" "$SOL_QUALIFICATION_CA" --phase "$phase" \
    --request "$LOG_DIR/ca-request-$phase.json" >"$LOG_DIR/ca-$phase.log" 2>&1 || status=$?
  if [ "$status" != 0 ]; then
    say "the shared database-CA $phase phase did not pass; see $LOG_DIR/ca-$phase.log"
    if [ "$status" = 124 ]; then
      say "the $phase phase exceeded ${PHASE_TIMEOUT}s; its cleanup is unestablished and remains the operator's responsibility"
    fi
    tail -n 20 "$LOG_DIR/ca-$phase.log"
    return 1
  fi
}

# The whole-target deploy reconciles the durable installation inline (DEC-057 §2), and on an
# account whose installation is not established it offers to set it up through one
# interactive confirmation. The run drives that confirmation through a pty with a single
# 'y'; an account whose installation is already established is deployed to without a
# prompt, and the extra 'y' is left unread. A deploy also verifies immutable --image-ref
# manifests before it applies anything, so the bootstrap deploy names a tag: the ECR
# repositories it is about to create are where phase_app later pushes the digests this run
# pins. Its exit status is returned rather than inspected here, because the deploy is
# expected to stop at the workloads those digests belong to.
bootstrap_deploy() {
  local name="$1"
  say "$name"
  # A profiled target's preflight refuses a mutable tag, so every deploy that moves workloads
  # names the digests published into Sol's repositories. The *cold* deploy has none: it is the
  # run that provisions the target, creates those repositories and then refuses at the artifact
  # gate with "Deployment incomplete" (issue #1413). So an empty argument list is expected here
  # and the phase reads the deploy's refusal, not its exit code.
  local image_ref_args
  image_ref_args="$(app_image_ref_args)"
  local command="cd '$WORKSPACE' && exec '$SOL' deploy '$TARGET' --registry '$ECR_REGISTRY' $image_ref_args"
  if command -v script >/dev/null 2>&1; then
    printf 'y\n' | timeout "$PHASE_TIMEOUT" script -qec "$command" /dev/null \
      >"$LOG_DIR/$name.log" 2>&1
  else
    timeout "$PHASE_TIMEOUT" bash -c "$command" >"$LOG_DIR/$name.log" 2>&1
  fi
}

# The cold deploy's refusal. `sol deploy` provisioned the target, created the repositories its
# release names, and stopped before any workload moved because the immutable image it requires is
# not published yet (#1473). This is the phase's contract on a fresh profiled target: infrastructure
# reconciled, artifacts pending, nothing applied.
pending_artifacts_refused() {
  grep -qF 'Deployment incomplete.' "$LOG_DIR"/cloud-apply*.log 2>/dev/null
}

# The namespaces the target's **selected** units declare, taken from the candidate-bound
# application contract -- the build context candidate-binding.sh materialized from the candidate
# revision -- and never from the working tree or from a fixed pair of names. The boundary
# assertion below is only as good as its selection: a set that omits a unit's namespace, or that
# silently selected nothing, would pass vacuously (#1488 review, #1492).
candidate_unit_dirs() {
  local unit dir
  for unit in $APP_UNITS; do
    for dir in "$APP_BUILD_CONTEXT"/app/*/"$unit"; do
      if [ -f "$dir/Dockerfile" ]; then
        printf '%s\n' "${dir#"$APP_BUILD_CONTEXT"/app/}"
        break
      fi
    done
  done
}

# Fails closed when the selection cannot be shown to cover every selected unit and the
# namespaces this row is configured to exercise.
cold_start_namespaces() {
  local prefix="${APP_NS%-*}" address unit expected=0 found=0 names
  if [ ! -d "$APP_BUILD_CONTEXT" ]; then
    refuse "REFUSING: no candidate-bound build context at $APP_BUILD_CONTEXT, so the namespaces the"
    refuse "target's selected units declare cannot be derived from the candidate's own contract"
    return 1
  fi
  for unit in $APP_UNITS; do expected=$((expected + 1)); done
  names="$(candidate_unit_dirs | while IFS= read -r address; do
    printf '%s-%s\n' "$prefix" "${address%%/*}"
  done | sort -u)"
  found="$(candidate_unit_dirs | grep -c .)"
  if [ "$found" != "$expected" ]; then
    refuse "REFUSING: $found of $expected selected units resolve to a candidate-bound directory, so"
    refuse "the declared namespace set would omit a consumer (APP_UNITS='$APP_UNITS')"
    return 1
  fi
  if [ -z "$names" ]; then
    refuse "REFUSING: the selected units declare no namespace, so the boundary assertion would look"
    refuse "nowhere and pass vacuously"
    return 1
  fi
  for unit in "$APP_NS" "$WORKER_NS"; do
    if ! printf '%s\n' "$names" | grep -qxF "$unit"; then
      refuse "REFUSING: the derived namespace set ($(printf '%s' "$names" | tr '\n' ' ')) does not cover"
      refuse "$unit, which this row is configured to exercise; the assertion would not be looking"
      refuse "where the row claims"
      return 1
    fi
  done
  printf '%s\n' "$names"
}

# The cold-start boundary, established from the cluster rather than inferred from the deploy log.
#
# The claim is "this deploy moved no workload and recorded no release". A namespaced workload or
# release cannot exist without its namespace, so the boundary is established by showing every
# namespace the target's selected units declare to be **positively absent**. Reading it this way
# is what makes the claim observable at this point in the lifecycle: an identity with no grant in
# the namespace is answered Forbidden for a namespaced read (RBAC is evaluated before namespace
# existence), which is exactly what the deploy identity is before it has deployed, so a list of
# Deployments is unreadable here and could never establish the claim (#1488).
#
# The observation runs under the cluster-access identity, and its view is validated before any
# absence is trusted: a namespace that must exist must be readable, and a name that cannot exist
# must answer NotFound rather than Forbidden. A view that answered NotFound because it is
# filtered could otherwise turn an unreadable look-up into a false boundary, and this observation
# gates a decision about a live target -- so it fails closed.
#
# What it establishes: no namespaced workload (Deployment/CronJob/Job/Rollout) and no
# `sol.dev/type=release` ConfigMap can exist in the declared namespaces. It does not establish
# anything about cluster-scoped objects, which the target's roots own and Sol's teardown removes;
# and a namespace that does exist makes the boundary UNKNOWN here rather than passing, because
# what it might contain cannot be read with the identities this row holds.
cold_start_boundary() {
  local names ns out err file="$LOG_DIR/cold-start-namespaces.txt"
  local probe="sol-nonexistent-namespace-probe-$ATTEMPT"
  local present=0 unknown=0
  names="$(cold_start_namespaces)" || return 1
  if ! timeout 60 kubectl --kubeconfig "$ACCESS_KUBECONFIG" get namespace kube-system -o name \
    >/dev/null 2>"$LOG_DIR/cold-start-namespaces-authority.err"; then
    say "UNKNOWN: the cluster-access identity's namespace view could not be established, so"
    say "whether a workload moved cannot be read (see cold-start-namespaces-authority.err)"
    return 1
  fi
  if timeout 60 kubectl --kubeconfig "$ACCESS_KUBECONFIG" get namespace "$probe" -o name \
    >/dev/null 2>"$LOG_DIR/cold-start-namespaces-absent-probe.err"; then
    say "UNKNOWN: the observation identity answered that $probe exists, so its namespace view"
    say "cannot establish absence"
    return 1
  fi
  if ! grep -q 'NotFound' "$LOG_DIR/cold-start-namespaces-absent-probe.err" 2>/dev/null; then
    say "UNKNOWN: a name that cannot exist did not answer NotFound, so the namespace view is"
    say "filtered -- a namespace that does exist would answer the same way, and absence cannot be"
    say "read from it (see cold-start-namespaces-absent-probe.err)"
    return 1
  fi
  {
    printf 'boundary_namespaces: %s\n' "$(printf '%s' "$names" | tr '\n' ' ')"
    printf 'boundary_identity: cluster-access (%s), view validated against kube-system and an absent name\n' \
      "$ACCESS_KUBECONFIG"
  } >"$file"
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    err="$LOG_DIR/cold-start-namespace-$ns.err"
    if out="$(timeout 60 kubectl --kubeconfig "$ACCESS_KUBECONFIG" get namespace "$ns" -o name 2>"$err")"; then
      printf 'cold-start-namespace: %s PRESENT (it may hold a workload or a recorded release)\n' \
        "$ns" >>"$file"
      present=$((present + 1))
    elif grep -q 'NotFound' "$err" 2>/dev/null; then
      printf 'cold-start-namespace: %s ABSENT\n' "$ns" >>"$file"
    else
      printf 'cold-start-namespace: %s UNKNOWN (%s)\n' \
        "$ns" "$(head -n 1 "$err" 2>/dev/null)" >>"$file"
      unknown=$((unknown + 1))
    fi
  done <<EOF
$names
EOF
  if [ "$unknown" != 0 ]; then
    say "$unknown declared namespace(s) could not be read, so whether a workload moved is UNKNOWN"
    say "  (see $file)"
    return 1
  fi
  if [ "$present" != 0 ]; then
    say "the cold deploy created a declared namespace before its immutable artifacts were published:"
    say "  $(grep ' PRESENT' "$file" | sed 's/^cold-start-namespace: //' | tr '\n' ' ')"
    say "whether it holds a workload or a recorded release cannot be established with the"
    say "identities this row holds at this point, so the boundary is UNKNOWN, never a pass"
    return 1
  fi
  say "the cold deploy moved no workload and recorded no release: every declared namespace"
  say "  ($(printf '%s' "$names" | tr '\n' ' ')) is positively absent"
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

# `sol deploy` takes no --var-file: the target names the file its cluster and platform roots
# read, and a target without one would apply those roots with their default variables. The
# run refuses rather than qualify a target that is not the row's.
target_issuer() { sed -n 's/^ *cluster_issuer: *//p' "$TARGET_FILE" 2>/dev/null | head -1; }

# The target declaration is the issuer's authority. An attempt whose label and
# target disagree, or a target that omits the issuer, could silently qualify one
# claim while the evidence says another; fail closed before any build or mutation.
require_target_issuer() {
  local declared
  declared="$(target_issuer)"
  if [ -z "$declared" ]; then
    refuse "REFUSING: $TARGET_FILE does not declare cluster_issuer, so this attempt's issuer claim cannot be established"
    return 1
  fi
  if [ "$declared" != "$CLUSTER_ISSUER" ]; then
    refuse "REFUSING: the target declares cluster_issuer=$declared but this attempt is labelled $CLUSTER_ISSUER"
    return 1
  fi
}

require_target_terraform_var_file() {
  if grep -qE '^[[:space:]]*terraform_var_file:' "$TARGET_FILE" 2>/dev/null; then
    return 0
  fi
  say "REFUSING: $TARGET_FILE declares no terraform_var_file, and sol deploy takes no --var-file,"
  say "so the cluster and platform roots would be applied with their default variables."
  return 1
}


k8s_name() { printf '%s' "$1" | tr '_' '-'; }
# Sol's cluster root owns `pluto/<unit>` — the repositories the target's release names — and the
# run publishes into exactly those, after the `cloud` phase's deploy has created them (issue
# #1413). The run never creates a repository itself: the harness owning a parallel `sol-runs/...`
# registry let a cold start pass without exercising the product's own cold-start path, which is
# what `sol deploy` now provides (a profiled cold target provisions, then reports its pending
# artifacts, then resumes once the digests exist). Pushing into a repository Sol created is the
# operator's legitimate act; creating one is not.
sol_repo() { printf '%s/pluto/%s' "$ECR_REGISTRY" "$(k8s_name "$1")"; }
sol_image_ref() { printf '%s:%s' "$(sol_repo "$1")" "$APP_TAG"; }

# Sol's own repositories, as its target inventory sees them: ABSENT before `cloud` creates them,
# PRESENT after, ABSENT again after teardown.
ecr_record_sol_repositories() {
  local label="$1" unit name state
  local out="$LOG_DIR/ecr-sol-repositories-$label.txt"
  : >"$out"
  for unit in $APP_UNITS; do
    name="pluto/$(k8s_name "$unit")"
    if aws ecr describe-repositories --repository-names "$name" >/dev/null 2>&1; then
      state=PRESENT
    else
      state=ABSENT
    fi
    printf 'ecr-sol-repository[%s]: %s %s\n' "$label" "$name" "$state" >>"$out"
  done
  say "recorded Sol's repositories ($label) in $out"
}

unit_dir() {
  local unit="$1" dir
  for dir in "$WORKSPACE"/app/*/"$unit"; do
    if [ -f "$dir/Dockerfile" ]; then
      printf '%s' "${dir#"$WORKSPACE"/}"
      return 0
    fi
  done
  return 1
}

image_digest() {
  local ref="$1" digest
  digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$ref" 2>/dev/null || true)"
  case "$digest" in
    *"@sha256:"*) printf '%s' "$digest" ;;
    *)
      say "docker inspect reported no immutable digest for $ref"
      return 1
      ;;
  esac
}

target_state_bucket() {
  sed -n 's/^ *state_bucket: *//p' "$TARGET_FILE" | head -1
}

capture_state() {
  aws s3 cp "s3://$(target_state_bucket)/$STATE_KEY" - 2>"$LOG_DIR/state/copy.log" | \
    python3 "$ROOT/internal/qualification/state-evidence.py" >"$LOG_DIR/state/cloud.tfstate" || true
}

capture_kube_evidence() {
  kubectl get nodes -o wide >"$LOG_DIR/k8s-nodes.txt" 2>&1 || true
  kubectl get pods --all-namespaces -o wide >"$LOG_DIR/k8s-pods.txt" 2>&1 || true
  kubectl get events --all-namespaces --sort-by=.lastTimestamp >"$LOG_DIR/k8s-events.txt" 2>&1 || true
  kubectl get certificates --all-namespaces >"$LOG_DIR/k8s-certificates.txt" 2>&1 || true
  kubectl get applications -n argocd >"$LOG_DIR/k8s-applications.txt" 2>&1 || true
  kubectl -n "$APP_NS" logs -l app.kubernetes.io/component=svc --tail=200 --all-containers=true \
    >"$LOG_DIR/app-svc.log" 2>&1 || true
  kubectl -n "$WORKER_NS" logs -l app.kubernetes.io/component=worker --tail=200 --all-containers=true \
    >"$LOG_DIR/app-worker.log" 2>&1 || true
}

# The independent inventory is the teardown verdict's only owner (absence.py).
# It reads every required disposable class, validates each response's JSON
# shape, and attributes what it returns to this target by the target's cluster
# tag, cluster-name prefix or declared registry path. A failed, timed-out,
# unparseable or wrong-shaped read is UNKNOWN, and UNKNOWN never becomes
# absence, so an unreadable provider cannot be read as a clean teardown.
# Durable prerequisites (the delegated zone) are observed separately and are
# excluded. Nothing here calls terraform or helm, and absence is never inferred
# from Sol's exit code or Terraform state.
aws_observe() {
  python3 "$ABSENCE" "$@" \
    --prior "$LOG_DIR/aws-pre-teardown-identities.json" \
    --cluster "$CLUSTER" --region "$AWS_REGION" --account "$ACCOUNT" \
    --registry-prefix "$WORKSPACE_NAME" --base-domain "$BASE_DOMAIN" \
    --retention "$RETENTION" --attempt "$ATTEMPT" --target "$TARGET" \
    --state-key "$STATE_KEY" --candidate "$SOL_CANDIDATE"
}

capture_independent_identities() {
  if ! aws_observe capture "$@" >"$LOG_DIR/aws-identity-capture.stdout" 2>"$LOG_DIR/aws-identity-capture.err"; then
    say "independent identity capture failed; refusing teardown before destructive operations"
    cat "$LOG_DIR/aws-identity-capture.err" >&2
    return 1
  fi
}

aws_inventory() {
  say "independent inventory (read-only): every required disposable class"
  if ! aws_observe collect --dir "$LOG_DIR" \
    >"$LOG_DIR/aws-inventory.stdout" 2>"$LOG_DIR/aws-inventory.err"; then
    say "the independent inventory does not read ABSENT; teardown is not complete"
    say "  evidence: $LOG_DIR/aws-inventory.txt and $LOG_DIR/aws-inventory-verdict.json"
    return 1
  fi
  say "the independent inventory reads ABSENT for every required disposable class"
}



DEPLOY_KUBECONFIG="$LOG_DIR/kubeconfig-deploy.yaml"
ACCESS_KUBECONFIG="$LOG_DIR/kubeconfig-access.yaml"
OPERATOR_KUBECONFIG="$LOG_DIR/kubeconfig-operator.yaml"
QUALIFIER_KUBECONFIG="$LOG_DIR/kubeconfig-qualifier.yaml"

verify_kubeconfig_endpoint() {
  local kubeconfig="$1" endpoint configured
  endpoint="$(aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" \
    --query 'cluster.endpoint' --output text 2>/dev/null | tr -d '\r')"
  [ -n "$endpoint" ] || return 0
  configured="$(kubectl --kubeconfig "$kubeconfig" config view --minify \
    --output 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)"
  if [ "$configured" != "$endpoint" ]; then
    say "the credential at $kubeconfig addresses ${configured:-<nothing>}, not this cluster's current"
    say "endpoint $endpoint: a replaced cluster of the same name is not this run's target"
    return 1
  fi
  return 0
}

ensure_contexts() {
  say "kubeconfig"
  KUBECONFIG="$DEPLOY_KUBECONFIG" aws eks update-kubeconfig --region "$AWS_REGION" \
    --name "$CLUSTER" --alias "$CLUSTER-deploy" --role-arn "$DEPLOY_ROLE_ARN" >/dev/null || return 1
  KUBECONFIG="$ACCESS_KUBECONFIG" aws eks update-kubeconfig --region "$AWS_REGION" \
    --name "$CLUSTER" --alias "$CLUSTER-access" --role-arn "$CLUSTER_ACCESS_ROLE_ARN" >/dev/null || return 1
  if [ -n "$OPERATOR_ROLE_ARN" ]; then
    KUBECONFIG="$OPERATOR_KUBECONFIG" aws eks update-kubeconfig --region "$AWS_REGION" \
      --name "$CLUSTER" --alias "$CLUSTER-operator" --role-arn "$OPERATOR_ROLE_ARN" >/dev/null || return 1
  fi
  verify_kubeconfig_endpoint "$DEPLOY_KUBECONFIG" || return 1
  verify_kubeconfig_endpoint "$ACCESS_KUBECONFIG" || return 1
  if [ -n "$OPERATOR_ROLE_ARN" ]; then verify_kubeconfig_endpoint "$OPERATOR_KUBECONFIG" || return 1; fi
  export KUBECONFIG="$DEPLOY_KUBECONFIG"
}

verify_identity_boundary() {
  say "identity-boundary"
  if ! kubectl --kubeconfig "$DEPLOY_KUBECONFIG" auth can-i create rolebindings \
      --namespace "$APP_NS" >/dev/null 2>&1; then
    say "the deploy identity cannot create rolebindings, so application operations cannot bootstrap"
    return 1
  fi
  if kubectl --kubeconfig "$ACCESS_KUBECONFIG" auth can-i create rolebindings \
      --namespace "$APP_NS" >/dev/null 2>&1; then
    say "the cluster-access identity can create rolebindings: the two identities are not separated,"
    say "and the row would no longer be testing the separation the platform is built on"
    return 1
  fi
  say "identity boundary holds: deploy creates rolebindings, cluster-access does not"
}

probe_production_separation() {
  local phase="$1" label kc verdict
  : >"$LOG_DIR/transport-separation-$phase.txt"
  for label in cluster-access deploy operator; do
    case "$label" in
      cluster-access) kc="$ACCESS_KUBECONFIG" ;;
      deploy) kc="$DEPLOY_KUBECONFIG" ;;
      operator) kc="$OPERATOR_KUBECONFIG" ;;
    esac
    if [ ! -f "$kc" ]; then
      printf '%s: no kubeconfig for this run, so it was not probed\n' "$label" \
        >>"$LOG_DIR/transport-separation-$phase.txt"
      continue
    fi
    verdict="$(kubectl --kubeconfig "$kc" auth can-i create pods --subresource=portforward -n "$APP_NS" 2>/dev/null || true)"
    printf '%s create pods/portforward -n %s: %s\n' "$label" "$APP_NS" "${verdict:-<no answer>}" \
      >>"$LOG_DIR/transport-separation-$phase.txt"
    if [ "$verdict" != no ]; then
      say "the $label identity answered '${verdict:-no answer}' for pods/portforward in $APP_NS;"
      say "the qualification transport is not separated from the identities under qualification"
      return 1
    fi
  done
  printf 'provisioner: holds no EKS access entry, so it cannot open a transport\n' \
    >>"$LOG_DIR/transport-separation-$phase.txt"
  return 0
}

probe_qualifier_identity() {
  local whoami
  if ! whoami="$(kubectl --kubeconfig "$QUALIFIER_KUBECONFIG" --context "$CLUSTER-qualifier" \
      auth whoami -o json 2>"$LOG_DIR/transport-whoami.err")"; then
    say "the qualifier context could not answer auth whoami: $(cat "$LOG_DIR/transport-whoami.err" 2>/dev/null)"
    return 1
  fi
  printf '%s\n' "$whoami" >"$LOG_DIR/transport-whoami.json"
  case "$whoami" in
    *"assumed-role/$QUALIFIER_ROLE/"*) : ;;
    *)
      say "the transport context does not authenticate as the qualifier $QUALIFIER_ROLE;"
      say "kubectl auth whoami said: $whoami"
      return 1
      ;;
  esac
  say "  qualifier: $(printf '%s' "$whoami" | tr -d '\n')"
}

phase_transport() {
  if [ -z "$QUALIFIER_ROLE" ]; then
    say "QUALIFIER_ROLE is not set, so the qualification transport principal cannot be named"
    return 1
  fi
  ensure_contexts || return 1
  say "transport-separation-pre"
  probe_production_separation pre || return 1
  # The CA family observes the migration Job where the deploy declared it. That
  # namespace is platform-provided (it may be the database's own namespace), so it
  # is read from the deploy's `sol-database-identity:` line rather than derived.
  local -a observe_namespaces=("$APP_NS" "$WORKER_NS")
  local database_ns
  database_ns="$(app_database_field namespace)"
  if [ -n "$database_ns" ]; then
    observe_namespaces+=("$database_ns")
  fi
  say "transport-establish"
  # The refusal text is evidence, not console output: establish.sh keeps it here
  # and prints only its class, so the tail below cannot carry a server message.
  if ! KUBECONFIG="$QUALIFIER_KUBECONFIG" SOL_TRANSPORT_REFUSAL_EVIDENCE="$LOG_DIR/transport-refusal.txt" \
      timeout "$PHASE_TIMEOUT" \
      "$ROOT/internal/qualification/transport/establish.sh" \
      "$CLUSTER" "$QUALIFIER_ROLE" "$AWS_REGION" "${observe_namespaces[@]}" \
      >"$LOG_DIR/transport-establish.log" 2>&1; then
    say "FAILED: transport-establish (last 40 lines; full log $LOG_DIR/transport-establish.log)"
    tail -n 40 "$LOG_DIR/transport-establish.log"
    return 1
  fi
  say "transport-verify"
  probe_qualifier_identity || return 1
  # The CA observations must match an authority established independently of the
  # product's report; record it from the read-only transport now.
  record_ca_authority || return 1
  say "transport-separation-post"
  probe_production_separation post || return 1
  local pf
  pf="$(kubectl --kubeconfig "$QUALIFIER_KUBECONFIG" --context "$CLUSTER-qualifier" \
    auth can-i create pods --subresource=portforward -n "$APP_NS" 2>/dev/null || true)"
  printf 'qualifier create pods/portforward -n %s: %s\n' "$APP_NS" "${pf:-<no answer>}" \
    >>"$LOG_DIR/transport-separation-post.txt"
  if [ "$pf" != yes ]; then
    say "the qualifier cannot create pods/portforward in $APP_NS, so the transport is not established"
    return 1
  fi
  say "  the qualification transport is established; the production identities' surfaces are"
  say "  recorded before and after, and none of them holds pods/portforward"
}

# The credential path **Terraform** will use, refreshed now.
#
# `aws sts get-caller-identity` is not this check: it answers from cached role credentials and
# keeps succeeding long after the SSO session that mints them has expired. That is the shape that
# left a substrate live twice -- terraform could not refresh the SSO token, the destroy died at
# `terraform init` with `No valid credential sources found`, and the only signal was an inventory
# somebody had to read (sol-fab/sol#1443).
#
# `aws configure export-credentials` resolves credentials through the profile's own path, so it
# fails exactly when the plan/apply/destroy would, *before* anything is created or destroyed.
require_credentials() {
  local detail
  if detail="$(aws configure export-credentials --profile "$AWS_PROFILE" --format env 2>&1 >/dev/null)"; then
    return 0
  fi
  say "the AWS credentials for profile '$AWS_PROFILE' cannot be refreshed:"
  printf '%s\n' "$detail" | sed 's/^/  /' >&2
  say "terraform uses the same credential path, so no plan, apply or destroy can run; nothing was attempted."
  say "Re-authenticate (for an SSO profile: aws sso login --profile $AWS_PROFILE), then re-run."
  return 1
}

phase_cloud() {
  require_credentials || return 1
  require_target_terraform_var_file || return 1
  require_target_issuer || return 1
  capture_independent_identities --initial || return 1
  # A fixed repository name is not made fresh by a fresh target name, so record it on the way in.
  ecr_record_sol_repositories before
  # The cold deploy. `sol deploy` establishes the durable installation inline, applies the
  # environment's cluster and platform roots (which create `pluto/<unit>`), and then -- because
  # this run has published no images yet -- refuses at the immutable-artifact gate with
  # "Deployment incomplete" (#1473). That refusal is this phase's contract on a fresh profiled
  # target: infrastructure reconciled, no workload moved, no release recorded. The deploy's exit
  # code is not what decides the phase.
  local deploy_rc=0
  bootstrap_deploy cloud-apply || deploy_rc=$?
  if cloud_mutated; then CLOUD_APPLIED=1; fi

  capture_independent_identities || return 1
  if ! environment_reconciled; then
    say "the bootstrap deploy did not reconcile the environment $TARGET (full log $LOG_DIR/cloud-apply.log)"
    return 1
  fi
  # The environment stage ran; the artifact gate is the next step the same deploy checks. Its
  # refusal is the cold-start claim -- provisioned, nothing applied.
  if ! pending_artifacts_refused; then
    say "the cold deploy reconciled the environment but did not refuse at the artifact gate"
    say "(expected 'Deployment incomplete.' in $LOG_DIR/cloud-apply*.log)"
    return 1
  fi
  # Infrastructure reconciled is not the same as workloads moved. Before this run publishes the
  # immutable artifacts, establish from the cluster that the cold deploy moved no workload and
  # recorded no release -- the distinction #1473 makes and a successful cold-start row must show,
  # over the complete declared namespace set derived from the candidate-bound contract.
  ensure_contexts || return 1
  cold_start_boundary || return 1
  # Publish the images `prepare` built into the repositories the deploy just created, then preview
  # the whole target with the digests those pushes resolved to. `sol plan` is the read-only
  # whole-target preview; `sol deploy` is the only command that reconciles the substrate.
  app_push_images || return 1
  say "cloud-plan"
  local plan_image_refs plan_rc=0
  plan_image_refs="$(app_image_ref_args)"
  if [ -z "$plan_image_refs" ]; then
    say "the run published no image digests, so the whole-target preview has nothing to name"
    return 1
  fi
  if ! timeout "$PHASE_TIMEOUT" bash -c "cd '$WORKSPACE' && exec '$SOL' plan '$TARGET' --var-file '$TFVARS' $plan_image_refs" \
    >"$LOG_DIR/cloud-plan.log" 2>&1; then
    plan_rc=1
  fi
  if [ "$plan_rc" != 0 ]; then
    say "FAILED: cloud-plan (last 40 lines; full log $LOG_DIR/cloud-plan.log)"
    tail -n 40 "$LOG_DIR/cloud-plan.log"
    return 1
  fi
  run nodes kubectl --kubeconfig "$ACCESS_KUBECONFIG" get nodes -o wide || return 1
  capture_kube_evidence
  capture_state
  # Recorded, not asserted: whether the apply created them is Sol's business, and the reading
  # that matters is the one after teardown (below), which must be ABSENT.
  ecr_record_sol_repositories after
  say "the substrate and platform install completed; evidence in $LOG_DIR"
}


# `prepare` builds the run's images and nothing else: a build touches no provider state, so the
# `cloud` phase still sees a fresh target. The images stay in the local daemon; `cloud` pushes
# them into the repositories Sol's deploy creates.
app_build_images() {
  local unit dir ref
  : >"$LOG_DIR/app-built-tags.txt"
  local context="$APP_BUILD_CONTEXT" pins
  if ! pins="$(sol_candidate_bind_context "$WORKSPACE" "$SOL_REVISION" "$context")"; then
    say "refusing to build the application: it cannot be bound to candidate $SOL_REVISION"
    return 1
  fi
  sol_candidate_record_binding "$LOG_DIR" "$SOL_REVISION" "$WORKSPACE" "$context" "$pins" "$(git -C "$WORKSPACE" rev-parse HEAD)"
  # Record the database-contract pins the app phase re-verifies. This reads the
  # immutable install and the candidate-bound workspace only.
  record_database_contract_pins || return 1
  say "app images build from candidate $SOL_REVISION ($WORKSPACE at that revision, framework pinned to it)"
  for unit in $APP_UNITS; do
    if ! dir="$(unit_dir "$unit")"; then
      say "no app/*/$unit directory with a Dockerfile in $WORKSPACE"
      return 1
    fi
    if [ ! -f "$context/$dir/Dockerfile" ]; then
      say "candidate $SOL_REVISION has no app/*/$unit directory with a Dockerfile"
      return 1
    fi
    ref="$(sol_image_ref "$unit")"
    run "app-build-$unit" docker build -f "$context/$dir/Dockerfile" -t "$ref" "$context" || return 1
    printf '%s=%s\n' "$unit" "$ref" >>"$LOG_DIR/app-built-tags.txt"
    say "  $unit built as $ref"
  done
}

# The publisher's own assumed-role session (SEC-011, ADR 0002). Publication is a separate
# authority from substrate mutation and from deployment, so the operator's ambient
# AdministratorAccess is never what publishes: the run demonstrates that the scoped publisher
# identity is sufficient, and it fails closed rather than fall back when no publisher is named
# or its session cannot be assumed.
#
# The assumed session lives only in this shell (`PUBLISHER_ACCESS_KEY_ID` and its two
# companions). It is never exported, never written into the evidence bundle and never
# recorded; `publisher-identity.txt` records only the role and the identity the session
# actually answered with.
publisher_session() {
  local json
  if [ -z "$PUBLISHER_ROLE_ARN" ]; then
    say "REFUSING: no publisher identity is named (PUBLISHER_ROLE_ARN). Publication is the"
    say "publisher's own scoped authority, so this run does not publish with the operator's"
    say "ambient credentials (SEC-011, ADR 0002); nothing was published."
    return 1
  fi
  if ! json="$(aws sts assume-role \
      --role-arn "$PUBLISHER_ROLE_ARN" \
      --role-session-name "sol-qualification-publisher" \
      --duration-seconds 3600 \
      --output json 2>"$LOG_DIR/publisher-assume.err")"; then
    say "could not assume the publisher identity $PUBLISHER_ROLE_ARN, so nothing is published"
    say "  (see $LOG_DIR/publisher-assume.err)"
    return 1
  fi
  PUBLISHER_ACCESS_KEY_ID="$(printf '%s' "$json" | jq -r '.Credentials.AccessKeyId // empty')"
  PUBLISHER_SECRET_ACCESS_KEY="$(printf '%s' "$json" | jq -r '.Credentials.SecretAccessKey // empty')"
  PUBLISHER_SESSION_TOKEN="$(printf '%s' "$json" | jq -r '.Credentials.SessionToken // empty')"
  if [ -z "$PUBLISHER_ACCESS_KEY_ID" ] \
    || [ -z "$PUBLISHER_SECRET_ACCESS_KEY" ] \
    || [ -z "$PUBLISHER_SESSION_TOKEN" ]; then
    say "sts:AssumeRole for $PUBLISHER_ROLE_ARN returned no usable session, so nothing is published"
    return 1
  fi
  return 0
}

publisher_clear_session() {
  unset PUBLISHER_ACCESS_KEY_ID PUBLISHER_SECRET_ACCESS_KEY PUBLISHER_SESSION_TOKEN
}

# Run a command as the publisher session. `-u AWS_PROFILE` is what makes it the publisher and
# not whatever the operator's profile holds: the assumed environment credentials then resolve
# through the CLI's own chain, ahead of any profile.
publisher_run() {
  local name="$1"
  shift
  run "$name" env -u AWS_PROFILE \
    "AWS_ACCESS_KEY_ID=$PUBLISHER_ACCESS_KEY_ID" \
    "AWS_SECRET_ACCESS_KEY=$PUBLISHER_SECRET_ACCESS_KEY" \
    "AWS_SESSION_TOKEN=$PUBLISHER_SESSION_TOKEN" \
    "$@"
}

# What the publishing session actually authenticates as, read back rather than assumed: the
# evidence has to show the publisher principal published, not the operator's. A session that
# answers as anything else stops the phase before a push.
publisher_record_identity() {
  local arn
  if ! arn="$(env -u AWS_PROFILE \
      "AWS_ACCESS_KEY_ID=$PUBLISHER_ACCESS_KEY_ID" \
      "AWS_SECRET_ACCESS_KEY=$PUBLISHER_SECRET_ACCESS_KEY" \
      "AWS_SESSION_TOKEN=$PUBLISHER_SESSION_TOKEN" \
      aws sts get-caller-identity --query Arn --output text 2>"$LOG_DIR/publisher-identity.err")" \
    || [ -z "$arn" ]; then
    say "the publisher session could not answer sts get-caller-identity, so nothing is published"
    say "  (see $LOG_DIR/publisher-identity.err)"
    return 1
  fi
  case "$arn" in
    *"assumed-role/"*"/sol-qualification-publisher") : ;;
    *)
      say "the publishing session answers as $arn, which is not the publisher identity"
      say "$PUBLISHER_ROLE_ARN on its own session; nothing is published"
      return 1
      ;;
  esac
  {
    printf 'publisher_role_arn: %s\n' "$PUBLISHER_ROLE_ARN"
    printf 'publisher_session_identity: %s\n' "$arn"
    printf 'publisher_session_name: sol-qualification-publisher\n'
    printf 'publisher_session_values: never recorded\n'
  } >"$LOG_DIR/publisher-identity.txt"
  say "publishing as $arn"
}

# Publish the built images into the repositories Sol's deploy created, and record the immutable
# digest each push resolved to; those digests are what every later deploy names.
app_push_images() {
  local unit ref digest
  : >"$LOG_DIR/app-image-refs.txt"
  rm -f "$LOG_DIR/publisher-identity.txt"
  if [ ! -s "$LOG_DIR/app-built-tags.txt" ]; then
    say "no built images to publish for $TARGET; run live-qual.sh prepare first"
    return 0
  fi
  publisher_session || return 1
  publisher_record_identity || { publisher_clear_session; return 1; }
  publisher_run ecr-login bash -c \
    "aws ecr get-login-password --region '$AWS_REGION' | docker login --username AWS --password-stdin '$ECR_REGISTRY'" \
    || { publisher_clear_session; return 1; }
  while IFS= read -r line; do
    unit="${line%%=*}"
    ref="${line#*=}"
    [ -n "$unit" ] || continue
    [ -n "$ref" ] || continue
    publisher_run "app-push-$unit" docker push "$ref" || { publisher_clear_session; return 1; }
    if ! digest="$(image_digest "$ref")"; then publisher_clear_session; return 1; fi
    printf '%s=%s\n' "$unit" "$digest" >>"$LOG_DIR/app-image-refs.txt"
    say "  $unit -> $digest"
  done <"$LOG_DIR/app-built-tags.txt"
  publisher_clear_session
}

# The digests this run pins, as `sol deploy --image-ref` arguments. A profiled target's preflight
# refuses a mutable tag, and on a cold target the digests cannot exist before the deploy creates
# the repositories; `cloud` publishes them once the environment is reconciled, and every later
# deploy names them (the cold-target ordering, issue #1413).
app_image_ref_args() {
  local ref args="" file="$LOG_DIR/app-image-refs.txt"
  # A cold deploy has no published digest yet, so the file legitimately does not exist and the
  # argument list is empty; testing for it keeps an intended empty result from printing a shell
  # error into the run log and reading like a failure.
  [ -f "$file" ] || {
    printf '%s' ""
    return 0
  }
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    args="$args --image-ref $(printf '%q' "$ref")"
  done <"$file"
  printf '%s' "$args"
}

# `app` reuses the digests `cloud` published into Sol's repositories; it never publishes its own.
app_require_published_images() {
  if [ -s "$LOG_DIR/app-image-refs.txt" ]; then
    say "reusing the digests the cloud phase published into Sol's repositories"
    return 0
  fi
  say "no published image digests for $TARGET: run live-qual.sh cloud first, which provisions the"
  say "target's repositories and publishes the images built by live-qual.sh prepare"
  return 1
}

# `prepare` runs before `cloud`: it builds the application images bound to the candidate and
# touches no provider state, so `cloud` still sees a fresh specimen.
phase_prepare() {
  require_target_terraform_var_file || return 1
  require_target_issuer || return 1
  app_build_images || return 1
  say "the run images are built; the cloud phase publishes them into the repositories Sol creates"
}


# 2b moved migration verification to the post-setup gates, so on a fresh target the deploy
# reaches the migration gate before the required-secret check. It is the first refusal a
# fresh profiled target produces, and the harness models it rather than assuming the
# pre-2b order.
app_migration_gate_failure() {
  grep -qF 'the required migration set is not applied' "$1" 2>/dev/null
}

app_unit_addresses() {
  local unit dir
  for unit in $APP_UNITS; do
    if dir="$(unit_dir "$unit")"; then
      printf '%s\n' "${dir#app/}"
    fi
  done | sort -u
}


app_class_credential_name() { printf '%s' "$TARGET" | tr '[:upper:]/' '[:lower:]-'; }

# The deploy declares the delivered Kafka credential's Secret name in its own
# output; the row reads that declaration rather than reproducing the naming rule.
app_kafka_credential_name() {
  grep -h 'Kafka: delivered the managed credential to ' "$LOG_DIR"/app-deploy.log 2>/dev/null \
    | tail -1 | sed -n 's/.*credential to \([^ ]*\) in .*/\1/p'
}

# 2b: the migration Job reads <target>-ddl-creds and a consuming unit reads
# <target>-dml-creds, both written by the deploy's database setup step. This asserts the
# delivered form exists and that the consumer did not also receive an operator's master
# copy — the "value nothing reads" failure this arc removes.
app_namespaces() {
  local prefix="${APP_NS%-*}" address
  for address in $(app_unit_addresses); do
    printf '%s-%s\n' "$prefix" "${address%%/*}"
  done | sort -u
}

# **Read where the deploy says it wrote** (sol-database-identity: ...), rather than reproducing
# the naming rule here. The row asserts Sol's decision, not its own copy of it (#1424). The
# field names are the interface; the deploy's line is a stable, documented output, and the
# product test `database identity report is the interface the rows read` fails if they drift.
app_database_declaration() {
  local log
  # The app phase reads the final deploy's declaration; the transport, established
  # after the first deploy, reads the gate deploy's. Prefer the final deploy when
  # both exist, and never reproduce the namespace naming rule here.
  for log in "$LOG_DIR"/app-deploy.log "$LOG_DIR"/app-deploy-gate.log; do
    [ -f "$log" ] || continue
    if grep -q 'sol-database-identity:' "$log"; then
      grep -h 'sol-database-identity:' "$log" | tail -1
      return 0
    fi
  done
}

app_database_field() {
  app_database_declaration | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1
}

app_verify_kafka_delivery() {
  local state="$LOG_DIR/state/cloud.tfstate" public unit credential
  local consumers=() behavioral=()
  local transaction="$LOG_DIR/app-transaction.txt"
  if [ "$TRANSPORT" = 1 ]; then transaction="$LOG_DIR/transport-transaction.txt"; fi
  # Independent requirements for this row's selected reference applications.
  # Do not derive them from observed env refs: a missing projection must fail.
  #
  # The unit-to-namespace map below is still harness-owned and NOT candidate-derived:
  # the candidate's specimen declares database consumers, not the Kafka resource
  # identity, so there is nothing in it to match these units against. This is a known
  # gap, not an intentional design; it is tracked separately from the database
  # delivery assertion.
  for unit in $APP_UNITS; do
    case "$unit" in
      charge_svc | orders_svc) consumers+=(--consumer "$APP_NS/$(k8s_name "$unit")") ;;
      notify_worker | fulfilment_worker) consumers+=(--consumer "$WORKER_NS/$(k8s_name "$unit")") ;;
      checkout_svc) ;; # This scenario's checkout is not a Kafka consumer.
      *) say "no Kafka qualification requirement defined for selected unit $unit"; return 1 ;;
    esac
  done
  # The transaction is the behavioral half: it publishes through the service and
  # consumes through the worker, so those two prove authentication and use.
  for unit in $APP_UNITS; do
    case "$unit" in
      charge_svc) behavioral+=(--behavioral-consumer "$APP_NS/$(k8s_name "$unit")") ;;
      notify_worker) behavioral+=(--behavioral-consumer "$WORKER_NS/$(k8s_name "$unit")") ;;
    esac
  done
  if [ "${#behavioral[@]}" = 0 ]; then
    say "the selected units do not include the transaction's Kafka publisher and consumer"
    return 1
  fi
  credential="$(app_kafka_credential_name)"
  if [ -z "$credential" ]; then
    say "the deploy declared no delivered Kafka credential; the projection cannot be read"
    return 1
  fi
  public="$(jq -ce '.outputs.kafka_authority.value | select(type == "object")' "$state")" || return 1
  # The projection and Secret metadata are observed without reading credential values:
  # Deployments through the namespace-scoped qualification transport, and the Secret's
  # name through the deploy identity that wrote it. Credential data is never parsed.
  printf '%s' "$public" | python3 "$ROOT/internal/qualification/kafka-delivery.py" \
    --provider aws --cluster "$CLUSTER" --region "$AWS_REGION" --account "$ACCOUNT" \
    --kubeconfig "$CA_KUBECONFIG" \
    --secret-kubeconfig "$DEPLOY_KUBECONFIG" \
    --credential-secret "$credential" \
    --transaction "$transaction" \
    "${behavioral[@]}" \
    "${consumers[@]}" \
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
app_verify_database_delivery() {
  local declared_ns ddl_name specimen consumers delivery
  local namespace workload cred_ns cred_name containers container ref found
  declared_ns="$(app_database_field namespace)"
  ddl_name="$(app_database_field ddl-creds)"
  if [ -z "$declared_ns" ] || [ -z "$ddl_name" ]; then
    say "the deploy declared no database identity, so where it wrote is not known; the assertion cannot read a location it cannot name"
    return 1
  fi
  # Reporting is not verification: read the Secret at the declared location.
  if ! kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get secret "$ddl_name" -n "$declared_ns" \
    >/dev/null 2>&1; then
    say "the deploy declared its migration Job's $ddl_name in $declared_ns, and it is absent there"
    return 1
  fi
  specimen="$LOG_DIR/database-contract-specimen.json"
  if [ ! -s "$specimen" ]; then
    say "the candidate's specimen is not recorded, so the delivery assertion cannot name its consumers"
    return 1
  fi
  if ! consumers="$(jq -r '.declaration.workloads[]
      | select(.database != null)
      | [.namespace, .name, (.credential.namespace // ""), (.credential.name // ""),
         ((.consuming_containers // []) | join(","))] | @tsv' "$specimen")"; then
    say "the candidate's specimen could not be read; the consumer set is unknown"
    return 1
  fi
  if [ -z "$consumers" ]; then
    say "the candidate's specimen declares no database consumer, so the delivery assertion has no subject"
    return 1
  fi
  # The migration Job's address is the deploy's own declaration; the consumers are the
  # candidate's. Both are read, neither is reconstructed.
  delivery="$ddl_name@$declared_ns (migration Job, as the deploy declared it)"
  while IFS=$'\t' read -r namespace workload cred_ns cred_name containers; do
    [ -n "$namespace" ] || continue
    if [ -z "$cred_name" ] || [ -z "$cred_ns" ]; then
      say "the candidate declared $namespace/$workload as a database consumer without a credential address"
      return 1
    fi
    if ! kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get secret "$cred_name" -n "$cred_ns" \
      >/dev/null 2>&1; then
      say "the candidate declared $namespace/$workload as a database consumer, and $cred_name is absent from $cred_ns"
      return 1
    fi
    found=""
    for container in ${containers//,/ }; do
      [ -n "$container" ] || continue
      ref="$(kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get deployment "$workload" -n "$namespace" -o json 2>/dev/null \
        | jq -r --arg c "$container" '
            [.spec.template.spec.containers[]? | select(.name == $c)
             | .env[]? | select(.name == "POSTGRES_URL")
             | .valueFrom.secretKeyRef.name // empty] | first // ""' 2>/dev/null)"
      if [ "$ref" != "$cred_name" ]; then
        say "$namespace/$workload container $container reads POSTGRES_URL from '${ref:-nothing}', not the declared class Secret $cred_name"
        return 1
      fi
      found=1
    done
    if [ -z "$found" ]; then
      say "the candidate declared no consuming container for $namespace/$workload, so where it reads POSTGRES_URL is not established"
      return 1
    fi
    delivery="$delivery, $cred_name@$cred_ns (unit consumer $workload)"
  done <<<"$consumers"
  # The database CA family is owned by the shared candidate-bound observer. The
  # migration phase already ran at the row's migration step; the application
  # phase ran after the final deploy. This report re-reads their durable evidence
  # and refuses an incomplete or non-passing family.
  ca_qualify report "" "$LOG_DIR/ca-report.json" || return 1
  {
    printf 'database_delivery: %s\n' "$delivery"
    printf 'database_delivery_assertion: every declared consumer reads POSTGRES_URL from its class Secret\n'
  } >>"$LOG_DIR/prerequisites.txt"
  say "the deploy delivered the database; every declared consumer reads POSTGRES_URL from its class Secret"
}

# A diagnostic continuation of a spent attempt. The evidence store records one CA
# verdict per instance per attempt, so a spent attempt cannot be re-observed; the
# new attempt carries only the provisioning inputs and is marked non-promotable.
phase_resume() {
  local from="${RESUME_FROM:-}" field value
  if [ -z "$from" ]; then
    say "resume requires RESUME_FROM=<the spent attempt directory>"
    return 2
  fi
  if [ ! -f "$from/attempt.txt" ]; then
    say "resume: $from records no attempt"
    return 2
  fi
  for field in target cluster state_key; do
    value="$(sed -n "s/^$field=//p" "$from/attempt.txt" | head -1)"
    case "$field" in
      target)
        [ "$value" = "${TARGET:-}" ] || {
          say "resume: $from targets '$value', not '${TARGET:-}'"
          return 2
        }
        ;;
      cluster)
        [ "$value" = "${CLUSTER:-}" ] || {
          say "resume: $from cluster is '$value', not '${CLUSTER:-}'"
          return 2
        }
        ;;
      state_key)
        [ "$value" = "${STATE_KEY:-}" ] || {
          say "resume: $from state key is '$value', not '${STATE_KEY:-}'"
          return 2
        }
        ;;
    esac
  done
  # Carry only the provisioning inputs a later phase needs. The dispatch already
  # required a fresh evidence directory; CA evidence, kubeconfigs and
  # transaction transcripts stay in the spent attempt.
  cp "$from/app-image-refs.txt" "$LOG_DIR/" || return 1
  cp "$from/database-contract-pins.json" "$LOG_DIR/" || return 1
  if [ -f "$from/aws-pre-teardown-identities.json" ]; then
    cp "$from/aws-pre-teardown-identities.json" "$LOG_DIR/"
  fi
  say "resumed attempt $ATTEMPT from $from: diagnostic only, not promotion-eligible"
}

phase_app() {
  # A CA phase records one verdict per instance in the attempt's evidence store. A
  # second app run in the same attempt cannot record a second verdict; the attempt is
  # spent. Refuse with the supported paths instead of a store-level conflict.
  if [ -e "$LOG_DIR/ca-migration.json" ] || [ -e "$LOG_DIR/ca-application.json" ]; then
    say "attempt $ATTEMPT already recorded CA observations; an attempt's CA evidence cannot be re-recorded"
    say "for a diagnostic continuation: live-qual.sh resume with RESUME_FROM=$LOG_DIR and a new ATTEMPT/LOG_DIR"
    say "for a promotion-eligible verdict: restart the whole row in a fresh attempt (prepare through verify)"
    return 2
  fi
  require_target_terraform_var_file || return 1
  ensure_contexts || return 1
  verify_identity_boundary || return 1
  record_ca_submission_authority || return 1
  # The app phase reuses the images `cloud` published, so `prepare`'s build (and its
  # recording) is not guaranteed here, and a resumed app phase has a fresh evidence
  # directory. Re-record the contract: the delivery assertion names its consumers from
  # this specimen, never from a harness-owned namespace map.
  record_database_contract_pins || return 1
  app_require_published_images || return 1
  say "runner: release $SOL_BUNDLE_VERSION names $SOL_RUNNER_IMAGE; the publisher publishes nothing"
  capture_state
  local url
  url="$(jq -r '.outputs.postgres_url.value // empty' "$LOG_DIR/state/cloud.tfstate" 2>/dev/null)"
  if [ -z "$url" ]; then
    say "could not read the cluster root's postgres_url output, so the deploy's database setup has no master"
    return 1
  fi
  # The cluster root's postgres_url output is the *deploy's* input: the database setup step
  # derives <target>-ddl-creds / <target>-dml-creds from it. The harness records the source
  # redacted and never feeds the value to `sol secret set`.
  {
    printf 'database master source: the cluster root postgres_url output (never recorded in the clear)\n'
    printf 'Kafka authority: generated and delivered by Sol; independently compared after deploy\n'
  } >"$LOG_DIR/app-runtime-secrets.txt" 2>&1
  local image_ref_args=""
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    image_ref_args="$image_ref_args --image-ref $(printf '%q' "$ref")"
  done <"$LOG_DIR/app-image-refs.txt"
  if [ -z "$image_ref_args" ]; then
    say "no immutable image refs were published, so the profile's artifact guarantee cannot be met"
    return 1
  fi
  deploy_namespaces="$APP_NS $WORKER_NS"
  say "deploy-substrate"
  for ns in $deploy_namespaces; do
    if kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get rolebinding sol-deploy -n "$ns" >/dev/null 2>&1; then
      say "  $ns: sol-deploy already bound (not a clean test of the substrate prerequisite)"
    else
      say "  $ns: no sol-deploy RoleBinding yet"
    fi
  done
  say "app-deploy-gate"
  # 2b's ordering on a fresh profiled target: `gates -> database_setup -> post_setup_gates`.
  # The first whole-target deploy reconciles the substrate, delivers the class credentials in
  # the database setup step, and then the post-setup migration gate refuses to move workloads
  # against an unapplied migration. That refusal is the ordering claim, not an obstacle.
  if ! run app-deploy-gate bash -c "cd '$WORKSPACE' && exec '$SOL' deploy '$TARGET' --registry '$ECR_REGISTRY' $image_ref_args"; then
    if app_migration_gate_failure "$LOG_DIR/app-deploy-gate.log"; then
      say "  the deploy reconciled the substrate and delivered the class credentials, then refused to move workloads against an unapplied migration (expected)"
    else
      say "FAILED: the deploy did not reach the migration gate"
      return 1
    fi
  fi
  # The observation RoleBindings are namespace-scoped: the transport cannot bind
  # them until Sol's first deploy has created the declared application namespaces.
  # Establish it after that deploy (which moves no workload) and before the
  # migration step, so the CA family's migration observation has an independent
  # read authority. Establish it on every app run: a kubeconfig left by an earlier
  # attempt does not show that the current observation set (including the declared
  # database namespace) is bound. With TRANSPORT=0 the same observations use the
  # deploy identity, never the product's own report.
  if [ "$TRANSPORT" = 1 ]; then
    phase_transport || return 1
  fi
  if [ "$TRANSPORT" = 1 ]; then
    CA_KUBECONFIG="$QUALIFIER_KUBECONFIG"
    CA_CONTEXT="$CLUSTER-qualifier"
  else
    CA_KUBECONFIG="$DEPLOY_KUBECONFIG"
    CA_CONTEXT="$CLUSTER-deploy"
  fi
  record_ca_authority || return 1
  say "app-deploy-migrate"
  # The qualifier brackets the row's normal migration step: it runs the verified
  # candidate's own `migrate apply`, captures the actual Job and observes its CA
  # before cleanup. It does not add a second migration.
  ca_qualify migration "$LOG_DIR/ca-migration-capture.json" "$LOG_DIR/ca-migration.json" \
    "$(python3 -c 'import secrets; print(secrets.token_hex(32))')" || return 1
  # A distinct declaration-only specimen preserves the operator-input refusal
  # claim without treating generated Kafka credentials as operator inputs.
  bash "$ROOT/internal/qualification/application-secret-refusal.sh" "$SOL" \
    "$CLUSTER-deploy" "$(head -1 "$LOG_DIR/app-image-refs.txt" | cut -d= -f2-)" \
    "$LOG_DIR/application-secret-refusal.log" >>"$LOG_DIR/prerequisites.txt" || return 1
  run app-deploy bash -c "cd '$WORKSPACE' && exec '$SOL' deploy '$TARGET' --registry '$ECR_REGISTRY' $image_ref_args" || return 1
  # The final deploy reconciles namespaces and their RBAC. Re-establish the
  # observation transport against the resulting namespaces before observing, so
  # the CA/delivery reads never use a binding the deploy has just replaced.
  if [ "$TRANSPORT" = 1 ]; then
    phase_transport || return 1
    CA_KUBECONFIG="$QUALIFIER_KUBECONFIG"
    CA_CONTEXT="$CLUSTER-qualifier"
    record_ca_authority || return 1
  fi
  # The workloads exist now; observe the application CA delivery in the same
  # assessment as the migration phase.
  ca_qualify application "$LOG_DIR/ca-application-capture.json" "$LOG_DIR/ca-application.json" || return 1
  app_verify_database_delivery || return 1
  # ADR 0004: destruction removes what the lifecycle created, and the images this run published
  # live in the `pluto/<unit>` repositories Sol's own deploy created (#1413). The destroy phase's
  # independent inventory therefore decides a *populated* teardown.
  for ns in $deploy_namespaces; do
    if ! kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get rolebinding sol-deploy -n "$ns" >/dev/null 2>&1; then
      say "the deploy completed into $ns without establishing its scoped deploy RBAC"
      return 1
    fi
  done
  say "  the deploy established the scoped deploy RBAC in every namespace it entered"
  if [ "$TRANSPORT" = 1 ]; then
    export KUBECONFIG_TRANSPORT="$QUALIFIER_KUBECONFIG"
    if ! run app-transaction bash "$ROOT/internal/qualification/aws/transport-transaction.sh" "$LOG_DIR"; then
      capture_kube_evidence
      return 1
    fi
  elif ! run app-transaction bash "$ROOT/internal/qualification/aws/app-transaction.sh" "$LOG_DIR"; then
    capture_kube_evidence
    return 1
  fi
  # The transaction is the behavioral Kafka evidence: it authenticated with the
  # delivered credential and consumed the event. Observe the projection now that
  # the transcript exists; the observer never reads broker credential material.
  app_verify_kafka_delivery || return 1
  capture_kube_evidence
  capture_state
  say "the application transaction completed: the request was accepted, the worker consumed it, and"
  say "the service read the worker's effect back out of PostgreSQL through the qualification transport"
}

# The Kubernetes destination teardown runs against, selected explicitly instead of inherited
# from whatever the calling shell happens to hold.
#
# `sol destroy` releases the target's workloads before it drops the substrate, and that release
# runs in whatever cluster the ambient `KUBECONFIG` names. A fresh session has none of this
# attempt's contexts, and an operator's default kubeconfig can carry *another* cluster's context
# under this cluster's name from an earlier window -- so a destroy that trusts the ambient
# environment can silently skip the release, or aim it at the wrong cluster (#1443 is the same
# shape one level down: state that outlives the session must not be read as the current run's).
#
# This decides what it can, and records which of the three it was:
#
#   attempted   the declared cluster is readable and the attempt's kubeconfig addresses its
#               current endpoint, so the release runs against this target's cluster;
#   skipped     the provider positively answers that the cluster does not exist, so there is
#               nothing to release from, and no context another cluster could answer is handed
#               to Sol;
#   blocked     the cluster could not be read, or could not be reached with a credential that
#               addresses it -- UNKNOWN, never recorded as a skipped release.
#
# Every branch still runs the destroy and the independent inventory: the release is a
# precondition of destruction, not the absence verdict, which stays `absence.py`'s.
destroy_kube_destination() {
  local file="$LOG_DIR/destroy-kubeconfig.txt"
  local describe_err="$LOG_DIR/destroy-cluster-describe.err"
  : >"$file"
  if aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" \
    >"$LOG_DIR/destroy-cluster-describe.json" 2>"$describe_err"; then
    :
  elif grep -q 'ResourceNotFoundException' "$describe_err" 2>/dev/null; then
    # No cluster by this name. Give Sol a config that resolves no context at all, so neither a
    # stale file in this attempt's directory nor the operator's default kubeconfig can aim the
    # release at a different, live cluster; Sol then reports the release as not applicable.
    : >"$LOG_DIR/kubeconfig-none.yaml"
    export KUBECONFIG="$LOG_DIR/kubeconfig-none.yaml"
    printf 'destroy_cluster: ABSENT (describe-cluster answered ResourceNotFoundException)\n' >>"$file"
    printf 'destroy_kubeconfig: %s (empty: no context resolves)\n' "$LOG_DIR/kubeconfig-none.yaml" >>"$file"
    printf 'destroy_release_cleanup: skipped (the cluster is genuinely absent, so there is nothing to release from)\n' >>"$file"
    say "teardown: the cluster $CLUSTER is absent, so the workload release is skipped -- nothing to release from"
    return 0
  else
    : >"$LOG_DIR/kubeconfig-none.yaml"
    export KUBECONFIG="$LOG_DIR/kubeconfig-none.yaml"
    printf 'destroy_cluster: UNKNOWN (describe-cluster did not answer; see %s)\n' "$describe_err" >>"$file"
    printf 'destroy_release_cleanup: blocked (the cluster could not be read) -- UNKNOWN, not skipped\n' >>"$file"
    say "teardown: could not read whether $CLUSTER exists, so whether the workloads were released is UNKNOWN"
    say "  the destroy still runs and the independent inventory still decides absence"
    return 0
  fi
  # The cluster exists. Rebuild the attempt's own kubeconfig when this session does not have
  # one, or has one that addresses a replaced cluster of the same name.
  if [ ! -f "$DEPLOY_KUBECONFIG" ] || ! verify_kubeconfig_endpoint "$DEPLOY_KUBECONFIG" >/dev/null 2>&1
  then
    if ! KUBECONFIG="$DEPLOY_KUBECONFIG" aws eks update-kubeconfig --region "$AWS_REGION" \
      --name "$CLUSTER" --alias "$CLUSTER-deploy" --role-arn "$DEPLOY_ROLE_ARN" \
      >"$LOG_DIR/destroy-kubeconfig-refresh.log" 2>&1 \
      || ! verify_kubeconfig_endpoint "$DEPLOY_KUBECONFIG" >/dev/null 2>&1; then
      : >"$LOG_DIR/kubeconfig-none.yaml"
      export KUBECONFIG="$LOG_DIR/kubeconfig-none.yaml"
      printf 'destroy_cluster: PRESENT\n' >>"$file"
      printf 'destroy_kubeconfig: %s (could not be established; see destroy-kubeconfig-refresh.log)\n' "$DEPLOY_KUBECONFIG" >>"$file"
      printf 'destroy_release_cleanup: blocked (the cluster exists but no credential available here addresses it) -- UNKNOWN, not skipped\n' >>"$file"
      say "teardown: could not establish a kubeconfig that addresses $CLUSTER, so whether the workloads were released is UNKNOWN"
      return 0
    fi
  fi
  export KUBECONFIG="$DEPLOY_KUBECONFIG"
  printf 'destroy_cluster: PRESENT\n' >>"$file"
  printf 'destroy_kubeconfig: %s (verified against the cluster current endpoint)\n' "$DEPLOY_KUBECONFIG" >>"$file"
  if timeout 60 kubectl --kubeconfig "$DEPLOY_KUBECONFIG" --context "$CLUSTER-deploy" \
    auth can-i get namespaces >/dev/null 2>&1; then
    printf 'destroy_release_cleanup: attempted (Kubernetes answered at the cluster endpoint, so Sol releases the workloads before the substrate)\n' >>"$file"
    say "teardown: releasing the workloads through this attempt's kubeconfig $DEPLOY_KUBECONFIG"
  else
    printf 'destroy_release_cleanup: blocked (the cluster exists and the kubeconfig addresses it, but Kubernetes did not answer) -- UNKNOWN, not skipped\n' >>"$file"
    say "teardown: Kubernetes did not answer through this attempt's kubeconfig, so whether the workloads were released is UNKNOWN"
  fi
  return 0
}

phase_destroy() {
  # Checked *before* TEARDOWN_ATTEMPTED: a destroy that cannot start must not record that a
  # teardown was attempted, or an inventory that was never taken reads as a failed teardown.
  require_credentials || return 1
  TEARDOWN_ATTEMPTED=1
  if [ ! -f "$LOG_DIR/aws-pre-teardown-identities.json" ]; then
    say "independent identity capture is missing; teardown is blocked, not verified absent"
    return 1
  fi
  capture_independent_identities || return 1
  destroy_kube_destination
  capture_state
  local destroy_rc=0 verdict_rc=0
  run cloud-destroy bash -c "cd '$WORKSPACE' && exec '$SOL' destroy '$TARGET' --apply --var-file '$TFVARS'" || destroy_rc=$?
  if [ "$destroy_rc" = 0 ]; then
    say "destroy returned success; the independent inventory decides absence"
  else
    say "destroy exited non-zero; the independent inventory decides absence"
  fi
  aws_inventory || verdict_rc=$?
  # Sol's repositories are the target's, so the independent inventory above decides them: every
  # `pluto/<unit>` repository this run published into must read ABSENT after teardown. The run owns
  # no repositories of its own (issue #1413), so there is nothing outside the inventory to remove.
  ecr_record_sol_repositories after-destroy
  if [ "$verdict_rc" != 0 ]; then
    say "the independent inventory does not read ABSENT, so teardown is not complete"
    return 1
  fi
  return "$destroy_rc"
}

disposable_state_present() {
  aws s3api head-object --bucket "$(target_state_bucket)" --key "$STATE_KEY" >/dev/null 2>&1
}

case "${1:-}" in
  cloud)
    attempt_begin 1
    mkdir -p "$LOG_DIR/state"
    sol_under_test_record_identity "$LOG_DIR"
    say "sol-under-test: release $SOL_BUNDLE_VERSION at $SOL_INSTALL"
    say "  migration runner: $SOL_RUNNER_IMAGE"
    ;;
  prepare)
    # `prepare` creates no provider state, so it records no specimen: the specimen belongs to
    # the first phase that provisions one. `cloud` therefore still sees a fresh target.
    attempt_begin 0
    mkdir -p "$LOG_DIR/state"
    sol_under_test_record_identity "$LOG_DIR"
    say "sol-under-test: release $SOL_BUNDLE_VERSION at $SOL_INSTALL"
    say "  migration runner: $SOL_RUNNER_IMAGE"
    ;;
  app | destroy)
    attempt_begin 0
    mkdir -p "$LOG_DIR/state"
    sol_under_test_record_identity "$LOG_DIR"
    say "sol-under-test: release $SOL_BUNDLE_VERSION at $SOL_INSTALL"
    say "  migration runner: $SOL_RUNNER_IMAGE"
    ;;
  resume)
    if [ -z "${RESUME_FROM:-}" ]; then
      say "resume requires RESUME_FROM=<the spent attempt directory>"
      exit 2
    fi
    if [ -e "$LOG_DIR/attempt.txt" ] || [ -n "$(ls -A "$LOG_DIR" 2>/dev/null)" ]; then
      say "resume: $LOG_DIR is not empty; a resumed attempt starts a fresh evidence directory"
      exit 2
    fi
    export ATTEMPT_RESUMED_FROM="$RESUME_FROM"
    attempt_begin 0
    mkdir -p "$LOG_DIR/state"
    sol_under_test_record_identity "$LOG_DIR"
    say "sol-under-test: release $SOL_BUNDLE_VERSION at $SOL_INSTALL"
    say "  migration runner: $SOL_RUNNER_IMAGE"
    ;;
esac

case "${1:-}" in
  cloud) phase_cloud ;;
  prepare) phase_prepare ;;
  transport) phase_transport ;;
  app) phase_app ;;
  destroy) phase_destroy ;;
  resume) phase_resume ;;
  verify | inventory)
    phases_ok=yes
    for ledger_phase in prepare cloud app destroy; do
      grep -q "^phase=$ledger_phase exit=0 " "$LOG_DIR/phase-verdicts.txt" 2>/dev/null ||
        phases_ok=no
    done
    {
      if attempt_promotion_eligible && [ "$phases_ok" = yes ]; then
        printf 'promotion_eligible=yes\n'
      else
        printf 'promotion_eligible=no\n'
        if attempt_promotion_eligible; then
          say "the attempt is continuous but its required phases are incomplete; not promotion-eligible"
        else
          printf 'resumed_from=%s\n' "$(attempt_field resumed_from || true)"
          say "resumed attempt: this evidence is diagnostic, not promotion-eligible"
        fi
      fi
      printf 'required_phases_ok=%s\n' "$phases_ok"
      # Continuity is whether this attempt resumed another, not whether it is
      # promotion-eligible. A staging (mechanism-only) attempt is continuous and
      # ineligible; reading the promotion flag here conflated the two.
      if [ -n "$(attempt_field resumed_from || true)" ]; then
        printf 'attempt_continuity=resumed\n'
      else
        printf 'attempt_continuity=continuous\n'
      fi
      printf 'attempt=%s\n' "$ATTEMPT"
    } >"$LOG_DIR/promotion-eligibility.txt"
    aws_inventory
    ;;
  *) usage; exit 2 ;;
esac
