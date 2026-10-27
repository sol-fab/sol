#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/tmp"
cat > "$work/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2 $3" in
  "run services describe")
    cat <<'JSON'
{"metadata":{"labels":{"sol-owned":"cloud-run-experiment","sol-service":"checkout_svc"}},"status":{"url":"https://observed.example","latestReadyRevisionName":"rev-1","traffic":[{"revisionName":"rev-1","percent":100}]}}
JSON
    ;;
  *)
    echo "unexpected gcloud: $*" >&2
    exit 1
    ;;
esac
FAKE
cat > "$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
url=""
config=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    --output|--write-out) shift 2 ;;
    --silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "$url" == */readyz ]]; then
  printf '\n200'
elif [[ -s "$config" ]] && grep -q 'Authorization: Bearer' "$config"; then
  printf 'ok\n200'
else
  printf 'no\n401'
fi
FAKE
chmod +x "$work/bin/gcloud" "$work/bin/curl"
export PATH="$work/bin:$PATH"
export TMPDIR="$work/tmp"
printf 'secret-token\n' > "$work/token"
cd examples/pluto
if ! "$sol" cloud-run verify \
  --project p --region r --service checkout_svc \
  --image repo@sha256:abc123 \
  --unit checkout/checkout_svc \
  --issuer https://accounts.google.com \
  --jwks-uri https://www.googleapis.com/oauth2/v3/certs \
  --token-file "$work/token" \
  --record "$work/release.json" \
  --ingress public > "$work/out" 2> "$work/err"; then
  cat "$work/err" >&2
  exit 1
fi
grep -q '"revision":"rev-1"' "$work/release.json"
[[ ! -n "$(find "$work/tmp" -name 'sol-cloud-run-curl-*' -print -quit)" ]]
printf 'first-token\nsecond-token\n' > "$work/bad-token"
if "$sol" cloud-run verify \
  --project p --region r --service checkout_svc \
  --image repo@sha256:abc123 \
  --unit checkout/checkout_svc \
  --issuer https://accounts.google.com \
  --jwks-uri https://www.googleapis.com/oauth2/v3/certs \
  --token-file "$work/bad-token" --ingress public > /dev/null 2> "$work/bad-err"; then
  echo "multi-line token was accepted" >&2
  exit 1
fi
grep -q 'exactly one token' "$work/bad-err"
echo "cloud-run verify CLI/token cleanup test passed"
