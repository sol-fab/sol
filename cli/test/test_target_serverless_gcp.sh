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
    gcp/us-west1:
      execution: serverless
      state_bucket: test-state
      gcp:
        project_id: example-project
        serverless_callers: checkout/checkout_svc=123
YAML
cat > "$work/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"output -json"*)
    printf '%s
' '{"serverless_service_accounts":{"value":{"checkout/checkout_svc":"sol-runtime@example.iam.gserviceaccount.com"}}}'
    ;;
esac
exit 0
FAKE
chmod +x "$work/bin/terraform"
cat > "$work/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_GCLOUD_STATE"
if [[ "$1 $2" == "run deploy" ]]; then
  [[ "$*" == *"--service-account sol-runtime@example.iam.gserviceaccount.com"* ]] || { echo "deploy lost runtime identity" >&2; exit 1; }
  rev="rev-1"
  [[ -f "$state/revision" ]] && rev="rev-$(($(cat "$state/revision") + 1))"
  printf '%s\n' "${rev#rev-}" > "$state/revision"
  echo "deployed"
  exit 0
fi
if [[ "$1 $2 $3" == "run services describe" ]]; then
  [[ -f "$state/revision" ]] || { echo "ERROR: not found" >&2; exit 1; }
  rev="rev-$(cat "$state/revision")"
  cat <<JSON
{"spec":{"template":{"spec":{"serviceAccountName":"sol-runtime@example.iam.gserviceaccount.com","containers":[{"image":"repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}},"metadata":{"name":"checkout-svc","labels":{"sol-owned":"cloud-run-experiment","sol-service":"checkout-svc"}},"status":{"url":"https://service.example","latestReadyRevisionName":"$rev","traffic":[{"revisionName":"$rev","percent":100}]}}
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
  if [[ "${FAKE_TRAFFIC_ERROR:-0}" == 1 ]]; then
    echo "simulated update-traffic transport failure" >&2
    exit 1
  fi
  echo "updated"
  exit 0
fi
if [[ "$1 $2 $3" == "run services list" ]]; then
  [[ -f "$state/revision" ]] && echo "checkout-svc" || true
  exit 0
fi
if [[ "$1 $2 $3" == "run services delete" ]]; then
  rm -f "$state/revision"
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
if [[ "${FAKE_HTTP_FAIL:-0}" == 1 ]]; then printf '\n500'
elif [[ "$url" == */readyz ]]; then printf '\n200'
elif [[ -s "$config" ]] && grep -q 'Authorization: Bearer' "$config"; then printf 'ok\n200'
else printf 'no\n401'; fi
FAKE
chmod +x "$work/bin/gcloud" "$work/bin/curl"
unset XDG_DATA_HOME
export PATH="$work/bin:$PATH" FAKE_GCLOUD_STATE="$work/state" HOME="$work/home"
printf 'token\n' > "$work/token"
cd "$work/ws"
"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref checkout_svc=repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$work/deploy"
grep -q '"revision":"rev-1"' "$work/deploy"
grep -q '"project":"example-project"' "$work/deploy"
grep -q '"provider_service":"checkout-svc"' "$work/deploy"
record=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
[[ -n "$record" ]]
grep -q '"revision":"rev-1"' "$record"
"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref checkout_svc=repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$work/deploy2"
grep -q '"revision":"rev-2"' "$work/deploy2"

# A deploy that moves traffic but fails its post-deploy smoke must still leave the
# ownership record naming the revision that is live.
if FAKE_HTTP_FAIL=1 "$sol" deploy live/gcp/us-west1 --image-tag test --image-ref checkout_svc=repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$work/deploy-fail" 2>&1; then
  echo "deploy accepted a failed post-deploy smoke" >&2; exit 1
fi
grep -q 'post-deploy readiness 500' "$work/deploy-fail"
record_fail=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
grep -q '"revision":"rev-3"' "$record_fail"
record="$record_fail"

"$sol" rollback --target live/gcp/us-west1 --record "$record" --service checkout_svc --to-revision rev-1 --token-file "$work/token" > "$work/rollback"
grep -q '"revision":"rev-1"' "$work/rollback"
grep -q '"revision":"rev-1"' "$record"

# A traffic update that applied but whose CLI call reported an error is reconciled
# against observed traffic; the original error is preserved as a warning.
FAKE_TRAFFIC_ERROR=1 "$sol" rollback --target live/gcp/us-west1 --record "$record" --service checkout_svc --to-revision rev-2 --token-file "$work/token" > "$work/rollback-reconcile" 2>&1
grep -q '"revision":"rev-2"' "$work/rollback-reconcile"
grep -q 'reconciled' "$work/rollback-reconcile"
[[ "$(cat "$work/state/revision")" == 2 ]]
grep -q '"revision":"rev-2"' "$record"

# A rollback whose smoke fails after traffic moved must leave the record naming the
# revision the provider is actually serving.
if FAKE_HTTP_FAIL=1 "$sol" rollback --target live/gcp/us-west1 --record "$record" --service checkout_svc --to-revision rev-1 --token-file "$work/token" > "$work/rollback-fail" 2>&1; then
  echo "rollback accepted a failed post-rollback smoke" >&2; exit 1
fi
grep -q 'serving verification failed' "$work/rollback-fail"
[[ "$(cat "$work/state/revision")" == 1 ]]
grep -q '"revision":"rev-1"' "$record"

"$sol" destroy live/gcp/us-west1 --apply --service checkout_svc --record "$record" > /dev/null
[[ ! -f "$work/state/revision" ]]
echo "target serverless GCP deploy/rollback/destroy fake-provider test passed"
