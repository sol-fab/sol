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

hook_gcp_app_precondition() {
  # The application row keeps its specimen: capture happens either way, and destroy is
  # a deliberate separate phase.
  KEEP=1
  KEEP_REASON="the application row keeps its specimen: capture happens either way, and destroy is a deliberate separate phase"
  APP_STATE=failed
  if [ ! -s "$RUN_KUBECONFIG" ]; then
    say "app: no run kubeconfig in $LOG_DIR — run the cloud phase first, which establishes it"
    exit 2
  fi
  write_app_target
  APP_BUILD_CONTEXT="$LOG_DIR/app-build-context"
  export APP_BUILD_CONTEXT
  if [ ! -d "$APP_BUILD_CONTEXT" ]; then
    say "app: no candidate-bound build context at $APP_BUILD_CONTEXT; run prepare first"
    return 1
  fi
}

# This provider's publication lifecycle is here: its cluster-named Artifact Registry
# exists only after the cloud phase, so the build and push run immediately before the
# digest-pinned deploy, in the same phase. `prepare` bound the context first.
hook_gcp_app_images() {
  say "app images build from candidate $SOL_REVISION ($WORKSPACE at that revision, framework pinned to it)"
  if ! run app-build bash -c "$(declare -f $(app_helpers)); build_app_images"; then
    return 1
  fi
  if ! run app-push bash -c "$(declare -f $(app_helpers)); push_app_images"; then
    return 1
  fi
  say "runner: release $SOL_BUNDLE_VERSION names $SOL_RUNNER_IMAGE; the publisher publishes nothing"
}

hook_gcp_app_database_source() { app_capture_database_source; }

hook_gcp_app_bootstrap_deploy() {
  local image_ref_args="$1"
  # Establish namespaces/database setup; a first deployment may stop at its migration
  # gate. Any other failure is not an accepted bootstrap outcome.
  if ! run app-deploy-bootstrap "$SOL" deploy "$TARGET" --registry "$(app_registry)" $image_ref_args; then
    grep -Fq 'the required migration set is not applied' "$LOG_DIR/app-deploy-bootstrap.log" || return 1
  fi
}

hook_gcp_app_secret_refusal() {
  bash "$ROOT/internal/qualification/application-secret-refusal.sh" "$SOL" \
    "$(app_kube_context)" "$(head -1 "$LOG_DIR/app-image-refs.txt" | cut -d= -f2-)" \
    "$LOG_DIR/application-secret-refusal.log" >>"$LOG_DIR/prerequisites.txt" || return 1
  printf 'scoped_out: "A deploy refuses to move workloads against an unapplied migration" (this row applies migrations before its steady-state deploy)\n' >>"$LOG_DIR/prerequisites.txt"
}

# This provider establishes its qualification transport in the cloud phase; the app
# phase has no separate transport setup or re-establishment.
hook_gcp_app_transport() { return 0; }

# The migration Job is submitted by the deploy identity, but its CA is read by a
# separate read-only identity. Record both authorities before the migration step so
# the shared launcher can validate the receipt without conflating them.
hook_gcp_app_authorities() {
  record_gcp_deploy_authority || return 1
  establish_gcp_ca_observer || return 1
}

hook_gcp_app_deploy() {
  local image_ref_args="$1"
  run app-deploy "$SOL" deploy "$TARGET" --registry "$(app_registry)" $image_ref_args || return 1
}

hook_gcp_app_post_deploy() { return 0; }

# The report re-reads the durable phase captures, candidate binding and recorded
# verdicts. A successful phase exit is not a family pass.
hook_gcp_app_ca_report() {
  ca_qualify report "" "$LOG_DIR/ca-report.json" || return 1
  {
    printf 'database_ca: the shared candidate-bound observer established the GCP application and migration CA family\n'
    printf 'database_ca_report: %s\n' "$LOG_DIR/ca-report.json"
    printf 'database_ca_observation_identity: %s\n' "$(authority_field "$LOG_DIR/ca-authority.json" principal)"
    printf 'database_ca_submission_identity: %s\n' "$(authority_field "$LOG_DIR/ca-deploy-authority.json" principal)"
  } >>"$LOG_DIR/prerequisites.txt"
}

