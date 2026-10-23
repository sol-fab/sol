#!/usr/bin/env bash
# Run on every path, including docs-only changes: a dead command or a stale
# support table in the user docs is exactly the kind of change docs-only would
# otherwise skip.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 "$root/internal/ci/check_docs_commands.py"
python3 "$root/internal/ci/check_product_matrix.py"
