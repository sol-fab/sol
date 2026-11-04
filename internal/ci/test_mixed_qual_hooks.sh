#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/log"
export LOG_DIR="$work/log" WORKSPACE="$work/ws" TARGET="live/aws/us-east-1"
export APP_SERVICE="charge_svc" APP_NS="pluto-payments" MIXED_FN_UNIT="probe_fn"
export AWS_REGION="us-east-1" AWS_PROFILE="test" KUBECONFIG="$work/kubeconfig"
export TARGET_FILE="$work/target.yml" MIXED_UPDATE_REPLICAS=2
printf 'live:\n  targets:\n    aws/us-east-1:\n      execution: mixed\n      services:\n        charge_svc: {}\n        orders_svc: {}\n' >"$TARGET_FILE"
export RUN_KUBECONFIG="$work/kubeconfig" REGION="us-central1" PROJECT="test-project"
mkdir -p "$WORKSPACE"
: >"$KUBECONFIG"
say() { :; }
app_k8s_name() { printf '%s' "$1" | tr '_' '-'; }
mixed_set_replicas() { :; }

cat >"$work/bin/sol" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'sol %s\n' "$*" >>"$SOL_LOG"
if [ "${1:-}" = "deploy" ] && [[ "$*" == *mixed-bad-plan.json* ]]; then
  printf '%s\n' 'note: the serverless component was applied before the Kubernetes component failed; mixed-target apply is not atomic and did not roll the serverless component back. Re-run the same reviewed plan to converge.'
  exit 1
fi
if [ "${1:-}" = "plan" ]; then
  out=""
  prev=""
  for arg in "$@"; do
    [ "$prev" = "--out" ] && out="$arg"
    prev="$arg"
  done
  [ -n "$out" ] || exit 9
  printf '%s\n' '{"components":{"serverless":{},"kubernetes":{}},"changes":[{"action":"update"}]}' >"$out"
fi
exit 0
SH
cat >"$work/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *jsonpath=*replicas*) printf '2'; exit 0 ;;
  *) exit 0 ;;
esac
SH
cat >"$work/bin/aws" <<'SH'
#!/usr/bin/env bash
if [ -f "$AWS_STATE" ]; then
  printf '%s\n' '{"Configuration":{"FunctionName":"probe-fn"}}'
  exit 0
fi
printf '%s\n' 'An error occurred (ResourceNotFoundException) when calling the GetFunction operation: Function not found' >&2
exit 254
SH
cat >"$work/bin/gcloud" <<'SH'
#!/usr/bin/env bash
if [ -f "$GCP_STATE" ]; then
  printf '%s\n' '{"name":"probe-fn"}'
  exit 0
fi
printf '%s\n' 'ERROR: (gcloud.run.jobs.describe) NOT_FOUND: Resource not found' >&2
exit 1
SH
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH"
export SOL="$work/bin/sol" SOL_LOG="$work/sol.log" AWS_STATE="$work/aws-present" GCP_STATE="$work/gcp-present"
: >"$SOL_LOG"

# shellcheck source=/dev/null
source "$root/internal/qualification/provider-aws.sh"
# shellcheck source=/dev/null
source "$root/internal/qualification/provider-gcp.sh"

touch "$AWS_STATE"
hook_aws_app_mixed "--image-ref probe_fn=repo@sha256:aaaa"
grep -q 'plan live/aws/us-east-1' "$SOL_LOG"
grep -q 'deploy live/aws/us-east-1' "$SOL_LOG"
grep -q 'serverless=' "$LOG_DIR/mixed-evidence.txt"
if hook_aws_destroy_mixed_absent; then
  echo "AWS mixed absence accepted a present function" >&2
  exit 1
fi
rm -f "$AWS_STATE"
hook_aws_destroy_mixed_absent

touch "$GCP_STATE"
hook_gcp_app_mixed "--image-ref probe_fn=repo@sha256:aaaa"
grep -q 'plan live/aws/us-east-1' "$SOL_LOG"
grep -q 'serverless=' "$LOG_DIR/mixed-evidence.txt"
if hook_gcp_destroy_mixed_absent; then
  echo "GCP mixed absence accepted a present job" >&2
  exit 1
fi
rm -f "$GCP_STATE"
hook_gcp_destroy_mixed_absent

# MIXED=1 must name a target that actually selects mixed execution. A target
# still declaring kubernetes would send the function through the Kubernetes
# renderer, so the harness refuses before prepare.
cat >"$work/kubernetes-target.yml" <<'YAML'
live:
  targets:
    aws/us-east-1:
      execution: kubernetes
YAML
if MIXED=1 TARGET_FILE="$work/kubernetes-target.yml" require_mixed_target 2>"$work/kube.err"; then
  echo "MIXED=1 accepted a Kubernetes target" >&2
  exit 1
fi
grep -q 'declares execution: kubernetes' "$work/kube.err"
MIXED=1 TARGET_FILE="$TARGET_FILE" require_mixed_target
MIXED=0 TARGET_FILE="$work/kubernetes-target.yml" require_mixed_target
echo "mixed target disposition guard passed"

# The AWS cloud bootstrap deploy has no image digests yet, so a mixed target's
# serverless unit must be omitted for that deploy and restored for app.
cat >"$work/cloud-target.yml" <<'YAML'
live:
  targets:
    aws/us-east-1:
      execution: mixed
      services:
        probe_fn: {}
        orders_svc: {}
YAML
MIXED=1 TARGET_FILE="$work/cloud-target.yml" TARGET=live/aws/us-east-1 \
  mixed_omit_serverless_target
python3 - "$work/cloud-target.yml" <<'PY'
import sys, yaml
document = yaml.safe_load(open(sys.argv[1]))
target = document["live"]["targets"]["aws/us-east-1"]
assert target["execution"] == "mixed"
assert target["services"]["probe_fn"] == {"omit": True}, target["services"]
assert target["services"]["orders_svc"] == {}, target["services"]
PY
echo "mixed bootstrap omits the serverless component"

echo "mixed qualification hooks passed"
