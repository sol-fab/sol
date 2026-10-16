#!/usr/bin/env bash
set -uo pipefail
trap '' PIPE

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
TARGET_FILE="$WORKSPACE/sol/environments.local.yml"
ROW="${ROW:-qualreg}"
PROVIDER=aws
ATTEMPT="${ATTEMPT:-}"
TARGET="${TARGET:-$ROW-$ATTEMPT/aws/us-east-1}"
TFVARS="${TFVARS:-$ROOT/internal/qualification/aws/qual-aws-row.tfvars}"
AWS_PROFILE="${AWS_PROFILE:-sol-qual}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:?Set CLUSTER to this the run EKS cluster name}"
DEPLOY_ROLE_ARN="${DEPLOY_ROLE_ARN:?Set DEPLOY_ROLE_ARN to the deploy role the target declares}"
CLUSTER_ACCESS_ROLE_ARN="${CLUSTER_ACCESS_ROLE_ARN:?Set CLUSTER_ACCESS_ROLE_ARN to the cluster-access role the target declares}"
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
ABSENCE="$ROOT/internal/qualification/aws/absence.py"
export ECR_REGISTRY

mkdir -p "$LOG_DIR"
SAY_LOG="$LOG_DIR/harness.log"

say() {
  local line
  printf -v line '[%(%H:%M:%S)T] %s' -1 "$*"
  printf '%s\n' "$line" >>"$SAY_LOG" 2>/dev/null || true
  printf '%s\n' "$line" 2>/dev/null || true
}

CLOUD_APPLIED=0
TEARDOWN_ATTEMPTED=0
TERMINATION_SIGNAL=""

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

trap cleanup EXIT
trap 'on_terminate TERM' TERM
trap 'on_terminate INT' INT

source "$ROOT/internal/qualification/sol-under-test.sh"
source "$ROOT/internal/qualification/candidate-binding.sh"
source "$ROOT/internal/qualification/attempt.sh"

case "${1:-}" in
  prepare | cloud | app | destroy)
    sol_under_test_resolve
    ;;
esac

