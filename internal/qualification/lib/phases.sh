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

# Build the CA driver request for one phase from inputs the row recorded earlier. Nothing
# here is read from the product's own report. The scenario comes from the provider hook,
# because the candidate declaration carries none; the identity scope is derived from
# whether the observation kubeconfig is the independent qualifier's, not asserted; and
# the submission authority is the deploy identity that submitted the migration Job,
# recorded under one file name by both providers.
ca_request() {
  local phase="$1" capture="${2:-}" report="${3:-}" binding="${4:-}"
  local hook="hook_${PROVIDER}" scenario identity_scope
  local submission_authority="$LOG_DIR/ca-submission-authority.json"
  scenario="$("${hook}_ca_scenario")" || return 1
  if [ "$CA_KUBECONFIG" = "$QUALIFIER_KUBECONFIG" ]; then
    identity_scope=qualifier
  else
    identity_scope=deploy
  fi
  python3 - "$ROOT" "$SOL_CANDIDATE" "$SOL_INSTALL" "$WORKSPACE" "$LOG_DIR" \
    "$CA_KUBECONFIG" "$CA_CONTEXT" "$ATTEMPT" "$phase" "$capture" "$report" "$binding" \
    "$identity_scope" "$scenario" "$submission_authority" <<'PY'
import json, os, sys
(root, candidate, install, workspace, log, kubeconfig, context, attempt,
 phase, capture, report, binding, identity_scope, scenario, submission_authority) = sys.argv[1:16]
request = {
    "repository": root,
    "candidate": candidate,
    "install": install,
    "workspace": workspace,
    "pins": json.load(open(os.path.join(log, "database-contract-pins.json"))),
    "authority": json.load(open(os.path.join(log, "ca-authority.json"))),
    "kubeconfig": kubeconfig,
    "context": context,
    "identity_scope": identity_scope,
    "attempt": attempt,
    "assessment": "database-ca",
    "scenario": scenario,
    "evidence": os.path.join(log, "ca-evidence"),
    "phase": phase,
    "capture": capture,
    "report": report,
    "binding": binding,
    "migration_capture": os.path.join(log, "ca-migration-capture.json"),
    "application_capture": os.path.join(log, "ca-application-capture.json"),
}
if os.path.exists(submission_authority):
    request["submission_authority"] = json.load(open(submission_authority))
json.dump(request, open(os.path.join(log, "ca-request-" + phase + ".json"), "w"))
PY
}

# The deploy's own database declaration: the product prints `sol-database-identity:` when
# it reconciles the database. The final deploy's line is authoritative; the bootstrap
# deploy's log is the fallback, and its name is the provider's. Nothing here reconstructs
# the declaration.
app_database_declaration() {
  local hook="hook_${PROVIDER}" bootstrap log
  bootstrap="$("${hook}_app_bootstrap_deploy_log")" || return 1
  for log in "$LOG_DIR/app-deploy.log" "$bootstrap"; do
    [ -f "$log" ] || continue
    if grep -q 'sol-database-identity:' "$log"; then
      grep -h 'sol-database-identity:' "$log" | tail -1
      return 0
    fi
  done
}

# The Kafka delivery observation. The consumer map is harness-owned and NOT
# candidate-derived: the candidate's specimen declares database consumers, not the Kafka
# resource identity, so there is nothing in it to match these units against (criterion 5,
# a named defect; the observation fix remains deferred). The map and the ordering are
# shared; the observer invocation is the provider hook kafka_observe.
app_verify_kafka_delivery() {
  local hook="hook_${PROVIDER}" public credential unit
  local consumers=() behavioral=()
  for unit in $(app_services); do
    case "$unit" in
      charge_svc | orders_svc) consumers+=(--consumer "$APP_NS/$(app_k8s_name "$unit")") ;;
      notify_worker | fulfilment_worker) consumers+=(--consumer "$WORKER_NS/$(app_k8s_name "$unit")") ;;
      checkout_svc | order_svc | fulfillment_worker) ;;
      *)
        say "no Kafka qualification requirement defined for selected unit $unit"
        return 1
        ;;
    esac
  done
  for unit in ${KAFKA_BEHAVIORAL_UNITS:-}; do
    case "$unit" in
      charge_svc | orders_svc) behavioral+=(--behavioral-consumer "$APP_NS/$(app_k8s_name "$unit")") ;;
      notify_worker | fulfilment_worker) behavioral+=(--behavioral-consumer "$WORKER_NS/$(app_k8s_name "$unit")") ;;
    esac
  done
  if [ "${#behavioral[@]}" = 0 ]; then
    say "the selected units do not include the transaction's Kafka publisher and consumer"
    return 1
  fi
  credential="$(app_kafka_credential_name)"
  if [ -z "$credential" ]; then
    say "the deploy declared no delivered Kafka credential; the projection cannot be read"
    return 1
  fi
  public="$(jq -ce '.outputs.kafka_authority.value | select(type == "object")' \
    "$LOG_DIR/state/cloud.tfstate")" || return 1
  "${hook}_kafka_observe" "$public" "$credential" "${consumers[@]}" "${behavioral[@]}" \
    >"$LOG_DIR/kafka-delivery.json"
}

