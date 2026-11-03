#!/usr/bin/env bash
# Offline composition test: the provider-secret scenario is a valid scenario for the
# shared runner and --plan is non-mutating. No provider is contacted.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib" "$tmp/log"
cat >"$tmp/lib/attempt.sh" <<'LIB'
attempt_begin() { :; }
LIB
cat >"$tmp/lib/sol-under-test.sh" <<'LIB'
sol_under_test_resolve() { : "${SOL_CANDIDATE_REVISION:?}"; }
sol_under_test_record_identity() { :; }
LIB
candidate_revision="$(git -C "$root" rev-parse c6ec37e7)"
calls="$tmp/calls"
for provider in aws gcp; do
  output="$(
    PROVIDER="$provider" SOL_TARGET="prod/$provider/us-east-1" \
      QUAL_UNIT=probe/secret_probe_worker QUAL_PROBE_KEY=SOL_PROBE_SECRET \
      QUAL_REGISTRY=registry.example.test SOL_CLUSTER=qualification \
      QUAL_CLUSTER=qualification QUAL_REGION=us-east-1 QUAL_PROJECT=example-project \
      SOL_CANDIDATE_REVISION="$candidate_revision" \
      CALLS="$calls" LOG_DIR="$tmp/log" ATTEMPT="test-$provider" ATTEMPT_CLAIM=production \
      QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
      --scenario "$root/internal/qualification/secrets/$provider-scenario.sh" --plan
  )"
  printf '%s\n' "$output" | grep -F "Provider-backed secret scenario ($provider)" >/dev/null
  printf '%s\n' "$output" | grep -F 'Steps:' >/dev/null
  printf '%s\n' "$output" | grep -F 'Estimated live cost' >/dev/null
  [ ! -e "$calls" ] || { echo "plan contacted scenario prepare/execute/cleanup" >&2; exit 1; }
done
python3 "$root/internal/qualification/scenarios/test-catalog.py" >/dev/null
grep -q '"id": "provider-secrets-aws"' "$root/internal/qualification/scenarios/catalog.json"
grep -q '"id": "provider-secrets-gcp"' "$root/internal/qualification/scenarios/catalog.json"
echo "provider-secret scenario composes with the shared runner and catalog"

# A candidate built before #1915 is not a provider-backed secret candidate; --plan must
# refuse it before any live action. This is the same check a live run performs.
pre_feature="$(git -C "$root" rev-parse c6ec37e7^)"
if PLAN_OUTPUT="$(
  PROVIDER=aws SOL_TARGET="prod/aws/us-east-1" \
    QUAL_UNIT=probe/secret_probe_worker QUAL_PROBE_KEY=SOL_PROBE_SECRET \
    QUAL_REGISTRY=registry.example.test QUAL_CLUSTER=qualification QUAL_REGION=us-east-1 \
    SOL_CANDIDATE_REVISION="$pre_feature" \
    LOG_DIR="$tmp/log" ATTEMPT="test-pre-1915" ATTEMPT_CLAIM=production \
    QUALIFICATION_LIB_DIR="$tmp/lib" "$root/internal/qualification/scenarios/run.sh" \
    --scenario "$root/internal/qualification/secrets/aws-scenario.sh" --plan 2>&1
)"; then
  echo "a pre-#1915 candidate was accepted by the secret scenario" >&2
  exit 1
fi
printf '%s\n' "$PLAN_OUTPUT" | grep -q 'candidate=FAIL' || {
  echo "the pre-#1915 refusal did not name the candidate" >&2; exit 1; }

# The shared runner requires both canonical evidence functions before it will execute.
(
  export ROOT="$root" HERE="$root/internal/qualification/secrets" PROVIDER=aws
  export LOG_DIR="$tmp/log" SOL_TARGET="prod/aws/us-east-1"
  # shellcheck source=/dev/null
  source "$root/internal/qualification/secrets/scenario.sh"
  declare -F scenario_inventory >/dev/null
  declare -F scenario_absence >/dev/null
) || { echo "scenario lacks the canonical inventory/absence functions" >&2; exit 1; }
echo "provider-secret candidate and evidence-function checks passed"

# Declaration validation is offline: a durable target with the probe authority mapping is
# accepted, and a non-durable target is refused before any provider call.
mkdir -p "$tmp/decl/log"
cat >"$tmp/decl/env.yml" <<'YAML'
qual:
  targets:
    aws/us-east-1:
      shape: durable
      cluster_name: qual-secret
      registry: registry.example.test
      secrets:
        probe/secret_probe_worker:
          SOL_PROBE_SECRET:
            authority: sol
