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
sol_under_test_resolve
sol_under_test_record_identity "$LOG_DIR"
if [ "$PLAN" = 1 ]; then
  scenario_plan
  printf 'scenario plan: %s\n' "$SCENARIO"
  exit 0
fi
: "${APPROVED:?set APPROVED=1 only after live qualification is authorized}"
scenario_prepare
cleanup() { scenario_cleanup || true; }
trap cleanup EXIT
scenario_execute
scenario_assert
scenario_evidence >"$LOG_DIR/scenario-evidence.txt"
printf 'scenario passed: %s\n' "$SCENARIO"
if [ -n "${SOL_QUALIFICATION_EVALUATOR:-}" ]; then
  "$ROOT/internal/qualification/record.sh" \
    --provider "${PROVIDER:?set PROVIDER}" --attempt-dir "$LOG_DIR" \
    --candidate "$SOL_CANDIDATE" --auto --out "$LOG_DIR/record.json"
fi
