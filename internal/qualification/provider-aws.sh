#!/usr/bin/env bash
# AWS hook implementations for the shared phase bodies.

# A target var file and an issuer must exist before anything is bound or built. This is
# AWS-specific: the target's Terraform variables are this provider's input.
hook_aws_prepare_precondition() {
  require_target_terraform_var_file || return 1
  require_target_issuer || return 1
}

hook_aws_prepare_bind() { candidate_bind; }

hook_aws_prepare_build() {
  app_build_images || return 1
  say "the run images are built; the cloud phase publishes them into the repositories Sol creates"
}

hook_aws_app_precondition() {
  require_target_terraform_var_file || return 1
  ensure_contexts || return 1
  verify_identity_boundary || return 1
  record_ca_submission_authority || return 1
}

# The images were built in `prepare` and published by `cloud` into the repositories the
# deploy created; `app` never builds or publishes. It refuses without those digests.
hook_aws_app_images() {
  app_require_published_images || return 1
  say "runner: release $SOL_BUNDLE_VERSION names $SOL_RUNNER_IMAGE; the publisher publishes nothing"
}

hook_aws_app_database_source() {
  capture_state
  local url
  url="$(jq -r '.outputs.postgres_url.value // empty' "$LOG_DIR/state/cloud.tfstate" 2>/dev/null)"
  if [ -z "$url" ]; then
    say "could not read the cluster root's postgres_url output, so the deploy's database setup has no master"
    return 1
  fi
  # The cluster root's postgres_url output is the *deploy's* input: the database setup
  # step derives <target>-ddl-creds / <target>-dml-creds from it. The harness records
  # the source redacted and never feeds the value to `sol secret set`.
  {
    printf 'database master source: the cluster root postgres_url output (never recorded in the clear)\n'
    printf 'Kafka authority: generated and delivered by Sol; independently compared after deploy\n'
  } >"$LOG_DIR/app-runtime-secrets.txt" 2>&1
}

hook_aws_app_bootstrap_deploy() {
  local image_ref_args="$1" ns
  # Deliberately not local: the transaction hook re-reads the namespaces the deploy
  # was expected to enter, which is the same set this step deployed into.
  deploy_namespaces="$APP_NS $WORKER_NS"
  say "deploy-substrate"
  for ns in $deploy_namespaces; do
    if kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get rolebinding sol-deploy -n "$ns" >/dev/null 2>&1; then
      say "  $ns: sol-deploy already bound (not a clean test of the substrate prerequisite)"
    else
      say "  $ns: no sol-deploy RoleBinding yet"
    fi
  done
  say "app-deploy-gate"
  # 2b's ordering on a fresh profiled target: `gates -> database_setup -> post_setup_gates`.
  # The first whole-target deploy reconciles the substrate, delivers the class
  # credentials in the database setup step, and then the post-setup migration gate
  # refuses to move workloads against an unapplied migration. That refusal is the
  # ordering claim, not an obstacle.
  if ! run app-deploy-gate bash -c "cd '$WORKSPACE' && exec '$SOL' deploy '$TARGET' --registry '$ECR_REGISTRY' $image_ref_args"; then
    if app_migration_gate_failure "$LOG_DIR/app-deploy-gate.log"; then
      say "  the deploy reconciled the substrate and delivered the class credentials, then refused to move workloads against an unapplied migration (expected)"
    else
      say "FAILED: the deploy did not reach the migration gate"
      return 1
    fi
  fi
}

hook_aws_app_secret_refusal() {
  # A distinct declaration-only specimen preserves the operator-input refusal claim
  # without treating generated Kafka credentials as operator inputs.
  bash "$ROOT/internal/qualification/application-secret-refusal.sh" "$SOL" \
    "$CLUSTER-deploy" "$(head -1 "$LOG_DIR/app-image-refs.txt" | cut -d= -f2-)" \
    "$LOG_DIR/application-secret-refusal.log" >>"$LOG_DIR/prerequisites.txt" || return 1
}

