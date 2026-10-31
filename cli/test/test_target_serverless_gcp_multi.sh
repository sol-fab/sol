#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
examples="${2:-examples/pluto}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/home" "$work/ws/app/checkout" "$work/ws/app/payments"
ln -s "$(cd "$examples/app/checkout/checkout_svc" && pwd)" "$work/ws/app/checkout/checkout_svc"
ln -s "$(cd "$examples/app/payments/charge_svc" && pwd)" "$work/ws/app/payments/charge_svc"
cat > "$work/ws/sol.yml" <<'YAML'
project: pluto
services:
  checkout_svc:
    type: http
    path: app/checkout/checkout_svc
    language: ocaml
  charge_svc:
    type: http
    path: app/payments/charge_svc
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
    printf '%s\n' '{"serverless_service_accounts":{"value":{"checkout/checkout_svc":"sol-runtime-checkout@example.iam.gserviceaccount.com","payments/charge_svc":"sol-runtime-orders@example.iam.gserviceaccount.com"}}}'
    ;;
esac
exit 0
FAKE
cat > "$work/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_GCLOUD_STATE"
case "$1 $2" in
  "run services")
    case "$3" in
      list)
        [[ -f "$state/checkout-svc" ]] && echo checkout-svc
        [[ -f "$state/charge-svc" ]] && echo charge-svc
        ;;
      describe)
        service="$4"
        [[ -f "$state/$service" ]] || { echo "ERROR: not found" >&2; exit 1; }
        printf '{"spec":{"template":{"spec":{"serviceAccountName":"%s"}}},"metadata":{"name":"%s","labels":{"sol-owned":"cloud-run-experiment","sol-service":"%s"}},"status":{"url":"https://%s.example","latestReadyRevisionName":"rev-1","traffic":[{"revisionName":"rev-1","percent":100}]}}\n' \
          "$(cat "$state/$service.role")" "$service" "$service" "$service"
        ;;
    esac
    ;;
  "run deploy")
    service="$3"
    touch "$state/$service"
    case "$service" in
      checkout-svc) echo "sol-runtime-checkout@example.iam.gserviceaccount.com" > "$state/$service.role" ;;
      charge-svc) echo "sol-runtime-orders@example.iam.gserviceaccount.com" > "$state/$service.role" ;;
    esac
    ;;
esac
exit 0
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
chmod +x "$work/bin/gcloud" "$work/bin/terraform" "$work/bin/curl"
export PATH="$work/bin:$PATH" FAKE_GCLOUD_STATE="$work/state" HOME="$work/home"
cd "$work/ws"
image=repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"$sol" deploy live/gcp/us-west1 --image-tag test \
  --image-ref checkout_svc="$image" --image-ref charge_svc="$image" > "$work/deploy"
[[ "$(grep -c '"service":"' "$work/deploy")" -eq 2 ]]
[[ -f "$HOME/.local/share/sol/runs" ]] || true
records="$(find "$HOME/.local/share/sol/runs" -name 'serverless-release-*.json' -type f | wc -l | tr -d ' ')"
[[ "$records" -eq 2 ]]
echo "GCP multi-unit serverless fake-provider test passed"
