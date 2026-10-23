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

# The bootstrap deploy's log name, which the database-declaration reader falls back to
# after the final deploy.
hook_aws_app_bootstrap_deploy_log() { printf '%s' "$LOG_DIR/app-deploy-gate.log"; }

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

# The AWS row's CA family report re-reads the durable captures after the delivery check;
# the app phase records the migration and application verdicts only.
hook_aws_app_ca_report() {
  ca_qualify report "" "$LOG_DIR/ca-report.json" || return 1
}

# The CA driver's scenario for this row. The candidate declaration does not carry a
# scenario, so the row's provider is the declaration of which scenario it exercises.
hook_aws_ca_scenario() { printf '%s' "$PROVIDER"; }

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
# workloads (#1443). DESTROY_KUBECONFIG is the attempt-owned path the skeleton set; this
# hook establishes that exact path and sets the classified outcome.
hook_aws_destroy_kube_destination() {
  local describe_err="$LOG_DIR/destroy-cluster-describe.err"
  DESTROY_CLUSTER_STATE=""
  DESTROY_KUBECONFIG_READY=0
  if aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" \
    >"$LOG_DIR/destroy-cluster-describe.json" 2>"$describe_err"; then
    DESTROY_CLUSTER_STATE=PRESENT
  elif grep -q 'ResourceNotFoundException' "$describe_err" 2>/dev/null; then
    DESTROY_CLUSTER_STATE=ABSENT
    DESTROY_CLUSTER_REASON="describe-cluster answered ResourceNotFoundException"
    return 0
  else
    DESTROY_CLUSTER_STATE=UNKNOWN
    DESTROY_CLUSTER_REASON="describe-cluster did not answer; see $describe_err"
    return 0
  fi
  # The cluster exists. Rebuild the attempt's own kubeconfig when it does not have one,
  # or has one that addresses a replaced cluster of the same name.
  if [ ! -f "$DESTROY_KUBECONFIG" ] || ! verify_kubeconfig_endpoint "$DESTROY_KUBECONFIG" >/dev/null 2>&1
  then
    if ! KUBECONFIG="$DESTROY_KUBECONFIG" aws eks update-kubeconfig --region "$AWS_REGION" \
      --name "$CLUSTER" --alias "$CLUSTER-deploy" --role-arn "$DEPLOY_ROLE_ARN" \
      >"$LOG_DIR/destroy-kubeconfig-refresh.log" 2>&1 \
      || ! verify_kubeconfig_endpoint "$DESTROY_KUBECONFIG" >/dev/null 2>&1; then
      DESTROY_CLUSTER_REASON="no credential available here addresses it"
      return 0
    fi
  fi
  DESTROY_KUBECONFIG_READY=1
}

hook_aws_destroy_kubernetes_answers() {
  timeout 60 kubectl --kubeconfig "$DESTROY_KUBECONFIG" --context "$CLUSTER-deploy" \
    auth can-i get namespaces >/dev/null 2>&1
}

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

# The cloud cold deploy. AWS builds in prepare and publishes in cloud before this deploy,
# so it names the published digests when they exist and nothing for a cold account whose
# artifact gate has not run yet. The app's workload-moving deploy pins digests separately.
hook_aws_cloud_cold_deploy() {
  local name="$1" image_ref_args
  say "$name"
  image_ref_args="$(app_image_ref_args)"
  local command="cd '$WORKSPACE' && exec '$SOL' deploy '$TARGET' --registry '$ECR_REGISTRY' $image_ref_args"
  if command -v script >/dev/null 2>&1; then
    printf 'y\n' | timeout "$PHASE_TIMEOUT" script -qec "$command" /dev/null \
      >"$LOG_DIR/$name.log" 2>&1
  else
    timeout "$PHASE_TIMEOUT" bash -c "$command" >"$LOG_DIR/$name.log" 2>&1
  fi
}

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