# The observation RoleBindings are namespace-scoped: the transport cannot bind them
# until Sol's first deploy has created the declared application namespaces. It is
# established after that deploy (which moves no workload) and before the migration
# step, so the CA family's migration observation has an independent read authority.
hook_aws_app_transport() {
  if [ "$TRANSPORT" = 1 ]; then
    phase_transport || return 1
  fi
}

hook_aws_app_authorities() {
  if [ "$TRANSPORT" = 1 ]; then
    CA_KUBECONFIG="$QUALIFIER_KUBECONFIG"
    CA_CONTEXT="$CLUSTER-qualifier"
  else
    CA_KUBECONFIG="$DEPLOY_KUBECONFIG"
    CA_CONTEXT="$CLUSTER-deploy"
  fi
  record_ca_authority || return 1
  say "app-deploy-migrate"
}

hook_aws_app_deploy() {
  local image_ref_args="$1"
  run app-deploy bash -c "cd '$WORKSPACE' && exec '$SOL' deploy '$TARGET' --registry '$ECR_REGISTRY' $image_ref_args" || return 1
}

# The final deploy reconciles namespaces and their RBAC. Re-establish the observation
# transport against the resulting namespaces before observing, so the CA/delivery
# reads never use a binding the deploy has just replaced.
hook_aws_app_post_deploy() {
  if [ "$TRANSPORT" = 1 ]; then
    phase_transport || return 1
    CA_KUBECONFIG="$QUALIFIER_KUBECONFIG"
    CA_CONTEXT="$CLUSTER-qualifier"
    record_ca_authority || return 1
  fi
}

# This provider's CA family report runs in the verify phase, which re-reads the durable
# captures; the app phase records the migration and application verdicts only.
hook_aws_app_ca_report() { return 0; }

hook_aws_app_transaction_primary() {
  local ns
  # ADR 0004: destruction removes what the lifecycle created, and the images this run
  # published live in the `pluto/<unit>` repositories Sol's own deploy created (#1413).
  for ns in $deploy_namespaces; do
    if ! kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get rolebinding sol-deploy -n "$ns" >/dev/null 2>&1; then
      say "the deploy completed into $ns without establishing its scoped deploy RBAC"
      return 1
    fi
  done
  say "  the deploy established the scoped deploy RBAC in every namespace it entered"
  if [ "$TRANSPORT" = 1 ]; then
    export KUBECONFIG_TRANSPORT="$QUALIFIER_KUBECONFIG"
    if ! run app-transaction bash "$ROOT/internal/qualification/aws/transport-transaction.sh" "$LOG_DIR"; then
      capture_kube_evidence
      return 1
    fi
  elif ! run app-transaction bash "$ROOT/internal/qualification/aws/app-transaction.sh" "$LOG_DIR"; then
    capture_kube_evidence
    return 1
  fi
}

# This provider runs one application transaction; the skeleton's Kafka observation
# follows it and there is no second language namespace to drive.
hook_aws_app_transaction_secondary() { return 0; }

hook_aws_app_evidence() {
  capture_kube_evidence
  capture_state
}

hook_aws_app_success() {
  say "the application transaction completed: the request was accepted, the worker consumed it, and"
  say "the service read the worker's effect back out of PostgreSQL through the qualification transport"
}

# AWS keeps the attempt's logs and evidence directory on failure; there is no frozen
# bundle to finalise here.
hook_aws_app_failed() { return 0; }

# Checked before TEARDOWN_ATTEMPTED is set by the skeleton: a destroy that cannot
# refresh its credentials must not record that a teardown was attempted.
hook_aws_destroy_precondition() { require_credentials; }

hook_aws_destroy_prestate() {
  if [ ! -f "$LOG_DIR/aws-pre-teardown-identities.json" ]; then
    say "independent identity capture is missing; teardown is blocked, not verified absent"
    return 1
  fi
  capture_independent_identities || return 1
}

# The teardown destination is selected explicitly, never inherited from the calling
# shell: a destroy that trusts the ambient kubeconfig can release another cluster's
# workloads (#1443).
hook_aws_destroy_kube_destination() { destroy_kube_destination; }

