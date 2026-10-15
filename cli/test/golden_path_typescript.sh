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

cd examples/pluto

# Unit-scoped ignored inputs allow different values for identical secret keys.
mkdir -p sol/secrets.local/demo_ts
for unit in order_svc fulfillment_worker; do
  cat >"sol/secrets.local/demo_ts/${unit}.env" <<'SECRETS'
POSTGRES_URL=postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev
SOL_API_KEY=dev-internal-key
SECRETS
done

# The first deploy establishes infrastructure, then refuses pending migrations
# before applying any workload. Check that boundary rather than accepting any error.
first_deploy_log=$(mktemp)
if sol local deploy --scope=demo_ts >"$first_deploy_log" 2>&1; then
  cat "$first_deploy_log"
  echo "::error::first deploy unexpectedly accepted pending migrations"
  exit 1
fi
cat "$first_deploy_log"
grep -Fq 'the required migration set is not applied' "$first_deploy_log"
grep -Fq 'sol local migrate' "$first_deploy_log"
rm -f "$first_deploy_log"
if [ -n "$(kubectl get deployments,statefulsets,jobs,cronjobs -n pluto-demo-ts -o name)" ]; then
  echo "::error::pending migrations must prevent workload application"
  exit 1
fi

# This must work with infrastructure alone: no successful workload deployment,
# workload namespace, or class Secret is a prerequisite for local migration.
sol local migrate
sol local deploy --scope=demo_ts

demo_ns=$(kubectl get ns -o name | sed 's|namespace/||' | grep -- '-demo-ts$' | head -1)

# fulfillment_worker subscribes with `fromBeginning: false`
# (app code, out of scope to change here). For a genuinely new
# consumer group -- exactly what a fresh cluster's first-ever
# deploy creates -- that means "start from the tail": a message
# produced before the group finishes joining is not delayed, it
# is invisible to it forever. This job's first real run hit
# exactly this: POST /orders succeeded at a timestamp 8.8s
# *before* the worker's own log showed "[ConsumerGroup] Consumer
# has joined the group", so the message landed in a topic no
# consumer had subscribed to yet, and no retry budget on the
# Postgres check downstream could ever have found it.
#
# A Kubernetes-level `kubectl wait --for=condition=ready` cannot
# establish this (verified experimentally, see git history on
# this file): the worker Deployment has no readiness probe, so
# that condition means "container started," nothing more. The
# only real signal is the application's own evidence that it
# joined -- so wait on that directly, the same "poll for the
# actual observed effect" pattern `probe()` below uses for HTTP.
# The wait itself must not be fragile. This step runs under
# `set -o pipefail`, and `kubectl logs ... | grep -q PATTERN`
# reports *no match* whenever PATTERN appears early in a stream
# larger than the pipe buffer: `grep -q` exits at the first match,
# kubectl keeps writing into a now-closed pipe, and pipefail
# propagates kubectl's SIGPIPE exit (141) out of the whole
# pipeline -- so the success case reads as a miss. Reproduced
# locally: a 2,000,000-line producer with the pattern on line 2
# returned NOMATCH. Capture the logs first, then match with a
# herestring, so no pipeline is involved and no exit status can
# come from anything but grep.
wait_for_consumer_join() {
  local i logs
  for i in $(seq 1 30); do
    logs=$(kubectl logs -n "$demo_ns" -l app=fulfillment-worker --all-containers 2>/dev/null || true)
    if grep -Fq '"message":"[ConsumerGroup] Consumer has joined the group","groupId":"sol-demo-ts-fulfillment-worker"' <<< "$logs"; then
      echo "fulfillment-worker consumer group joined OK"
      return 0
    fi
    sleep 2
  done
  echo "::error::TS golden-path smoke test: fulfillment-worker's consumer group never reported joining within the timeout"
  return 1
}
wait_for_consumer_join

probe() {
  local path=$1
  local i
  for i in $(seq 1 30); do
    if curl -sf "http://localhost:8080${path}" > /dev/null; then
      echo "${path} OK"
      return 0
    fi
    sleep 2
  done
  echo "::error::TS golden-path smoke test: ${path} never became reachable"
  return 1
}

