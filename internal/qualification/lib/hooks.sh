#!/usr/bin/env bash
# The hook contract. A phase calls hooks; a provider implements them. This file
# declares what every provider must supply, so a missing implementation is a
# load-time error rather than a mid-run 127.
#
# REQUIRED_HOOKS grows as phases extract. An entry here must also be called from
# lib/phases.sh: a declared hook nobody calls is dead weight, and the call-site
# coverage check exists to catch that.

REQUIRED_HOOKS=()

# require_provider_hooks -- called by live-qual.sh at startup and by the shared test
# shell, in the process that will actually call the hooks.
require_provider_hooks() {
  local hook
  if [ -z "${PROVIDER:-}" ]; then
    echo "the harness has no PROVIDER, so no hook surface can be checked" >&2
    return 1
  fi
  for hook in "${REQUIRED_HOOKS[@]}"; do
    if ! declare -F "hook_${PROVIDER}_${hook}" >/dev/null; then
      echo "provider ${PROVIDER} does not implement hook ${hook}" >&2
      return 1
    fi
  done
  return 0
}
