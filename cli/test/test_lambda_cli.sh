#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
examples="${2:-examples/pluto}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
args="$*"
if [[ "$args" == *"lambda list-functions"* ]]; then
  if [[ -f "$FAKE_AWS_STATE/function" ]]; then printf '{"Functions":[{"FunctionName":"checkout-svc"}]}\n'; else printf '{"Functions":[]}\n'; fi
elif [[ "$args" == *"lambda create-function"* ]]; then touch "$FAKE_AWS_STATE/function"; printf '{}\n'
elif [[ "$args" == *"lambda update-function-code"* ]]; then printf '{}\n'
elif [[ "$args" == *"lambda wait function-updated"* ]]; then printf '{}\n'
elif [[ "$args" == *"lambda publish-version"* ]]; then
  if [[ -n "${FAKE_AWS_PUBLISH_FAIL:-}" ]]; then
    printf 'An error occurred (ServiceException) when calling the PublishVersion operation\n' >&2
    exit 254
  fi
  printf '{"Version":"1"}\n'
elif [[ "$args" == *"lambda get-alias"* ]]; then if [[ -f "$FAKE_AWS_STATE/alias" ]]; then printf '{"FunctionVersion":"1"}\n'; else printf 'ResourceNotFoundException: Alias not found.\n' >&2; exit 254; fi
elif [[ "$args" == *"lambda create-alias"* || "$args" == *"lambda update-alias"* ]]; then touch "$FAKE_AWS_STATE/alias"; printf '{}\n'
elif [[ "$args" == *"lambda get-function-url-config"* ]]; then printf '{"FunctionUrl":"https://lambda.example/"}\n'
elif [[ "$args" == *"lambda create-function-url-config"* ]]; then printf '{}\n'
elif [[ "$args" == *"lambda remove-permission"* || "$args" == *"lambda add-permission"* ]]; then printf '{}\n'
elif [[ "$args" == *"lambda get-function-configuration"* ]]; then printf '{"Role":"arn:aws:iam::123:role/test"}\n'
elif [[ "$args" == *"lambda get-function"* ]]; then printf '{"Configuration":{"Version":"1","FunctionArn":"arn:aws:lambda:us-east-1:123:function:checkout-svc"},"Tags":{"sol-owned":"lambda-experiment","sol-service":"checkout-svc"}}\n'
elif [[ "$args" == *"lambda delete-function-url-config"* ]]; then
  if [[ -n "${FAKE_AWS_URL_ABSENT:-}" ]]; then
    printf 'An error occurred (ResourceNotFoundException) when calling the DeleteFunctionUrlConfig operation\n' >&2
    exit 254
  fi
  printf '{}\n'
elif [[ "$args" == *"lambda delete-function"* ]]; then
  if [[ -n "${FAKE_AWS_DELETE_FAIL:-}" ]]; then
    printf 'An error occurred (ServiceException) when calling the DeleteFunction operation\n' >&2
    exit 254
  fi
  rm -f "$FAKE_AWS_STATE/function" "$FAKE_AWS_STATE/alias"; printf '{}\n'
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
export PATH="$work/bin:$PATH" FAKE_AWS_LOG="$work/aws.log" FAKE_AWS_STATE="$work/state"
printf 'token\n' > "$work/token"
cd "$examples"
common=(--profile test --region us-east-1 --service checkout_svc --image repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --role arn:aws:iam::123:role/test --unit checkout/checkout_svc --issuer https://accounts.google.com --jwks-uri https://www.googleapis.com/oauth2/v3/certs)
"$sol" lambda deploy "${common[@]}" --caller checkout/checkout_svc=123 --record "$work/release.json" > "$work/deploy"
grep -q '"kind":"svc"' "$work/deploy"
grep -q '"version":"1"' "$work/deploy"
grep -q 'lambda create-function' "$FAKE_AWS_LOG"
"$sol" lambda verify "${common[@]}" --token-file "$work/token" > "$work/verify"
grep -q '"version":"1"' "$work/verify"
"$sol" lambda rollback "${common[@]}" --to-version 1 --token-file "$work/token" > "$work/rollback"
# A partial destroy that already removed the URL config must be retryable: the second
# delete-function-url-config reports ResourceNotFoundException and must not block deletion.
if FAKE_AWS_DELETE_FAIL=1 "$sol" lambda destroy --profile test --region us-east-1 --service checkout_svc --record "$work/release.json" > /dev/null 2>&1; then
  echo "an injected function-delete failure was reported as successful" >&2
  exit 1
fi
FAKE_AWS_URL_ABSENT=1 "$sol" lambda destroy --profile test --region us-east-1 --service checkout_svc --record "$work/release.json" > /dev/null
[[ ! -f "$work/state/function" ]]
# A first deploy that creates the function and then fails to publish must still leave a
# destroyable ownership record.
if FAKE_AWS_PUBLISH_FAIL=1 "$sol" lambda deploy "${common[@]}" --caller checkout/checkout_svc=123 --record "$work/partial.json" > /dev/null 2>&1; then
  echo "an injected publish failure was reported as a successful deploy" >&2
  exit 1
fi
[[ -f "$work/partial.json" ]]
"$sol" lambda destroy --profile test --region us-east-1 --service checkout_svc --record "$work/partial.json" > /dev/null
[[ ! -f "$work/state/function" ]]
echo "lambda CLI fake-provider test passed"
