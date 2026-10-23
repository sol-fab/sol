#!/usr/bin/env bash
set -eo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$repo_root}"
export SOL_HOME="$GITHUB_WORKSPACE"
cd "$GITHUB_WORKSPACE"
mkdir -p "$SOL_HOME/.ci-bin"
ln -sf "$SOL_HOME/_build/default/cli/bin/main.exe" "$SOL_HOME/.ci-bin/sol"
export PATH="$SOL_HOME/.ci-bin:$PATH"
hash -r

sol new workspace ci_smoke
cd ci_smoke

# The workspace scaffold ships exactly one -svc plus one
# worker, and only -svc gets a ClusterIP Service -- so a real
# cross-namespace request needs a second service to call. Add a
# throwaway peer and declare the synchronous dependency on charge_svc
# (whose sol.toml is the shared template, so appending a [service]
# section is valid TOML).
sol new svc checkout/checkout
printf '\n[service]\ncalls = ["checkout/checkout_svc"]\n' >> app/payments/charge_svc/sol.toml

# No -fn app exists in the scaffold or examples
# yet, and this is the only place a real cluster is already up --
# add one here (rather than a whole new example app) to exercise
# scheduled_concurrency/backoff_limit rendering
# on a real deployed CronJob, in the same sol local deploy pass as everything
# else so this does not need its own health-wait cycle.
# `sol new fn` appends _fn to the given name itself (the same way
# `sol new svc checkout/checkout` above produced checkout_svc), so
# passing "heartbeat" here (not "heartbeat_fn") is what actually
# lands at app/ops/heartbeat_fn/ -- confirmed by this job's first
# real run, which instead produced app/ops/heartbeat_fn_fn/.
sol new fn ops/heartbeat
# [service] is already open at the top of the generated file (it
# holds `schedule`); appending a second [service] header at EOF
# would be a duplicate-table TOML error, so insert into the
# existing block instead, right after `schedule = ...`.
sed -i '/^schedule = /a scheduled_concurrency = "forbid"\nbackoff_limit = 5' \
  app/ops/heartbeat_fn/sol.toml

# The scaffold must pin the framework to the revision this binary was built
# from, not a moving branch. The images then build this PR's scaffold against
# this PR's framework, and the artifact under test is the artifact a user gets.
expected_pin="$(git rev-parse HEAD)"
if ! grep -rq "sol-fab/sol.git#${expected_pin}" --include='*.opam' .; then
  echo "::error::scaffolded workspace does not pin the framework to the build revision ${expected_pin}"
  grep -rn 'sol-fab/sol.git#' --include='*.opam' . || true
  exit 1
fi
if grep -rq 'sol-fab/sol.git#main' --include='*.opam' .; then
  echo "::error::scaffolded workspace still pins sol.git#main"; exit 1
fi

eval $(opam env)
dune build

# Each workload has its own ignored secret input. Keep the same key names
# separate so the fixture exercises unit-scoped delivery.
for unit in payments/charge_svc comms/notify_worker checkout/checkout_svc ops/heartbeat_fn; do
  mkdir -p "sol/secrets.local/${unit%/*}"
  cat >"sol/secrets.local/${unit}.env" <<'SECRETS'
POSTGRES_URL=postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev
SOL_API_KEY=dev-internal-key
SECRETS
done

first_deploy_log=$(mktemp)
if sol local deploy >"$first_deploy_log" 2>&1; then
  cat "$first_deploy_log"
  echo "::error::first deploy unexpectedly accepted pending migrations"
  exit 1
fi
cat "$first_deploy_log"
grep -Fq 'the required migration set is not applied' "$first_deploy_log"
rm -f "$first_deploy_log"
sol local migrate

sol local deploy

# `sol local deploy` installs ingress-nginx and forwards
# the controller to localhost:8088, so the Ingress `sol local deploy` generated
# for charge_svc must route a request end to end. A service with no
# declared ingress_host gets a per-service dev host
# (`<svc>.<ns>.localhost`), so send it as the Host header; derive the
# namespace from the cluster rather than assuming the
# workspace->namespace normalization.
ingress_ns=$(kubectl get ns -o name | sed 's|namespace/||' | grep -- '-payments$' | head -1 || true)
ingress_host="charge-svc.${ingress_ns}.localhost"
ingress_ok=0
for i in $(seq 1 30); do
  if curl -sf -H "Host: ${ingress_host}" "http://localhost:8088/health" >/dev/null; then
    echo "/health via ingress OK (Host: ${ingress_host})"
    ingress_ok=1
    break
  fi
  sleep 2
