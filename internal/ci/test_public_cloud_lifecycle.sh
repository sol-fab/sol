#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
guard="$root/internal/ci/check_public_cloud_lifecycle.sh"

runners=(
  "internal/qualification/aws/live-smoke.sh"
  "internal/qualification/aws/live-qual.sh"
  "internal/qualification/gcp/live-qual.sh"
)

"$guard" "$root"

# Every real provider runner is covered, not only the legacy smoke script: a direct
# Terraform invocation added to any of them must be rejected, for that runner.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

seed() {
  local dir="$1" runner
  for runner in "${runners[@]}"; do
    mkdir -p "$dir/$(dirname "$runner")"
    printf '#!/usr/bin/env bash\necho clean\n' >"$dir/$runner"
  done
}

for runner in "${runners[@]}"; do
  dir="$tmp/direct-$(printf '%s' "$runner" | tr '/' '-')"
  seed "$dir"
  printf '#!/usr/bin/env bash\nterraform apply\n' >"$dir/$runner"
  if "$guard" "$dir" >/dev/null 2>&1; then
    echo "guard accepted a runner that provisions with Terraform directly: $runner" >&2
    exit 1
  fi
  refusal="$("$guard" "$dir" 2>&1 || true)"
  if ! printf '%s' "$refusal" | grep -q "$runner"; then
    echo "guard rejected the tree but did not name the offending runner: $runner" >&2
    exit 1
  fi
done

# A runner that has been renamed or deleted is not silently uncovered.
missing="$tmp/missing"
seed "$missing"
rm "$missing/internal/qualification/gcp/live-qual.sh"
if "$guard" "$missing" >/dev/null 2>&1; then
  echo "guard accepted a tree with no active GCP runner" >&2
  exit 1
fi