probe /healthz

# One real transaction through the whole path: HTTP -> order_svc ->
# Kafka -> fulfillment_worker -> Postgres. Marker is unique per run
# so a re-run (or a flaky retry) can't misread a stale row from a
# previous attempt as this run's evidence. The request also carries a
# traceparent we chose, so the trace id is known in advance and can be
# asserted end to end below.
marker="ci-ts-golden-$(date +%s)-${RANDOM}"
trace_id=$(openssl rand -hex 16)
span_id=$(openssl rand -hex 8)
http_code=$(curl -s -o /tmp/order_response.json -w '%{http_code}' \
  -X POST http://localhost:8080/orders \
  -H 'Content-Type: application/json' \
  -H "traceparent: 00-${trace_id}-${span_id}-01" \
  -d "{\"order_id\":\"${marker}\",\"item\":\"widget\",\"quantity\":1}")
if [ "$http_code" != "202" ]; then
  echo "::error::TS golden-path smoke test: POST /orders returned $http_code, expected 202 ($(cat /tmp/order_response.json))"
  exit 1
fi
echo "POST /orders OK (202, marker=${marker}, trace=${trace_id})"

# fulfilled_orders_ts is one of the workspace's migrations now
# (db/migrations/0006_orders_ts.sql, applied by `sol local migrate`
# above); the units create nothing at runtime.
#
# POSTGRES_URL is the consumer's delivered credential: 2b delivers it from
# the target's DML class Secret, and the renderer's single routing decision
# (`secret_name_for_key`) points the pod's own `secretKeyRef` at
# `<target>-dml-creds`. `sol local deploy` treats the workspace as the local
# stand-in target (`Sol_cli_up_execution.local_plan`, `sanitize_name` of the
# workspace), so this workspace (`project: pluto`) gets `pluto-dml-creds` in
# the consumer's namespace. Read that Secret -- the credential the app
# itself reads -- not the unit's own `fulfillment-worker-secrets`, which no
# longer carries the key for a consumer, and not the Postgres Helm chart's
# internal secret path -- decoupled from that chart's own implementation,
# which this job has no reason to know about.
pg_url=$(kubectl get secret -n "$demo_ns" pluto-dml-creds -o jsonpath='{.data.POSTGRES_URL}' | base64 -d)
if [ -z "$pg_url" ]; then
  echo "::error::TS golden-path smoke test: the delivered class Secret pluto-dml-creds carries no POSTGRES_URL"
  exit 1
