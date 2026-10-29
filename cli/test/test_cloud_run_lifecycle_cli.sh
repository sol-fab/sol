#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
examples="${2:-examples/pluto}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/tmp" "$work/state"
cat > "$work/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_GCLOUD_STATE"
if [[ "$1 $2" == "run deploy" ]]; then
  rev="rev-1"
  [[ -f "$state/revision" ]] && rev="rev-$(($(cat "$state/revision") + 1))"
  printf '%s\n' "${rev#rev-}" > "$state/revision"
  printf '%s\n' "$rev" > "$state/traffic"
  echo "deployed"
  exit 0
fi
if [[ "$1 $2 $3" == "run services describe" ]]; then
  [[ -f "$state/revision" ]] || { echo "ERROR: not found" >&2; exit 1; }
  rev="rev-$(cat "$state/revision")"
  cat <<JSON
{"spec":{"template":{"spec":{"containers":[{"image":"repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}},"metadata":{"name":"checkout-svc","labels":{"sol-owned":"cloud-run-experiment","sol-service":"checkout-svc"}},"status":{"url":"https://service.example","latestReadyRevisionName":"$rev","traffic":[{"revisionName":"$rev","percent":100}]}}
JSON
  exit 0
fi
if [[ "$1 $2 $3" == "run services update-traffic" ]]; then
  rev=""
  for arg in "$@"; do
    case "$arg" in
      --to-revisions=*) rev="${arg#--to-revisions=}"; rev="${rev%=100}" ;;
    esac
  done
  printf '%s\n' "${rev#rev-}" > "$state/revision"
  echo "updated"
  exit 0
fi
if [[ "$1 $2 $3" == "run services list" ]]; then
  [[ -f "$state/revision" ]] && echo "checkout-svc" || true
  exit 0
fi
if [[ "$1 $2 $3" == "run services delete" ]]; then
  rm -f "$state/revision" "$state/traffic"
  echo "deleted"
  exit 0
fi
echo "unexpected gcloud: $*" >&2
exit 1
FAKE
cat > "$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
url=""; config=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    --output|--write-out) shift 2 ;;
    --silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "$url" == */readyz ]]; then printf '\n200'
elif [[ -s "$config" ]] && grep -q 'Authorization: Bearer' "$config"; then printf 'ok\n200'
else printf 'no\n401'; fi
FAKE
chmod +x "$work/bin/gcloud" "$work/bin/curl"
export PATH="$work/bin:$PATH"
export TMPDIR="$work/tmp"
export FAKE_GCLOUD_STATE="$work/state"
printf 'secret-token\n' > "$work/token"
cd "$examples"
common=(--project p --region r --service checkout_svc --image repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --unit checkout/checkout_svc --issuer https://accounts.google.com --jwks-uri https://www.googleapis.com/oauth2/v3/certs)
"$sol" cloud-run deploy "${common[@]}" --caller checkout/checkout_svc=103076866099743206289 --ingress public > "$work/deploy1"
grep -q '"revision":"rev-1"' "$work/deploy1"
"$sol" cloud-run verify "${common[@]}" --token-file "$work/token" --record "$work/release.json" --ingress public > "$work/verify1"
grep -q '"provider_service":"checkout-svc"' "$work/release.json"
"$sol" cloud-run deploy "${common[@]}" --caller checkout/checkout_svc=103076866099743206289 --caller checkout/checkout_svc=999999999999999999999 --ingress public > "$work/deploy2"
grep -q '"revision":"rev-2"' "$work/deploy2"
"$sol" cloud-run rollback "${common[@]}" --revision rev-1 --token-file "$work/token" --ingress public > "$work/rollback"
grep -q '"revision":"rev-1"' "$work/rollback"
"$sol" cloud-run verify "${common[@]}" --token-file "$work/token" --record "$work/release.json" --ingress public > "$work/verify2"
grep -q '"revision":"rev-1"' "$work/release.json"
"$sol" cloud-run destroy "${common[@]}" --caller checkout/checkout_svc=103076866099743206289 --record "$work/release.json" --apply > "$work/destroy"
[[ ! -f "$work/state/revision" ]]
echo "cloud-run full CLI lifecycle test passed"
