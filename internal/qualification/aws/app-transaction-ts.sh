#!/usr/bin/env bash
# Drive the TypeScript order path from inside the cluster.
#
# The Job only transports requests and prints their bodies with stable prefixes.
# The host owns the verdict through the same structural predicates the other
# qualification transactions use: the response must carry the submitted order
# identity and a later read-back must show the worker effect.
set -uo pipefail

LOG_DIR="${1:?usage: app-transaction-ts.sh LOG_DIR}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TRANSACTION="$(cd "$HERE/.." && pwd)/transaction.py"
NS="${TS_APP_NS:-pluto-demo-ts}"
SERVICE="${TS_SERVICE:-order-svc}"
JOB="row-transaction-ts-$(date -u +%H%M%S)-$$"
URL="http://$SERVICE.$NS.svc.cluster.local"
ORDER_ID="ord-ts-$(date -u +%s)-$$"
TRANSCRIPT="$LOG_DIR/app-transaction-ts.txt"
ATTEMPTS="${APP_READBACK_ATTEMPTS:-12}"
INTERVAL="${APP_READBACK_INTERVAL:-5}"

kubectl -n "$NS" get pods -o wide >"$LOG_DIR/app-pods-ts.txt" 2>&1 || exit 1
kubectl -n "$NS" get events --sort-by=.lastTimestamp >"$LOG_DIR/app-events-ts.txt" 2>&1 || true
kubectl -n "$NS" logs -l app.kubernetes.io/component=svc --tail=80 --all-containers=true \
  >"$LOG_DIR/app-svc-ts.log" 2>&1 || true
kubectl -n "$NS" logs -l app.kubernetes.io/component=worker --tail=80 --all-containers=true \
  >"$LOG_DIR/app-worker-ts.log" 2>&1 || true

cleanup() { kubectl -n "$NS" delete job "$JOB" --ignore-not-found >"$LOG_DIR/app-transaction-ts-cleanup.txt" 2>&1 || true; }
trap cleanup EXIT

kubectl -n "$NS" apply -f - >"$LOG_DIR/app-transaction-ts-job.txt" 2>&1 <<EOF || exit 1
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: transaction
          image: curlimages/curl:8.10.1
          command: ["sh", "-c"]
          args:
            - |
              set -e
              health=\$(curl -fsS -m 10 $URL/healthz)
              printf 'SOL_TRANSACTION_TS health %s\n' "\$health"
              order=\$(curl -fsS -m 30 -X POST $URL/orders -H 'Content-Type: application/json' -d '{"order_id":"$ORDER_ID","item":"widget","quantity":1}')
              printf 'SOL_TRANSACTION_TS order %s\n' "\$order"
              i=0
              while [ \$i -lt $ATTEMPTS ]; do
                i=\$((i + 1))
                readback=\$(curl -fsS -m 20 $URL/orders/$ORDER_ID 2>&1 || true)
                printf 'SOL_TRANSACTION_TS readback %s\n' "\$readback"
                sleep $INTERVAL
              done
EOF

complete=1
if ! kubectl -n "$NS" wait --for=condition=complete "job/$JOB" --timeout=300s \
  >"$LOG_DIR/app-transaction-ts-wait.txt" 2>&1; then
  complete=0
  kubectl -n "$NS" wait --for=condition=failed "job/$JOB" --timeout=10s \
    >>"$LOG_DIR/app-transaction-ts-wait.txt" 2>&1 || true
fi
pod="$(kubectl -n "$NS" get pods -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "$pod" ]; then
  kubectl -n "$NS" logs "$pod" >"$TRANSCRIPT" 2>&1 || true
fi

verdict_err="$LOG_DIR/app-transaction-ts-verdict.err"
: >"$verdict_err"
order_payload="$(sed -n 's/^SOL_TRANSACTION_TS order //p' "$TRANSCRIPT" 2>/dev/null | tail -1)"
if [ -z "$order_payload" ]; then
  echo "the TypeScript transaction produced no order response (complete=$complete)" >&2
  tail -20 "$TRANSCRIPT" 2>/dev/null >&2
  exit 1
fi
if ! served="$(printf '%s' "$order_payload" | python3 "$TRANSACTION" order-id 2>>"$verdict_err")"; then
  echo "the order response was not a usable order identity:" >&2
  cat "$verdict_err" >&2
  exit 1
fi
if [ "$served" != "$ORDER_ID" ]; then
  echo "the order response identified $served, not the submitted $ORDER_ID" >&2
  exit 1
fi
printf 'order id: %s\n' "$served" >>"$TRANSCRIPT"

visible=0
while IFS= read -r readback; do
  [ -n "$readback" ] || continue
  if printf '%s' "$readback" | python3 "$TRANSACTION" order-effect "$ORDER_ID" 2>>"$verdict_err"; then
    visible=1
    break
  fi
done <<EOF
$(sed -n 's/^SOL_TRANSACTION_TS readback //p' "$TRANSCRIPT" 2>/dev/null)
EOF

if [ "$visible" = 0 ]; then
  echo "the TypeScript transaction did not complete: no read-back showed order $ORDER_ID fulfilled" >&2
  cat "$verdict_err" 2>/dev/null >&2
  tail -20 "$TRANSCRIPT" 2>/dev/null >&2
  exit 1
fi
printf 'read-back: the worker effect %s is visible to the service\n' "$ORDER_ID" >>"$TRANSCRIPT"
exit 0
