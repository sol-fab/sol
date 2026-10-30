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
TS_APP_NS="${TS_APP_NS:-pluto-demo-ts}"
TS_SERVICE="${TS_SERVICE:-order-svc}"
APP_SERVICE="${APP_SERVICE:-charge-svc}"
APP_PORT="${APP_PORT:-80}"
SCENARIO="${SCENARIO:-charges}"
SVC_UNIT="${SVC_UNIT:-charge_svc}"
WORKER_UNIT="${WORKER_UNIT:-notify_worker}"
# Every workload the target's plan selects needs an immutable artifact; the
# production-single-region profile refuses a mutable tag. The profile qualifies
# OCaml workloads only, and the example target omits the two TypeScript units.
APP_UNITS="${APP_UNITS:-checkout_svc charge_svc notify_worker orders_svc fulfilment_worker}"
KAFKA_BEHAVIORAL_UNITS="charge_svc notify_worker"
# The namespaces this row is configured to exercise; the cold-start boundary derives the
# per-unit namespaces from the candidate and requires this declared set to be covered.
COLD_START_REQUIRED_NAMESPACES="${COLD_START_REQUIRED_NAMESPACES:-$APP_NS $WORKER_NS}"
LEDGER_PREFIX="${LEDGER_PREFIX:-sol}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-2400}"
APP_TAG="${APP_TAG:-row-$(date -u +%Y%m%d-%H%M%S)}"
LOG_DIR="${LOG_DIR:-/tmp/sol-aws-row-$ATTEMPT}"
export AWS_PROFILE AWS_REGION APP_TAG APP_NS WORKER_NS TS_APP_NS TS_SERVICE APP_SERVICE APP_PORT SCENARIO

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
  *prod*) ATTEMPT_CLAIM=production ;;
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

# `say` and `refuse` are the shared output functions in lib/shared.sh.

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

cleanup() { cleanup_run; }

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

# Provider identity and the shared phase bodies. The hooks this provider must supply
# are checked here, in the process that will call them, before any phase runs.
PROVIDER=aws
# shellcheck source=/dev/null
source "$ROOT/internal/qualification/lib/shared.sh"
# shellcheck source=/dev/null
source "$ROOT/internal/qualification/lib/hooks.sh"
# shellcheck source=/dev/null
source "$ROOT/internal/qualification/lib/phases.sh"
# shellcheck source=/dev/null
source "$ROOT/internal/qualification/provider-aws.sh"
require_provider_hooks || exit 1

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

# The shared database-CA family owner (#1510). It is a harness executable,
# distinct from the installed candidate's own sol.
SOL_QUALIFICATION_CA="${SOL_QUALIFICATION_CA:-$ROOT/_build/default/internal/tooling/sol_qualification/bin/qualification_database_ca.exe}"
# The typed phase/attempt assessment. The shell executes the decision but does not
# re-derive it from the ledger.
SOL_QUALIFICATION_LIFECYCLE="${SOL_QUALIFICATION_LIFECYCLE:-$ROOT/_build/default/internal/tooling/sol_qualification/bin/qualification_lifecycle.exe}"

# The database-contract pins are recorded by the shared `record_database_contract_pins`
# in lib/shared.sh; the specimen it keeps carries the candidate's own declaration.

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
# The shared database-CA launcher is `ca_qualify` in lib/shared.sh; the provider's
# `ca_request` builds the request it runs. A phase's exit status is not evidence: the
# report phase re-reads the recorded captures and verdicts.

