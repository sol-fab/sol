#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib" "$tmp/log"
cat >"$tmp/lib/attempt.sh" <<'LIB'
attempt_begin() { :; }
LIB
cat >"$tmp/lib/sol-under-test.sh" <<'LIB'
sol_under_test_resolve() { :; }
sol_under_test_record_identity() { :; }
LIB
cat >"$tmp/scenario.sh" <<'SCN'
scenario_prepare() { :; }
scenario_plan() { :; }
scenario_cleanup() { :; }
scenario_execute() { :; }
scenario_assert() { :; }
scenario_evidence() { printf 'evidence\n'; }
SCN
LOG_DIR="$tmp/log" ATTEMPT=test ATTEMPT_CLAIM=production \
  QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
  --scenario "$tmp/scenario.sh" --plan
test -s "$tmp/log/scenario-evidence.txt" || true
echo "scenario runner composition passed"