# The cloud phase. The order is the contract:
#   precondition -> (plan-only shortcut) -> prestate -> apply -> post_apply
#   -> reconciled? -> artifact gate refused? -> pre_verify -> cold-start boundary
#   -> reconciled tail, with provider-specific failure capture on every failing path.
#
# The cold deploy is the provider hook `cloud_cold_deploy`: its artifact shape follows the
# publication lifecycle. AWS can name the digests prepare built and cloud published; GCP
# publishes in app, after cloud, so its cold deploy names the tag it built. The deploy's
# exit code is deliberately not the verdict: a cold deploy is expected to stop at the
# artifact gate, so what decides the phase is that the environment reconciled and that the
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
  "${hook}_cloud_cold_deploy" cloud-apply || deploy_rc=$?
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
  if ! "${hook}_cloud_cold_start"; then
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

# The destroy destination. The attempt owns the kubeconfig path (ATTEMPT_KUBECONFIG):
# the destination hook establishes that exact path and returns a classified outcome
# (ABSENT, UNKNOWN, or PRESENT with the kubeconfig ready or blocked). The skeleton
# records the outcome and probes Kubernetes through the path before the substrate
# destroy. A destination that cannot be read never aborts the destroy: it is UNKNOWN,
# and the independent inventory still decides absence. #1633's app-side fix uses this
# same rule: the attempt owns the path; a provider hook establishes it or returns a
# classified failure.
destroy_kube_destination_run() {
  local hook="hook_${PROVIDER}"
  local record="$LOG_DIR/destroy-kubeconfig.txt"
  local empty="$LOG_DIR/kubeconfig-none.yaml"

  DESTROY_KUBECONFIG="${ATTEMPT_KUBECONFIG:-}"
  DESTROY_CLUSTER_STATE=""
  DESTROY_CLUSTER_REASON=""
  DESTROY_CLUSTER_ENDPOINT=""
  DESTROY_KUBECONFIG_READY=0

  if [ -z "$DESTROY_KUBECONFIG" ]; then
    DESTROY_CLUSTER_STATE=UNKNOWN
    DESTROY_CLUSTER_REASON="the attempt declares no kubeconfig path"
  elif ! "${hook}_destroy_kube_destination"; then
    DESTROY_CLUSTER_STATE=UNKNOWN
    DESTROY_CLUSTER_REASON="the destination hook did not complete"
  fi
  case "$DESTROY_CLUSTER_STATE" in
    ABSENT | UNKNOWN | PRESENT) ;;
    *)
      DESTROY_CLUSTER_STATE=UNKNOWN
      DESTROY_CLUSTER_REASON="the destination hook returned no classified state"
      ;;
  esac

  : >"$record"
  case "$DESTROY_CLUSTER_STATE" in
    ABSENT)
      : >"$empty"
      export KUBECONFIG="$empty"
      printf 'destroy_cluster: ABSENT (%s)\n' "$DESTROY_CLUSTER_REASON" >>"$record"
      printf 'destroy_kubeconfig: %s (empty: no context resolves)\n' "$KUBECONFIG" >>"$record"
      printf 'destroy_release_cleanup: skipped (the cluster is genuinely absent, so there is nothing to release from)\n' >>"$record"
      say "teardown: the cluster $CLUSTER is absent, so the workload release is skipped -- nothing to release from"
      ;;
    UNKNOWN)
      : >"$empty"
      export KUBECONFIG="$empty"
      printf 'destroy_cluster: UNKNOWN (%s)\n' "$DESTROY_CLUSTER_REASON" >>"$record"
      printf 'destroy_release_cleanup: blocked (the cluster could not be read) -- UNKNOWN, not skipped\n' >>"$record"
      say "teardown: could not read whether $CLUSTER exists, so whether the workloads were released is UNKNOWN"
      say "  the destroy still runs and the independent inventory still decides absence"
      ;;
    PRESENT)
      if [ "$DESTROY_KUBECONFIG_READY" != 1 ]; then
        : >"$empty"
        export KUBECONFIG="$empty"
        printf 'destroy_cluster: PRESENT\n' >>"$record"
        printf 'destroy_kubeconfig: %s (could not be established; see destroy-kubeconfig-refresh.log)\n' "$DESTROY_KUBECONFIG" >>"$record"
        printf 'destroy_release_cleanup: blocked (%s) -- UNKNOWN, not skipped\n' \
          "${DESTROY_CLUSTER_REASON:-no credential available here addresses it}" >>"$record"
        say "teardown: could not establish a kubeconfig that addresses $CLUSTER, so whether the workloads were released is UNKNOWN"
        return 0
      fi
      export KUBECONFIG="$DESTROY_KUBECONFIG"
      printf 'destroy_cluster: PRESENT\n' >>"$record"
      printf 'destroy_kubeconfig: %s (verified against the cluster current endpoint)\n' "$DESTROY_KUBECONFIG" >>"$record"
      if "${hook}_destroy_kubernetes_answers"; then
        printf 'destroy_release_cleanup: attempted (Kubernetes answered at the cluster endpoint, so Sol releases the workloads before the substrate)\n' >>"$record"
        say "teardown: releasing the workloads through this attempt's kubeconfig $DESTROY_KUBECONFIG"
      else
        printf 'destroy_release_cleanup: blocked (the cluster exists and the kubeconfig addresses it, but Kubernetes did not answer) -- UNKNOWN, not skipped\n' >>"$record"
        say "teardown: Kubernetes did not answer through this attempt's kubeconfig, so whether the workloads were released is UNKNOWN"
      fi
      ;;
  esac
}

