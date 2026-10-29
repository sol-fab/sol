#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home"
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >> "$FAKE_PROVIDER_LOG"
exit 99
FAKE
cat > "$work/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
printf 'gcloud %s\n' "$*" >> "$FAKE_PROVIDER_LOG"
exit 99
FAKE
chmod +x "$work/bin/aws" "$work/bin/gcloud"
unset XDG_DATA_HOME
export PATH="$work/bin:$PATH" FAKE_PROVIDER_LOG="$work/provider.log" HOME="$work/home"
image="repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
: > "$work/provider.log"

workspace() {
  local dir="$1" name="$2" type="$3" uses="$4"
  mkdir -p "$dir/app/checkout/$name" "$dir/sol"
  printf 'FROM scratch\n' > "$dir/app/checkout/$name/Dockerfile"
  {
    printf 'project: refusal\n'
    if [[ "$uses" == yes ]]; then
      printf 'resources:\n  app_db:\n    type: postgres\n'
    fi
    printf 'services:\n  %s:\n    type: %s\n    path: app/checkout/%s\n    language: ocaml\n' "$name" "$type" "$name"
    if [[ "$uses" == yes ]]; then printf '    uses: [app_db]\n'; fi
  } > "$dir/sol.yml"
}

# GCP serverless -fn is refused, without invoking gcloud.
ws="$work/gcp-fn"
workspace "$ws" checkout_fn fn no
cat > "$ws/sol/environments.yml" <<'YAML'
live:
  targets:
    gcp/us-west1:
      execution: serverless
      gcp:
        project_id: example-project
YAML
cd "$ws"
if "$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "checkout_fn=$image" > "$work/gcp-fn.out" 2>&1; then
  echo "GCP serverless -fn deploy was accepted" >&2; exit 1
fi
grep -q 'not implemented for GCP' "$work/gcp-fn.out"
[[ ! -s "$work/provider.log" ]]

# GCP serverless -worker is refused, without invoking gcloud.
ws="$work/gcp-worker"
workspace "$ws" checkout_worker worker no
cat > "$ws/sol/environments.yml" <<'YAML'
live:
  targets:
    gcp/us-west1:
      execution: serverless
      gcp:
        project_id: example-project
YAML
cd "$ws"
if "$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "checkout_worker=$image" > "$work/gcp-worker.out" 2>&1; then
  echo "GCP serverless -worker deploy was accepted" >&2; exit 1
fi
grep -q 'does not support -worker on GCP' "$work/gcp-worker.out"
[[ ! -s "$work/provider.log" ]]

# AWS serverless -worker is refused, without invoking aws.
ws="$work/aws-worker"
workspace "$ws" checkout_worker worker no
cat > "$ws/sol/environments.yml" <<'YAML'
live:
  targets:
    aws/us-east-1:
      execution: serverless
      aws:
        profile: test
        lambda_role_arn: arn:aws:iam::123:role/test
YAML
cd "$ws"
if "$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_worker=$image" > "$work/aws-worker.out" 2>&1; then
  echo "AWS serverless -worker deploy was accepted" >&2; exit 1
fi
grep -q 'does not support -worker' "$work/aws-worker.out"
[[ ! -s "$work/provider.log" ]]

# A -fn with dependencies is refused before provider mutation.
ws="$work/aws-fn-deps"
workspace "$ws" checkout_fn fn yes
cat > "$ws/sol/environments.yml" <<'YAML'
live:
  targets:
    aws/us-east-1:
      execution: serverless
      aws:
        profile: test
        lambda_role_arn: arn:aws:iam::123:role/test
YAML
cd "$ws"
if "$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_fn=$image" > "$work/aws-fn-deps.out" 2>&1; then
  echo "AWS serverless -fn with dependencies was accepted" >&2; exit 1
fi
grep -q 'does not yet support service dependencies' "$work/aws-fn-deps.out"
[[ ! -s "$work/provider.log" ]]

echo "serverless unsupported-combination refusals passed"
