#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib" "$tmp/log"
cat >"$tmp/lib/attempt.sh" <<'LIB'
attempt_begin() { :; }
LIB
cat >"$tmp/lib/sol-under-test.sh" <<LIB
sol_under_test_resolve() { SOL="\${SOL_BIN:-$root/_build/default/cli/bin/main.exe}"; }
sol_under_test_record_identity() { :; }
LIB
LOG_DIR="$tmp/log" ATTEMPT=test ATTEMPT_CLAIM=production \
  QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
  --scenario "$root/internal/qualification/external-resources/gcp/phase1/scenario.sh" --plan \
  >"$tmp/plan.log"
grep -q 'sol check: ok' "$tmp/plan.log"
grep -q 'target=extqual-gcp-1/gcp/us-central1' "$tmp/plan.log"
# The shared runner records the canonical plan outcome; no scenario phase may
# write any other evidence in plan mode.
grep -qx 'plan=PASS' "$tmp/log/plan-status.txt"
[ "$(ls -A "$tmp/log")" = "plan-status.txt" ]
echo "GCP Phase 1 scenario plan composes without mutation"

# A candidate whose `sol check` rejects the fixture is not a ready candidate.
# Plan mode must fail closed instead of printing steps and recording PASS.
mkdir -p "$tmp/bin" "$tmp/fail-log"
cat >"$tmp/bin/sol" <<SOL
#!/bin/sh
if [ "\$1" = check ]; then
  echo 'sol check: FAILED' >&2
  exit 1
fi
exec "$root/_build/default/cli/bin/main.exe" "\$@"
SOL
chmod +x "$tmp/bin/sol"
if SOL_BIN="$tmp/bin/sol" LOG_DIR="$tmp/fail-log" ATTEMPT=test ATTEMPT_CLAIM=production \
  QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
  --scenario "$root/internal/qualification/external-resources/gcp/phase1/scenario.sh" --plan \
  >"$tmp/fail-plan.log" 2>&1; then
  echo "plan mode reported success although sol check failed" >&2
  exit 1
fi
grep -qx 'plan=FAIL' "$tmp/fail-log/plan-status.txt"
echo "GCP Phase 1 scenario plan fails closed on a rejected declaration"
