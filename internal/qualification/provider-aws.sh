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
