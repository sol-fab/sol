#!/usr/bin/env bash
# Run one qualification scenario through the shared attempt/candidate/evidence
# contract. A scenario supplies only its preparation, execution, assertions,
# and cleanup; it does not own candidate resolution or attempt identity.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCENARIO=""
PLAN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scenario) SCENARIO="${2:?--scenario needs a path}"; shift 2 ;;
    --plan) PLAN=1; shift ;;
    *) printf 'run: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$SCENARIO" ] || { printf 'run: --scenario is required\n' >&2; exit 2; }
[ -f "$SCENARIO" ] || { printf 'run: scenario %s does not exist\n' "$SCENARIO" >&2; exit 2; }
# shellcheck source=/dev/null
source "${QUALIFICATION_LIB_DIR:-$ROOT/internal/qualification}/attempt.sh"
# shellcheck source=/dev/null
source "${QUALIFICATION_LIB_DIR:-$ROOT/internal/qualification}/sol-under-test.sh"
# shellcheck source=/dev/null
source "$SCENARIO"
: "${LOG_DIR:?set LOG_DIR to the attempt evidence directory}"
: "${ATTEMPT:?set ATTEMPT to a unique attempt identity}"
attempt_begin 0
if ! ( sol_under_test_resolve ); then
  printf 'plan=FAIL\nreason=candidate-rejected\nscenario=%s\n' "$SCENARIO" >"$LOG_DIR/plan-status.txt"
  exit 2
fi
sol_under_test_resolve
sol_under_test_record_identity "$LOG_DIR"
if [ "$PLAN" = 1 ]; then
  rc=0
  scenario_plan || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'plan=FAIL\nrc=%s\nscenario=%s\n' "$rc" "$SCENARIO" >"$LOG_DIR/plan-status.txt"
    printf 'scenario plan failed with status %s: %s\n' "$rc" "$SCENARIO" >&2
    exit "$rc"
  fi
  printf 'plan=PASS\nscenario=%s\n' "$SCENARIO" >"$LOG_DIR/plan-status.txt"
  printf 'scenario plan: %s\n' "$SCENARIO"
  exit 0
fi
: "${APPROVED:?set APPROVED=1 only after live qualification is authorized}"
declare -F scenario_inventory >/dev/null || { printf 'run: scenario must define scenario_inventory\n' >&2; exit 2; }
declare -F scenario_absence >/dev/null || { printf 'run: scenario must define scenario_absence\n' >&2; exit 2; }
cleanup() {
  local rc=$?
  if scenario_cleanup; then
    if scenario_absence >"$LOG_DIR/absence.txt" && [ -s "$LOG_DIR/absence.txt" ]; then
      printf 'cleanup=PASS\nabsence=PASS\n' >"$LOG_DIR/cleanup-verdict.txt"
    else
      printf 'cleanup=PASS\nabsence=FAIL\n' >"$LOG_DIR/cleanup-verdict.txt"
      rc=1
    fi
  else
    printf 'cleanup=FAIL\nabsence=UNKNOWN\n' >"$LOG_DIR/cleanup-verdict.txt"
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
scenario_prepare
scenario_inventory >"$LOG_DIR/inventory-before.txt"
scenario_execute
scenario_assert
scenario_inventory >"$LOG_DIR/inventory-after.txt"
scenario_evidence >"$LOG_DIR/scenario-evidence.txt"
printf 'scenario passed: %s\n' "$SCENARIO"
if [ -n "${SOL_QUALIFICATION_EVALUATOR:-}" ]; then
  "$ROOT/internal/qualification/record.sh" \
    --provider "${PROVIDER:?set PROVIDER}" --attempt-dir "$LOG_DIR" \
    --candidate "$SOL_CANDIDATE" --auto --out "$LOG_DIR/record.json"
fi
