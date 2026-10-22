#!/usr/bin/env bash
# Hook-surface guards.
#
# Required-hook completeness: every hook declared in lib/hooks.sh is implemented by
# every declared provider. This is the static half; live-qual.sh and the shared test
# shell run the same check at load through require_provider_hooks, so a missing hook
# fails the run that would have called it.
#
# Call-site coverage: every declared hook is actually called from lib/phases.sh. A
# hook that is declared, implemented and never called is dead weight -- the shape a
# check takes when someone adds the declaration and forgets the wiring.
#
# LIMIT, stated so nobody assumes otherwise: this checks presence and call sites, not
# ORDER. An ordering rule (freeze before a heavy read) is carried by the mutation
# manifest, not by this guard.
set -uo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
# shellcheck source=/dev/null
source "$root/internal/qualification/providers.sh"
# shellcheck source=/dev/null
source "$root/internal/qualification/lib/hooks.sh"

status=0
for hook in "${REQUIRED_HOOKS[@]}"; do
  if ! grep -q "\"\${hook}_${hook}\"\|_${hook}\"\|_${hook}\b" "$root/internal/qualification/lib/phases.sh"; then
    echo "call-site coverage: hook $hook is declared but lib/phases.sh never calls it" >&2
    status=1
  fi
  for provider in "${PROVIDERS[@]}"; do
    file="$root/internal/qualification/provider-$provider.sh"
    if [ ! -f "$file" ]; then
      echo "provider $provider has no hook file ($file)" >&2
      status=1
      continue
    fi
    if ! grep -q "^hook_${provider}_${hook}()" "$file"; then
      echo "completeness: provider $provider does not implement hook $hook" >&2
      status=1
    fi
  done
done

[ "$status" = 0 ] && echo "harness hooks: ${#REQUIRED_HOOKS[@]} hooks, all implemented and called (${PROVIDERS[*]})"
exit "$status"
