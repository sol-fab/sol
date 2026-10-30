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
      state_bucket: test-state
      aws:
        profile: test
        state_lock_table: test-locks
YAML
cat > "$work/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"output -json"*) printf '%s\n' '{"serverless_role_arns":{"value":{"checkout/checkout_fn":"arn:aws:iam::123:role/test"}}}' ;;
esac
exit 0
FAKE
chmod +x "$work/bin/terraform"
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
args="$*"
if [[ "$args" == *"lambda list-functions"* ]]; then
  if [[ "${FAKE_LIST_MALFORMED:-0}" == 1 ]]; then printf '{}\n'
  elif [[ "${FAKE_LIST_MALFORMED:-0}" == 2 ]]; then printf '{"Functions":[{}]}\n'
  elif [[ -f "$FAKE_AWS_STATE/function" ]]; then printf '{"Functions":[{"FunctionName":"checkout-fn"}]}\n'
  else printf '{"Functions":[]}\n'; fi
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
  if [[ "${FAKE_ALIAS_ERROR:-0}" == 1 && "${FAKE_ALIAS_NO_MUTATE:-0}" == 1 ]]; then
    echo "simulated alias transport failure before mutation" >&2
    exit 1
  fi
  if [[ "${FAKE_ALIAS_STALE:-0}" == 1 ]]; then printf '{}\n'; exit 0; fi
  for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--function-version" ]]; then j=$((i+1)); echo "${!j}" > "$FAKE_AWS_STATE/alias"; fi; done
  if [[ "${FAKE_ALIAS_ERROR:-0}" == 1 ]]; then echo "simulated alias transport failure" >&2; exit 1; fi
  printf '{}\n'
elif [[ "$args" == *"lambda get-function-configuration"* ]]; then printf '{"Role":"%s"}\n' "${FAKE_AWS_ROLE:-arn:aws:iam::123:role/test}"
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

if FAKE_AWS_ROLE=arn:aws:iam::123:role/other "$sol" rollback --target live/aws/us-east-1 --record "$record" --service checkout_fn --to-version 1 --token-file "$work/token" > "$work/rollback-role" 2>&1; then
  echo "rollback accepted a foreign execution role" >&2; exit 1
fi
grep -q 'not the recorded execution role' "$work/rollback-role"
"$sol" rollback --target live/aws/us-east-1 --record "$record" --service checkout_fn --to-version 1 --token-file "$work/token" > "$work/rollback"
grep -q '"version":"1"' "$work/rollback"
grep -q '"invocation_status":"ok"' "$work/rollback"
grep -q '"version":"1"' "$record"
[[ "$(cat "$work/state/alias")" == 1 ]]

# An alias update that applied but whose CLI call reported an error is reconciled
# against the observed alias; the original error is preserved as a warning.
FAKE_ALIAS_ERROR=1 "$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_fn=$image" > "$work/deploy-reconcile" 2>&1
grep -q '"version":"3"' "$work/deploy-reconcile"
grep -q 'reconciled' "$work/deploy-reconcile"
[[ "$(cat "$work/state/alias")" == 3 ]]
record=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
grep -q '"version":"3"' "$record"

# An alias command that failed before the mutation must not be recorded as applied.
if FAKE_ALIAS_ERROR=1 FAKE_ALIAS_NO_MUTATE=1 "$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_fn=$image" > "$work/deploy-unapplied" 2>&1; then
  echo "deploy accepted an alias error that did not apply" >&2; exit 1
fi
grep -q 'update alias failed' "$work/deploy-unapplied"
[[ "$(cat "$work/state/alias")" == 3 ]]
grep -q '"version":"3"' "$record"

# A command that reports success without moving the alias must fail the serving
# postcondition rather than record a version that is not live.
if FAKE_ALIAS_STALE=1 "$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_fn=$image" > "$work/deploy-stale" 2>&1; then
  echo "deploy accepted an alias that did not move" >&2; exit 1
fi
grep -q 'did not reach version' "$work/deploy-stale"
[[ "$(cat "$work/state/alias")" == 3 ]]
grep -q '"version":"3"' "$record"

# A provider FunctionError must fail the lifecycle step, but only after the record
# reflects the alias the provider actually moved.
if FAKE_INVOKE_FAIL=1 "$sol" rollback --target live/aws/us-east-1 --record "$record" --service checkout_fn --to-version 2 --token-file "$work/token" > "$work/invoke-fail" 2>&1; then
  echo "rollback accepted a Lambda FunctionError" >&2; exit 1
fi
grep -q 'FunctionError' "$work/invoke-fail"
[[ "$(cat "$work/state/alias")" == 2 ]]
grep -q '"version":"2"' "$record"

# Destroy refuses a function that no longer carries the adapter's tags.
FAKE_FUNCTION_OWNER=foreign "$sol" destroy live/aws/us-east-1 --apply --service checkout_fn --record "$record" > "$work/destroy-foreign" 2>&1 && {
  echo "destroy accepted a function without this adapter's ownership tags" >&2; exit 1
}
[[ -f "$work/state/function" ]]

if FAKE_AWS_ROLE=arn:aws:iam::123:role/other "$sol" destroy live/aws/us-east-1 --apply --service checkout_fn --record "$record" > "$work/destroy-role" 2>&1; then
  echo "destroy accepted a foreign execution role" >&2; exit 1
fi
grep -q 'not the recorded execution role' "$work/destroy-role"
"$sol" destroy live/aws/us-east-1 --apply --service checkout_fn --record "$record" > /dev/null
[[ ! -f "$work/state/function" ]]
grep -q 'delete-function-url-config' "$FAKE_AWS_LOG" && { echo "fn destroy deleted a Function URL" >&2; exit 1; }

# A malformed inventory is not evidence of absence, and must not trigger a create.
if FAKE_LIST_MALFORMED=1 "$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_fn=$image" > "$work/malformed" 2>&1; then
  echo "deploy accepted a malformed list-functions response" >&2; exit 1
fi
grep -q 'Functions array' "$work/malformed"
[[ ! -f "$work/state/function" ]]

# A malformed entry must not be silently dropped from the inventory either.
if FAKE_LIST_MALFORMED=2 "$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_fn=$image" > "$work/malformed-entry" 2>&1; then
  echo "deploy accepted a list-functions entry without FunctionName" >&2; exit 1
fi
grep -q 'entry 1 has no FunctionName' "$work/malformed-entry"
[[ ! -f "$work/state/function" ]]

# A first deploy whose invocation fails must still leave an ownership record, so the
# provider resource can be destroyed rather than becoming untracked.
if FAKE_INVOKE_FAIL=1 "$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "checkout_fn=$image" > "$work/first-deploy-fail" 2>&1; then
  echo "first deploy accepted a Lambda FunctionError" >&2; exit 1
fi
grep -q 'FunctionError' "$work/first-deploy-fail"
[[ -f "$work/state/function" ]]
[[ "$(cat "$work/state/alias")" == 1 ]]
record_fail=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
grep -q '"kind":"fn"' "$record_fail"
grep -q '"version":"1"' "$record_fail"
"$sol" destroy live/aws/us-east-1 --apply --service checkout_fn --record "$record_fail" > /dev/null
[[ ! -f "$work/state/function" ]]
echo "target serverless fn deploy/invoke/rollback/destroy fake-provider test passed"
