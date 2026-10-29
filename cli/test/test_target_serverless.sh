#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
examples="${2:-examples/pluto}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/home" "$work/ws/app/checkout"
ln -s "$(cd "$examples/app/checkout/checkout_svc" && pwd)" "$work/ws/app/checkout/checkout_svc"
cat > "$work/ws/sol.yml" <<'YAML'
project: pluto
services:
  checkout_svc:
    type: http
    path: app/checkout/checkout_svc
    language: ocaml
YAML
mkdir -p "$work/ws/sol"
cat > "$work/ws/sol/environments.yml" <<'YAML'
live:
  targets:
    aws/us-east-1:
      execution: serverless
      aws:
        profile: test
        lambda_role_arn: arn:aws:iam::123:role/test
        serverless_callers: checkout/checkout_svc=123
YAML
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
args="$*"
if [[ "$args" == *"lambda list-functions"* ]]; then
  if [[ -f "$FAKE_AWS_STATE/function" ]]; then printf '{"Functions":[{"FunctionName":"checkout-svc"}]}\n'; else printf '{"Functions":[]}\n'; fi
elif [[ "$args" == *"lambda create-function"* ]]; then touch "$FAKE_AWS_STATE/function"; printf '{}\n'
elif [[ "$args" == *"lambda update-function-code"* || "$args" == *"lambda update-function-configuration"* ]]; then printf '{}\n'
elif [[ "$args" == *"lambda wait function-updated"* ]]; then printf '{}\n'
elif [[ "$args" == *"lambda publish-version"* ]]; then v=$(cat "$FAKE_AWS_STATE/version" 2>/dev/null || echo 0); v=$((v+1)); echo "$v" > "$FAKE_AWS_STATE/version"; printf '{"Version":"%s"}\n' "$v"
elif [[ "$args" == *"lambda get-alias"* ]]; then if [[ -f "$FAKE_AWS_STATE/alias" ]]; then printf '{"FunctionVersion":"%s"}\n' "$(cat "$FAKE_AWS_STATE/alias")"; else printf 'ResourceNotFoundException: Alias not found.\n' >&2; exit 254; fi
elif [[ "$args" == *"lambda create-alias"* || "$args" == *"lambda update-alias"* ]]; then
  for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--function-version" ]]; then j=$((i+1)); echo "${!j}" > "$FAKE_AWS_STATE/alias"; fi; done
  printf '{}\n'
elif [[ "$args" == *"lambda get-function-url-config"* ]]; then printf '{"FunctionUrl":"https://lambda.example/"}\n'
elif [[ "$args" == *"lambda create-function-url-config"* || "$args" == *"lambda remove-permission"* || "$args" == *"lambda add-permission"* ]]; then printf '{}\n'
elif [[ "$args" == *"lambda get-function"* ]]; then printf '{"Configuration":{"Version":"%s","FunctionArn":"arn:aws:lambda:us-east-1:123:function:checkout-svc"},"Tags":{"sol-owned":"lambda-experiment","sol-service":"checkout-svc"}}\n' "$(cat "$FAKE_AWS_STATE/version")"
elif [[ "$args" == *"lambda delete-function-url-config"* ]]; then printf '{}\n'
elif [[ "$args" == *"lambda delete-function"* ]]; then rm -f "$FAKE_AWS_STATE/function" "$FAKE_AWS_STATE/alias"; printf '{}\n'
else printf '{}\n'; fi
FAKE
cat > "$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
url=""; config=""
while [[ $# -gt 0 ]]; do case "$1" in --config) config="$2"; shift 2;; --output|--write-out) shift 2;; --silent|--show-error) shift;; *) url="$1"; shift;; esac; done
if [[ "$url" == */readyz ]]; then printf '\n200'; elif [[ -s "$config" ]]; then printf 'ok\n200'; else printf 'no\n401'; fi
FAKE
chmod +x "$work/bin/aws" "$work/bin/curl"
unset XDG_DATA_HOME
export PATH="$work/bin:$PATH" FAKE_AWS_LOG="$work/aws.log" FAKE_AWS_STATE="$work/state" HOME="$work/home"
cd "$work/ws"
"$sol" deploy live/aws/us-east-1 --image-tag test --image-ref checkout_svc=repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$work/deploy"
grep -q '"kind":"svc"' "$work/deploy"
grep -q '"function_name":"checkout-svc"' "$work/deploy"
"$sol" deploy live/aws/us-east-1 --image-tag test --image-ref checkout_svc=repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$work/deploy2"
grep -q '"version":"2"' "$work/deploy2"
record=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
[[ -n "$record" ]]
printf 'token\n' > "$work/token"
"$sol" rollback --target live/aws/us-east-1 --record "$record" --service checkout_svc --to-version 1 --token-file "$work/token" > "$work/rollback"
grep -q '"version":"1"' "$work/rollback"
grep -q '"version":"1"' "$record"
"$sol" destroy live/aws/us-east-1 --apply --service checkout_svc --record "$record" > /dev/null
[[ ! -f "$work/state/function" ]]
echo "target serverless deploy/rollback/destroy fake-provider test passed"
