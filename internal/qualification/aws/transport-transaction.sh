#!/usr/bin/env bash
# DEC-039 transport transaction for AWS; GCP has no qualifier principal, see #1616.
set -uo pipefail

LOG_DIR="${1:?usage: transport-transaction.sh LOG_DIR}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TRANSACTION="$(cd "$HERE/.." && pwd)/transaction.py"
KUBECONFIG_TRANSPORT="${KUBECONFIG_TRANSPORT:?Set KUBECONFIG_TRANSPORT to the qualification transport principal kubeconfig}"
APP_NS="${APP_NS:-pluto-payments}"
APP_SERVICE="${APP_SERVICE:-charge-svc}"
APP_PORT="${APP_PORT:-80}"
SCENARIO="${SCENARIO:-charges}"
PF_TIMEOUT="${PF_TIMEOUT:-30}"
READBACK_ATTEMPTS="${READBACK_ATTEMPTS:-12}"
READBACK_INTERVAL="${READBACK_INTERVAL:-5}"

PF_LOG="$LOG_DIR/transport-port-forward.log"
TRANSCRIPT="$LOG_DIR/transport-transaction.txt"
PF_PID=""

fail() {
  printf 'transport-transaction: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

read_forward_port() {
  local line rest
  while IFS= read -r line; do
    case "$line" in
      *"Forwarding from 127.0.0.1:"*)
        rest="${line#*Forwarding from 127.0.0.1:}"
        printf '%s' "${rest%% *}"
        return 0
        ;;
    esac
  done <"$PF_LOG"
  return 1
}

kubectl --kubeconfig "$KUBECONFIG_TRANSPORT" -n "$APP_NS" port-forward "svc/$APP_SERVICE" ":$APP_PORT" \
  >"$PF_LOG" 2>&1 &
PF_PID=$!

port=""
attempt=0
while [ -z "$port" ] && [ "$attempt" -lt "$PF_TIMEOUT" ]; do
  attempt=$((attempt + 1))
  port="$(read_forward_port 2>/dev/null || true)"
  [ -n "$port" ] || sleep 1
done
if [ -z "$port" ]; then
  printf 'transport-transaction: the port-forward never reported a local port; its output follows\n' >&2
  cat "$PF_LOG" >&2 2>/dev/null || true
  fail "the qualification transport did not open"
fi

URL="http://127.0.0.1:$port"
{
  printf 'transport: svc/%s in %s via kubeconfig %s\n' "$APP_SERVICE" "$APP_NS" "$KUBECONFIG_TRANSPORT"
  printf 'local endpoint: %s (resolved by the port-forward, never assumed)\n' "$URL"
} >"$TRANSCRIPT" 2>&1

# The runtime declares its operational endpoints in
# framework/ocaml/sol-svc/lib/service.ml: `/healthz` and `/readyz`. Probes here
# must name that endpoint rather than a path the service never serves.
health="$(curl -fsS -m 10 "$URL/healthz" 2>&1)" || fail "the service health endpoint was unreachable through the transport"
printf 'health: %s\n' "$health" >>"$TRANSCRIPT"

run_charges() {
  local charge id notifications i
  charge="$(curl -fsS -m 30 -X POST "$URL/charges" -H 'Content-Type: application/json' \
    -d '{"customer_id":"cus_qualification","amount_cents":4999,"currency":"usd"}' 2>&1)" ||
    fail "POST /charges failed"
  printf 'charge: %s\n' "$charge" >>"$TRANSCRIPT"
  id="$(printf '%s' "$charge" | python3 "$TRANSACTION" charge-id 2>>"$TRANSCRIPT")" ||
    fail "the charge response carried no usable id"
  printf 'charge id: %s\n' "$id" >>"$TRANSCRIPT"
  i=0
  while [ "$i" -lt "$READBACK_ATTEMPTS" ]; do
    i=$((i + 1))
    notifications="$(curl -fsS -m 20 "$URL/notifications" 2>/dev/null || true)"
    printf 'read-back attempt %s: %s\n' "$i" "$notifications" >>"$TRANSCRIPT"
    if printf '%s' "$notifications" | python3 "$TRANSACTION" charge-effect "$id" 2>>"$TRANSCRIPT"; then
      printf 'read-back: the worker effect is visible to the service\n' >>"$TRANSCRIPT"
      return 0
    fi
    sleep "$READBACK_INTERVAL"
  done
  return 1
}

run_orders() {
  local order_id placed served body i
  order_id="ord-$(date -u +%s)-$$"
  placed="$(curl -fsS -m 30 -X POST "$URL/orders" -H 'Content-Type: application/json' \
    -d "{\"order_id\":\"$order_id\",\"item\":\"widget\",\"quantity\":1}" 2>&1)" ||
    fail "POST /orders failed"
  printf 'order: %s\n' "$placed" >>"$TRANSCRIPT"
  served="$(printf '%s' "$placed" | python3 "$TRANSACTION" order-id 2>>"$TRANSCRIPT")" ||
    fail "the order response carried no usable order id"
  [ "$served" = "$order_id" ] ||
    fail "the order response carried $served, not the submitted $order_id"
  i=0
  while [ "$i" -lt "$READBACK_ATTEMPTS" ]; do
    i=$((i + 1))
    body="$(curl -fsS -m 20 "$URL/orders/$order_id" 2>/dev/null || true)"
    printf 'read-back attempt %s: %s\n' "$i" "$body" >>"$TRANSCRIPT"
    if printf '%s' "$body" | python3 "$TRANSACTION" order-effect "$order_id" 2>>"$TRANSCRIPT"; then
      printf 'read-back: the worker effect is visible to the service\n' >>"$TRANSCRIPT"
      return 0
    fi
    sleep "$READBACK_INTERVAL"
  done
  return 1
}

case "$SCENARIO" in
  charges)
    run_charges || fail "the worker's row never became visible to the service"
    ;;
  orders)
    run_orders || fail "the order never reached fulfilled or confirmed"
    ;;
  *)
    fail "unknown SCENARIO $SCENARIO (expected charges or orders)"
    ;;
esac

cat "$TRANSCRIPT"
exit 0
