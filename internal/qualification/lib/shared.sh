#!/usr/bin/env bash
# Functions both provider suites run identically. They read provider-supplied globals
# (SAY_LOG, LOG_DIR, PHASE_TIMEOUT, SOL_QUALIFICATION_CA, the candidate/install paths)
# but decide nothing about a provider, so they have one implementation rather than two
# that drift. Provider mechanics stay in the suites and the hook files.

# A harness-emitted line: written to the attempt's harness log when one is configured,
# and to stdout. Raw provider output is never printed here; it stays in evidence.
say() {
  local line
  printf -v line '[%(%H:%M:%S)T] %s' -1 "$*"
  if [ -n "${SAY_LOG:-}" ]; then
    printf '%s\n' "$line" >>"$SAY_LOG" 2>/dev/null || true
  fi
  printf '%s\n' "$line" 2>/dev/null || true
}

# A refusal from inside a function whose stdout is captured (a command substitution) is
# written to stderr: the message would otherwise be captured as the function's value and
# never reach the operator. It still goes to the harness log like `say`.
refuse() { say "$@" >&2; }

# Run one phase of the shared database-CA owner. The request is built by the provider's
# `ca_request`; the driver is bounded by the phase timeout so a hung driver cannot hang
# the phase, and its output stays in evidence.
ca_qualify() {
  local phase="$1" capture="${2:-}" report="${3:-}" binding="${4:-}" status=0
  if [ ! -x "$SOL_QUALIFICATION_CA" ]; then
    say "the shared database-CA qualifier is not built at $SOL_QUALIFICATION_CA"
    return 1
  fi
  if ! ca_request "$phase" "$capture" "$report" "$binding"; then
    say "could not build the database-CA $phase request"
    return 1
  fi
  # The driver bounds its own child and cleanup; this outer watchdog keeps a
  # hung driver from hanging the phase, and names the cleanup responsibility.
  timeout "$PHASE_TIMEOUT" "$SOL_QUALIFICATION_CA" --phase "$phase" \
    --request "$LOG_DIR/ca-request-$phase.json" >"$LOG_DIR/ca-$phase.log" 2>&1 || status=$?
  if [ "$status" != 0 ]; then
    say "the shared database-CA $phase phase did not pass; see $LOG_DIR/ca-$phase.log"
    if [ "$status" = 124 ]; then
      say "     the $phase phase exceeded ${PHASE_TIMEOUT}s; its cleanup is unestablished and remains the operator's responsibility"
    fi
    tail -n 20 "$LOG_DIR/ca-$phase.log" || true
    if [ -n "$report" ] && [ -s "$report" ]; then
      tail -n 20 "$report" || true
    fi
    return 1
  fi
}

# The database-contract pins and specimen the delivery assertion reads. Recorded from
# the immutable install and the candidate-bound workspace, never the working tree.
record_database_contract_pins() {
  mkdir -p "$LOG_DIR"
  local bound="$LOG_DIR/database-contract-binding.json"
  if ! python3 "$ROOT/internal/qualification/database-contract-binding.py" \
      --candidate "$SOL_CANDIDATE" --install "$SOL_INSTALL" --workspace "$WORKSPACE" \
      --target "$TARGET" >"$bound"; then
    say "could not bind the candidate's database contract; the CA family cannot be qualified"
    return 1
  fi
  # The specimen is kept whole because the delivery assertion names its consumers from
  # it: the candidate declares which workloads consume the database and which Secret
  # each reads, so the row does not reconstruct those names (#1492 class).
  if ! python3 - "$bound" "$LOG_DIR/database-contract-pins.json" \
      "$LOG_DIR/database-contract-specimen.json" <<'PY'
import json, sys
bound = json.load(open(sys.argv[1]))
s = bound["specimen"]["declaration"]
json.dump({"revision": bound["candidate"]["revision"],
           "bundle_digest": bound["candidate"]["bundle_sha256"],
           "definition_digest": bound["definition"]["digest"],
           "specimen_digest": bound["specimen"]["digest"],
           "requested_target": s["requested_target"],
           "target": s["target"]}, open(sys.argv[2], "w"))
json.dump(bound["specimen"], open(sys.argv[3], "w"))
PY
  then
    say "could not record the candidate's specimen; the delivery assertion cannot name its consumers"
    return 1
  fi
  say "recorded the candidate's database-contract pins and specimen for the shared CA family"
}

