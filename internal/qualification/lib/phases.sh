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

# The application phase. The order is the contract:
#   spent-attempt guard -> precondition -> contract pins -> images ready
#   -> database source -> immutable refs -> bootstrap deploy (its migration-gate
#   refusal accepted) -> secret refusal -> transport -> authorities -> migration CA
#   -> final deploy -> transport re-established -> application CA -> delivery
#   -> CA report -> primary transaction -> Kafka delivery -> secondary transaction
#   -> evidence -> success, with the provider's failure capture on every failing path.
#
# The images step is a hook because the providers' publication lifecycles differ, not
# by preference. GCP's cluster-named Artifact Registry exists only after the cloud
# phase, so GCP builds, pushes and resolves digests immediately before its digest-pinned
# deploy. AWS's ECR repositories are created in the cloud phase's reconciled tail, so it
# builds in `prepare` and only requires the published digests here. A shared step would
# still need provider hooks for the service list, image reference and registry.
#
# The skeleton still owns binding-before-build (`phase_prepare_run` calls bind before
# build) and that no deploy runs against a mutable tag: an empty immutable-ref list
# refuses the phase. If a provider's build ever stops being bound-first, the hook shape
# is the finding, not a reason to relax this order.
phase_app_run() {
  local hook="hook_${PROVIDER}"
  # A CA phase records one verdict per instance in the attempt's evidence store. A
  # second app run in the same attempt cannot record a second verdict; the attempt is
  # spent. Refuse with the supported paths instead of a store-level conflict.
  if [ -e "$LOG_DIR/ca-migration.json" ] || [ -e "$LOG_DIR/ca-application.json" ]; then
    say "attempt $ATTEMPT already recorded CA observations; an attempt's CA evidence cannot be re-recorded"
    say "for a diagnostic continuation: live-qual.sh resume with RESUME_FROM=$LOG_DIR and a new ATTEMPT/LOG_DIR"
    say "for a promotion-eligible verdict: restart the whole row in a fresh attempt (prepare through verify)"
    return 2
  fi
  "${hook}_app_precondition" || { "${hook}_app_failed"; return 1; }
  record_database_contract_pins || { "${hook}_app_failed"; return 1; }
  "${hook}_app_images" || { "${hook}_app_failed"; return 1; }
  "${hook}_app_database_source" || { "${hook}_app_failed"; return 1; }
  local image_ref_args
  image_ref_args="$(app_image_ref_args)"
  if [ -z "$image_ref_args" ]; then
    say "no immutable image refs were published, so the profile's artifact guarantee cannot be met"
    "${hook}_app_failed"
    return 1
  fi
  "${hook}_app_bootstrap_deploy" "$image_ref_args" || { "${hook}_app_failed"; return 1; }
  "${hook}_app_secret_refusal" || { "${hook}_app_failed"; return 1; }
  "${hook}_app_transport" || { "${hook}_app_failed"; return 1; }
  "${hook}_app_authorities" || { "${hook}_app_failed"; return 1; }
  ca_qualify migration "$LOG_DIR/ca-migration-capture.json" "$LOG_DIR/ca-migration.json" \
    "$(python3 -c 'import secrets; print(secrets.token_hex(32))')" \
    || { "${hook}_app_failed"; return 1; }
  "${hook}_app_deploy" "$image_ref_args" || { "${hook}_app_failed"; return 1; }
  "${hook}_app_post_deploy" || { "${hook}_app_failed"; return 1; }
  ca_qualify application "$LOG_DIR/ca-application-capture.json" "$LOG_DIR/ca-application.json" \
    || { "${hook}_app_failed"; return 1; }
  app_verify_database_delivery || { "${hook}_app_failed"; return 1; }
  "${hook}_app_ca_report" || { "${hook}_app_failed"; return 1; }
  "${hook}_app_transaction_primary" || { "${hook}_app_failed"; return 1; }
  app_verify_kafka_delivery || { "${hook}_app_failed"; return 1; }
  "${hook}_app_transaction_secondary" || { "${hook}_app_failed"; return 1; }
  "${hook}_app_success"
  # Evidence last: GCP's bundle finalisation must see the phase's closing output, and
  # its status is the phase's status, as it was before the extraction.
  "${hook}_app_evidence"
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

# The destroy phase. The order is the contract:
#   precondition -> prestate -> kube destination -> substrate destroy -> absence
#   verdict -> evidence.
#
# The destroy's exit code is deliberately not the verdict: a destroy can exit non-zero
# after removing the substrate, and it can exit zero while resources remain. The
# independent inventory decides absence. TEARDOWN_ATTEMPTED is set only once the
# preconditions and prestate have passed, so a destroy that cannot start is not
# recorded as attempted and a later inventory does not read as a failed teardown.
phase_destroy_run() {
  local hook="hook_${PROVIDER}"
  "${hook}_destroy_precondition" || return 1
  "${hook}_destroy_prestate" || return 1
  destroy_teardown_run
}

# The teardown sequence every destructive path uses: the scheduled phase and the
# cleanup path that runs when a phase failed before it could start a teardown. One
# sequence, so an emergency teardown cannot drift from the scheduled one.
destroy_teardown_run() {
  local hook="hook_${PROVIDER}"
  TEARDOWN_ATTEMPTED=1
  "${hook}_destroy_kube_destination" || return 1
  local destroy_rc=0
  "${hook}_destroy_substrate" || destroy_rc=$?
  "${hook}_destroy_verdict" || return 1
  "${hook}_destroy_evidence"
  return "$destroy_rc"
}
