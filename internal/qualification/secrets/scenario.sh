#!/usr/bin/env bash
# Live verification of provider-backed application secrets through the shared
# qualification runner.
#
# This is a FEATURE verification, not a release-promotion record: it binds the shared
# attempt/candidate identity and the canonical scenario/evidence contract, but the
# canonical release contract does not yet carry a provider-secret claim family. Do not
# attach its output as a release record until the parity/producer work adds that family.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/common.sh"
# shellcheck source=/dev/null
source "$HERE/${PROVIDER:?set PROVIDER to aws or gcp}.sh"

scenario_plan() {
  cat <<PLAN
Provider-backed secret scenario (${PROVIDER})
Target:            ${SOL_TARGET:-<unset>}
Probe unit/key:    ${QUAL_UNIT:-probe/secret_probe_worker}/${QUAL_PROBE_KEY:-SOL_PROBE_SECRET}
Probe image:       ${QUAL_PROBE_IMAGE:-built and pushed from internal/qualification/secrets/fixture}
Registry:          ${QUAL_REGISTRY:-<unset>}
Steps:             preflight, seed authority, cold deploy, grants apply, warm deploy,
                   projection and no-mirror assertions, rotation, grant revocation/restore,
                   missing-authority fail-closed, namespace recovery, destroy, absence.
Estimated live cost (list on-demand, 2-4h): AWS approximately USD 5-15; GCP approximately
USD 4-12. The estimate covers the target's EKS/GKE control plane, nodes, database, NAT,
disks and load balancer; it excludes image egress and operator time. Tear down on
completion or on any blocker; a stopped run still bills until teardown.
No mutation is performed by --plan.
PLAN
}

scenario_prepare() {
  require_env SOL_TARGET QUAL_TARGET_FILE QUAL_REGISTRY QUAL_CLUSTER QUAL_REGION
  scenario_setup_workspace
  scenario_write_contract
  hook_preflight || return 1
  scenario_build_probe_image || return 1
  scenario_record_phase prepare 0
}

scenario_execute() {
  scenario_seed_authority || return 1
  scenario_plan_json
  scenario_extract_plan
  hook_authority_metadata "$AUTHORITY_REFERENCE" || return 1
  scenario_cold_deploy || return 1
  scenario_apply_grants || return 1
  scenario_plan_json
  scenario_extract_plan
  scenario_warm_deploy || return 1
  hook_after_deploy || return 1
  scenario_assert_projection || return 1
  scenario_assert_no_mirror || return 1
  hook_assert_authorization allowed || return 1
  scenario_rotation || return 1
  scenario_revoke_and_restore || return 1
  scenario_missing_authority || return 1
  scenario_namespace_recovery || return 1
  scenario_destroy_and_absence || return 1
}

scenario_assert() {
  [ -s "$LOG_DIR/absence.txt" ] || scenario_die "absence evidence is missing"
  grep -q '^absence=PASS' "$LOG_DIR/absence.txt" || scenario_die "provider absence was not established"
  [ -s "$LOG_DIR/projection.json" ] || scenario_die "projection evidence is missing"
  [ -s "$LOG_DIR/kubernetes-secret-absence.txt" ] || scenario_die "no-mirror evidence is missing"
  [ -s "$LOG_DIR/rotation.json" ] || scenario_die "rotation evidence is missing"
  [ -s "$LOG_DIR/authorization.json" ] || scenario_die "authorization evidence is missing"
  [ -s "$LOG_DIR/missing-failclosed.log" ] || scenario_die "missing-authority evidence is missing"
  [ -s "$LOG_DIR/recovery.txt" ] || scenario_die "recovery evidence is missing"
  [ -s "$LOG_DIR/contract.txt" ] || scenario_die "contract binding is missing"
  grep -q '^scenario_contract=qualification-scenario/v1$' "$LOG_DIR/contract.txt" ||
    scenario_die "the scenario contract binding is missing"
  ! grep -q '^failed=' "$LOG_DIR/scenario-status.txt" ||
    scenario_die "a scenario step recorded a failure"
  return 0
}

scenario_evidence() {
  printf 'provider_backed_secrets: %s\n' "$PROVIDER"
  printf 'target: %s\n' "$SOL_TARGET"
  printf 'probe_unit: %s\n' "$QUAL_UNIT"
  printf 'evidence_class: behavioral\n'
  printf 'contract_binding: %s\n' "$LOG_DIR/contract.txt"
  printf 'phases: %s\n' "$LOG_DIR/phase-verdicts.txt"
  printf 'evidence:\n'
  for file in projection.json kubernetes-secret-absence.txt rotation.json \
    authorization.json missing-failclosed.log recovery.txt namespace-recovery.txt \
    absence.txt destroy.log; do
    [ -f "$LOG_DIR/$file" ] && printf '  %s\n' "$file"
  done
}

scenario_cleanup() {
  scenario_stop_port_forward
  # The success path calls destroy itself so absence is part of scenario_assert. This
  # trap is the interrupted/failed path; it still destroys and records what it observed,
  # but it cannot turn a failed run into a passing one.
  if [ "${SCENARIO_CLEANED:-0}" = 1 ]; then return 0; fi
  local rc=0
  if [ -n "${SOL:-}" ] && [ -n "${SOL_TARGET:-}" ]; then
    "$SOL" destroy "$SOL_TARGET" --apply >"$LOG_DIR/destroy.log" 2>&1 || rc=$?
  fi
  hook_absence "${AUTHORITY_REFERENCE:-}" >"$LOG_DIR/absence.txt" 2>&1 || rc=$?
  scenario_record_phase destroy "$rc"
  scenario_record_phase verify "$rc"
  SCENARIO_CLEANED=1
  return "$rc"
}