fi
pg_pod=$(kubectl get pods -n postgresql -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
row_found=0
# With the consumer-join wait above having closed the cold-start
# window, what remains is genuine in-flight latency (publish ->
# broker -> handler -> Postgres), so this stays an eventual
# assertion with an outer deadline rather than a fixed sleep.
# It is also the assertion that actually matters: the contract
# under test is "an accepted order is eventually fulfilled", not
# "Kafka group membership became ready". 90*2s=3min is a generous
# but bounded ceiling so CI cannot hang forever, not an assumption
# about how long startup should take.
for i in $(seq 1 90); do
  row=$(kubectl exec -n postgresql "$pg_pod" -- psql "$pg_url" -tAc \
    "SELECT order_id FROM fulfilled_orders_ts WHERE order_id = '${marker}';" 2>/dev/null || true)
  if [ "$row" = "$marker" ]; then
    row_found=1
    break
  fi
  sleep 2
done
if [ "$row_found" -ne 1 ]; then
  echo "::error::TS golden-path smoke test: order ${marker} never reached fulfilled_orders_ts (Kafka -> worker -> Postgres path did not complete)"
  exit 1
fi
echo "Postgres row for ${marker} confirmed OK -- HTTP -> Kafka -> worker -> Postgres path proven"

# The traceparent sent
# with that request must survive order_svc and the Kafka header, so
# the trace holds a span from each unit rather than two rooted traces.
# Asserted against Tempo's query API (the same store the demo's README
# tells a user to read), so an app that starts a fresh root trace --
# the pre-fix behaviour -- fails here. The service names are Sol's --
# the workload's bare Kubernetes name, not the app's own label --
# because `@sol-fab/obs` composes the injected identity.
trace_ok=0
for i in $(seq 1 30); do
  trace=$(curl -sf "http://localhost:3200/api/traces/${trace_id}" 2>/dev/null || true)
  services=$(jq -r '[.batches[].resource.attributes[]? | select(.key == "service.name") | .value.stringValue] | unique | .[]' <<< "$trace" 2>/dev/null || true)
  if grep -Fxq 'order-svc' <<< "$services" && grep -Fxq 'fulfillment-worker' <<< "$services"; then
    trace_ok=1
    break
  fi
  sleep 2
done
if [ "$trace_ok" -ne 1 ]; then
  echo "::error::TS golden-path smoke test: trace ${trace_id} did not span both order-svc and fulfillment-worker -- inbound trace context was not preserved"
  curl -s "http://localhost:3200/api/traces/${trace_id}" | head -c 500 || true
  exit 1
fi
echo "trace ${trace_id} spans order-svc and fulfillment-worker -- inbound trace context preserved"

# The framework, not the app, owns the semantic workload
# identity, so the trace resource carries every identity label the pod
# was injected with. Read the expected labels off the running pod
# rather than restating them, so a manifest that injects five (no
# release for a local target) is asserted as five.
order_pod=$(kubectl get pods -n "$demo_ns" -l app=order-svc -o jsonpath='{.items[0].metadata.name}')
expected_identity=$(kubectl exec -n "$demo_ns" "$order_pod" -- env 2>/dev/null \
  | grep -oE '^SOL_(WORKSPACE|ENV|DOMAIN|SERVICE|PRIMITIVE|RELEASE)=' \
  | sed -E 's/^SOL_//; s/=$//' | tr 'A-Z' 'a-z' | sort -u || true)
if [ -z "$expected_identity" ]; then
  echo "::error::TS golden-path smoke test: ${order_pod} carries none of the SOL_* identity variables, so OBS-051 cannot be verified"
  exit 1
fi
keys=$(jq -r '[.batches[].resource.attributes[]?.key] | unique | .[]' <<< "$trace" 2>/dev/null || true)
while IFS= read -r key; do
  [ -z "$key" ] && continue
  if ! grep -Fxq "$key" <<< "$keys"; then
    echo "::error::TS golden-path smoke test: the pod injects SOL_${key} but trace ${trace_id} has no '${key}' identity attribute (OBS-051)"
    curl -s "http://localhost:3200/api/traces/${trace_id}" | head -c 500 || true
    exit 1
  fi
done <<< "$expected_identity"
echo "trace ${trace_id} carries every Sol workload-identity label the pod injects"

# Coarse liveness check, not a reproduction of the forced-shutdown
# and redelivery experiments: a graceful pod delete
# must produce a clean replacement, not a CrashLoopBackOff.
order_pod=$(kubectl get pods -n "$demo_ns" -l app=order-svc -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n "$demo_ns" "$order_pod" --grace-period=30 --wait=false
replacement_ok=0
for i in $(seq 1 30); do
  new_pod=$(kubectl get pods -n "$demo_ns" -l app=order-svc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  phase=$(kubectl get pod "$new_pod" -n "$demo_ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  restarts=$(kubectl get pod "$new_pod" -n "$demo_ns" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)
  if [ -n "$new_pod" ] && [ "$new_pod" != "$order_pod" ] && [ "$phase" = "Running" ] && [ "$restarts" = "0" ]; then
    replacement_ok=1
    break
  fi
  sleep 2
done
if [ "$replacement_ok" -ne 1 ]; then
  echo "::error::TS golden-path smoke test: order-svc replacement pod did not come up cleanly after a graceful delete"
  exit 1
fi
echo "graceful pod delete OK -- clean replacement, 0 restarts"
