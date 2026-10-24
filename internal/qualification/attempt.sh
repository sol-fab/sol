#!/usr/bin/env bash

attempt_emit() {
  if command -v say >/dev/null 2>&1; then
    say "$1"
    return 0
  fi
  printf '%s\n' "$1" 2>/dev/null || true
}

attempt_refuse() {
  printf 'qualification: %s\n' "$1" >&2 || true
}

attempt_die() {
  attempt_refuse "$1"
  exit 2
}

attempt_identity_file() { printf '%s/attempt.txt' "$LOG_DIR"; }

attempt_require() {
  if [ -z "${ATTEMPT:-}" ]; then
    attempt_die "set ATTEMPT to a unique identity for this disposable run; a qualification attempt is never anonymous and never inherits another attempt's state"
  fi
}

attempt_recorded() {
  local file
  file="$(attempt_identity_file)"
  [ -s "$file" ] || return 1
  sed -n 's/^attempt=//p' "$file" | head -1
}

attempt_recorded_candidate_revision() {
  local file
  file="$(attempt_identity_file)"
  [ -s "$file" ] || return 1
  sed -n 's/^candidate_revision=//p' "$file" | head -1
}

attempt_dir_continuation() {
  local recorded recorded_candidate
  if recorded="$(attempt_recorded)"; then
    if [ "$recorded" != "$ATTEMPT" ]; then
      attempt_die "$LOG_DIR holds attempt '$recorded'; this run is attempt '$ATTEMPT', and one evidence directory belongs to one attempt"
    fi
    recorded_candidate="$(attempt_recorded_candidate_revision || true)"
    if [ -n "$recorded_candidate" ] && [ -n "${SOL_CANDIDATE_REVISION:-}" ] &&
      [ "$recorded_candidate" != "$SOL_CANDIDATE_REVISION" ]; then
      attempt_die "$LOG_DIR holds attempt '$recorded' for candidate revision $recorded_candidate, and this run qualifies ${SOL_CANDIDATE_REVISION}: one evidence directory belongs to one attempt and one candidate"
    fi
    return 0
  fi
  if [ -d "$LOG_DIR" ] && [ -n "$(ls -A "$LOG_DIR" 2>/dev/null)" ]; then
    attempt_die "$LOG_DIR is non-empty and records no attempt; a later attempt does not inherit an unidentified bundle"
  fi
  return 1
}

attempt_field() {
  local key="$1" file
  file="$(attempt_identity_file)"
  [ -s "$file" ] || return 1
  sed -n "s/^$key=//p" "$file" | head -1
}