# The whole-target deploy reconciles the durable installation inline (DEC-057 §2), and on an
# account whose installation is not established it offers to set it up through one
# interactive confirmation. The run drives that confirmation through a pty with a single
# 'y'; an account whose installation is already established is deployed to without a
# prompt, and the extra 'y' is left unread. A deploy also verifies immutable --image-ref
# manifests before it applies anything, so the bootstrap deploy names a tag: the ECR
# repositories it is about to create are where phase_app later pushes the digests this run
# pins. Its exit status is returned rather than inspected here, because the deploy is
# expected to stop at the workloads those digests belong to.
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
  for unit in $(cold_start_services); do
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
  digest="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" 2>/dev/null | grep -F "${ref%:*}@" | head -1 || true)"
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
  local qualifier_arn=""
  if [ -n "$QUALIFIER_ROLE" ] && [ -n "$ACCOUNT" ]; then
    qualifier_arn="arn:aws:iam::${ACCOUNT}:role/${QUALIFIER_ROLE}"
  fi
  python3 "$ABSENCE" "$@" \
    --prior "$LOG_DIR/aws-pre-teardown-identities.json" \
    --cluster "$CLUSTER" --region "$AWS_REGION" --account "$ACCOUNT" \
    --qualifier-arn "$qualifier_arn" \
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
# The attempt-owned kubeconfig the destroy destination establishes and probes through.
ATTEMPT_KUBECONFIG="$DEPLOY_KUBECONFIG"
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
  if app_unit_addresses | grep -qE '^(app/)?demo_ts/'; then
    observe_namespaces+=("$TS_APP_NS")
  fi
  local database_ns
  database_ns="$(app_database_field namespace)"
  if [ -n "$database_ns" ]; then
    observe_namespaces+=("$database_ns")
  fi
  say "transport-establish"
  # The refusal text is evidence, not console output: establish.sh keeps it here
  # and prints only its class, so the tail below cannot carry a server message.
  if ! KUBECONFIG="$QUALIFIER_KUBECONFIG" SOL_TRANSPORT_EVIDENCE_DIR="$LOG_DIR" \
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
  local min_minutes="${1:-0}" output detail expiration expires now remaining
  if ! output="$(aws configure export-credentials --profile "$AWS_PROFILE" --format env 2>&1)"; then
    detail="$output"
    say "the AWS credentials for profile '$AWS_PROFILE' cannot be refreshed:"
    printf '%s\n' "$detail" | sed 's/^/  /' >&2
    say "terraform uses the same credential path, so no plan, apply or destroy can run; nothing was attempted."
    say "Re-authenticate (for an SSO profile: aws sso login --profile $AWS_PROFILE), then re-run."
    return 1
  fi
  expiration="$(printf '%s\n' "$output" | sed -n 's/^export AWS_CREDENTIAL_EXPIRATION=//p' | tail -1)"
  # Non-SSO credential sources may not expose an expiry. Do not invent one; the
  # refresh check above still established that the credential resolves.
  [ -n "$expiration" ] || return 0
  expires="$(date -d "$expiration" +%s 2>/dev/null || true)"
  if [ -z "$expires" ]; then
    say "REFUSING: the AWS credential expiry '$expiration' cannot be read, so the run window cannot be checked"
    return 1
  fi
  now="$(date +%s)"
  remaining=$(( (expires - now) / 60 ))
  if [ "$remaining" -lt "$min_minutes" ]; then
    say "REFUSING: the AWS credentials for profile '$AWS_PROFILE' expire at $expiration, only ${remaining}m remain; this phase needs at least ${min_minutes}m"
    say "Re-authenticate (for an SSO profile: aws sso login --profile $AWS_PROFILE), then re-run."
    return 1
  fi
}

phase_cloud() { phase_cloud_run; }


# Bind the application to the candidate revision and record what the binding enforced.
#
# This is a `prepare` step, not a build step. The build helper is called wherever a
# provider needs the run's images, so a binding inside it would bind as a side effect of
# building -- and a caller that built again would bind again. The phase owns the
# ordering: precondition, bind, then build. It touches no provider state.
candidate_bind() {
  local context="$APP_BUILD_CONTEXT" pins
  if ! pins="$(sol_candidate_bind_context "$WORKSPACE" "$SOL_REVISION" "$context")"; then
    say "refusing to build the application: it cannot be bound to candidate $SOL_REVISION"
    return 1
  fi
  if ! sol_candidate_record_binding "$LOG_DIR" "$SOL_REVISION" "$WORKSPACE" "$context" "$pins" "$(git -C "$WORKSPACE" rev-parse HEAD)"; then
    say "the candidate binding could not be recorded (candidate-binding.txt), so nothing is built"
    return 1
  fi
  # Record the database-contract pins the app phase re-verifies. This reads the
  # immutable install and the candidate-bound workspace only.
  record_database_contract_pins || return 1
}