usage() {
  cat <<'USAGE'
live-row.sh — the AWS regression row: the application contract GCP Attempt 28 established

usage: live-row.sh PHASE      PHASE in: prepare | cloud | transport | app | destroy | verify

required
  ATTEMPT           a unique identity for this disposable run; the target, state key and
                    evidence directory are bound to it, and a repeated ATTEMPT continues it
  CLUSTER           this run's EKS cluster name
  DEPLOY_ROLE_ARN   the deploy identity whose kubeconfig the deploy uses
  SOL_INSTALL       the extracted release prefix holding bin/sol and share/sol/<version>
  SOL_CANDIDATE     the candidate document this run qualifies (the draft's candidate.json);
                    the run verifies the prefix is that candidate before it provisions
  QUALIFIER_ROLE    the qualification-only transport role; required unless TRANSPORT=0
optional (defaults shown)
  ROW=qualreg                    the stable logical row label
  TARGET=qualreg-<attempt>/aws/us-east-1   CONTINUE_ATTEMPT=0
  ECR_REGISTRY=<account>.dkr.ecr.us-east-1.amazonaws.com
  AWS_PROFILE=sol-qual           AWS_REGION=us-east-1
  TFVARS=internal/qualification/aws/qual-aws-row.tfvars
  WORKSPACE=examples/pluto
  PHASE_TIMEOUT=2400             LOG_DIR=/tmp/sol-aws-row-<attempt>
  OPERATOR_ROLE_ARN=<unset>      TRANSPORT=1
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
             artifact gate), then publish the built images into the repositories Sol
             created, the read-only whole-target plan, the deploy identity's kubeconfig,
             node evidence, and state capture
  transport  establish and verify the qualification-only transport (INFRA-060 / DEC-039)
  app        Sol's work: runtime secrets, migrate apply, deploy with the published digests,
             the transaction
  destroy    supported teardown, then the independent inventory
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

# The other half of that contract, read from the cluster rather than inferred from the log:
# reconciliation is not a workload rollout and not a recorded release. A namespace that does not
# exist yet is not a moved workload; a read that fails for any other reason is UNKNOWN, never
# absence.
cold_start_moved_nothing() {
  local ns out err
  for ns in $APP_NS $WORKER_NS; do
    err="$LOG_DIR/cold-start-$ns.err"
    if ! out="$(kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get deploy -n "$ns" -o name 2>"$err")"; then
      if grep -q 'not found' "$err" 2>/dev/null; then
        continue
      fi
      say "could not read the deployments in $ns, so whether a workload moved is UNKNOWN (see $err)"
      return 1
    fi
    if [ -n "$out" ]; then
      say "the cold deploy moved a workload before its immutable artifacts were published: $out"
      return 1
    fi
    if ! out="$(kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get configmap -n "$ns" \
      -l sol.dev/type=release -o name 2>"$err")"; then
      if grep -q 'not found' "$err" 2>/dev/null; then
        continue
      fi
      say "could not read the release ConfigMaps in $ns, so whether a release was recorded is UNKNOWN (see $err)"
      return 1
    fi
    if [ -n "$out" ]; then
      say "the cold deploy recorded a release before its immutable artifacts were published: $out"
      return 1
    fi
  done
  say "the cold deploy provisioned the target and moved no workload and recorded no release"
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
require_target_terraform_var_file() {
  if grep -qE '^[[:space:]]*terraform_var_file:' "$TARGET_FILE" 2>/dev/null; then
    return 0
  fi
  say "REFUSING: $TARGET_FILE declares no terraform_var_file, and sol deploy takes no --var-file,"
  say "so the cluster and platform roots would be applied with their default variables."
  return 1
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
  # `redpanda` is a reserved platform namespace: the deploy identity is
  # namespace-scoped application authority and correctly cannot write there. The
  # harness stands in for the operator, who holds platform-management authority,
  # so it uses the cluster-access identity.
  if ! kubectl --kubeconfig "$ACCESS_KUBECONFIG" create secret generic redpanda-users -n redpanda \
      --from-literal="users.txt=sol-workloads:$KAFKA_SASL_PASSWORD:SCRAM-SHA-256" \
      >"$LOG_DIR/platform-credential.log" 2>&1; then
    say "could not create the platform's documented prerequisite Secret redpanda/redpanda-users"
    say "(see $LOG_DIR/platform-credential.log); the harness stands in for the operator and will not proceed without it"
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
  aws s3 cp "s3://$(target_state_bucket)/$STATE_KEY" "$LOG_DIR/state/cloud.tfstate" \
    >"$LOG_DIR/state/copy.log" 2>&1 || true
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
aws_inventory() {
  if ! command -v python3 >/dev/null 2>&1; then
    say "the independent inventory needs python3, which is not on PATH"
    return 1
  fi
  say "independent inventory (read-only): every required disposable class"
  if ! python3 "$ABSENCE" collect \
    --dir "$LOG_DIR" \
    --cluster "$CLUSTER" \
    --region "$AWS_REGION" \
    --account "$ACCOUNT" \
    --registry-prefix "$WORKSPACE_NAME" \
    --base-domain "$BASE_DOMAIN" \
    --retention "$RETENTION" \
    --attempt "$ATTEMPT" \
    --target "$TARGET" \
    --state-key "$STATE_KEY" \
    >"$LOG_DIR/aws-inventory.stdout" 2>"$LOG_DIR/aws-inventory.err"; then
    say "the independent inventory does not read ABSENT; teardown is not complete"
    say "  evidence: $LOG_DIR/aws-inventory.txt and $LOG_DIR/aws-inventory-verdict.txt"
    return 1
  fi
  say "the independent inventory reads ABSENT for every required disposable class"
  return 0
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
  say "transport-establish"
  if ! KUBECONFIG="$QUALIFIER_KUBECONFIG" timeout "$PHASE_TIMEOUT" \
      "$ROOT/internal/qualification/transport/establish.sh" \
      "$CLUSTER" "$QUALIFIER_ROLE" "$AWS_REGION" "$APP_NS" \
      >"$LOG_DIR/transport-establish.log" 2>&1; then
    say "FAILED: transport-establish (last 40 lines; full log $LOG_DIR/transport-establish.log)"
    tail -n 40 "$LOG_DIR/transport-establish.log"
    return 1
  fi
  say "transport-verify"
  probe_qualifier_identity || return 1
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
  if [ "$deploy_rc" != 0 ] && platform_credential_missing; then
    say "the bootstrap deploy stopped at the platform's documented credential prerequisite; supplying it and resuming"
    ensure_contexts || return 1
    supply_platform_credential || return 1
    bootstrap_deploy cloud-apply-resume || deploy_rc=$?
    if cloud_mutated; then CLOUD_APPLIED=1; fi
  fi
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
  # recorded no release -- the distinction #1473 makes and a successful cold-start row must show.
  ensure_contexts || return 1
  cold_start_moved_nothing || return 1
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
  local context="$LOG_DIR/app-build-context" pins
  if ! pins="$(sol_candidate_bind_context "$WORKSPACE" "$SOL_REVISION" "$context")"; then
    say "refusing to build the application: it cannot be bound to candidate $SOL_REVISION"
    return 1
  fi
  sol_candidate_record_binding "$LOG_DIR" "$SOL_REVISION" "$WORKSPACE" "$context" "$pins" "$(git -C "$WORKSPACE" rev-parse HEAD)"
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

# Publish the built images into the repositories Sol's deploy created, and record the immutable
# digest each push resolved to; those digests are what every later deploy names.
app_push_images() {
  local unit ref digest
  : >"$LOG_DIR/app-image-refs.txt"
  if [ ! -s "$LOG_DIR/app-built-tags.txt" ]; then
    say "no built images to publish for $TARGET; run live-row.sh prepare first"
    return 0
  fi
  run ecr-login bash -c \
    "aws ecr get-login-password --region '$AWS_REGION' | docker login --username AWS --password-stdin '$ECR_REGISTRY'" || return 1
  while IFS= read -r line; do
    unit="${line%%=*}"
    ref="${line#*=}"
    [ -n "$unit" ] || continue
    [ -n "$ref" ] || continue
    run "app-push-$unit" docker push "$ref" || return 1
    if ! digest="$(image_digest "$ref")"; then return 1; fi
    printf '%s=%s\n' "$unit" "$digest" >>"$LOG_DIR/app-image-refs.txt"
    say "  $unit -> $digest"
  done <"$LOG_DIR/app-built-tags.txt"
}

# The digests this run pins, as `sol deploy --image-ref` arguments. A profiled target's preflight
# refuses a mutable tag, and on a cold target the digests cannot exist before the deploy creates
# the repositories; `cloud` publishes them once the environment is reconciled, and every later
# deploy names them (the cold-target ordering, issue #1413).
app_image_ref_args() {
  local ref args=""
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    args="$args --image-ref $(printf '%q' "$ref")"
  done <"$LOG_DIR/app-image-refs.txt"
  printf '%s' "$args"
}

# `app` reuses the digests `cloud` published into Sol's repositories; it never publishes its own.
app_require_published_images() {
  if [ -s "$LOG_DIR/app-image-refs.txt" ]; then
    say "reusing the digests the cloud phase published into Sol's repositories"
    return 0
  fi
  say "no published image digests for $TARGET: run live-row.sh cloud first, which provisions the"
  say "target's repositories and publishes the images built by live-row.sh prepare"
  return 1
}

# `prepare` runs before `cloud`: it builds the application images bound to the candidate and
# touches no provider state, so `cloud` still sees a fresh specimen.
phase_prepare() {
  require_target_terraform_var_file || return 1
  app_build_images || return 1
  say "the run images are built; the cloud phase publishes them into the repositories Sol creates"
}

app_secret_failure() {
  grep -qF 'does not hold the required non-empty secret key(s)' "$1" 2>/dev/null
}

# 2b moved migration verification to the post-setup gates, so on a fresh target the deploy
# reaches the migration gate before the required-secret check. It is the first refusal a
# fresh profiled target produces, and the harness models it rather than assuming the
# pre-2b order.
app_migration_gate_failure() {
  grep -qF 'the required migration set is not applied' "$1" 2>/dev/null
}

app_read_platform_password() {
  local password
  if [ -n "${KAFKA_SASL_PASSWORD:-}" ]; then
    printf '%s' "$KAFKA_SASL_PASSWORD"
    return 0
  fi
  password="$(kubectl --kubeconfig "$ACCESS_KUBECONFIG" get secret redpanda-users -n redpanda \
    -o jsonpath='{.data.users\.txt}' 2>/dev/null | base64 -d 2>/dev/null |
    sed -n 's/^sol-workloads:\([^:]*\):.*/\1/p' | head -1)"
  [ -n "$password" ] || return 1
  printf '%s' "$password"
}

app_read_kafka_ca() {
  kubectl --kubeconfig "$ACCESS_KUBECONFIG" get secret redpanda-default-cert -n redpanda \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null
}

# The supported `sol secret set` surface is positional — `TARGET ADDRESS` — where ADDRESS is
# `@platform/<KEY>` for a Sol Job input or `<domain>/<unit>/<KEY>` for one unit's secret. The
# pre-2b `--target`/`--domain` flags are gone. The value must arrive with `--from-stdin`: the
# CLI does not auto-detect a pipe and otherwise demands a terminal (#1432).
app_unit_addresses() {
  local unit dir
  for unit in $APP_UNITS; do
    if dir="$(unit_dir "$unit")"; then
      printf '%s\n' "${dir#app/}"
    fi
  done | sort -u
}

app_secret_set_unit() {
  local key="$1" address
  for address in $(app_unit_addresses); do
    run "app-secret-$key-$(printf '%s' "$address" | tr '/' '-')" bash -c \
      "cd '$WORKSPACE' && printf '%s' \"\$SOL_SECRET_VALUE\" | exec '$SOL' secret set '$TARGET' '$address/$key' --from-stdin"
  done
}

app_secret_set_platform() {
  local key="$1"
  run "app-secret-platform-$key" bash -c \
    "cd '$WORKSPACE' && printf '%s' \"\$SOL_SECRET_VALUE\" | exec '$SOL' secret set '$TARGET' '@platform/$key' --from-stdin"
}

# Production secrets are operator-supplied: Sol's deploy verifies the ones a unit or a Job
# declares and fails closed. The harness stands in for the operator, supplying the Kafka
# platform inputs through the supported `sol secret set`. The database is *not* one of them:
# the deploy delivers it from the target's binding (2b), so the harness neither holds nor sets
# a POSTGRES_URL.
#
# This workspace declares the two Kafka keys **per unit** with `authority: sol`, and the
# deploy verifies each unit's own Secret holds every key that unit declares, so the keys are
# supplied in **both** scopes: `@platform/<KEY>` for Sol's Jobs, `<domain>/<unit>/<KEY>` for
# the workload. Supplying only the platform scope leaves the deploy refusing the unit Secret
# (#1438); supplying an *undeclared* key is refused by the CLI (#1430). Writing the unit
# scope before the workload exists is fine — `sol secret set` writes and stops, and the
# deploy that follows activates (#1350).
app_supply_secrets() {
  local password ca
  if ! password="$(app_read_platform_password)"; then
    say "could not establish KAFKA_SASL_PASSWORD: set it in the environment, or ensure redpanda/redpanda-users exists"
    return 1
  fi
  ca="$(app_read_kafka_ca)"
  if [ -z "$ca" ]; then
    say "could not read the Redpanda CA from redpanda/redpanda-default-cert"
    return 1
  fi
  export SOL_SECRET_VALUE="$password"
  app_secret_set_platform KAFKA_SASL_PASSWORD || return 1
  app_secret_set_unit KAFKA_SASL_PASSWORD || return 1
  export SOL_SECRET_VALUE="$ca"
  app_secret_set_platform KAFKA_SSL_CA_CERT || return 1
  app_secret_set_unit KAFKA_SSL_CA_CERT || return 1
  unset SOL_SECRET_VALUE
  {
    printf 'unit_secret_keys: KAFKA_SASL_PASSWORD KAFKA_SSL_CA_CERT (declared per unit, authority sol)\n'
    printf 'platform_secret_keys: KAFKA_SASL_PASSWORD KAFKA_SSL_CA_CERT\n'
    printf 'secret_values: never recorded\n'
    printf 'database_delivery: delivered by the deploy from the target binding; no operator copy\n'
  } >>"$LOG_DIR/prerequisites.txt"
  say "supplied the workspace's declared Kafka secrets through sol secret set; the database is delivered by the deploy"
}

app_class_credential_name() { printf '%s' "$TARGET" | tr '[:upper:]/' '[:lower:]-'; }

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
  grep -h 'sol-database-identity:' "$LOG_DIR"/app-deploy.log 2>/dev/null | tail -1
}

app_database_field() {
  app_database_declaration | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1
}

app_verify_database_delivery() {
  local name ddl dml consumer namespace declared_ns ddl_name
  name="$(app_class_credential_name)"
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
  dml=""
  for namespace in $(app_namespaces); do
    if kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get secret "$name-dml-creds" -n "$namespace" \
      >/dev/null 2>&1; then
      dml="$namespace"
    fi
  done
  if [ -z "$dml" ]; then
    say "no consuming namespace carries the $name-dml-creds class Secret"
    return 1
  fi
  consumer="$APP_SERVICE-secrets"
  if kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get secret "$consumer" -n "$APP_NS" \
    -o jsonpath='{.data.POSTGRES_URL}' 2>/dev/null | grep -q .; then
    say "$consumer still carries POSTGRES_URL; the unit is not reading the class Secret"
    return 1
  fi
  # The CA is a **mount**, read from the workload's own namespace, not a value routed like the
  # class Secret. Verified per selected workload, from its own pod template (#1481).
  app_verify_database_ca "$declared_ns" || return 1
  {
    printf 'database_delivery: %s@%s (migration Job, as the deploy declared it), %s@%s (unit consumer)\n' \
      "$ddl_name" "$declared_ns" "$name-dml-creds" "$dml"
    printf 'database_delivery_assertion: the consumer unit Secret carries no POSTGRES_URL\n'
  } >>"$LOG_DIR/prerequisites.txt"
  say "the deploy delivered the database as $name-ddl-creds / $name-dml-creds; the consumer's unit Secret carries no master copy"
}

# The database CA is a mount, so its verification is per workload and reads the pod template — not
# the rendered object's text: a name appearing somewhere in an object proves neither that the pod
# template mounts it nor that a neighbour does, and a CA written only beside the migration Job
# leaves a pod in ContainerCreating (#1481). Every read distinguishes a **missing object** from an
# **unreadable one**: an authorization failure or an API outage is UNKNOWN, never absence.
app_verify_database_ca() {
  local declared_ns="$1"
  local ca namespace mount workload address err mounted=0
  ca="$(app_database_field ca-configmap)"
  if [ -z "$ca" ]; then
    say "the deploy declared no ca-configmap, so the database CA mount cannot be verified"
    return 1
  fi
  # Where the workloads read it: each consuming namespace, and the location the deploy declared.
  for namespace in $(app_namespaces) "$declared_ns"; do
    err="$LOG_DIR/db-ca-$namespace.err"
    if ! mount="$(kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get configmap "$ca" -n "$namespace" \
      -o name 2>"$err")"; then
      if grep -qi 'not found' "$err" 2>/dev/null; then
        say "the deploy declared CA ConfigMap $ca and it is absent from $namespace, where the workloads read it"
      else
        say "could not read CA ConfigMap $ca in $namespace, so its presence is UNKNOWN (see $err)"
      fi
      return 1
    fi
  done
  # One read per selected workload, from its own pod template. A workload missing the mount fails
  # even when another workload in the same namespace mounts the CA correctly.
  for address in $(app_unit_addresses); do
    namespace="${APP_NS%-*}-${address%%/*}"
    workload="$(k8s_name "${address##*/}")"
    err="$LOG_DIR/db-ca-volume-$workload.err"
    if ! mount="$(kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get deploy "$workload" -n "$namespace" \
      -o json 2>"$err" \
      | jq -r --arg ca "$ca" \
        '[.spec.template.spec.volumes[]? | select(.name == "db-ca") | .configMap.name]
         | if index($ca) then "yes" else "no" end' 2>>"$err")"; then
      say "could not read $namespace/$workload, so whether it mounts $ca is UNKNOWN (see $err)"
      return 1
    fi
    if [ "$mount" != "yes" ]; then
      say "$namespace/$workload does not mount the declared CA $ca through its db-ca volume"
      return 1
    fi
    mounted=$((mounted + 1))
  done
  if [ "$mounted" = 0 ]; then
    say "no selected workload was read for the database CA mount, so the assertion would be vacuous"
    return 1
  fi
  printf 'database_ca: %s present at every consuming namespace and the declared location, and mounted through the db-ca volume by %s selected workload(s)\n' \
    "$ca" "$mounted" >>"$LOG_DIR/prerequisites.txt"
  say "$mounted selected workload(s) mount the declared database CA $ca through their db-ca volume"
}

phase_app() {
  require_target_terraform_var_file || return 1
  ensure_contexts || return 1
  verify_identity_boundary || return 1
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
    printf 'operator secrets: supplied with sol secret set; values never recorded\n'
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
  say "app-deploy-migrate"
  run migrate-apply bash -c "cd '$WORKSPACE' && exec '$SOL' migrate apply '$TARGET'" || return 1
  say "app-deploy-secrets"
  if ! run app-deploy-secrets bash -c "cd '$WORKSPACE' && exec '$SOL' deploy '$TARGET' --registry '$ECR_REGISTRY' $image_ref_args"; then
    if app_secret_failure "$LOG_DIR/app-deploy-secrets.log"; then
      say "  the deploy established the namespaces and their scoped RBAC, then refused the absent operator secrets (expected)"
    else
      say "FAILED: the deploy did not reach the secret prerequisite"
      return 1
    fi
  fi
  app_supply_secrets || return 1
  run app-deploy bash -c "cd '$WORKSPACE' && exec '$SOL' deploy '$TARGET' --registry '$ECR_REGISTRY' $image_ref_args" || return 1
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
  if [ "$TRANSPORT" = 1 ] && [ ! -f "$QUALIFIER_KUBECONFIG" ]; then
    phase_transport || return 1
  fi
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
  capture_kube_evidence
  capture_state
  say "the application transaction completed: the request was accepted, the worker consumed it, and"
  say "the service read the worker's effect back out of PostgreSQL through the qualification transport"
}

phase_destroy() {
  # Checked *before* TEARDOWN_ATTEMPTED: a destroy that cannot start must not record that a
  # teardown was attempted, or an inventory that was never taken reads as a failed teardown.
  require_credentials || return 1
  TEARDOWN_ATTEMPTED=1
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
esac

case "${1:-}" in
  cloud) phase_cloud ;;
  prepare) phase_prepare ;;
  transport) phase_transport ;;
  app) phase_app ;;
  destroy) phase_destroy ;;
  verify | inventory) aws_inventory ;;
  *) usage; exit 2 ;;
esac