# The row's application unit set. APP_UNITS is the AWS row's list; APP_SERVICES is the
# GCP row's; the default is the demo's. The set is row data, not a provider mechanic.
app_services() {
  if [ -n "${APP_UNITS:-}" ]; then
    printf '%s\n' $APP_UNITS
  else
    printf '%s\n' ${APP_SERVICES-orders_svc fulfilment_worker order_svc fulfillment_worker}
  fi
}

# The cold-start selection: the row's exercise set. COLD_START_SERVICES is the explicit
# selection (the S1 seeds use it); otherwise the full app set.
cold_start_services() {
  if [ -n "${COLD_START_SERVICES+set}" ]; then
    printf '%s\n' $COLD_START_SERVICES
  else
    app_services
  fi
}

# A directory segment as a Kubernetes name. The candidate declares the segment; this is
# the one place its Kubernetes spelling is decided, so no reader re-implements it.
app_k8s_name() { printf '%s' "$1" | tr '_' '-'; }

# The candidate-bound address of each app unit (the path under app/), taken from the build
# context candidate-binding.sh materialized. Never the working tree and never a hardcoded
# service-to-path map: the candidate's own layout is the authority.
app_unit_addresses() {
  local unit dir
  if [ ! -d "$APP_BUILD_CONTEXT" ]; then
    refuse "REFUSING: no candidate-bound build context at $APP_BUILD_CONTEXT, so the units' namespaces"
    refuse "cannot be derived from the candidate's own contract"
    return 1
  fi
  for unit in $(app_services); do
    for dir in "$APP_BUILD_CONTEXT"/app/*/"$unit"; do
      if [ -f "$dir/Dockerfile" ]; then
        printf '%s\n' "${dir#"$APP_BUILD_CONTEXT"/app/}"
        break
      fi
    done
  done | sort -u
}

# The namespaces the app's units declare: the row's app-namespace prefix and the first
# segment of each candidate-bound address, spelled once by app_k8s_name.
app_namespaces() {
  local prefix="${APP_NS%-*}" address
  for address in $(app_unit_addresses); do
    printf '%s-%s\n' "$prefix" "$(app_k8s_name "${address%%/*}")"
  done | sort -u
}

# The deploy's immutable image arguments: one --image-ref per published digest. A cold
# deploy has no published digest, so the file legitimately does not exist and the list is
# empty; testing for it keeps an intended empty result from printing a shell error that
# reads like a failure.
app_image_ref_args() {
  local ref args="" file="$LOG_DIR/app-image-refs.txt"
  [ -f "$file" ] || {
    printf '%s' ""
    return 0
  }
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    args="$args --image-ref $(printf '%q' "$ref")"
  done <"$file"
  printf '%s' "$args"
}

# The attempt owns the kubeconfig path (#1633). Probe the endpoint through it before the
# delivery reads, so a path that no longer answers is a classified refusal here rather than
# a misleading absence later.
probe_attempt_kubeconfig() {
  if [ -z "${ATTEMPT_KUBECONFIG:-}" ]; then
    say "no attempt-owned kubeconfig is recorded; the delivery assertion cannot read through it"
    return 1
  fi
  if ! kubectl --kubeconfig "$ATTEMPT_KUBECONFIG" get namespace kube-system -o name >/dev/null 2>&1; then
    say "the attempt's kubeconfig ($ATTEMPT_KUBECONFIG) does not answer at its endpoint; the delivery assertion cannot read through it"
    return 1
  fi
}

# The deploy's own declaration and the candidate's consumer set are read, neither is
# reconstructed. The reads go through the attempt-owned kubeconfig (#1633), probed at its
# endpoint first, so a path that no longer answers is a refusal here rather than a
# misleading absence later. The CA family report is the app phase's next step, not this
# function's.
app_verify_database_delivery() {
  probe_attempt_kubeconfig || return 1
  local declared_ns ddl_name specimen consumers delivery
  local namespace workload cred_ns cred_name containers container ref found
  declared_ns="$(app_database_field namespace)"
  ddl_name="$(app_database_field ddl-creds)"
  if [ -z "$declared_ns" ] || [ -z "$ddl_name" ]; then
    say "the deploy declared no database identity, so where it wrote is not known; the assertion cannot read a location it cannot name"
    return 1
  fi
  # Reporting is not verification: read the Secret at the declared location.
  if ! kubectl --kubeconfig "$ATTEMPT_KUBECONFIG" get secret "$ddl_name" -n "$declared_ns" \
    >/dev/null 2>&1; then
    say "the deploy declared its migration Job's $ddl_name in $declared_ns, and it is absent there"
    return 1
  fi
  specimen="$LOG_DIR/database-contract-specimen.json"
  if [ ! -s "$specimen" ]; then
    say "the candidate's specimen is not recorded, so the delivery assertion cannot name its consumers"
    return 1
  fi
  if ! consumers="$(jq -r '.declaration.workloads[]
      | select(.database != null)
      | [.namespace, .name, (.credential.namespace // ""), (.credential.name // ""),
         ((.consuming_containers // []) | join(","))] | @tsv' "$specimen")"; then
    say "the candidate's specimen could not be read; the consumer set is unknown"
    return 1
  fi
  if [ -z "$consumers" ]; then
    say "the candidate's specimen declares no database consumer, so the delivery assertion has no subject"
    return 1
  fi
  # The migration Job's address is the deploy's own declaration; the consumers are the
  # candidate's. Both are read, neither is reconstructed.
  delivery="$ddl_name@$declared_ns (migration Job, as the deploy declared it)"
  while IFS=$'\t' read -r namespace workload cred_ns cred_name containers; do
    [ -n "$namespace" ] || continue
    if [ -z "$cred_name" ] || [ -z "$cred_ns" ]; then
      say "the candidate declared $namespace/$workload as a database consumer without a credential address"
      return 1
    fi
    if ! kubectl --kubeconfig "$ATTEMPT_KUBECONFIG" get secret "$cred_name" -n "$cred_ns" \
      >/dev/null 2>&1; then
      say "the candidate declared $namespace/$workload as a database consumer, and $cred_name is absent from $cred_ns"
      return 1
    fi
    found=""
    for container in ${containers//,/ }; do
      [ -n "$container" ] || continue
      ref="$(kubectl --kubeconfig "$ATTEMPT_KUBECONFIG" get deployment "$workload" -n "$namespace" -o json 2>/dev/null \
        | jq -r --arg c "$container" '
            [.spec.template.spec.containers[]? | select(.name == $c)
             | .env[]? | select(.name == "POSTGRES_URL")
             | .valueFrom.secretKeyRef.name // empty] | first // ""' 2>/dev/null)"
      if [ "$ref" != "$cred_name" ]; then
        say "$namespace/$workload container $container reads POSTGRES_URL from '${ref:-nothing}', not the declared class Secret $cred_name"
        return 1
      fi
      found=1
    done
    if [ -z "$found" ]; then
      say "the candidate declared no consuming container for $namespace/$workload, so where it reads POSTGRES_URL is not established"
      return 1
    fi
    delivery="$delivery, $cred_name@$cred_ns (unit consumer $workload)"
  done <<<"$consumers"
  # The database CA family is owned by the shared candidate-bound observer. The
  # migration phase already ran at the row's migration step; the application
  # phase ran after the final deploy. This report re-reads their durable evidence
  # and refuses an incomplete or non-passing family.
    {
    printf 'database_delivery: %s\n' "$delivery"
    printf 'database_delivery_assertion: every declared consumer reads POSTGRES_URL from its class Secret\n'
  } >>"$LOG_DIR/prerequisites.txt"
  say "the deploy delivered the database; every declared consumer reads POSTGRES_URL from its class Secret"
}

# Run one external step with a bounded deadline. Runs from the attempt's workspace, in a
# subshell, so a step's `cd` cannot change the harness's own directory, and captures the
# status so exit 124 is named as the harness deadline rather than Sol's failure.
run() {
  local name="$1" rc=0
  shift
  say "phase: $name"
  ( cd "$WORKSPACE" && timeout "$PHASE_TIMEOUT" "$@" ) >"$LOG_DIR/$name.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$rc" = 124 ]; then
      say "FAILED: $name  (THE HARNESS ENDED IT after ${PHASE_TIMEOUT}s, not Sol: this deadline killed a phase that was still working, so the log above ends mid-step. Raise PHASE_TIMEOUT for a cold run.)"
    else
      say "FAILED: $name  (exit $rc; last 40 lines; full log $LOG_DIR/$name.log)"
    fi
    tail -n 40 "$LOG_DIR/$name.log" || true
    return 1
  fi
  say "ok: $name"
}


# Let's Encrypt has no remaining-quota API. Refuse before provisioning when
# public CT history already shows the duplicate-certificate limit reached, or
# when that history cannot be read. This is a best-effort guard, not a
# reservation: CT can lag, so a successful check does not guarantee issuance.
require_letsencrypt_headroom() {
  if [ "${CLUSTER_ISSUER:-}" != "letsencrypt-prod" ]; then
    return 0
  fi
  case "${SOL_LE_PREFLIGHT:-enforce}" in
    off)
      say "letsencrypt-preflight: skipped by SOL_LE_PREFLIGHT=off"
      return 0
      ;;
    allow-unknown)
      set -- --allow-unknown
      ;;
    *)
      set --
      ;;
  esac
  local ledger="${SOL_LE_LEDGER:-${XDG_DATA_HOME:-$HOME/.local/share}/sol/qualification/letsencrypt-issuance.json}"
  if ! python3 "$ROOT/internal/qualification/letsencrypt_preflight.py" \
    --base-domain "$BASE_DOMAIN" --issuer "$CLUSTER_ISSUER" \
    --ledger "$ledger" --reserve \
    --out "$LOG_DIR/letsencrypt-preflight.txt" "$@" \
    >>"$LOG_DIR/letsencrypt-preflight.log" 2>&1; then
    say "REFUSING: Let's Encrypt duplicate-certificate headroom is not established;"
    say "  see $LOG_DIR/letsencrypt-preflight.txt. Wait for the reported window or use"
    say "  a new base domain; only an operator may set SOL_LE_PREFLIGHT=allow-unknown/off."
    return 1
  fi
}

# Record the CA's own retry window when a platform apply failed on the
# duplicate-certificate limit. CT can lag; this local block is authoritative
# for our next attempt until the CA says the window has passed.
record_letsencrypt_rate_limit() {
  [ "${CLUSTER_ISSUER:-}" = "letsencrypt-prod" ] || return 0
  local retry
  retry="$(grep -rhoE 'retry after [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC' "$LOG_DIR"/*.log 2>/dev/null     | sed -E 's/^retry after //; s/ UTC$//' | tail -1)"
  [ -n "$retry" ] || return 0
  local ledger="${SOL_LE_LEDGER:-${XDG_DATA_HOME:-$HOME/.local/share}/sol/qualification/letsencrypt-issuance.json}"
  python3 "$ROOT/internal/qualification/letsencrypt_preflight.py" \
    --record-block --ledger "$ledger" --base-domain "$BASE_DOMAIN" --issuer "$CLUSTER_ISSUER" \
    --retry-after "$retry" \
    | sed 's/^/letsencrypt-preflight: /'
  say "recorded the CA rate-limit window; the next attempt will refuse before provisioning"
}

# Production TLS and Grafana SSO are both part of the profile. Terraform's
# OIDC variables default to empty, so a missing client is discovered only when
# the platform apply reaches Grafana. Refuse before any provider mutation.
require_grafana_oidc_inputs() {
  [ "${CLUSTER_ISSUER:-}" = "letsencrypt-prod" ] || return 0
  local missing="" provider="${TF_VAR_grafana_oidc_provider:-google}" var value
  for var in TF_VAR_grafana_oidc_client_id TF_VAR_grafana_oidc_client_secret; do
    eval "value=\${$var:-}"
    [ -n "$value" ] || missing="$missing $var"
  done
  if [ "$provider" = "custom" ]; then
    for var in TF_VAR_grafana_oidc_auth_url TF_VAR_grafana_oidc_token_url TF_VAR_grafana_oidc_api_url; do
      eval "value=\${$var:-}"
      [ -n "$value" ] || missing="$missing $var"
    done
  fi
  if [ -n "$missing" ]; then
    say "REFUSING: production Grafana SSO inputs are missing:$missing"
    say "  register a web client for redirect https://grafana.$BASE_DOMAIN/login/generic_oauth"
    say "  and export the TF_VAR_grafana_oidc_* values before provisioning; secrets are not recorded."
    return 1
  fi
  say "production preflight: Grafana OIDC inputs present"
}
