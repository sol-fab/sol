#!/usr/bin/env bash
# #1428: `sol secret status` must report the readiness state deploy evaluates, without
# waiting.
#
# Deploy treats a Ready=True/SecretSynced ExternalSecret as ready only when
# status.syncedResourceVersion names the applied generation. Status used to inspect only
# the condition, so it printed "ready" for a Ready object carrying no generation-bound
# version — an observation deploy refuses. This drives the real CLI against a stub
# kubectl that returns raw ESO JSON and asserts the public status rows.
set -euo pipefail

sol="$(realpath "$1")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
note() {
  echo "test_secret_status_readiness: $1" >&2
  fail=1
}

mkdir -p "$tmp/workspace/app/payments/api_svc" "$tmp/workspace/sol" "$tmp/bin"
printf 'FROM scratch\n' >"$tmp/workspace/app/payments/api_svc/Dockerfile"
cat >"$tmp/workspace/app/payments/api_svc/sol.toml" <<'EOF'
[infra.env]
secrets = ["PAYMENT_KEY"]
EOF

cat >"$tmp/workspace/sol.yml" <<'EOF'
project: secret_status_readiness_test
services:
  api_svc:
    type: http
    path: app/payments/api_svc
    language: ocaml
EOF

cat >"$tmp/workspace/sol/environments.yml" <<'EOF'
prod:
  targets:
    aws/us-east-1:
      shape: local
      cluster_name: planned
      kube_context: planned
      state_bucket: sol-secret-status-readiness
      secrets:
        payments/api_svc:
          PAYMENT_KEY:
            authority: external
            store: payments-store
            key: payments/payment-key
      aws:
        state_lock_table: sol-secret-status-readiness-lock
EOF

# The stub returns raw ExternalSecret JSON for each ESO observation mode. It is the
# fixture, not the decision: the CLI parses and evaluates the same fields it reads in a
# cluster.
cat >"$tmp/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_LOG"
mode=$(cat "$KUBECTL_MODE")
case " $* " in
  *" get externalsecret "*)
    case "$mode" in
      eso-ready)
        printf '{"metadata":{"generation":2},"status":{"refreshTime":"2026-10-10T12:00:00Z","syncedResourceVersion":"2-abc","conditions":[{"type":"Ready","status":"True","reason":"SecretSynced"}]}}\n'
        ;;
      eso-no-synced-version)
        printf '{"metadata":{"generation":2},"status":{"refreshTime":"2026-10-10T12:00:00Z","conditions":[{"type":"Ready","status":"True","reason":"SecretSynced"}]}}\n'
        ;;
      eso-stale-version)
        printf '{"metadata":{"generation":3},"status":{"refreshTime":"2026-10-10T12:00:00Z","syncedResourceVersion":"2-abc","conditions":[{"type":"Ready","status":"True","reason":"SecretSynced"}]}}\n'
        ;;
      eso-not-synced)
        printf '{"metadata":{"generation":2},"status":{"refreshTime":"2026-10-10T12:00:00Z","syncedResourceVersion":"2-abc","conditions":[{"type":"Ready","status":"False","reason":"SecretSyncedError"}]}}\n'
        ;;
    esac
    ;;
  *" get secret api-svc-external-secrets "*)
    printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"api-svc-external-secrets","namespace":"workspace-payments"},"data":{"PAYMENT_KEY":"dmFsdWU="}}\n'
    ;;
  *" get secret "*)
    echo 'Error from server (NotFound): secrets "api-svc-secrets" not found' >&2
    exit 1
    ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/kubectl"

cd "$tmp/workspace"

run_status() {
  printf '%s\n' "$1" >"$tmp/mode"
  KUBECTL_LOG="$tmp/kubectl.log" KUBECTL_MODE="$tmp/mode" \
    PATH="$tmp/bin:$PATH" SOL_HOME="$(dirname "$sol")" \
    timeout 5 "$sol" secret status prod/aws/us-east-1 2>"$tmp/err"
}

expect_row() {
  mode=$1
  expected=$2
  : >"$tmp/kubectl.log"
  if ! output="$(run_status "$mode")"; then
    note "$mode: status failed: $(cat "$tmp/err")"
    return
  fi
  printf '%s\n' "$output" | grep -F "$expected" >/dev/null \
    || note "$mode: expected '$expected' in: $output"
  if [ "$mode" != eso-ready ] \
    && printf '%s\n' "$output" | grep -F 'state=ready' >/dev/null; then
    note "$mode: status reported ready for an observation deploy rejects: $output"
  fi
}

expect_row eso-ready 'state=ready (SecretSynced; refreshed 2026-10-10T12:00:00Z)'
expect_row eso-no-synced-version \
  'state=not ready (no generation-bound synced version: status.syncedResourceVersion is absent)'
expect_row eso-stale-version \
  'state=not ready (syncedResourceVersion 2-abc has not reached generation 3)'
expect_row eso-not-synced 'state=not ready (SecretSyncedError)'

[ "$fail" -eq 0 ] || exit 1
echo "secret status reports deploy's readiness state without waiting"