attempt_write_identity() {
  local file issuer claim
  file="$(attempt_identity_file)"
  mkdir -p "$LOG_DIR"
  # Invariant: an attempt's issuer and claim are fixed when the attempt starts.
  # A continuation -- including a diagnostic resume -- preserves the original
  # attempt's issuer/claim and never adopts the current target's. If the operator
  # wants a different issuer, that is a new ATTEMPT, not a continuation.
  if [ -s "$file" ]; then
    local recorded_issuer recorded_claim
    recorded_issuer="$(sed -n 's/^issuer=//p' "$file" | head -1)"
    recorded_claim="$(sed -n 's/^claim=//p' "$file" | head -1)"
    if [ -z "$recorded_issuer" ] || [ -z "$recorded_claim" ]; then
      attempt_die "the attempt in $LOG_DIR records no issuer/claim; its claim cannot be established, so it cannot be continued"
    fi
    if [ "$recorded_issuer" != "${CLUSTER_ISSUER:-unset}" ]; then
      attempt_die "the attempt recorded issuer=$recorded_issuer; this continuation declares ${CLUSTER_ISSUER:-unset}; a different issuer requires a new ATTEMPT, not a continuation"
    fi
    printf 'continued=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$file"
    if [ -n "${ATTEMPT_RESUMED_FROM:-}" ]; then
      grep -q '^resumed_from=' "$file" || printf 'resumed_from=%s\n' "$ATTEMPT_RESUMED_FROM" >>"$file"
      grep -q '^promotion_eligible=' "$file" || printf 'promotion_eligible=no\n' >>"$file"
    elif [ "$recorded_claim" = production ]; then
      grep -q '^promotion_eligible=' "$file" || printf 'promotion_eligible=yes\n' >>"$file"
    else
      grep -q '^promotion_eligible=' "$file" || printf 'promotion_eligible=no\n' >>"$file"
    fi
    return 0
  fi
  if [ -n "${ATTEMPT_RESUMED_FROM:-}" ]; then
    # A diagnostic resume is a new attempt that carries the source attempt's
    # issuer/claim; the current target must still name the same issuer.
    issuer="$(sed -n 's/^issuer=//p' "$ATTEMPT_RESUMED_FROM/attempt.txt" | head -1)"
    claim="$(sed -n 's/^claim=//p' "$ATTEMPT_RESUMED_FROM/attempt.txt" | head -1)"
    if [ -z "$issuer" ] || [ -z "$claim" ]; then
      attempt_die "the source attempt $ATTEMPT_RESUMED_FROM records no issuer/claim; the resume cannot establish its claim"
    fi
    if [ "$issuer" != "${CLUSTER_ISSUER:-unset}" ]; then
      attempt_die "the source attempt recorded issuer=$issuer; this resume declares ${CLUSTER_ISSUER:-unset}; a different issuer requires a new ATTEMPT"
    fi
  else
    issuer="${CLUSTER_ISSUER:-unset}"
    claim="${ATTEMPT_CLAIM:-unset}"
  fi
  {
    printf 'attempt=%s\n' "$ATTEMPT"
    printf 'row=%s\n' "${ROW:-}"
    printf 'target=%s\n' "${TARGET:-}"
    printf 'state_key=%s\n' "${STATE_KEY:-}"
    printf 'cluster=%s\n' "${CLUSTER:-}"
    printf 'provider=%s\n' "${PROVIDER:-}"
    printf 'candidate_version=%s\n' "${SOL_CANDIDATE_VERSION:-}"
    printf 'candidate_revision=%s\n' "${SOL_CANDIDATE_REVISION:-}"
    printf 'issuer=%s\n' "$issuer"
    printf 'claim=%s\n' "$claim"
    if [ -n "${ATTEMPT_RESUMED_FROM:-}" ] || [ "$claim" != production ]; then
      printf 'promotion_eligible=no\n'
    else
      printf 'promotion_eligible=yes\n'
    fi
    if [ -n "${ATTEMPT_RESUMED_FROM:-}" ]; then
      printf 'resumed_from=%s\n' "$ATTEMPT_RESUMED_FROM"
    fi
    printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$file"
}

attempt_specimen_recorded() {
  local file
  file="$(attempt_identity_file)"
  [ -s "$file" ] || return 1
  sed -n 's/^specimen=//p' "$file" | head -1
}

attempt_record_specimen() {
  printf 'specimen=%s\n' "${CLUSTER:-}" >>"$(attempt_identity_file)"
}

attempt_check_fresh() {
  local continuing="$1"
  if ! "hook_${PROVIDER}_disposable_state_present"; then
    # The attempt's kubeconfig, captures and logs describe the specimen it
    # provisioned. Reusing the attempt for a second specimen leaves the first
    # one's credentials and evidence in place, which is how a run came to read a
    # destroyed cluster's kubeconfig as its own.
    if [ -n "$(attempt_specimen_recorded || true)" ]; then
      attempt_die "$LOG_DIR holds attempt '$ATTEMPT', which already provisioned $(attempt_specimen_recorded): one attempt is one specimen and one set of evidence. Start a new ATTEMPT for a new specimen."
    fi
    attempt_emit "qualification: fresh disposable target ${TARGET:-} (state key ${STATE_KEY:-})"
    # Recorded by attempt_begin once the identity is written: appending here would
    # create the identity file and the standard record would never be written.
    ATTEMPT_FRESH_SPECIMEN=1
    return 0
  fi
  if [ "$continuing" = 1 ] || [ "${CONTINUE_ATTEMPT:-0}" = 1 ]; then
    attempt_emit "qualification: continuing attempt $ATTEMPT against the existing disposable state key ${STATE_KEY:-}"
    return 0
  fi
  attempt_refuse "REFUSING: the disposable state key ${STATE_KEY:-} already exists, so ${TARGET:-} is not a fresh target."
  attempt_refuse "A repeated invocation never reuses an old target as a fresh run. Start a new ATTEMPT with a"
  attempt_refuse "new target, or set CONTINUE_ATTEMPT=1 with the same ATTEMPT to continue this one."
  KEEP=1
  KEEP_REASON="a refused fresh target never tears down a target it did not create"
  exit 2
}

attempt_begin() {
  local check_fresh="${1:-1}" continuing=0
  ATTEMPT_FRESH_SPECIMEN=0
  attempt_require
  if attempt_dir_continuation; then continuing=1; fi
  if [ "$check_fresh" = 1 ]; then attempt_check_fresh "$continuing"; fi
  attempt_write_identity
  if [ "$ATTEMPT_FRESH_SPECIMEN" = 1 ]; then attempt_record_specimen; fi
}