done
if [ "$ingress_ok" -ne 1 ]; then
  echo "::error::FEAT-042: /health never became reachable through the local ingress (Host: ${ingress_host})"
  exit 1
fi

# CODE_LAYER-022: verify the framework's runtime endpoints against a
# real deployed pod, not just the scaffolded /health route. /healthz
# and /metrics are registered by Sol_svc.Service, so a regression in
# that layer must fail this job rather than only showing up as a
# missing Grafana series later.
# Single source of truth for where probe() writes a response body.
# /metrics is read back below, so deriving this name in two places is
# how it came to disagree with what probe() actually wrote: `echo`
# appends a newline that tr turned into a trailing '_', leaving the
# body at /tmp/probe_metrics_.out while the check grepped
# /tmp/probe_metrics.out. printf keeps the derivation exact.
probe_out_path() {
  printf '/tmp/probe%s.out' "$(printf '%s' "$1" | tr -c '[:alnum:]' '_')"
}

probe() {
  local path=$1
  local out
  out=$(probe_out_path "$path")
  local i
  for i in $(seq 1 30); do
    if curl -sf "http://localhost:8080${path}" > "$out"; then
      echo "${path} OK"
      return 0
    fi
    sleep 2
  done
  echo "::error::golden-path smoke test: ${path} never became reachable"
  return 1
}

probe /health
probe /healthz
probe /metrics
if ! grep -Eq '# (HELP|TYPE)' "$(probe_out_path /metrics)"; then
  echo "::error::golden-path smoke test: /metrics did not return Prometheus text"
  exit 1
fi

# A declared call's network path is a pair of
# NetworkPolicies plus an injected peer URL. Assert that the deploy
# applied all three as rendered -- this covers resolution, rendering
# and apply end to end.
#
# Enforcement is deliberately NOT asserted against the live cluster
# here: the dev substrate's policy engine (kube-router on k3s v1.27.4)
# does not match `namespaceSelector` ingress rules for freshly created
# namespaces and ignores egress policy entirely, so an allow-probe is
# denied even though the policy is correct per the Kubernetes spec.
# The deterministic reproducer is in `cli/test/test_manifest_render.ml`;
# customer-cloud CNIs enforce it.
#
# Derive namespaces from the cluster rather than assuming the
# workspace->namespace normalization, so this keeps working if the
# naming rule changes.
caller_ns=$(kubectl get ns -o name | sed 's|namespace/||' | grep -- '-payments$' | head -1 || true)
peer_ns=$(kubectl get ns -o name | sed 's|namespace/||' | grep -- '-checkout$' | head -1 || true)
if [ -z "$caller_ns" ] || [ -z "$peer_ns" ]; then
  echo "::error::FEAT-041: could not locate caller ('$caller_ns') or peer ('$peer_ns') namespace"
  exit 1
fi

caller_env=$(kubectl -n "$caller_ns" get configmap charge-svc-env -o yaml 2>/dev/null || true)
for needle in "CHECKOUT_SVC_URL" "http://checkout-svc.${peer_ns}.svc.cluster.local"; do
  case "$caller_env" in
    *"$needle"*) ;;
    *) echo "::error::FEAT-041: caller ConfigMap is missing '$needle'"; exit 1 ;;
  esac
done

caller_np=$(kubectl -n "$caller_ns" get networkpolicy charge-svc-netpol -o yaml 2>/dev/null || true)
peer_np=$(kubectl -n "$peer_ns" get networkpolicy checkout-svc-netpol -o yaml 2>/dev/null || true)
for needle in "$peer_ns" "app: checkout-svc"; do
  case "$caller_np" in
    *"$needle"*) ;;
    *) echo "::error::FEAT-041: caller NetworkPolicy is missing '$needle'"; exit 1 ;;
  esac
done
for needle in "$caller_ns" "app: charge-svc" "port: 8080"; do
  case "$peer_np" in
    *"$needle"*) ;;
    *) echo "::error::FEAT-041: peer NetworkPolicy is missing '$needle'"; exit 1 ;;
  esac
done
echo "declared service-call wiring (env + NetworkPolicy pair) applied OK"

# A successful deploy must leave a content-addressed target release
# record, listed by `sol releases` and pointed at by the current-release
# object. The workload's `release` label has a separate identity: it is
# derived from that workload's effective spec so an unrelated target
# release does not change its Pod template. The manifest unit tests verify
# that derivation; this smoke test verifies the live label and target record.
sol local releases > "$GITHUB_WORKSPACE/releases.txt"
grep -F 'ID' "$GITHUB_WORKSPACE/releases.txt" >/dev/null
if [ "$(wc -l < "$GITHUB_WORKSPACE/releases.txt")" -lt 2 ]; then
  echo "::error::FEAT-067: sol local deploy recorded no release"
  exit 1
