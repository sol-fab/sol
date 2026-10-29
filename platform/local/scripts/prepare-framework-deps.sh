#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# The root *.opam files are the package contracts. Derive the framework set
# from them instead of keeping a second list here: sol-task was added to the
# repository and omitted from the hand-written list, so a checkout switch could
# not install a public package. The CLI package (`sol`) is not part of the
# application framework and is intentionally excluded.
FRAMEWORK_PACKAGES=()
for opam_file in "$SOL_ROOT"/*.opam; do
  [ -f "$opam_file" ] || continue
  package="$(basename "$opam_file" .opam)"
  [ "$package" = "sol" ] && continue
  FRAMEWORK_PACKAGES+=("$package")
done
if [ "${#FRAMEWORK_PACKAGES[@]}" -eq 0 ]; then
  echo "error: $SOL_ROOT has no package .opam files -- is it a Sol checkout?" >&2
  exit 1
fi

echo "Preparing Sol framework dev dependencies from: $SOL_ROOT"

for pkg in "${FRAMEWORK_PACKAGES[@]}"; do
  echo "  pinning $pkg"
  opam pin add -y --kind=path "$pkg" "$SOL_ROOT" >/dev/null
done

echo "  installing framework (this compiles it into the switch)"
opam install -y "${FRAMEWORK_PACKAGES[@]}"

echo
echo "Done. The framework is installed into the current opam switch:"
echo "  $(opam var prefix 2>/dev/null || echo '<switch>')"
echo
echo "Run the suite with:  eval \$(opam env) && dune runtest"
