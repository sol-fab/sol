#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib" "$tmp/log"
cat >"$tmp/lib/attempt.sh" <<'LIB'
attempt_begin() { :; }
LIB
cat >"$tmp/lib/sol-under-test.sh" <<LIB
sol_under_test_resolve() { SOL="$root/_build/default/cli/bin/main.exe"; }
sol_under_test_record_identity() { :; }
LIB
LOG_DIR="$tmp/log" ATTEMPT=test ATTEMPT_CLAIM=production \
  QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
  --scenario "$root/internal/qualification/external-resources/gcp/phase1/scenario.sh" --plan \
  >"$tmp/plan.log"
grep -q 'sol check: ok' "$tmp/plan.log"
grep -q 'target=extqual-gcp-1/gcp/us-central1' "$tmp/plan.log"
[ -z "$(ls -A "$tmp/log")" ]
echo "GCP Phase 1 scenario plan composes without mutation"
