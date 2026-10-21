#!/usr/bin/env bash
# The guards on the shared shell must be able to fail. Each case below is a real
# violation placed in the real file by internal/ci/mutation-proof.sh, which restores
# it from a checksummed copy and verifies the checksum afterwards.
#
# A guard with no failing case is a shape assertion: it reports that a file looks a
# certain way without ever showing that the rule it stands for is enforced.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
check="$here/check_harness_shared_shell.sh"
proof="$here/mutation-proof.sh"
shared="$root/internal/qualification/common.sh"

# shellcheck source=/dev/null
source "$root/internal/qualification/providers.sh"
first_provider="${PROVIDERS[0]}"

pass=0
fail=0
ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }

# The guard must accept the tree as it stands, or every proof below is meaningless.
if "$check" "$root" >/dev/null 2>&1; then
  ok "the shared shell passes the guard as it stands"
else
  no "the shared shell does not pass its own guard"
fi

# G1: provider dispatch in the shared shell.
if "$proof" "G1 bites on a provider dispatch" "$shared" \
    's/^(set -uo pipefail)$/$1\nif [ "\$PROVIDER" = x ]; then :; fi/m' \
    "$check" "$root"; then
  ok "G1 is proven: a PROVIDER dispatch fails the guard"
else
  no "G1 is not proven: a PROVIDER dispatch did not fail the guard"
fi

# G2: a provider name from the declared list inside the shared shell.
if "$proof" "G2 bites on a provider name ('$first_provider')" "$shared" \
    "s/^(set -uo pipefail)\$/\$1\nPROVIDER_FIXTURE='$first_provider'/m" \
    "$check" "$root"; then
  ok "G2 is proven: a provider name fails the guard"
else
  no "G2 is not proven: a provider name did not fail the guard"
fi

# The restore in the proofs is checksum-verified; this re-checks the file is intact
# and the guard still accepts it, so a proof cannot leave the tree damaged.
if "$check" "$root" >/dev/null 2>&1; then
  ok "the shared shell still passes after both mutations were restored"
else
  no "the shared shell does not pass after the mutations were restored"
fi

printf '\nharness shared shell guards: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
