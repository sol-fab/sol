#!/usr/bin/env bash
# Guards on the shared (provider-neutral) harness shell.
#
# G1: the shared shell carries no provider dispatch -- no `$PROVIDER`, no
#     `[ "$PROVIDER" = ... ]`, no `case` over a provider value. A shared file that
#     branches on the provider has the provider's logic in the wrong place.
# G2: the shared shell names no provider at all. A provider name in a shared file
#     means a provider-specific decision leaked out of its provider's file.
#
# The provider names come from the declared list, never from this script: adding a
# provider must not require editing the guard.
set -uo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
# shellcheck source=/dev/null
source "$root/internal/qualification/providers.sh"

shared=(
  "internal/qualification/common.sh"
)

status=0
for file in "${shared[@]}"; do
  path="$root/$file"
  if [ ! -f "$path" ]; then
    echo "harness-shared-shell: expected shared file $file is missing" >&2
    status=1
    continue
  fi
  # Comments legitimately explain a provider; the rule is about code.
  code="$(sed '/^[[:space:]]*#/d' "$path")"

  # G1 -- provider dispatch in the shared shell.
  if printf '%s\n' "$code" | grep -Eq '\$[{]?PROVIDER|}PROVIDER\b|PROVIDER='; then
    echo "G1: $file dispatches on PROVIDER; the shared shell must not know which provider is running" >&2
    status=1
  fi

  # G2 -- a provider name in the shared shell, iterating the declared list.
  for provider in "${PROVIDERS[@]}"; do
    if printf '%s\n' "$code" | grep -Eqi "(^|[^[:alnum:]_])${provider}([^[:alnum:]_]|$)"; then
      echo "G2: $file names the provider '$provider'; that decision belongs in the provider's own file" >&2
      status=1
    fi
  done
done

if [ "$status" = 0 ]; then
  echo "harness-shared-shell: the shared shell is provider-neutral (${PROVIDERS[*]})"
fi
exit "$status"