fi
listed_ids=$(awk 'NR>1 {print $1}' "$GITHUB_WORKSPACE/releases.txt" | tr '\n' ' ')

label_release=$(kubectl -n "$caller_ns" get deployment charge-svc -o jsonpath='{.spec.template.metadata.labels.release}' 2>/dev/null || true)
case "$label_release" in
  r-????????????????) ;;
  *) echo "::error::FEAT-069: workload release label '$label_release' is not a content-addressed release id"; exit 1 ;;
esac
pointer=$(kubectl -n default get configmap -l sol.dev/type=release-current,sol.dev/workspace=ci_smoke -o jsonpath='{.items[0].data.release_id}' 2>/dev/null || true)
case " ${listed_ids} " in
  *" ${pointer} "*) ;;
  *) echo "::error::FEAT-069: current-release pointer '$pointer' is not among the ids sol releases lists (${listed_ids})"; exit 1 ;;
esac
if [ "$pointer" = "$label_release" ]; then
  echo "::error::FEAT-069: workload release label uses the target-wide release id '$pointer'"
  exit 1
fi

release_cm="sol-release-${pointer}"
if ! kubectl -n default get configmap "$release_cm" >/dev/null 2>&1; then
  echo "::error::FEAT-069: current release ConfigMap '$release_cm' is missing"
  exit 1
fi
release_cm_immutable=$(kubectl -n default get configmap "$release_cm" -o jsonpath='{.immutable}' 2>/dev/null || true)
if [ "$release_cm_immutable" != "true" ]; then
  echo "::error::FEAT-067: release ConfigMap '$release_cm' is not immutable"
  exit 1
fi
if kubectl -n default patch configmap "$release_cm" -p '{"data":{"tampered":"1"}}' >/dev/null 2>&1; then
  echo "::error::FEAT-067: release ConfigMap was edited in place (immutable: true not honoured)"
  exit 1
fi
echo "target release is listed/current/immutable; workload carries independent release identity"

# `scheduled_concurrency` and `backoff_limit` render into the
# deployed CronJob, and remains available through the Kubernetes CronJob API. It needs no
# health-wait loop, unlike the HTTP-serving workloads above.
fn_ns=$(kubectl get ns -o name | sed 's|namespace/||' | grep -- '-ops$' | head -1 || true)
if [ -z "$fn_ns" ]; then
  echo "::error::FEAT-079: could not locate the heartbeat_fn namespace"
  exit 1
fi
fn_cronjob=$(kubectl -n "$fn_ns" get cronjob -o name | sed 's|cronjob.batch/||' | head -1 || true)
if [ -z "$fn_cronjob" ]; then
  echo "::error::FEAT-079: no CronJob found in namespace $fn_ns"
  exit 1
fi
fn_spec=$(kubectl -n "$fn_ns" get cronjob "$fn_cronjob" -o yaml)
case "$fn_spec" in
  *"concurrencyPolicy: Forbid"*) ;;
  *) echo "::error::FEAT-079: CronJob $fn_cronjob is missing concurrencyPolicy: Forbid"; exit 1 ;;
esac
case "$fn_spec" in
  *"backoffLimit: 5"*) ;;
  *) echo "::error::FEAT-079: CronJob $fn_cronjob is missing backoffLimit: 5"; exit 1 ;;
esac
echo "scheduled_concurrency/backoff_limit rendered into the deployed CronJob OK"

# Rendering the CronJob is not running the primitive. Invoke it once as a Job
# created from the CronJob, wait for completion, and prove the generated
# entrypoint actually ran and exited 0. This is the local behavioral evidence
# for -fn; the cloud CronJob evidence is separate.
fn_job="heartbeat-manual-$(date +%s)"
kubectl -n "$fn_ns" create job --from=cronjob/"$fn_cronjob" "$fn_job" >/dev/null
kubectl -n "$fn_ns" wait --for=condition=complete --timeout=120s "job/$fn_job" >/dev/null
fn_logs=$(kubectl -n "$fn_ns" logs "job/$fn_job")
case "$fn_logs" in
  *"[heartbeat-fn] running"*) ;;
  *) echo "::error::the manually invoked -fn did not run its entrypoint"; echo "$fn_logs"; exit 1 ;;
esac
echo "manual -fn invocation completed and ran its entrypoint OK"
