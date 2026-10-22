#!/usr/bin/env bash
# GCP hook implementations for the shared phase bodies.

# Nothing has to hold before the binding: the candidate document, install and workspace
# the binding reads are validated by the binding itself, and the target check runs in the
# cloud phase. `prepare` therefore starts at the binding on this provider.
hook_gcp_prepare_precondition() { return 0; }

hook_gcp_prepare_bind() {
  local pins
  if ! pins="$(sol_candidate_bind_context "$WORKSPACE" "$SOL_REVISION" "$APP_BUILD_CONTEXT")"; then
    say "prepare: refusing to bind the application to candidate $SOL_REVISION"
    return 1
  fi
  if ! sol_candidate_record_binding "$LOG_DIR" "$SOL_REVISION" "$WORKSPACE" "$APP_BUILD_CONTEXT" "$pins" "$(git -C "$WORKSPACE" rev-parse HEAD)"; then
    say "prepare: the candidate binding could not be recorded (candidate-binding.txt)"
    return 1
  fi
}

# This provider builds and pushes the application images in the app phase, from the
# context `prepare` bound; `prepare` itself builds nothing.
hook_gcp_prepare_build() { return 0; }

hook_gcp_cloud_precondition() {
  write_target
  run cloud-check "$SOL" check || return 1
}

hook_gcp_cloud_plan_only() { plan_only; }

hook_gcp_cloud_plan() {
  local vars
  mapfile -t vars < <(cloud_vars)
  run cloud-plan "$SOL" plan "$TARGET" "${vars[@]}" || return 1
  say "PLAN_ONLY=1: no infrastructure mutation requested; durable setup skipped"
}

hook_gcp_cloud_prestate() { start_cluster_kubeconfig_waiter; }

hook_gcp_cloud_post_apply() { :; }

hook_gcp_cloud_not_reconciled() {
  INSTALL_STATE=failed
  say "the whole-target deploy did not reconcile the environment -- capturing the discriminator before any teardown"
}

# The freeze comes before the discriminate read, not after it: the bundle must
# describe the state as found, not the state after a heavy read has touched it.
hook_gcp_cloud_freeze() {
  capture_pre_teardown_inventory
  freeze_evidence
  finalise_bundle
}

hook_gcp_cloud_diagnose() { capture_platform_failure_evidence; }

hook_gcp_cloud_not_refused() {
  say "the cold deploy reconciled the environment but did not refuse at the artifact gate"
  say "(expected 'Deployment incomplete.' in $LOG_DIR/cloud-apply*.log)"
}

hook_gcp_cloud_pre_verify() {
  if [ ! -d "$APP_BUILD_CONTEXT" ]; then
    say "cloud: no candidate-bound build context at $APP_BUILD_CONTEXT; run prepare first"
    return 1
  fi
  return 0
}

hook_gcp_cloud_failed() {
  capture_pre_teardown_inventory
  freeze_evidence
  finalise_bundle
}

hook_gcp_cloud_reconciled() {
  INSTALL_STATE=succeeded
  capture_ready_evidence
  if [ ! -s "$LOG_DIR/nameservers.txt" ] && ! gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" \
    --format='value(nameServers)' >"$LOG_DIR/nameservers.txt" 2>"$LOG_DIR/nameservers.err"; then
    say "could not read the zone's nameservers -- the delegation half cannot proceed"
    return 1
  fi
  say "authoritative nameservers for $BASE_DOMAIN (paste these at Squarespace as NS records named 'qual-gcp'):"
  tr ';' '\n' <"$LOG_DIR/nameservers.txt" | sed 's/^/    /' 2>/dev/null || true
  capture_pre_teardown_inventory
  freeze_evidence
  finalise_bundle
  local deadline=$(( $(date +%s) + DELEGATION_WAIT_MINUTES * 60 ))
  say "waiting up to ${DELEGATION_WAIT_MINUTES}m for the delegation to resolve (Ctrl-C to continue later)"
  local ns_now
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ns_now="$(dns_ns "$BASE_DOMAIN")"
    if [ -n "$ns_now" ]; then
      say "delegation observed: $(printf '%s' "$ns_now" | tr '\n' ' ')"
      KEEP=1
      return 0
    fi
    sleep 15
  done
  say "delegation not observed within ${DELEGATION_WAIT_MINUTES}m."
  say "This is 'waiting on an external prerequisite', not a Sol failure: finish the NS"
  say "records at Squarespace, then run: CLUSTER=$CLUSTER ... live-qual.sh destroy"
  KEEP=1
  return 0
}
