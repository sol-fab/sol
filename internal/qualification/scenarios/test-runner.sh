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
scenario_absence() { printf 'absence\n' >>"$CALLS"; printf 'all resources absent\n'; [ "${FAIL_ABSENCE:-0}" != 1 ]; }
scenario_plan() { printf 'plan\n' >>"$CALLS"; }
scenario_cleanup() { printf 'cleanup\n' >>"$CALLS"; [ "${FAIL_CLEANUP:-0}" != 1 ]; }
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

# Inventory must bracket execution, and absence must follow cleanup.
awk 'BEGIN{want=1} /^inventory$/{n++; if(n==1 && $0!="") first=NR} /^execute$/{if(n!=1) exit 1} /^inventory$/{if(n==2 && NR<ex) exit 1} END{if(n!=2) exit 1}' "$CALLS" || {
  echo "inventory was not recorded before and after execution" >&2; exit 1; }

# Cleanup failure is a scenario failure and absence is UNKNOWN.
rm -f "$CALLS"
if FAIL_CLEANUP=1 APPROVED=1 LOG_DIR="$tmp/log" ATTEMPT=test ATTEMPT_CLAIM=production \
  QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
  --scenario "$tmp/scenario.sh"; then
  echo "runner passed despite cleanup failure" >&2; exit 1
fi
grep -q '^cleanup=FAIL' "$tmp/log/cleanup-verdict.txt"
grep -q '^absence=UNKNOWN' "$tmp/log/cleanup-verdict.txt"

# Independent absence failure is a scenario failure even when cleanup succeeded.
rm -f "$CALLS"
if FAIL_ABSENCE=1 APPROVED=1 LOG_DIR="$tmp/log" ATTEMPT=test ATTEMPT_CLAIM=production \
  QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
  --scenario "$tmp/scenario.sh"; then
  echo "runner passed despite absence failure" >&2; exit 1
fi
grep -q '^cleanup=PASS' "$tmp/log/cleanup-verdict.txt"
grep -q '^absence=FAIL' "$tmp/log/cleanup-verdict.txt"

# A plan that rejects the candidate must not be reported as a successful plan.
cat >"$tmp/failing-plan.sh" <<'SCN'
scenario_plan() { return 1; }
SCN
if LOG_DIR="$tmp/log" ATTEMPT=test ATTEMPT_CLAIM=production \
  QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
  --scenario "$tmp/failing-plan.sh" --plan >/dev/null 2>&1; then
  echo "runner reported success for a failing plan" >&2; exit 1
fi
grep -q '^plan=FAIL$' "$tmp/log/plan-status.txt"

# Candidate rejection is caught before scenario plan and leaves explicit evidence.
mkdir -p "$tmp/reject-lib"
cat >"$tmp/reject-lib/attempt.sh" <<'LIB'
attempt_begin() { :; }
LIB
cat >"$tmp/reject-lib/sol-under-test.sh" <<'LIB'
sol_under_test_resolve() { return 2; }
LIB
if LOG_DIR="$tmp/log" ATTEMPT=test ATTEMPT_CLAIM=production \
  QUALIFICATION_LIB_DIR="$tmp/reject-lib" "$root/internal/qualification/scenarios/run.sh" \
  --scenario "$tmp/scenario.sh" --plan >/dev/null 2>&1; then
  echo "runner accepted a rejected candidate" >&2; exit 1
fi
grep -q '^reason=candidate-rejected$' "$tmp/log/plan-status.txt"
