#!/usr/bin/env bash
# Provider-neutral phase bodies. A phase owns ordering, verdicts and evidence; it
# names no provider and branches on none. Provider mechanics arrive through
# hook_${PROVIDER}_*.

# The prepare phase. The order is the contract:
#   precondition -> bind -> build.
#
# The binding is a step here, not a side effect of the build: the build helper may be
# called wherever a provider needs the run's images, and a binding inside it would bind
# again on the second call. What must hold before a binding is a provider's question
# (precondition), what it builds from the bound context is the provider's mechanic
# (build); that the binding happens once, before any build, is the phase's.
phase_prepare_run() {
  local hook="hook_${PROVIDER}"
  "${hook}_prepare_precondition" || return 1
  "${hook}_prepare_bind" || return 1
  "${hook}_prepare_build" || return 1
  say "prepare: candidate $SOL_REVISION is bound (candidate-binding.txt)"
}

# The cloud phase. The order is the contract:
#   precondition -> (plan-only shortcut) -> prestate -> apply -> post_apply
#   -> reconciled? -> artifact gate refused? -> pre_verify -> cold-start boundary
#   -> reconciled tail, with provider-specific failure capture on every failing path.
#
# `bootstrap_deploy` is the same call on both providers, and the deploy's exit code
# is deliberately not the verdict: a cold deploy is expected to stop at the artifact
# gate, so what decides the phase is that the environment reconciled and that the
# gate refused.
phase_cloud_run() {
  local hook="hook_${PROVIDER}"
  "${hook}_cloud_precondition" || return 1
  if "${hook}_cloud_plan_only"; then
    "${hook}_cloud_plan" || return 1
    return 0
  fi
  "${hook}_cloud_prestate" || return 1
  local deploy_rc=0
  bootstrap_deploy cloud-apply || deploy_rc=$?
  if cloud_mutated; then CLOUD_APPLIED=1; fi
  "${hook}_cloud_post_apply" || { "${hook}_cloud_failed"; return 1; }
  if ! environment_reconciled; then
    "${hook}_cloud_not_reconciled"
    # Freeze the evidence before anything heavy reads the cluster again: a read that
    # runs first would make the frozen bundle describe the state after the read, and
    # the ordering is a verdict rule, not a provider mechanic -- so it is a step here
    # (cloud_freeze) and not a line inside a hook that happens to get it right.
    "${hook}_cloud_freeze"
    "${hook}_cloud_diagnose"
    return 1
  fi
  if ! pending_artifacts_refused; then
    "${hook}_cloud_not_refused"
    "${hook}_cloud_failed"
    return 1
  fi
  "${hook}_cloud_pre_verify" || { "${hook}_cloud_failed"; return 1; }
  if ! cold_start_boundary; then
    "${hook}_cloud_failed"
    return 1
  fi
  "${hook}_cloud_reconciled" || { "${hook}_cloud_failed"; return 1; }
}
