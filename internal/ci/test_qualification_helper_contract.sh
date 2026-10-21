#!/usr/bin/env bash
# Every helper that runs the harness must return the harness's status.
#
# The suites' helpers are interleaved with their scenarios, so this test evaluates
# each helper's *real definition*, extracted from the suite file, against a stub
# harness that exits 3. Nothing is re-declared here: if a helper stops returning the
# captured status, the body this test evaluates stops returning it too, and the
# assertion goes red. That is what makes the rc floor proven rather than asserted.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck source=/dev/null
source "$root/internal/qualification/providers.sh"

pass=0
fail=0
ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }

extract() { # <file> <function> -- one-line functions included
  awk -v f="$2" '
    index($0, f "()") == 1 {
      if ($0 ~ /}[[:space:]]*$/) { print; exit }
      p = 1; print; next
    }
    p { print; if ($0 ~ /^}[[:space:]]*$/) exit }
  ' "$1"
}

# helper:args per provider. The stub harness exits 3, so a helper that returns the
# subprocess status returns 3.
# Only helpers whose provider setup the sandbox can supply are listed. The other
# five -- aws:run_transaction, gcp:run_case, gcp:run_case_without_a_phase,
# gcp:run_case_closed_stdout, gcp:run_case_sigterm -- return 127 here because they
# call provider setup functions this sandbox does not define, so a green result
# would mean nothing about them. They are covered when the scenario-level pilot
# (step 3, first task) runs them against the real suites; listed here so the gap is
# recorded rather than implied by absence.
declare -A helpers=(
  [aws]="run_row:one|run_phase:one cloud|run_phase_closed_stdout:one cloud|run_phase_sigterm:one TERM cloud"
)

for provider in "${PROVIDERS[@]}"; do
  suite="$root/internal/qualification/$provider/stubbed-qual-test.sh"
  if [ ! -f "$suite" ]; then
    no "$provider: suite $suite is missing"
    continue
  fi
  work="$(mktemp -d)"
  mkdir -p "$work/root/internal/qualification/$provider" "$work/tmp" "$work/logs" "$work/bin"
  # A harness that fails in a way no helper can mistake for success.
  printf '#!/usr/bin/env bash\nexit 3\n' >"$work/root/internal/qualification/$provider/live-qual.sh"
  chmod +x "$work/root/internal/qualification/$provider/live-qual.sh"

  listed="${helpers[$provider]:-}"
  [ -n "$listed" ] || continue
  IFS='|' read -ra entries <<<"$listed"
  for entry in "${entries[@]}"; do
    helper="${entry%%:*}"
    args="${entry#*:}"
    body="$(extract "$suite" "$helper")"
    if [ -z "$body" ]; then
      no "$provider: $helper is not defined in the suite"
      continue
    fi
    rc="$(bash -c '
      set -uo pipefail
      TMP="'"$work"'/tmp"; ROOT="'"$work"'/root"; LOG_DIR="'"$work"'/logs"
      ECR=x; ECR_REGISTRY=r; WORKSPACE=w; INSTALL=i; PUBLISHER_ROLE_ARN=p
      PHASE_TIMEOUT=5; AWS_REGION=us-east-1; KUBECONFIG_TRANSPORT=k; APP_NS=pluto-payments
      stub_prepare() { :; }; seed_independent_capture() { :; }; stub_published_refs() { :; }
      seed_database_specimen() { :; }; seed_attempt() { :; }; stub_cli() { :; }
      '"$body"'
      '"$helper $args"'; echo "RC=$?"
    ' 2>/dev/null | tail -1 | sed 's/RC=//')"
    if [ "$rc" = 3 ]; then
      ok "$provider: $helper returns the harness status (3)"
    else
      no "$provider: $helper returned ${rc:-nothing}, not the harness status (3)"
    fi
  done
  rm -rf "$work"
done

printf '\nhelper rc contract: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