hook_aws_destroy_substrate() {
  # Capture the state the destroy is about to change, after the release destination
  # has been decided and before Sol runs.
  capture_state
  local destroy_rc=0
  run cloud-destroy bash -c "cd '$WORKSPACE' && exec '$SOL' destroy '$TARGET' --apply --var-file '$TFVARS'" || destroy_rc=$?
  if [ "$destroy_rc" = 0 ]; then
    say "destroy returned success; the independent inventory decides absence"
  else
    say "destroy exited non-zero; the independent inventory decides absence"
  fi
  return "$destroy_rc"
}

hook_aws_destroy_verdict() {
  local verdict_rc=0
  aws_inventory || verdict_rc=$?
  # Sol's repositories are the target's, so the independent inventory above decides
  # them: every `pluto/<unit>` repository this run published into must read ABSENT
  # after teardown. The run owns no repositories of its own (#1413).
  ecr_record_sol_repositories after-destroy
  if [ "$verdict_rc" != 0 ]; then
    say "the independent inventory does not read ABSENT, so teardown is not complete"
    return 1
  fi
}

# The identity and state captures above are the evidence; there is no bundle to freeze.
hook_aws_destroy_evidence() { return 0; }

hook_aws_cloud_precondition() {
  require_credentials || return 1
  require_target_terraform_var_file || return 1
  require_target_issuer || return 1
}

# This provider has no plan-only mode: the cloud phase always reconciles.
hook_aws_cloud_plan_only() { return 1; }
hook_aws_cloud_plan() { :; }

hook_aws_cloud_prestate() {
  capture_independent_identities --initial || return 1
  # A fixed repository name is not made fresh by a fresh target name, so record it on the way in.
  ecr_record_sol_repositories before
}

hook_aws_cloud_post_apply() { capture_independent_identities; }

hook_aws_cloud_not_reconciled() {
  say "the bootstrap deploy did not reconcile the environment $TARGET (full log $LOG_DIR/cloud-apply.log)"
}

hook_aws_cloud_not_refused() {
  say "the cold deploy reconciled the environment but did not refuse at the artifact gate"
  say "(expected 'Deployment incomplete.' in $LOG_DIR/cloud-apply*.log)"
}

hook_aws_cloud_pre_verify() { ensure_contexts; }

# No evidence bundle to freeze, and no separate diagnosis step: this provider's
# teardown reads the attempt directory and runs its own inventory.
hook_aws_cloud_freeze() { :; }
hook_aws_cloud_diagnose() { :; }
hook_aws_cloud_failed() { :; }

hook_aws_cloud_reconciled() {
  # Publish the images `prepare` built into the repositories the deploy just created,
  # then preview the whole target with the digests those pushes resolved to.
  app_push_images || return 1
  say "cloud-plan"
  local plan_image_refs plan_rc=0
  plan_image_refs="$(app_image_ref_args)"
  if [ -z "$plan_image_refs" ]; then
    say "the run published no image digests, so the whole-target preview has nothing to name"
    return 1
  fi
  if ! timeout "$PHASE_TIMEOUT" bash -c "cd '$WORKSPACE' && exec '$SOL' plan '$TARGET' --var-file '$TFVARS' $plan_image_refs" \
    >"$LOG_DIR/cloud-plan.log" 2>&1; then
    plan_rc=1
  fi
  if [ "$plan_rc" != 0 ]; then
    say "FAILED: cloud-plan (last 40 lines; full log $LOG_DIR/cloud-plan.log)"
    tail -n 40 "$LOG_DIR/cloud-plan.log"
    return 1
  fi
  run nodes kubectl --kubeconfig "$ACCESS_KUBECONFIG" get nodes -o wide || return 1
  capture_kube_evidence
  capture_state
  # Recorded, not asserted: whether the apply created them is Sol's business, and the
  # reading that matters is the one after teardown, which must be ABSENT.
  ecr_record_sol_repositories after
  say "the substrate and platform install completed; evidence in $LOG_DIR"
}
