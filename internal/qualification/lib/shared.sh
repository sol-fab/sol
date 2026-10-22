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

# The cold-start selection: the row's exercise set. COLD_START_SERVICES is the explicit
# selection (the S1 seeds use it); APP_UNITS is the AWS row's unit set; the default is
# the demo's unit set. The selection is row data, not a provider mechanic.
cold_start_services() {
  if [ -n "${COLD_START_SERVICES+set}" ]; then
    printf '%s\n' $COLD_START_SERVICES
  elif [ -n "${APP_UNITS:-}" ]; then
    printf '%s\n' $APP_UNITS
  else
    printf '%s\n' ${APP_SERVICES-orders_svc fulfilment_worker order_svc fulfillment_worker}
  fi
}

# A directory segment as a Kubernetes name. The candidate declares the segment; this is
# the one place its Kubernetes spelling is decided, so no reader re-implements it.
app_k8s_name() { printf '%s' "$1" | tr '_' '-'; }
