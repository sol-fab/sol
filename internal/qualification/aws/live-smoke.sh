#!/usr/bin/env bash
set -euo pipefail

# LEGACY, NON-AUTHORITATIVE SMOKE ENTRY POINT. The active qualification runner is
# `live-qual.sh`, and the only independent teardown/absence verdict is `absence.py`
# invoked by `live-qual.sh verify` (matrix H6). This script's cleanup below reads
# only the EKS cluster and one VPC filter: that is a best-effort smoke convenience,
# NOT an H6 absence guarantee, and it must not be cited as one. Use
# `live-qual.sh verify` when the claim is "the target is gone".

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
TARGET="${TARGET:-qual2/aws/us-east-1}"
TARGET_FILE="$WORKSPACE/sol/environments.local.yml"
TFVARS="$ROOT/internal/qualification/aws/smoke-test.tfvars"
PROFILE="${AWS_PROFILE:?Set AWS_PROFILE to a profile that can reach the target AWS account}"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:?Set CLUSTER to the EKS cluster name for this run}"
LOG_DIR="${LOG_DIR:-/tmp/sol-aws-live-smoke-$(date +%Y%m%d-%H%M%S)}"

PHASE_TIMEOUT="${PHASE_TIMEOUT:-900}"

say() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }

source "$ROOT/internal/qualification/sol-under-test.sh"
sol_under_test_resolve

run() {
  local name="$1"; shift
  say "$name"
  if ! timeout "$PHASE_TIMEOUT" "$@" >"$LOG_DIR/$name.log" 2>&1; then
    say "FAILED: $name (last 40 lines)"
    tail -n 40 "$LOG_DIR/$name.log"
    exit 1
  fi
}

cleanup() {
  local rc=$?
  say "cleanup: target destroy"
  (cd "$WORKSPACE" && AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" "$SOL" destroy "$TARGET" --apply) >"$LOG_DIR/aws-destroy.log" 2>&1 || true
  say "cleanup: best-effort smoke check of the cluster and one VPC (not the H6 verdict)"
  AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >"$LOG_DIR/verify-eks.log" 2>&1 && rc=1 || true
  if AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" aws ec2 describe-vpcs --filters Name=tag:Name,Values="$CLUSTER" --query 'length(Vpcs)' --output text >"$LOG_DIR/verify-vpcs.log" 2>&1; then
    [ "$(cat "$LOG_DIR/verify-vpcs.log")" = "0" ] || rc=1
  fi
  if [ -n "${WROTE_TARGET:-}" ] && head -1 "$TARGET_FILE" 2>/dev/null | grep -qF "live-smoke.sh"; then
    rm -f "$TARGET_FILE"
  fi
  say "logs: $LOG_DIR"
  exit "$rc"
}

write_target() {
  if [ -e "$TARGET_FILE" ]; then
    say "using existing $TARGET_FILE (not written by this run; left in place)"
    return
  fi
  mkdir -p "$(dirname "$TARGET_FILE")"
  cat >"$TARGET_FILE" <<YAML
# Written by internal/qualification/aws/live-smoke.sh for $TARGET; removed on exit.
${TARGET%%/*}:
  targets:
    ${TARGET#*/}:
      cluster_name: $CLUSTER
      base_domain: smoke-test.invalid
      dns_zone_ownership: sol
      cluster_issuer: letsencrypt-staging
      letsencrypt_email: smoke-test@example.invalid
      terraform_var_file: $TFVARS
      resources:
        app_db:
          omit: true
        events:
          omit: true
      services:
        charge_svc:
          omit: true
        notify_worker:
          omit: true
YAML
  WROTE_TARGET=1
}

mkdir -p "$LOG_DIR"
sol_under_test_record_identity "$LOG_DIR"
say "sol-under-test: release $SOL_BUNDLE_VERSION at $SOL_INSTALL"
trap cleanup EXIT
write_target

# The whole-target deploy reconciles the durable installation inline, the cluster and the
# platform, then stops at the workloads this smoke publishes no images for -- the ECR
# repositories do not exist until the cluster root this deploy applies creates them. A first
# run's installation offer is confirmed through a pty. The platform readiness checks below
# decide the smoke, not the deploy's exit status.
deploy_whole_target() {
  local name="$1" registry="$2"
  say "$name"
  local command="cd '$WORKSPACE' && AWS_PROFILE='$PROFILE' AWS_REGION='$REGION' exec '$SOL' deploy '$TARGET' --registry '$registry' --image-tag 'smoke-$(date -u +%Y%m%d-%H%M%S)'"
  local rc=0
  if command -v script >/dev/null 2>&1; then
    printf 'y\n' | timeout "$PHASE_TIMEOUT" script -qec "$command" /dev/null >"$LOG_DIR/$name.log" 2>&1 || rc=$?
  else
    timeout "$PHASE_TIMEOUT" bash -c "$command" >"$LOG_DIR/$name.log" 2>&1 || rc=$?
  fi
  if [ "$rc" != 0 ]; then
    say "note: $name exited $rc (the smoke builds no workload images); the platform checks below decide"
    tail -n 40 "$LOG_DIR/$name.log"
  fi
}

ACCOUNT="$(AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ECR_REGISTRY:-$ACCOUNT.dkr.ecr.$REGION.amazonaws.com}"
deploy_whole_target aws-deploy "$REGISTRY"
run kubeconfig aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
run nodes kubectl get nodes -o wide
run pods kubectl get pods -A
run loki-ready bash -lc "kubectl -n monitoring port-forward svc/loki 3100:3100 >/tmp/sol-loki-pf.log 2>&1 & pid=\$!; sleep 5; curl -fsS http://127.0.0.1:3100/ready; kill \$pid"
run alloy-ingest bash -lc "kubectl -n monitoring port-forward svc/loki 3100:3100 >/tmp/sol-loki-pf2.log 2>&1 & pid=\$!; sleep 5; body=\$(curl -fsS --get 'http://127.0.0.1:3100/loki/api/v1/query_range' --data-urlencode 'query={namespace=\"kube-system\"}' --data-urlencode limit=1); kill \$pid; echo \"\$body\"; echo \"\$body\" | grep -q '\"result\":\[{' "
run prom-ready bash -lc "kubectl -n monitoring port-forward svc/prometheus-server 9090:80 >/tmp/sol-prom-pf.log 2>&1 & pid=\$!; sleep 5; curl -fsS http://127.0.0.1:9090/-/ready; kill \$pid"
run grafana-ready bash -lc "kubectl -n monitoring port-forward svc/grafana 3000:80 >/tmp/sol-grafana-pf.log 2>&1 & pid=\$!; sleep 5; curl -fsS http://127.0.0.1:3000/api/health; kill \$pid"

say "smoke checks passed"