hook_gcp_app_transaction_primary() {
  local rows="$LOG_DIR/alpha-rows.txt"
  : >"$rows"
  if ! run app-transaction-ocaml bash -c \
      "$(declare -f $(app_helpers)); app_orders_transaction pluto-payments orders-svc ocaml 18080"; then
    return 1
  fi
  printf 'OCaml\tB1\trun\tPOST /orders accepted the order and the response carried the submitted id\n' >>"$rows"
  printf 'OCaml\tB4\trun\tthe order read back as fulfilled or confirmed through the service\n' >>"$rows"
  printf 'OCaml\tB3\tnot-run\tthe relay row needs Kafka-topic inspection this HTTP phase does not perform\n' >>"$rows"
}

# The second language namespace: the skeleton observes Kafka delivery between the two
# transactions, so each namespace's rows are written beside its own transaction.
hook_gcp_app_transaction_secondary() {
  local rows="$LOG_DIR/alpha-rows.txt"
  if ! run app-transaction-ts bash -c \
      "$(declare -f $(app_helpers)); app_orders_transaction pluto-demo-ts order-svc ts 18081"; then
    return 1
  fi
  printf 'TypeScript\tB1\trun\tPOST /orders accepted the order and the response carried the submitted id\n' >>"$rows"
  printf 'TypeScript\tB4\trun\tthe order read back as fulfilled or confirmed through the service\n' >>"$rows"
  printf 'TypeScript\tB3\tnot-run\tthe relay row needs Kafka-topic inspection this HTTP phase does not perform\n' >>"$rows"
}

hook_gcp_app_evidence() { finalise_bundle; }

hook_gcp_app_success() {
  APP_STATE=succeeded
  say "the alpha orders scenario completed in both language namespaces: the OCaml orders-svc in"
  say "pluto-payments and the TypeScript order-svc in pluto-demo-ts each accepted an order and"
  say "read its fulfilment back through the transport; the rows each namespace ran are recorded"
  say "in alpha-rows.txt (B1 and B4 asserted; B3 needs broker inspection this phase does not do)"
}

# Every failing path freezes the evidence bundle before the phase returns, so the
# diagnostics describe the state as found rather than a state a later read changed.
hook_gcp_app_failed() {
  capture_app_evidence
  freeze_evidence
  finalise_bundle
}

hook_gcp_destroy_precondition() {
  write_target
  CLOUD_APPLIED=1
}

# The teardown inventory is taken and frozen before anything is destroyed, so the
# bundle describes the state the destroy found.
hook_gcp_destroy_prestate() {
  capture_pre_teardown_inventory
  freeze_evidence
  finalise_bundle
}

hook_gcp_destroy_kube_destination() { destroy_kube_destination; }

hook_gcp_destroy_substrate() {
  local vars
  mapfile -t vars < <(destroy_vars)
  say "teardown: sol destroy $TARGET"
  ( cd "$WORKSPACE" && "$SOL" destroy "$TARGET" --apply "${vars[@]}" ) \
    >"$LOG_DIR/destroy.log" 2>&1 || say "  (destroy exited non-zero; the verification below decides)"
  return 0
}

# The absence verdict stays the independent inventory's, and the process status is
# decided by cleanup from TEARDOWN_OK; the destroy's own exit code is not the verdict.
hook_gcp_destroy_verdict() {
  if verify_absent; then
    say "teardown verified: absent"
    TEARDOWN_OK=1
  else
    say "teardown NOT verified: resources remain — see $LOG_DIR/inventory-*.tsv and inventory-*.log"
    TEARDOWN_OK=0
  fi
  return 0
}

hook_gcp_destroy_evidence() {
  bundle_manifest
  verify_bundle || true
}

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
