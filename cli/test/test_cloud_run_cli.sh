#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GCLOUD_LOG"
case "$1 $2" in
  "run deploy")
    touch "$FAKE_GCLOUD_STATE"
    echo "deployed"
    ;;
  "run services")
    case "$3" in
      describe)
        if [[ ! -f "$FAKE_GCLOUD_STATE" ]]; then
          echo "ERROR: service not found" >&2
          exit 1
        fi
        cat <<'JSON'
{"metadata":{"labels":{"sol-owned":"cloud-run-experiment","sol-service":"checkout_svc"}},"status":{"url":"https://observed.example","latestReadyRevisionName":"rev-1","traffic":[{"revisionName":"rev-1","percent":100}]}}
JSON
        ;;
      list)
        echo "checkout_svc"
        ;;
      *)
        echo "unexpected gcloud: $*" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected gcloud: $*" >&2
    exit 1
    ;;
esac

FAKE
chmod +x "$work/bin/gcloud"
export PATH="$work/bin:$PATH"
export FAKE_GCLOUD_LOG="$work/gcloud.log"
export FAKE_GCLOUD_STATE="$work/deployed"
cd examples/pluto
if ! "$sol" cloud-run deploy \
  --project p --region r --service checkout_svc \
  --image repo@sha256:abc123 \
  --unit checkout/checkout_svc \
  --issuer https://accounts.google.com \
  --jwks-uri https://www.googleapis.com/oauth2/v3/certs \
  --caller checkout/checkout_svc=103076866099743206289 \
  --ingress public > "$work/out" 2> "$work/err"; then
  cat "$work/err" >&2
  exit 1
fi
grep -q '"revision":"rev-1"' "$work/out"
grep -q '"url":"https://observed.example"' "$work/out"
grep -q 'run deploy checkout_svc' "$FAKE_GCLOUD_LOG"
if ! grep -q 'sol-owned=cloud-run-experiment' "$FAKE_GCLOUD_LOG"; then
  cat "$FAKE_GCLOUD_LOG" >&2
  exit 1
fi
grep -q 'SOL_WORKLOAD_SUBJECT_SCHEME=google_oidc_service_account' "$FAKE_GCLOUD_LOG"
echo "cloud-run CLI fake-provider test passed"
