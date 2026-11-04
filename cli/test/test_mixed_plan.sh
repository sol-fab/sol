#!/usr/bin/env bash
set -euo pipefail

sol=$(realpath "$1")
work=$(mktemp -d /tmp/sol-mixed-plan.XXXXXX)
trap 'rm -rf "$work"' EXIT
ws="$work/mixedplan"
mkdir -p "$ws/sol" "$ws/app/payments/charge_svc" "$ws/app/ops/cleanup_fn" "$ws/bin"
printf 'FROM scratch\n' > "$ws/app/payments/charge_svc/Dockerfile"
printf 'FROM scratch\n' > "$ws/app/ops/cleanup_fn/Dockerfile"
printf '[service]\n' > "$ws/app/payments/charge_svc/sol.toml"
printf '[service]\nschedule = "0 3 * * *"\n' > "$ws/app/ops/cleanup_fn/sol.toml"
cat > "$ws/sol.yml" <<'YAML'
project: mixedplan
services:
  charge_svc:
    type: svc
    path: app/payments/charge_svc
    language: ocaml
  cleanup_fn:
    type: fn
    path: app/ops/cleanup_fn
    language: ocaml
YAML
cat > "$ws/sol/environments.yml" <<'YAML'
live:
  targets:
    aws/us-east-1:
      execution: mixed
      shape: local
      state_bucket: test-state
      aws:
        profile: test
        state_lock_table: test-locks
YAML
cat > "$ws/bin/aws" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$ws/bin/terraform" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$ws/bin/aws" "$ws/bin/terraform"
image_svc="repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
image_fn="repo@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
cd "$ws"
PATH="$ws/bin:$PATH" HOME="$work/home" XDG_DATA_HOME="$work/data" \
  "$sol" plan live/aws/us-east-1 --image-ref "charge_svc=$image_svc" \
  --image-ref "cleanup_fn=$image_fn" --out "$work/plan.json" > "$work/plan.out" 2>&1
grep -q 'Sol deployment plan' "$work/plan.out"
grep -q '"components"' "$work/plan.json"
grep -q '"serverless"' "$work/plan.json"
grep -q '"kubernetes"' "$work/plan.json"
grep -q '"permission"' "$work/plan.json"
if PATH="$ws/bin:$PATH" HOME="$work/home" XDG_DATA_HOME="$work/data" \
  "$sol" deploy live/aws/us-east-1 --image-tag test --registry repo.example.com \
  --image-ref "charge_svc=$image_svc" --image-ref "cleanup_fn=$image_fn" \
  --plan "$work/plan.json" --yes > "$work/deploy.out" 2>&1; then
  echo "mixed persisted plan applied without a Kubernetes destination" >&2
  exit 1
fi
grep -q 'cannot validate the Kubernetes component' "$work/deploy.out"
if grep -q 'terraform.*apply' "$work/deploy.out"; then
  echo "mixed plan validation ran a Terraform apply" >&2
  exit 1
fi
echo "mixed target plan validation test passed"
