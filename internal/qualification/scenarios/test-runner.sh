#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib" "$tmp/log"
cat >"$tmp/lib/attempt.sh" <<'LIB'
attempt_begin() { printf 'attempt\n' >>"$CALLS"; }
LIB
cat >"$tmp/lib/sol-under-test.sh" <<'LIB'
sol_under_test_resolve() { printf 'resolve\n' >>"$CALLS"; }
sol_under_test_record_identity() { printf 'identity\n' >>"$CALLS"; }
LIB
cat >"$tmp/scenario.sh" <<'SCN'
scenario_prepare() { printf 'prepare\n' >>"$CALLS"; }
scenario_inventory() { printf 'inventory\n' >>"$CALLS"; }
scenario_absence() { printf 'absence\n' >>"$CALLS"; printf 'all resources absent\n'; }
scenario_plan() { printf 'plan\n' >>"$CALLS"; }
scenario_cleanup() { printf 'cleanup\n' >>"$CALLS"; }
scenario_execute() { printf 'execute\n' >>"$CALLS"; }
scenario_assert() { printf 'assert\n' >>"$CALLS"; }
scenario_evidence() { printf 'evidence\n'; }
SCN
export CALLS="$tmp/calls"
LOG_DIR="$tmp/log" ATTEMPT=test ATTEMPT_CLAIM=production \
  QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
  --scenario "$tmp/scenario.sh" --plan
grep -qx plan "$CALLS"
! grep -qx prepare "$CALLS"
rm -f "$CALLS"
APPROVED=1 LOG_DIR="$tmp/log" ATTEMPT=test ATTEMPT_CLAIM=production \
  QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
  --scenario "$tmp/scenario.sh"
grep -qx attempt "$CALLS"
grep -qx prepare "$CALLS"
grep -qx execute "$CALLS"
grep -qx assert "$CALLS"
grep -qx cleanup "$CALLS"
grep -qx absence "$CALLS"
test -s "$tmp/log/scenario-evidence.txt"
test -s "$tmp/log/absence.txt"
grep -q 'absence=PASS' "$tmp/log/cleanup-verdict.txt"
echo "scenario runner composition passed"
