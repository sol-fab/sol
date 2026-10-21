#!/usr/bin/env bash
# Re-derive the provider-suite divergence count that the merge works from.
#
#   harness-divergence.sh [root] [--list]
#
# Counts top-level functions in each provider's suite, then classifies the names
# both define as byte-identical or divergent. The extraction stops at the closing
# brace of the function OR at the end of its definition line: a one-line function
# (`fn() { ...; }`) has no line equal to `}`, and an extractor that only looks for
# `}` silently consumes the following function. That bug over-counted divergence by
# one and produced a count a reader would have trusted.
set -uo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
[ "${1:-}" = "--list" ] && { root="$(git rev-parse --show-toplevel)"; }
list=0
[ "${2:-}" = "--list" ] && list=1
[ "${1:-}" = "--list" ] && list=1

# shellcheck source=/dev/null
source "$root/internal/qualification/providers.sh"

extract() { # <file> <function>
  awk -v f="$2" '
    index($0, f "()") == 1 {
      if ($0 ~ /}[[:space:]]*$/) { print; exit }
      p = 1; print; next
    }
    p { print; if ($0 ~ /^}[[:space:]]*$/) exit }
  ' "$1"
}

suite() { printf '%s/internal/qualification/%s/live-qual.sh' "$root" "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

all_names="$tmp/all"
: >"$all_names"
for provider in "${PROVIDERS[@]}"; do
  file="$(suite "$provider")"
  if [ ! -f "$file" ]; then
    echo "harness-divergence: no suite for declared provider $provider ($file)" >&2
    exit 1
  fi
  rg -o '^([a-z_]+)\(\)' -r '$1' "$file" | sort -u >"$tmp/$provider.fns"
  cat "$tmp/$provider.fns" >>"$all_names"
done
sort -u "$all_names" -o "$all_names"
shared="$(comm -12 "$tmp/${PROVIDERS[0]}.fns" "$tmp/${PROVIDERS[1]}.fns" 2>/dev/null)"
# General form: a name is shared when every declared provider defines it.
shared="$(sort -u "$all_names" | while IFS= read -r name; do
  present=1
  for provider in "${PROVIDERS[@]}"; do
    grep -qxF "$name" "$tmp/$provider.fns" || present=0
  done
  [ "$present" = 1 ] && printf '%s\n' "$name"
done)"

identical=0
divergent=0
: >"$tmp/identical"
: >"$tmp/divergent"
for name in $shared; do
  first="$(extract "$(suite "${PROVIDERS[0]}")" "$name" | sha256sum | cut -d' ' -f1)"
  same=1
  for provider in "${PROVIDERS[@]:1}"; do
    other="$(extract "$(suite "$provider")" "$name" | sha256sum | cut -d' ' -f1)"
    [ "$first" = "$other" ] || same=0
  done
  if [ "$same" = 1 ]; then
    identical=$((identical + 1))
    printf '%s\n' "$name" >>"$tmp/identical"
  else
    divergent=$((divergent + 1))
    printf '%s\n' "$name" >>"$tmp/divergent"
  fi
done

printf 'providers: %s\n' "${PROVIDERS[*]}"
for provider in "${PROVIDERS[@]}"; do
  printf 'top-level functions, %-4s %s\n' "$provider" "$(wc -l <"$tmp/$provider.fns")"
done
printf 'names shared by every provider: %s\n' "$(printf '%s\n' $shared | grep -c .)"
printf 'of those, byte-identical:        %s\n' "$identical"
printf 'of those, divergent:             %s\n' "$divergent"

if [ "$list" = 1 ]; then
  printf '\nidentical:\n'; sed 's/^/  /' "$tmp/identical"
  printf '\ndivergent:\n'; sed 's/^/  /' "$tmp/divergent"
fi
