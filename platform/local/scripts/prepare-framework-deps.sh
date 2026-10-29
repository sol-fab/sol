#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

FRAMEWORK_PACKAGES=(
  sol-runtime
  sol-env
  sol-obs
  sol-svc-core
  kafka-eio-service
  sol-svc
  sol-worker
  sol-fn
  sol-retry
  sol-jobs
  sol-task
  sol-outbox
)

echo "Preparing Sol framework dev dependencies from: $SOL_ROOT"

for pkg in "${FRAMEWORK_PACKAGES[@]}"; do
  if [ ! -f "$SOL_ROOT/$pkg.opam" ]; then
    echo "error: $SOL_ROOT/$pkg.opam not found -- is SOL_ROOT a Sol checkout?" >&2
    exit 1
  fi
  echo "  pinning $pkg"
  opam pin add -y --kind=path "$pkg" "$SOL_ROOT" >/dev/null
done

echo "  installing framework (this compiles it into the switch)"
opam install -y sol-svc sol-worker sol-fn sol-retry sol-jobs sol-task sol-outbox

echo
echo "Done. The framework is installed into the current opam switch:"
echo "  $(opam var prefix 2>/dev/null || echo '<switch>')"
echo
echo "Run the suite with:  eval \$(opam env) && dune runtest"
