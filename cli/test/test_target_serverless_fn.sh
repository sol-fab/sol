#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/home" "$work/ws/app/checkout/checkout_fn"
printf 'FROM scratch\n' > "$work/ws/app/checkout/checkout_fn/Dockerfile"
cat > "$work/ws/sol.yml" <<'YAML'
project: pluto
services:
  checkout_fn:
    type: fn
    path: app/checkout/checkout_fn
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
YAML
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
args="$*"
if [[ "$args" == *"lambda list-functions"* ]]; then
  if [[ -f "$FAKE_AWS_STATE/function" ]]; then printf '{"Functions":[{"FunctionName":"checkout-fn"}]}\n'; else printf '{"Functions":[]}\n'; fi
elif [[ "$args" == *"lambda create-function"* ]]; then
  [[ "$args" == *"sol-owned=lambda-fn-experiment"* ]] || { echo "create-function lost the fn ownership tag" >&2; exit 1; }
  touch "$FAKE_AWS_STATE/function"; echo 0 > "$FAKE_AWS_STATE/version"; printf '{}\n'
elif [[ "$args" == *"lambda update-function-code"* || "$args" == *"lambda update-function-configuration"* ]]; then printf '{}\n'
elif [[ "$args" == *"lambda wait function-updated"* ]]; then printf '{}\n'
elif [[ "$args" == *"lambda publish-version"* ]]; then
  v=$(cat "$FAKE_AWS_STATE/version" 2>/dev/null || echo 0); v=$((v+1)); echo "$v" > "$FAKE_AWS_STATE/version"; printf '{"Version":"%s"}\n' "$v"
elif [[ "$args" == *"lambda get-alias"* ]]; then
  if [[ -f "$FAKE_AWS_STATE/alias" ]]; then printf '{"FunctionVersion":"%s"}\n' "$(cat "$FAKE_AWS_STATE/alias")"; else printf 'ResourceNotFoundException: Alias not found.\n' >&2; exit 254; fi
elif [[ "$args" == *"lambda create-alias"* || "$args" == *"lambda update-alias"* ]]; then
  for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--function-version" ]]; then j=$((i+1)); echo "${!j}" > "$FAKE_AWS_STATE/alias"; fi; done
  printf '{}\n'
elif [[ "$args" == *"lambda get-function"* ]]; then
  owner="${FAKE_FUNCTION_OWNER:-lambda-fn-experiment}"
  printf '{"Configuration":{"Version":"%s"},"Tags":{"sol-owned":"%s","sol-service":"checkout-fn"}}\n' "$(cat "$FAKE_AWS_STATE/version")" "$owner"
elif [[ "$args" == *"lambda invoke"* ]]; then
  outfile=""; qualifier=""
  for ((i=1;i<=$#;i++)); do
    case "${!i}" in
      --qualifier) j=$((i+1)); qualifier="${!j}";;
      *) if [[ "${!i}" == /tmp/*.json ]]; then outfile="${!i}"; fi;;
    esac
  done
  [[ -n "$outfile" ]]
  if [[ "${FAKE_INVOKE_FAIL:-0}" == 1 ]]; then
    printf '{"errorMessage":"boom"}\n' > "$outfile"
    printf '{"StatusCode":200,"FunctionError":"Unhandled"}\n'
  else
    printf '{"status":"ok"}\n' > "$outfile"
    printf '{"StatusCode":200,"ExecutedVersion":"%s"}\n' "$(cat "$FAKE_AWS_STATE/alias")"
  fi
elif [[ "$args" == *"lambda delete-function"* ]]; then
  rm -f "$FAKE_AWS_STATE/function" "$FAKE_AWS_STATE/alias" "$FAKE_AWS_STATE/version"; printf '{}\n'
else printf '{}\n'; fi
FAKE
chmod +x "$work/bin/aws"
unset XDG_DATA_HOME
export PATH="$work/bin:$PATH" FAKE_AWS_LOG="$work/aws.log" FAKE_AWS_STATE="$work/state" HOME="$work/home"
image="repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
printf 'token\n' > "$work/token"
cd "$work/ws"

# A foreign function with the same Lambda name must be refused, not adopted.
touch "$work/state/function"; echo 1 > "$work/state/version"
if FAKE_FUNCTION_OWNER=foreign "$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_fn=$image" > "$work/foreign" 2>&1; then
  echo "deploy adopted a function without this adapter's ownership tags" >&2; exit 1
fi
grep -q 'ownership tags' "$work/foreign"
rm -f "$work/state/function" "$work/state/version"

"$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_fn=$image" > "$work/deploy"
grep -q '"kind":"fn"' "$work/deploy"
grep -q '"function_name":"checkout-fn"' "$work/deploy"
grep -q '"version":"1"' "$work/deploy"
grep -q '"url"' "$work/deploy" && { echo "fn release record must not carry an HTTP URL" >&2; exit 1; }
grep -q 'lambda invoke' "$FAKE_AWS_LOG"
grep -q 'create-function-url-config' "$FAKE_AWS_LOG" && { echo "fn deploy created a Function URL" >&2; exit 1; }
[[ "$(cat "$work/state/alias")" == 1 ]]

"$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_fn=$image" > "$work/deploy2"
grep -q '"version":"2"' "$work/deploy2"
[[ "$(cat "$work/state/alias")" == 2 ]]
record=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
[[ -n "$record" ]]
grep -q '"kind":"fn"' "$record"

"$sol" rollback --target live/aws/us-east-1 --record "$record" --service checkout_fn --to-version 1 --token-file "$work/token" > "$work/rollback"
grep -q '"version":"1"' "$work/rollback"
grep -q '"invocation_status":"ok"' "$work/rollback"
grep -q '"version":"1"' "$record"
[[ "$(cat "$work/state/alias")" == 1 ]]

# A provider FunctionError must fail the lifecycle step and leave the record unchanged.
if FAKE_INVOKE_FAIL=1 "$sol" rollback --target live/aws/us-east-1 --record "$record" --service checkout_fn --to-version 2 --token-file "$work/token" > "$work/invoke-fail" 2>&1; then
  echo "rollback accepted a Lambda FunctionError" >&2; exit 1
fi
grep -q 'FunctionError' "$work/invoke-fail"
grep -q '"version":"1"' "$record"

# Destroy refuses a function that no longer carries the adapter's tags.
FAKE_FUNCTION_OWNER=foreign "$sol" destroy live/aws/us-east-1 --apply --service checkout_fn --record "$record" > "$work/destroy-foreign" 2>&1 && {
  echo "destroy accepted a function without this adapter's ownership tags" >&2; exit 1
}
[[ -f "$work/state/function" ]]

"$sol" destroy live/aws/us-east-1 --apply --service checkout_fn --record "$record" > /dev/null
[[ ! -f "$work/state/function" ]]
grep -q 'delete-function-url-config' "$FAKE_AWS_LOG" && { echo "fn destroy deleted a Function URL" >&2; exit 1; }
echo "target serverless fn deploy/invoke/rollback/destroy fake-provider test passed"
