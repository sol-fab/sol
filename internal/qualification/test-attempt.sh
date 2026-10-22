#!/usr/bin/env bash
# The shared attempt/evidence boundary: one attempt is one candidate and one
# specimen, and the run marker says which run wrote the files beside it
# (sol-fab/sol#1287).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }
no() {
  printf '  [FAIL] %s\n           expected: %s\n           actual:   %s\n' "$1" "$2" "$3"
  fail=$((fail + 1))
}
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1" "contains: $2" "$(tr '\n' '|' <"$3" 2>/dev/null | cut -c1-160)"; fi; }
lacks() { if grep -qF -- "$2" "$3" 2>/dev/null; then no "$1" "absent: $2" "present"; else ok "$1"; fi; }

STATE_PRESENT=1 # 0 = the disposable state key exists
hook_aws_disposable_state_present() { return "$STATE_PRESENT"; }
say() { :; }
# shellcheck source=attempt.sh
source "$HERE/attempt.sh"

# attempt_begin in a subshell with this case's identity and state, so its refusal
# (exit 2) is observable without ending the test.
begin() {
  local dir="$1" attempt="$2" revision="${3:-}" fresh="${4:-1}"
  (
    LOG_DIR="$dir" ATTEMPT="$attempt" ROW=qual PROVIDER=aws
    TARGET=qual/aws/us-east-1 STATE_KEY=sol/qual/cloud.tfstate CLUSTER=sol-qual
    SOL_CANDIDATE_REVISION="$revision" SOL_CANDIDATE_VERSION=v0.1.0-alpha.7
    attempt_begin "$fresh"
  )
}

printf '\nscenario: a fresh attempt records its identity and its specimen\n'
d="$TMP/fresh"
STATE_PRESENT=1 begin "$d" alpha7 "$(printf 'a%.0s' $(seq 1 40))" && ok "the fresh attempt is accepted" || no "the fresh attempt is accepted" "0" "$?"
has "the identity names the attempt" "attempt=alpha7" "$d/attempt.txt"
has "and the candidate it qualifies" "candidate_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$d/attempt.txt"
has "and the specimen it provisioned" "specimen=sol-qual" "$d/attempt.txt"
printf '\nscenario: an existing disposable state is not a fresh target\n'
d="$TMP/present"
STATE_PRESENT=0
if out="$(begin "$d" alpha7 "$(printf 'a%.0s' $(seq 1 40))" 1 2>&1)"; then
  no "an existing state key is refused as a fresh target" "non-zero" "0"
else
  ok "an existing state key is refused as a fresh target"
fi
case "$out" in
  *"already exists"*) ok "and the refusal says the state key exists" ;;
  *) no "and the refusal says the state key exists" "already exists" "$out" ;;
esac
if CONTINUE_ATTEMPT=1 begin "$d" alpha8 "$(printf 'a%.0s' $(seq 1 40))" 1 >/dev/null 2>&1; then
  ok "and an explicit continuation against it is allowed"
else
  no "and an explicit continuation against it is allowed" "0" "$?"
fi
printf '\nscenario: one attempt is one specimen\n'
d="$TMP/specimen"
mkdir -p "$d"
printf 'attempt=alpha7\ncandidate_revision=%s\nspecimen=sol-qual\n' "$(printf 'a%.0s' $(seq 1 40))" >"$d/attempt.txt"
STATE_PRESENT=1
if out="$(begin "$d" alpha7 "$(printf 'a%.0s' $(seq 1 40))" 2>&1)"; then
  no "a second specimen under one attempt is refused" "non-zero" "0"
else
  ok "a second specimen under one attempt is refused"
fi
case "$out" in
  *"one attempt is one specimen"*) ok "and the refusal says why" ;;
  *) no "and the refusal says why" "one attempt is one specimen" "$out" ;;
esac

printf '\nscenario: one attempt is one candidate\n'
d="$TMP/candidate"
mkdir -p "$d"
printf 'attempt=alpha7\ncandidate_revision=%s\nspecimen=sol-qual\n' "$(printf 'a%.0s' $(seq 1 40))" >"$d/attempt.txt"
STATE_PRESENT=1
if out="$(begin "$d" alpha7 "$(printf 'b%.0s' $(seq 1 40))" 2>&1)"; then
  no "an attempt reused for another candidate is refused" "non-zero" "0"
else
  ok "an attempt reused for another candidate is refused"
fi
case "$out" in
  *"one evidence directory belongs to one attempt and one candidate"*) ok "and the refusal names both" ;;
  *) no "and the refusal names both" "one evidence directory belongs to one attempt and one candidate" "$out" ;;
esac

printf '\nscenario: an evidence directory belongs to the attempt that wrote it\n'
d="$TMP/other"
mkdir -p "$d"
printf 'attempt=alpha6\n' >"$d/attempt.txt"
STATE_PRESENT=1
if out="$(begin "$d" alpha7 "$(printf 'a%.0s' $(seq 1 40))" 2>&1)"; then
  no "another attempt's evidence directory is refused" "non-zero" "0"
else
  ok "another attempt's evidence directory is refused"
fi
case "$out" in
  *"one evidence directory belongs to one attempt"*) ok "and the refusal names the recorded attempt" ;;
  *) no "and the refusal names the recorded attempt" "one evidence directory belongs to one attempt" "$out" ;;
esac

d="$TMP/unidentified"
mkdir -p "$d"
: >"$d/some-artifact.txt"
STATE_PRESENT=1
if begin "$d" alpha7 "$(printf 'a%.0s' $(seq 1 40))" >/dev/null 2>&1; then
  no "an unidentified non-empty directory is refused" "non-zero" "0"
else
  ok "an unidentified non-empty directory is refused"
fi

printf '\n'
if [ "$fail" != 0 ]; then
  printf 'test-attempt: %s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'test-attempt: %s passed\n' "$pass"