YAML
(
  export HERE="$root/internal/qualification/secrets"
  export ROOT="$root"
  export PROVIDER=aws
  export LOG_DIR="$tmp/decl/log"
  export SOL_TARGET="qual/aws/us-east-1"
  export QUAL_UNIT="probe/secret_probe_worker"
  export QUAL_PROBE_KEY="SOL_PROBE_SECRET"
  export QUAL_TARGET_FILE="$tmp/decl/env.yml"
  export QUAL_CLUSTER="qual-secret"
  export QUAL_REGION="us-east-1"
  # shellcheck source=/dev/null
  source "$root/internal/qualification/secrets/scenario.sh"
  scenario_setup_workspace
  scenario_write_contract
) >/dev/null 2>"$tmp/decl/err"
[ -s "$tmp/decl/log/target-facts.json" ] || { echo "durable declaration was not accepted" >&2; exit 1; }
[ -s "$tmp/decl/log/contract.txt" ] || { echo "contract binding was not written" >&2; exit 1; }
sed 's/shape: durable/shape: local/' "$tmp/decl/env.yml" >"$tmp/decl/local.yml"
if (
  export HERE="$root/internal/qualification/secrets" ROOT="$root" PROVIDER=aws
  export LOG_DIR="$tmp/decl/log-local" SOL_TARGET="qual/aws/us-east-1"
  export QUAL_UNIT="probe/secret_probe_worker" QUAL_PROBE_KEY="SOL_PROBE_SECRET"
  export QUAL_TARGET_FILE="$tmp/decl/local.yml" QUAL_CLUSTER="qual-secret" QUAL_REGION="us-east-1"
  # shellcheck source=/dev/null
  source "$root/internal/qualification/secrets/scenario.sh"
  scenario_setup_workspace
) >/dev/null 2>&1; then
  echo "a local target was accepted by the provider-secret scenario" >&2
  exit 1
fi
echo "provider-secret declaration validation passed"

# Cleanup ownership: a preflight refusal (no owned target/authority) must not destroy a
# target the scenario did not create; an interrupted owned target must be destroyed.
mkdir -p "$tmp/cleanup/log" "$tmp/cleanup/bin"
cat >"$tmp/cleanup/bin/sol" <<'SOL'
#!/bin/sh
printf '%s\n' "$*" >>"$CALLS"
SOL
chmod +x "$tmp/cleanup/bin/sol"
(
  export HERE="$root/internal/qualification/secrets" ROOT="$root" PROVIDER=aws
  export LOG_DIR="$tmp/cleanup/log" SOL_TARGET="qual/aws/us-east-1"
  export SOL="$tmp/cleanup/bin/sol" CALLS="$tmp/cleanup/calls"
  export QUAL_UNIT="probe/secret_probe_worker" QUAL_PROBE_KEY="SOL_PROBE_SECRET"
  export QUAL_TARGET_FILE="$tmp/decl/env.yml" QUAL_CLUSTER="qual-secret" QUAL_REGION="us-east-1"
  export SCENARIO_CLEANED=0 SCENARIO_OWNS_TARGET=0 SCENARIO_OWNS_AUTHORITY=0
  # shellcheck source=/dev/null
  source "$root/internal/qualification/secrets/scenario.sh"
  scenario_cleanup
) >/dev/null 2>"$tmp/cleanup/err1"
[ ! -s "$tmp/cleanup/err1" ] || cat "$tmp/cleanup/err1" >&2
[ ! -e "$tmp/cleanup/calls" ] || { echo "cleanup destroyed a target it did not own" >&2; exit 1; }
(
  export HERE="$root/internal/qualification/secrets" ROOT="$root" PROVIDER=aws
  export LOG_DIR="$tmp/cleanup/log" SOL_TARGET="qual/aws/us-east-1"
  export SOL="$tmp/cleanup/bin/sol" CALLS="$tmp/cleanup/calls-owned"
  export QUAL_UNIT="probe/secret_probe_worker" QUAL_PROBE_KEY="SOL_PROBE_SECRET"
  export QUAL_TARGET_FILE="$tmp/decl/env.yml" QUAL_CLUSTER="qual-secret" QUAL_REGION="us-east-1"
  export SCENARIO_CLEANED=0 SCENARIO_OWNS_TARGET=1 SCENARIO_OWNS_AUTHORITY=0
  # shellcheck source=/dev/null
  source "$root/internal/qualification/secrets/scenario.sh"
  hook_absence() { printf 'absence=PASS\n'; }
  scenario_cleanup
) >/dev/null 2>"$tmp/cleanup/err2"
[ ! -s "$tmp/cleanup/err2" ] || cat "$tmp/cleanup/err2" >&2
grep -q 'destroy qual/aws/us-east-1 --apply' "$tmp/cleanup/calls-owned" ||
  { echo "cleanup did not destroy an owned target" >&2; exit 1; }
echo "provider-secret cleanup ownership passed"

# The runner calls scenario_absence after cleanup; it must be the provider absence
# verdict, not a scenario-local duplicate of cleanup.
(
  export ROOT="$root" HERE="$root/internal/qualification/secrets" PROVIDER=aws
  export LOG_DIR="$tmp/cleanup/log" SOL_TARGET="qual/aws/us-east-1"
  # shellcheck source=/dev/null
  source "$root/internal/qualification/secrets/scenario.sh"
  hook_absence() { printf 'absence=PASS\nfull_inventory=ABSENT\n'; }
  scenario_absence
) >"$tmp/cleanup/absence-check.txt"
grep -q '^absence=PASS' "$tmp/cleanup/absence-check.txt" || {
  echo "scenario_absence did not return the provider verdict" >&2; exit 1; }
grep -q '^phase=verify exit=0$' "$tmp/cleanup/log/phase-verdicts.txt" || {
  echo "scenario_absence did not record the verify phase" >&2; exit 1; }
echo "provider-secret absence slot passed"