# The cold-start boundary, established from the cluster rather than inferred from the deploy log.
#
# The claim is "this deploy moved no workload and recorded no release". A namespaced workload or
# release cannot exist without its namespace, so the boundary is established by showing every
# namespace the target's selected units declare to be **positively absent**. Reading it this way
# is what makes the claim observable at this point in the lifecycle: an identity with no grant in
# the namespace is answered Forbidden for a namespaced read (RBAC is evaluated before namespace
# existence), which is exactly what the deploy identity is before it has deployed, so a list of
# Deployments is unreadable here and could never establish the claim (#1488).
#
# The observation runs under the cluster-access identity, and its view is validated before any
# absence is trusted: a namespace that must exist must be readable, and a name that cannot exist
# must answer NotFound rather than Forbidden. A view that answered NotFound because it is
# filtered could otherwise turn an unreadable look-up into a false boundary, and this observation
# gates a decision about a live target -- so it fails closed.
#
# What it establishes: no namespaced workload (Deployment/CronJob/Job/Rollout) and no
# `sol.dev/type=release` ConfigMap can exist in the declared namespaces. It does not establish
# anything about cluster-scoped objects, which the target's roots own and Sol's teardown removes;
# and a namespace that does exist makes the boundary UNKNOWN here rather than passing, because
# what it might contain cannot be read with the identities this row holds.
hook_aws_cloud_cold_start() {
  local names ns out err file="$LOG_DIR/cold-start-namespaces.txt"
  local probe="sol-nonexistent-namespace-probe-$ATTEMPT"
  local present=0 unknown=0
  names="$(cold_start_namespaces)" || return 1
  if ! timeout 60 kubectl --kubeconfig "$ACCESS_KUBECONFIG" get namespace kube-system -o name \
    >/dev/null 2>"$LOG_DIR/cold-start-namespaces-authority.err"; then
    say "UNKNOWN: the cluster-access identity's namespace view could not be established, so"
    say "whether a workload moved cannot be read (see cold-start-namespaces-authority.err)"
    return 1
  fi
  if timeout 60 kubectl --kubeconfig "$ACCESS_KUBECONFIG" get namespace "$probe" -o name \
    >/dev/null 2>"$LOG_DIR/cold-start-namespaces-absent-probe.err"; then
    say "UNKNOWN: the observation identity answered that $probe exists, so its namespace view"
    say "cannot establish absence"
    return 1
  fi
  if ! grep -q 'NotFound' "$LOG_DIR/cold-start-namespaces-absent-probe.err" 2>/dev/null; then
    say "UNKNOWN: a name that cannot exist did not answer NotFound, so the namespace view is"
    say "filtered -- a namespace that does exist would answer the same way, and absence cannot be"
    say "read from it (see cold-start-namespaces-absent-probe.err)"
    return 1
  fi
  {
    printf 'boundary_namespaces: %s\n' "$(printf '%s' "$names" | tr '\n' ' ')"
    printf 'boundary_identity: cluster-access (%s), view validated against kube-system and an absent name\n' \
      "$ACCESS_KUBECONFIG"
  } >"$file"
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    err="$LOG_DIR/cold-start-namespace-$ns.err"
    if out="$(timeout 60 kubectl --kubeconfig "$ACCESS_KUBECONFIG" get namespace "$ns" -o name 2>"$err")"; then
      printf 'cold-start-namespace: %s PRESENT (it may hold a workload or a recorded release)\n' \
        "$ns" >>"$file"
      present=$((present + 1))
    elif grep -q 'NotFound' "$err" 2>/dev/null; then
      printf 'cold-start-namespace: %s ABSENT\n' "$ns" >>"$file"
    else
      printf 'cold-start-namespace: %s UNKNOWN (%s)\n' \
        "$ns" "$(head -n 1 "$err" 2>/dev/null)" >>"$file"
      unknown=$((unknown + 1))
    fi
  done <<EOF
$names
EOF
  if [ "$unknown" != 0 ]; then
    say "$unknown declared namespace(s) could not be read, so whether a workload moved is UNKNOWN"
    say "  (see $file)"
    return 1
  fi
  if [ "$present" != 0 ]; then
    say "the cold deploy created a declared namespace before its immutable artifacts were published:"
    say "  $(grep ' PRESENT' "$file" | sed 's/^cold-start-namespace: //' | tr '\n' ' ')"
    say "whether it holds a workload or a recorded release cannot be established with the"
    say "identities this row holds at this point, so the boundary is UNKNOWN, never a pass"
    return 1
  fi
  say "the cold deploy moved no workload and recorded no release: every declared namespace"
  say "  ($(printf '%s' "$names" | tr '\n' ' ')) is positively absent"
}

hook_aws_disposable_state_present() {
  aws s3api head-object --bucket "$(target_state_bucket)" --key "$STATE_KEY" >/dev/null 2>&1
}
