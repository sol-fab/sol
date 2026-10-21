#!/usr/bin/env bash
set -euo pipefail

# Qualification observes Sol; it must not reproduce Sol's Terraform/Helm resource
# orchestration. Every runner that drives a real provider is checked here, so a new
# direct lifecycle implementation cannot reappear on the runner that is not the
# legacy smoke script. Read-only Terraform state capture (`*.tfstate` objects read
# from the backend) is evidence, not orchestration, and does not name this command.

root="${1:-$(git rev-parse --show-toplevel)}"
runners=(
  "internal/qualification/aws/live-smoke.sh"
  "internal/qualification/aws/live-qual.sh"
  "internal/qualification/gcp/live-qual.sh"
)

status=0
for runner in "${runners[@]}"; do
  path="$root/$runner"
  if [ ! -f "$path" ]; then
    echo "internal/ci: expected qualification runner $runner is missing" >&2
    status=1
    continue
  fi

  if sed '/^[[:space:]]*#/d' "$path" | grep -Eq '(^|[[:space:]])(terraform|helm)([[:space:]]|$)'; then
    echo "$runner must exercise Sol's supported cloud lifecycle, not invoke Terraform or Helm directly" >&2
    status=1
  fi
done

exit "$status"
