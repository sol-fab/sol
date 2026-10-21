#!/usr/bin/env bash
# Shared assertion shell for the qualification suites.
#
# This file is provider-neutral by construction: it may not name a provider and may
# not branch on one. Provider test cases stay in the provider's own suite file. A
# suite that needs its own failure context defines `test_case_diagnostics` before
# its first assertion; the shared semantics call it and do not know what it does.

# Deliberately NOT `-e`. These suites drive the harness into failures on purpose, so
# a shell option that aborts on the first non-zero would treat every scenario as a
# crash. Intent is declared instead: a command whose non-zero IS the scenario goes
# through `expect_failure`, which records the status as scenario data. A non-zero
# that no scenario claims is therefore unaccounted for, and the G4 guard requires
# every suite to prove it reports one.
set -uo pipefail

pass=0
fail=0

# Default: a suite without its own diagnostics still reports the failure itself.
test_case_diagnostics() { :; }

ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }

no() {
  printf '  [FAIL] %s\n           expected: %s\n           actual:   %s\n' "$1" "$2" "$3"
  fail=$((fail + 1))
  test_case_diagnostics
}

is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$3" "$2"; fi; }

has() {
  if grep -qF -- "$2" "$3" 2>/dev/null; then
    ok "$1"
  else
    no "$1" "contains: $2" "$(tr '\n' '|' <"$3" 2>/dev/null | cut -c1-200)"
  fi
}

lacks() { if grep -qF -- "$2" "$3" 2>/dev/null; then no "$1" "absent: $2" "present"; else ok "$1"; fi; }

present() { if [ -s "$1" ]; then ok "$2"; else no "$2" "present and non-empty" "missing: $1"; fi; }

not_exists() { if [ -e "$2" ]; then no "$1" "absent: $2" "present"; else ok "$1"; fi; }

exists() { if [ -f "$2" ]; then ok "$1"; else no "$1" "file exists: $2" "missing"; fi; }

# EXPECTED_RC carries the status of the most recent expected failure, so a scenario
# can assert on it (is "..." "$EXPECTED_RC" 2) without running the command twice.
EXPECTED_RC=""

# A scenario whose subject is a failure: <description> <output file> <command...>.
# The command's output and status are captured rather than printed, so the caller
# keeps both and the suite records that the failure was intended.
expect_failure() {
  local description="$1" out="$2"
  shift 2
  local rc=0
  "$@" >"$out" 2>&1 || rc=$?
  expect_failure_record "$description" "$rc"
}

# For a helper that captured the status itself (a pipeline, a backgrounded child),
# the capture is kept and only the recording is shared -- one place decides what an
# expected failure looks like, and no status is computed twice.
expect_failure_record() {
  local description="$1" rc="${2:-}"
  EXPECTED_RC="$rc"
  if [ -z "$rc" ]; then
    no "$description" "an exit status to record" "none was captured"
    return 1
  fi
  if [ "$rc" = 0 ]; then
    no "$description (expected a non-zero exit)" "non-zero" "exit 0"
    return 1
  fi
  ok "$description (exit $rc)"
}

# A scenario's declared outcome. The helpers return the harness status (the rc
# floor), so the expectation is stated where it is known instead of being re-derived
# from a .rc file by every scenario. EXPECTED_RC is left set for a scenario that also
# wants to name the exact code.
expect_success() {
  local description="$1"; shift
  local rc=0
  "$@" || rc=$?
  EXPECTED_RC="$rc"
  if [ "$rc" = 0 ]; then ok "$description (exit 0)"; else no "$description" "exit 0" "exit $rc"; fi
}

expect_failure() {
  local description="$1"; shift
  local rc=0
  "$@" || rc=$?
  EXPECTED_RC="$rc"
  if [ "$rc" != 0 ]; then ok "$description (exit $rc)"; else no "$description" "a non-zero exit" "exit 0"; fi
}

# Required-helper inventory for this file. A helper removed from here otherwise
# skips its assertions and can leave the suite green -- the #1610 defect class.
# A suite's own helpers are inventoried by that suite.
for helper in ok no is has lacks present not_exists exists test_case_diagnostics \
  expect_failure expect_failure_record expect_success; do
  if ! declare -F "$helper" >/dev/null; then
    echo "shared assertion helper missing: $helper" >&2
    exit 1
  fi
done