# `prepare` builds the run's images and nothing else: a build touches no provider state, so the
# `cloud` phase still sees a fresh target. The images stay in the local daemon; `cloud` pushes
# them into the repositories Sol's deploy creates.
app_build_images() {
  local unit dir ref
  : >"$LOG_DIR/app-built-tags.txt"
  local context="$APP_BUILD_CONTEXT"
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

phase_prepare() { phase_prepare_run; }


# 2b moved migration verification to the post-setup gates, so on a fresh target the deploy
# reaches the migration gate before the required-secret check. It is the first refusal a
# fresh profiled target produces, and the harness models it rather than assuming the
# pre-2b order.
app_migration_gate_failure() {
  grep -qF 'the required migration set is not applied' "$1" 2>/dev/null
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
# **Read where the deploy says it wrote** (sol-database-identity: ...), rather than reproducing
# the naming rule here. The row asserts Sol's decision, not its own copy of it (#1424). The
# field names are the interface; the deploy's line is a stable, documented output, and the
# product test `database identity report is the interface the rows read` fails if they drift.
app_database_field() {
  app_database_declaration | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1
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

# The source attempt is the provenance of everything the diagnostic resume carries.
# A resumed attempt must describe the same specimen, candidate and row; otherwise
# app-image-refs.txt and database-contract-pins.json would describe a different
# qualification. Missing or malformed source metadata refuses rather than matching
# by absence.
resume_source_field() {
  local key="$1" file="$2"
  sed -n "s/^$key=//p" "$file" | head -1
}

resume_validate_source() {
  local from="${RESUME_FROM:-}" field value expected
  if [ -z "$from" ]; then
    say "resume requires RESUME_FROM=<the spent attempt directory>"
    return 2
  fi
  if [ ! -f "$from/attempt.txt" ]; then
    say "resume: $from records no attempt"
    return 2
  fi
  for field in target cluster state_key; do
    value="$(resume_source_field "$field" "$from/attempt.txt")"
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
  expected="${SOL_CANDIDATE_REVISION:-}"
  if [ -z "$expected" ]; then
    say "resume: this run records no candidate revision; refusing to carry inputs without provenance"
    return 2
  fi
  value="$(resume_source_field candidate_revision "$from/attempt.txt")"
  case "$value" in
    "" | *[!0-9a-f]*)
      say "resume: $from records no valid candidate revision; refusing to carry inputs without provenance"
      return 2
      ;;
  esac
  if [ "${#value}" -ne 40 ]; then
    say "resume: $from records malformed candidate revision '$value'; refusing to carry inputs without provenance"
    return 2
  fi
  [ "$value" = "$expected" ] || {
    say "resume: $from was recorded for candidate revision $value, not $expected"
    return 2
  }
  expected="${ROW:-}"
  if [ -z "$expected" ]; then
    say "resume: this run records no qualification row; refusing to carry inputs without provenance"
    return 2
  fi
  value="$(resume_source_field row "$from/attempt.txt")"
  if [ -z "$value" ]; then
    say "resume: $from records no qualification row; refusing to carry inputs without provenance"
    return 2
  fi
  [ "$value" = "$expected" ] || {
    say "resume: $from row is '$value', not '$expected'"
    return 2
  }
  return 0
}

# A diagnostic continuation of a spent attempt. The evidence store records one CA
# verdict per instance per attempt, so a spent attempt cannot be re-observed; the
# new attempt carries only the provisioning inputs and is marked non-promotable.
phase_resume() {
  local from="${RESUME_FROM:-}"
  resume_validate_source || return 2
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

phase_app() { phase_app_run; }

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
phase_destroy() { phase_destroy_run; }

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
    resume_validate_source || exit $?
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
    if [ ! -x "$SOL_QUALIFICATION_LIFECYCLE" ]; then
      refuse "REFUSING: the typed lifecycle assessor is not built at $SOL_QUALIFICATION_LIFECYCLE"
      exit 1
    fi
    if ! assessment="$(timeout "$PHASE_TIMEOUT" "$SOL_QUALIFICATION_LIFECYCLE" --attempt-dir "$LOG_DIR")"; then
      refuse "REFUSING: the typed lifecycle assessor could not read $LOG_DIR"
      exit 1
    fi
    {
      printf 'promotion_eligible=%s\n' "$(printf '%s' "$assessment" | jq -r 'if .eligible then "yes" else "no" end')"
      printf 'required_phases_ok=%s\n' "$(printf '%s' "$assessment" | jq -r 'if .required_phases_ok then "yes" else "no" end')"
      printf 'attempt_continuity=%s\n' "$(printf '%s' "$assessment" | jq -r '.continuity')"
      printf 'attempt=%s\n' "$(printf '%s' "$assessment" | jq -r '.attempt')"
      printf '%s' "$assessment" | jq -r '.reasons[]? | "reason=\(.)"'
    } >"$LOG_DIR/promotion-eligibility.txt"
    aws_inventory
    ;;
  *) usage; exit 2 ;;
esac