# The teardown sequence every destructive path uses: the scheduled phase and the
# cleanup path that runs when a phase failed before it could start a teardown. One
# sequence, so an emergency teardown cannot drift from the scheduled one.
destroy_teardown_run() {
  local hook="hook_${PROVIDER}"
  TEARDOWN_ATTEMPTED=1
  destroy_kube_destination_run
  local destroy_rc=0
  "${hook}_destroy_substrate" || destroy_rc=$?
  "${hook}_destroy_verdict" || return 1
  "${hook}_destroy_evidence"
  return "$destroy_rc"
}

# The cleanup every exit path uses. The provider hooks own the background waiter and the
# provider's finish (target ownership, plan-only, and bundle/teardown verdict composition);
# the shared body owns the decisions that are the same for every row: KEEP, and the
# emergency teardown through the one destroy sequence when the run ends with mutated state
# and no teardown attempt.
cleanup_run() {
  local rc=$?
  local hook="hook_${PROVIDER}"
  "${hook}_cleanup_stop_background"
  if [ "${KEEP:-0}" = "1" ]; then
    say "not tearing down: ${KEEP_REASON:-the delegation boundary is deliberate, not a leak}"
    say "logs: $LOG_DIR"
    return "$rc"
  fi
  # `verify`/`inventory` only read the provider. A prior cloud attempt in the same
  # evidence directory arms `cloud_mutated`, but that does not make a read-only
  # phase responsible for a teardown it did not run and cannot perform safely.
  case "${PHASE:-}" in
    verify | inventory)
      say "not tearing down: $PHASE is a read-only evidence phase"
      say "logs: $LOG_DIR"
      "${hook}_cleanup_finish" "$rc" 0
      return $?
      ;;
  esac
  local mutated=0
  if [ "${CLOUD_APPLIED:-0}" = "1" ] || cloud_mutated; then mutated=1; fi
  if [ "${TEARDOWN_ATTEMPTED:-0}" = "0" ] && [ "$mutated" = "1" ]; then
    if [ -n "${TERMINATION_SIGNAL:-}" ]; then
      say "SIG$TERMINATION_SIGNAL ended the run: tearing down $TARGET and verifying absence"
    else
      say "the run ended before a verified teardown: tearing down $TARGET and verifying absence"
    fi
    destroy_teardown_run || true
  fi
  say "logs: $LOG_DIR"
  "${hook}_cleanup_finish" "$rc" "$mutated"
  return $?
}
