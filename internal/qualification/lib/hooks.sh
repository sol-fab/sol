#!/usr/bin/env bash
# The hook contract. A phase calls hooks; a provider implements them. This file
# declares what every provider must supply, so a missing implementation is a
# load-time error rather than a mid-run 127 on a path nobody exercised.
#
# Every entry here must also be called from a shared lifecycle file (lib/phases.sh
# for phase hooks, attempt.sh for the attempt lifecycle): a declared hook nobody
# calls is dead weight, and check_harness_hooks.sh enforces both directions.

REQUIRED_HOOKS=(
  prepare_precondition
  prepare_bind
  prepare_build
  app_precondition
  app_images
  app_database_source
  app_bootstrap_deploy
  # The bootstrap deploy's log name is provider-specific; the database-declaration
  # reader prefers the final deploy and falls back to this path.
  app_bootstrap_deploy_log
  app_secret_refusal
  app_transport
  app_authorities
  app_deploy
  app_post_deploy
  app_ca_report
  app_transaction_primary
  app_transaction_secondary
  app_evidence
  app_success
  app_failed
  cloud_precondition
  cloud_plan_only
  cloud_plan
  cloud_prestate
  # The cloud cold deploy differs by publication lifecycle: AWS can name published
  # digests; GCP publishes in app, after cloud, so the cold deploy names its tag.
  cloud_cold_deploy
  cloud_post_apply
  cloud_not_reconciled
  cloud_not_refused
  cloud_pre_verify
  cloud_cold_start
  cloud_reconciled
  cloud_freeze
  cloud_diagnose
  cloud_failed
  destroy_precondition
  destroy_prestate
  destroy_kube_destination
  destroy_kubernetes_answers
  destroy_substrate
  destroy_verdict
  destroy_evidence
  # The CA request's scenario name; the candidate declaration does not carry one.
  ca_scenario
  # Exit-path lifecycle, called from lib/phases.sh cleanup_run.
  cleanup_stop_background
  cleanup_finish
  # Attempt lifecycle, called from attempt.sh rather than a phase body.
  disposable_state_present
)

# Called by live-qual.sh at startup and by the shared test shell: the process that
# will actually call the hooks validates the surface it was handed.
require_provider_hooks() {
  local hook
  if [ -z "${PROVIDER:-}" ]; then
    echo "the harness has no PROVIDER, so no hook surface can be checked" >&2
    return 1
  fi
  if ! declare -F "phase_prepare_run" >/dev/null || ! declare -F "phase_app_run" >/dev/null \
    || ! declare -F "phase_destroy_run" >/dev/null || ! declare -F "phase_cloud_run" >/dev/null; then
    echo "the shared phase bodies are not loaded (lib/phases.sh)" >&2
    return 1
  fi
  for hook in "${REQUIRED_HOOKS[@]}"; do
    if ! declare -F "hook_${PROVIDER}_${hook}" >/dev/null; then
      echo "provider ${PROVIDER} does not implement hook ${hook}" >&2
      return 1
    fi
  done
  return 0
}
