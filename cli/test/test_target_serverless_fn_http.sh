#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/home"

workspace() {
  local dir="$1" provider="$2" exposure="$3" callers="$4"
  mkdir -p "$dir/app/checkout/quote_fn" "$dir/sol"
  printf 'FROM scratch\n' > "$dir/app/checkout/quote_fn/Dockerfile"
  printf '[service]\nhttp_path = "/quote"\nhttp_exposure = "%s"\n' "$exposure" \
    > "$dir/app/checkout/quote_fn/sol.toml"
  cat > "$dir/sol.yml" <<'YAML'
project: pluto
services:
  quote_fn:
    type: fn
    path: app/checkout/quote_fn
    language: ocaml
YAML
  if [[ "$provider" == gcp ]]; then
    {
      printf 'live:\n  targets:\n    gcp/us-west1:\n      execution: serverless\n      state_bucket: test-state\n      gcp:\n        project_id: example-project\n'
      if [[ "$callers" == yes ]]; then printf '        serverless_callers: checkout/quote_fn=caller\n'; fi
    } > "$dir/sol/environments.yml"
  else
    cat > "$dir/sol/environments.yml" <<'YAML'
live:
  targets:
    aws/us-east-1:
      execution: serverless
      state_bucket: test-state
      aws:
        profile: test
        state_lock_table: test-locks
YAML
  fi
}

two_function_workspace() {
  local dir="$1"
  mkdir -p "$dir/sol"
  for name in quote_fn orders_fn; do
    mkdir -p "$dir/app/checkout/$name"
    printf 'FROM scratch\n' > "$dir/app/checkout/$name/Dockerfile"
  done
  printf '[service]\nhttp_path = "/quote"\nhttp_exposure = "public"\n' > "$dir/app/checkout/quote_fn/sol.toml"
  printf '[service]\nhttp_path = "/orders"\nhttp_exposure = "public"\n' > "$dir/app/checkout/orders_fn/sol.toml"
  cat > "$dir/sol.yml" <<'YAML'
project: pluto
services:
  quote_fn:
    type: fn
    path: app/checkout/quote_fn
    language: ocaml
  orders_fn:
    type: fn
    path: app/checkout/orders_fn
    language: ocaml
YAML
  cat > "$dir/sol/environments.yml" <<'YAML'
live:
  targets:
    gcp/us-west1:
      execution: serverless
      state_bucket: test-state
      gcp:
        project_id: example-project
YAML
}

two_function_aws_workspace() {
  local dir="$1"
  mkdir -p "$dir/sol"
  for name in quote_fn orders_fn; do
    mkdir -p "$dir/app/checkout/$name"
    printf 'FROM scratch\n' > "$dir/app/checkout/$name/Dockerfile"
  done
  printf '[service]\nhttp_path = "/quote"\nhttp_exposure = "public"\n' > "$dir/app/checkout/quote_fn/sol.toml"
  printf '[service]\nhttp_path = "/orders"\nhttp_exposure = "public"\n' > "$dir/app/checkout/orders_fn/sol.toml"
  cat > "$dir/sol.yml" <<'YAML'
project: pluto
services:
  quote_fn:
    type: fn
    path: app/checkout/quote_fn
    language: ocaml
  orders_fn:
    type: fn
    path: app/checkout/orders_fn
    language: ocaml
YAML
  cat > "$dir/sol/environments.yml" <<'YAML'
live:
  targets:
    aws/us-east-1:
      execution: serverless
      state_bucket: test-state
      aws:
        profile: test
        state_lock_table: test-locks
YAML
}

cat > "$work/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"output -json"*) printf '%s\n' '{"serverless_service_accounts":{"value":{"checkout/quote_fn":"sol-runtime@example.iam.gserviceaccount.com","checkout/orders_fn":"sol-runtime@example.iam.gserviceaccount.com"}},"serverless_role_arns":{"value":{"checkout/quote_fn":"arn:aws:iam::123:role/test","checkout/orders_fn":"arn:aws:iam::123:role/test"}}}' ;;
esac
exit 0
FAKE
chmod +x "$work/bin/terraform"

cat > "$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) shift 2 ;;
    --output|--write-out) shift 2 ;;
    --silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "${FAKE_HTTP_FAIL:-0}" == 1 ]]; then printf '\n500'; else printf '\n200'; fi
FAKE
chmod +x "$work/bin/curl"

# --- GCP fake ---------------------------------------------------------------
cat > "$work/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_GCLOUD_STATE"
printf 'gcloud %s\n' "$*" >> "$FAKE_PROVIDER_LOG"
ws="$FAKE_WORKSPACE"
target="$FAKE_TARGET"

if [[ "$1 $2" == "services enable" ]]; then printf '{}\n'; exit 0; fi
if [[ "$1 $2" == "api-gateway apis" ]]; then
  case "$3" in
    describe)
      [[ -f "$state/api" ]] || { echo "ERROR: NOT_FOUND" >&2; exit 1; }
      printf '{"name":"%s","labels":{"sol-owned":"api-gateway-experiment","sol-workspace":"%s","sol-target":"%s"}}\n' "$(cat "$state/api")" "$ws" "$target"
      exit 0 ;;
    create) printf '%s\n' "$4" > "$state/api"; printf '{}\n'; exit 0 ;;
    delete) rm -f "$state/api" "$state/config" "$state/spec"; printf '{}\n'; exit 0 ;;
  esac
fi
if [[ "$1 $2" == "api-gateway api-configs" ]]; then
  case "$3" in
    describe)
      [[ -f "$state/config" ]] || { echo "ERROR: NOT_FOUND" >&2; exit 1; }
      cfg="$(cat "$state/config")"
      [[ "$4" == "$cfg" ]] || { echo "ERROR: NOT_FOUND" >&2; exit 1; }
      printf '{"openapiDocuments":[{"document":{"contents":"%s"}}],"name":"%s"}\n' "$(base64 -w0 < "$state/spec")" "$cfg"
      exit 0 ;;
    create)
      cfg="$4"; cp "$(flag_openapi "$@")" "$state/spec"; printf '%s\n' "$cfg" > "$state/config"; printf '{}\n'; exit 0 ;;
    list) [[ -f "$state/config" ]] && cat "$state/config"; exit 0 ;;
    delete) rm -f "$state/config" "$state/spec"; printf '{}\n'; exit 0 ;;
  esac
fi
if [[ "$1 $2" == "api-gateway gateways" ]]; then
  case "$3" in
    describe)
      [[ -f "$state/gateway" ]] || { echo "ERROR: NOT_FOUND" >&2; exit 1; }
      printf '{"name":"%s","labels":{"sol-owned":"api-gateway-experiment","sol-workspace":"%s","sol-target":"%s"},"apiConfig":"projects/example-project/locations/global/apis/%s/configs/%s","defaultHostname":"gateway.example"}\n' "$4" "$ws" "$target" "$(cat "$state/api")" "$(cat "$state/config")"
      exit 0 ;;
    create|update) touch "$state/gateway"; printf '{}\n'; exit 0 ;;
    delete) rm -f "$state/gateway"; printf '{}\n'; exit 0 ;;
  esac
fi
if [[ "$1 $2" == "run deploy" ]]; then
  svc="$3"
  [[ "$*" == *"SOL_HTTP_EXPOSURE="* ]] || { echo "deploy lost HTTP exposure" >&2; exit 1; }
  [[ "$*" == *"SOL_HTTP_PATH="* ]] || { echo "deploy lost HTTP path" >&2; exit 1; }
  mkdir -p "$state/revisions" "$state/services"
  rev="rev-1"; [[ -f "$state/revisions/$svc" ]] && rev="rev-$(($(cat "$state/revisions/$svc") + 1))"
  printf '%s\n' "${rev#rev-}" > "$state/revisions/$svc"
  touch "$state/services/$svc"
  printf 'deployed %s\n' "$svc"; exit 0
fi
if [[ "$1 $2" == "run services" ]]; then
  case "$3" in
    describe)
      svc="$4"
      [[ -f "$state/revisions/$svc" ]] || { echo "ERROR: not found" >&2; exit 1; }
      rev="rev-$(cat "$state/revisions/$svc")"
      printf '{"spec":{"template":{"spec":{"serviceAccountName":"sol-runtime@example.iam.gserviceaccount.com","containers":[{"image":"repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}},"metadata":{"name":"%s","labels":{"sol-owned":"cloud-run-experiment","sol-service":"%s"}},"status":{"url":"https://%s.example","latestReadyRevisionName":"%s","traffic":[{"revisionName":"%s","percent":100}]}}\n' "$svc" "$svc" "$svc" "$rev" "$rev"
      exit 0 ;;
    update-traffic)
      svc="$4"; rev=""
      for arg in "$@"; do case "$arg" in --to-revisions=*) rev="${arg#--to-revisions=}"; rev="${rev%=100}" ;; esac; done
      printf '%s\n' "${rev#rev-}" > "$state/revisions/$svc"; printf 'updated\n'; exit 0 ;;
    list)
      mkdir -p "$state/services"; for f in "$state"/services/*; do [[ -e "$f" ]] && basename "$f"; done; exit 0 ;;
    delete)
      svc="$4"; rm -f "$state/revisions/$svc" "$state/services/$svc"; printf 'deleted\n'; exit 0 ;;
  esac
fi
echo "unexpected gcloud: $*" >&2
exit 1
FAKE
chmod +x "$work/bin/gcloud"

flag_openapi() {
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--openapi-spec" ]]; then printf '%s' "$2"; return; fi
    shift
  done
}
export -f flag_openapi

# --- AWS fake ---------------------------------------------------------------
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_AWS_STATE"
printf 'aws %s\n' "$*" >> "$FAKE_PROVIDER_LOG"
args="$*"
ws="$FAKE_WORKSPACE"; target="$FAKE_TARGET"
flag() { local name="$1"; shift; while [[ $# -gt 0 ]]; do if [[ "$1" == "$name" ]]; then printf '%s' "$2"; return; fi; shift; done; }

if [[ "$args" == *"lambda list-functions"* ]]; then
  mkdir -p "$state/functions"; first=1; printf '{"Functions":['
  for f in "$state"/functions/*; do [[ -e "$f" ]] || continue; [[ "$first" == 1 ]] || printf ','; first=0; printf '{"FunctionName":"%s"}' "$(basename "$f")"; done
  printf ']}\n'; exit 0
elif [[ "$args" == *"lambda create-function --"* ]]; then
  fn="$(flag --function-name "$@")"
  [[ "$args" == *"sol-owned=lambda-fn-http-experiment"* ]] || { echo "create-function lost ownership tag" >&2; exit 1; }
  mkdir -p "$state/functions"; touch "$state/functions/$fn"; echo 0 > "$state/functions/$fn.version"; printf '{}\n'; exit 0
elif [[ "$args" == *"lambda update-function-code"* || "$args" == *"lambda update-function-configuration"* || "$args" == *"lambda wait function-updated"* ]]; then printf '{}\n'; exit 0
elif [[ "$args" == *"lambda publish-version"* ]]; then
  fn="$(flag --function-name "$@")"; v=$(cat "$state/functions/$fn.version" 2>/dev/null || echo 0); v=$((v+1)); echo "$v" > "$state/functions/$fn.version"; printf '{"Version":"%s"}\n' "$v"; exit 0
elif [[ "$args" == *"lambda get-alias"* ]]; then
  fn="$(flag --function-name "$@")"; [[ -f "$state/functions/$fn.alias" ]] || { echo "ResourceNotFoundException: Alias not found." >&2; exit 254; }; printf '{"FunctionVersion":"%s"}\n' "$(cat "$state/functions/$fn.alias")"; exit 0
elif [[ "$args" == *"lambda create-alias"* || "$args" == *"lambda update-alias"* ]]; then
  fn="$(flag --function-name "$@")"; v="$(flag --function-version "$@")"; printf '%s\n' "$v" > "$state/functions/$fn.alias"; printf '{}\n'; exit 0
elif [[ "$args" == *"lambda invoke"* ]]; then
  out=""; for a in "$@"; do [[ "$a" == /tmp/*.json ]] && out="$a"; done; [[ -n "$out" ]]
  printf '{"statusCode":200,"headers":{"x-sol-fn":"1"},"body":"ok","isBase64Encoded":false}\n' > "$out"
  printf '{"StatusCode":200}\n'; exit 0
elif [[ "$args" == *"lambda add-permission"* || "$args" == *"lambda remove-permission"* ]]; then printf '{}\n'; exit 0
elif [[ "$args" == *"lambda get-function-configuration"* ]]; then printf '{"Role":"arn:aws:iam::123:role/test"}\n'; exit 0
elif [[ "$args" == *"lambda get-function "* && "$args" == *"--query Configuration.FunctionArn"* ]]; then
  fn="$(flag --function-name "$@")"; printf '"arn:aws:lambda:us-east-1:123:function:%s"\n' "$fn"; exit 0
elif [[ "$args" == *"lambda get-function "* ]]; then
  fn="$(flag --function-name "$@")"; printf '{"Configuration":{"Version":"%s"},"Tags":{"sol-owned":"lambda-fn-http-experiment","sol-service":"%s"}}\n' "$(cat "$state/functions/$fn.version")" "$fn"; exit 0
elif [[ "$args" == *"lambda delete-function"* ]]; then
  fn="$(flag --function-name "$@")"; rm -f "$state/functions/$fn" "$state/functions/$fn".*; printf '{}\n'; exit 0
elif [[ "$args" == *"apigatewayv2 get-apis"* ]]; then
  if [[ -f "$state/api" ]]; then printf '{"Items":[{"ApiId":"api-1","Name":"%s","ApiEndpoint":"https://api-1.execute-api.us-east-1.amazonaws.com/"}]}\n' "$(cat "$state/api")"; else printf '{"Items":[]}\n'; fi; exit 0
elif [[ "$args" == *"apigatewayv2 create-api"* ]]; then
  printf '%s\n' "$(flag --name "$@")" > "$state/api"; printf '{"ApiId":"api-1","ApiEndpoint":"https://api-1.execute-api.us-east-1.amazonaws.com/"}\n'; exit 0
elif [[ "$args" == *"apigatewayv2 get-tags"* ]]; then
  printf '{"tags":{"sol-owned":"api-gateway-experiment","sol-workspace":"%s","sol-target":"%s"}}\n' "$ws" "$target"; exit 0
elif [[ "$args" == *"apigatewayv2 get-stages"* ]]; then
  [[ -f "$state/stage" ]] && printf '{"Items":[{"StageName":"$default"}]}\n' || printf '{"Items":[]}\n'; exit 0
elif [[ "$args" == *"apigatewayv2 create-stage"* ]]; then touch "$state/stage"; printf '{}\n'; exit 0
elif [[ "$args" == *"apigatewayv2 get-integrations"* ]]; then
  mkdir -p "$state/integrations"; first=1; printf '{"Items":['
  for f in "$state"/integrations/*; do [[ -e "$f" ]] || continue; [[ "$first" == 1 ]] || printf ','; first=0; printf '{"IntegrationId":"%s","IntegrationUri":"%s"}' "$(basename "$f")" "$(cat "$f")"; done
  printf ']}\n'; exit 0
elif [[ "$args" == *"apigatewayv2 create-integration"* ]]; then
  uri="$(flag --integration-uri "$@")"; fn="$(printf '%s' "$uri" | sed 's/.*function:\([^:]*\):live.*/\1/')"; mkdir -p "$state/integrations"; printf '%s\n' "$uri" > "$state/integrations/int-$fn"; printf '{"IntegrationId":"int-%s"}\n' "$fn"; exit 0
elif [[ "$args" == *"apigatewayv2 update-integration"* ]]; then printf '{}\n'; exit 0
elif [[ "$args" == *"apigatewayv2 get-routes"* ]]; then
  mkdir -p "$state/routes"; first=1; printf '{"Items":['
  for f in "$state"/routes/*; do [[ -e "$f" ]] || continue; [[ "$first" == 1 ]] || printf ','; first=0; printf '{"RouteKey":"%s","RouteId":"%s","Target":"%s"}' "$(cut -d'|' -f1 "$f")" "$(basename "$f")" "$(cut -d'|' -f2 "$f")"; done
  printf ']}\n'; exit 0
elif [[ "$args" == *"apigatewayv2 create-route"* ]]; then
  key="$(flag --route-key "$@")"; target_="$(flag --target "$@")"; mkdir -p "$state/routes"; n=$(find "$state/routes" -type f | wc -l); printf '%s|%s\n' "$key" "$target_" > "$state/routes/route-$n"; printf '{"RouteId":"route-%s"}\n' "$n"; exit 0
elif [[ "$args" == *"apigatewayv2 update-route"* ]]; then printf '{}\n'; exit 0
elif [[ "$args" == *"apigatewayv2 delete-route"* ]]; then rm -f "$state/routes/$(flag --route-id "$@")"; printf '{}\n'; exit 0
elif [[ "$args" == *"apigatewayv2 delete-integration"* ]]; then rm -f "$state/integrations/$(flag --integration-id "$@")"; printf '{}\n'; exit 0
elif [[ "$args" == *"apigatewayv2 delete-api"* ]]; then rm -rf "$state/api" "$state/routes" "$state/integrations" "$state/stage"; printf '{}\n'; exit 0
else printf '{}\n'; exit 0; fi
FAKE
chmod +x "$work/bin/aws"

unset XDG_DATA_HOME
export PATH="$work/bin:$PATH" HOME="$work/home"
export FAKE_GCLOUD_STATE="$work/gcp-state" FAKE_AWS_STATE="$work/aws-state" FAKE_PROVIDER_LOG="$work/provider.log"
mkdir -p "$FAKE_GCLOUD_STATE" "$FAKE_AWS_STATE"
image="repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
image2="repo@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

set_labels() { export FAKE_WORKSPACE="$(basename "$PWD" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9._-]/-/g' | cut -c1-63)"; }

# --- GCP public HTTP function ----------------------------------------------
ws="$work/gcp-public"; workspace "$ws" gcp public no; cd "$ws"; set_labels; export FAKE_TARGET=live-gcp-us-west1
"$sol" plan live/gcp/us-west1 --image-ref "quote_fn=$image" --out "$work/gcp-plan.json" > "$work/gcp-plan"
grep -q 'Sol deployment plan' "$work/gcp-plan"
grep -q 'ADD.*HTTP route' "$work/gcp-plan"
grep -q '"resource":"http_route"' "$work/gcp-plan.json"
[[ ! -f "$FAKE_GCLOUD_STATE/services/quote-fn" ]]
"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" --plan "$work/gcp-plan.json" > "$work/gcp-deploy"
grep -q '"kind":"fn_http"' "$work/gcp-deploy"
grep -q '"kind":"http_gateway"' "$work/gcp-deploy"
grep -q '"url":"https://gateway.example"' "$work/gcp-deploy"
grep -q 'api-gateway apis create' "$FAKE_PROVIDER_LOG"
grep -q 'api-gateway api-configs create' "$FAKE_PROVIDER_LOG"
grep -q 'api-gateway gateways create' "$FAKE_PROVIDER_LOG"
grep -q 'scheduler' "$FAKE_PROVIDER_LOG" && { echo "HTTP function created a scheduler" >&2; exit 1; }
# Re-applying the same reviewed plan is a safe retry: prior state has moved on,
# but the desired-state fingerprint is unchanged.
"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" --plan "$work/gcp-plan.json" --yes > "$work/gcp-retry"
grep -q 'no changes' "$work/gcp-retry"
record=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
[[ -n "$record" ]]
grep -q '"kind":"fn_http"' "$record"
if "$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image2" --plan "$work/gcp-plan.json" --yes > "$work/gcp-plan-image-mismatch" 2>&1; then
  echo "a plan for a different image was applied" >&2; exit 1
fi
grep -q 'no longer matches' "$work/gcp-plan-image-mismatch"
cp "$record" "$work/gcp-record-old"
# Changing the declared path re-routes the shared API; rolling back to the
# previous release restores that release's route as well as its revision.
printf '[service]\nhttp_path = "/v2/quote"\nhttp_exposure = "public"\n' > "$ws/app/checkout/quote_fn/sol.toml"
if "$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" --plan "$work/gcp-plan.json" --yes > "$work/gcp-plan-mismatch" 2>&1; then
  echo "a stale persisted plan was applied" >&2; exit 1
fi
grep -q 'no longer matches' "$work/gcp-plan-mismatch"
if "$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" > "$work/gcp-repath-refused" 2>&1; then
  echo "destructive route change was accepted without --yes" >&2; exit 1
fi
grep -q 're-run with --yes' "$work/gcp-repath-refused"
"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" --yes > "$work/gcp-repath"
grep -q '"/v2/quote"' "$FAKE_GCLOUD_STATE/spec"
"$sol" rollback --target live/gcp/us-west1 --record "$work/gcp-record-old" --service quote_fn --to-revision rev-1 > "$work/gcp-rollback"
grep -q '"revision":"rev-1"' "$work/gcp-rollback"
grep -q '"/quote"' "$FAKE_GCLOUD_STATE/spec"
grep -q '"/v2/quote"' "$FAKE_GCLOUD_STATE/spec" && { echo "rollback left the newer route in the shared API" >&2; exit 1; }
record="$work/gcp-record-old"
"$sol" destroy live/gcp/us-west1 --service quote_fn --record "$record" > "$work/gcp-destroy-plan"
grep -q 'Destruction plan' "$work/gcp-destroy-plan"
[[ -f "$FAKE_GCLOUD_STATE/services/quote-fn" ]]
"$sol" destroy live/gcp/us-west1 --apply --service quote_fn --record "$record" > "$work/gcp-destroy"
grep -q 'Destruction plan' "$work/gcp-destroy"
grep -q 'DELETE.*HTTP route' "$work/gcp-destroy"
grep -q 'DELETE.*gateway' "$work/gcp-destroy"
[[ ! -f "$FAKE_GCLOUD_STATE/gateway" ]]
[[ ! -f "$FAKE_GCLOUD_STATE/api" ]]

# --- GCP internal has no public gateway ------------------------------------
ws="$work/gcp-internal"; workspace "$ws" gcp internal yes; cd "$ws"; set_labels; export FAKE_TARGET=live-gcp-us-west1
: > "$FAKE_PROVIDER_LOG"
"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" > "$work/gcp-internal-deploy"
grep -q '"http_exposure":"internal"' "$work/gcp-internal-deploy"
grep -q '"kind":"http_gateway"' "$work/gcp-internal-deploy" && { echo "internal function created a public gateway" >&2; exit 1; }
grep -Eq 'api-gateway (apis|api-configs|gateways) (create|update)' "$FAKE_PROVIDER_LOG" && { echo "internal function created a public gateway" >&2; exit 1; }
grep -q -- '--ingress internal' "$FAKE_PROVIDER_LOG"
record=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
"$sol" destroy live/gcp/us-west1 --apply --service quote_fn --record "$record" > /dev/null

# --- GCP two functions share one endpoint ----------------------------------
ws="$work/gcp-two"; two_function_workspace "$ws"; cd "$ws"; set_labels; export FAKE_TARGET=live-gcp-us-west1
"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" --image-ref "orders_fn=$image" > "$work/gcp-two-deploy"
grep -q '"kind":"http_gateway"' "$work/gcp-two-deploy"
grep -q '"/quote"' "$FAKE_GCLOUD_STATE/spec"
grep -q '"/orders"' "$FAKE_GCLOUD_STATE/spec"
record_quote=$(grep -l '"service":"quote_fn"' "$work"/home/.local/share/sol/runs/*/serverless-release-quote_fn.json | tail -1)
record_orders=$(grep -l '"service":"orders_fn"' "$work"/home/.local/share/sol/runs/*/serverless-release-orders_fn.json | tail -1)
"$sol" destroy live/gcp/us-west1 --apply --service quote_fn --record "$record_quote" > /dev/null
[[ -f "$FAKE_GCLOUD_STATE/gateway" ]]
! grep -q '"/quote"' "$FAKE_GCLOUD_STATE/spec"
grep -q '"/orders"' "$FAKE_GCLOUD_STATE/spec"
"$sol" destroy live/gcp/us-west1 --apply --service orders_fn --record "$record_orders" > /dev/null
[[ ! -f "$FAKE_GCLOUD_STATE/gateway" ]]

# --- Removed functions are pruned only after explicit confirmation ----------
ws="$work/gcp-prune"; two_function_workspace "$ws"; cd "$ws"; set_labels; export FAKE_TARGET=live-gcp-us-west1
"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" --image-ref "orders_fn=$image" > /dev/null
rm -rf "$ws/app/checkout/orders_fn"
cat > "$ws/sol.yml" <<'YAML'
project: pluto
services:
  quote_fn:
    type: fn
    path: app/checkout/quote_fn
    language: ocaml
YAML
if "$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" > "$work/gcp-prune-refused" 2>&1; then
  echo "removed function was pruned without --yes" >&2; exit 1
fi
grep -q 'DELETE.*workload' "$work/gcp-prune-refused"
grep -q 're-run with --yes' "$work/gcp-prune-refused"
[[ -f "$FAKE_GCLOUD_STATE/services/orders-fn" ]]
"$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" --yes > "$work/gcp-prune-deploy"
[[ ! -f "$FAKE_GCLOUD_STATE/services/orders-fn" ]]
grep -q '"/quote"' "$FAKE_GCLOUD_STATE/spec"
grep -q '"/orders"' "$FAKE_GCLOUD_STATE/spec" && { echo "pruned function route remained" >&2; exit 1; }

# --- AWS public HTTP function uses the gateway, not a Function URL ---------
ws="$work/aws-public"; workspace "$ws" aws public no; cd "$ws"; set_labels; export FAKE_TARGET=live/aws/us-east-1
: > "$FAKE_PROVIDER_LOG"
"$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "quote_fn=$image" > "$work/aws-deploy"
grep -q '"kind":"fn_http"' "$work/aws-deploy"
grep -q '"kind":"http_gateway"' "$work/aws-deploy"
grep -q 'apigatewayv2 create-api' "$FAKE_PROVIDER_LOG"
grep -q 'apigatewayv2 create-route' "$FAKE_PROVIDER_LOG"
grep -q 'create-function-url-config' "$FAKE_PROVIDER_LOG" && { echo "HTTP function created an unrelated Function URL" >&2; exit 1; }
record=$(find "$work/home/.local/share/sol/runs" -name serverless-release.json -type f -print | sort | tail -1)
cp "$record" "$work/aws-record-old"
printf '[service]\nhttp_path = "/v2/quote"\nhttp_exposure = "public"\n' > "$ws/app/checkout/quote_fn/sol.toml"
"$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "quote_fn=$image" --yes > "$work/aws-repath"
grep -q 'ANY /v2/quote' "$FAKE_AWS_STATE"/routes/*
"$sol" rollback --target live/aws/us-east-1 --record "$work/aws-record-old" --service quote_fn --to-version 1 > "$work/aws-rollback"
grep -q '"kind":"fn_http"' "$work/aws-rollback"
grep -q 'ANY /quote' "$FAKE_AWS_STATE"/routes/*
grep -q 'ANY /v2/quote' "$FAKE_AWS_STATE"/routes/* && { echo "rollback left the newer route in the shared API" >&2; exit 1; }
record="$work/aws-record-old"
"$sol" destroy live/aws/us-east-1 --apply --service quote_fn --record "$record" > /dev/null
[[ ! -f "$FAKE_AWS_STATE/api" ]]
[[ ! -f "$FAKE_AWS_STATE/functions/quote-fn" ]]

# --- AWS two functions share one API Gateway ------------------------------
ws="$work/aws-two"; two_function_aws_workspace "$ws"; cd "$ws"; set_labels; export FAKE_TARGET=live/aws/us-east-1
: > "$FAKE_PROVIDER_LOG"
"$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "quote_fn=$image" --image-ref "orders_fn=$image" > "$work/aws-two-deploy"
grep -q '"kind":"http_gateway"' "$work/aws-two-deploy"
grep -q 'ANY /quote' "$FAKE_AWS_STATE"/routes/*
grep -q 'ANY /orders' "$FAKE_AWS_STATE"/routes/*
record_quote=$(grep -l '"service":"quote_fn"' "$work"/home/.local/share/sol/runs/*/serverless-release-quote_fn.json | tail -1)
record_orders=$(grep -l '"service":"orders_fn"' "$work"/home/.local/share/sol/runs/*/serverless-release-orders_fn.json | tail -1)
"$sol" destroy live/aws/us-east-1 --apply --service quote_fn --record "$record_quote" > "$work/aws-two-destroy-quote"
grep -q 'Destruction plan' "$work/aws-two-destroy-quote"
grep -q 'DELETE.*shared HTTP API' "$work/aws-two-destroy-quote" && { echo "destroy removed the shared gateway while another route remained" >&2; exit 1; }
[[ -f "$FAKE_AWS_STATE/api" ]]
! grep -q 'ANY /quote' "$FAKE_AWS_STATE"/routes/*
grep -q 'ANY /orders' "$FAKE_AWS_STATE"/routes/*
"$sol" destroy live/aws/us-east-1 --apply --service orders_fn --record "$record_orders" > "$work/aws-two-destroy-orders"
grep -q 'DELETE.*shared HTTP API' "$work/aws-two-destroy-orders"
[[ ! -f "$FAKE_AWS_STATE/api" ]]

# --- Refusals happen before mutation --------------------------------------
ws="$work/aws-internal"; workspace "$ws" aws internal yes; cd "$ws"; set_labels; export FAKE_TARGET=live/aws/us-east-1
: > "$FAKE_PROVIDER_LOG"
if "$sol" deploy live/aws/us-east-1 --image-tag test --image-ref "quote_fn=$image" > "$work/aws-internal-refuse" 2>&1; then
  echo "AWS internal HTTP function was accepted" >&2; exit 1
fi
grep -q 'public exposure only' "$work/aws-internal-refuse"
[[ ! -s "$FAKE_PROVIDER_LOG" ]]

ws="$work/gcp-ts"; workspace "$ws" gcp public no; cd "$ws"; set_labels; export FAKE_TARGET=live-gcp-us-west1
sed -i 's/language: ocaml/language: typescript/' "$ws/sol.yml"
: > "$FAKE_PROVIDER_LOG"
if "$sol" deploy live/gcp/us-west1 --image-tag test --image-ref "quote_fn=$image" > "$work/gcp-ts-refuse" 2>&1; then
  echo "TypeScript HTTP function was accepted without a runtime" >&2; exit 1
fi
grep -q 'TypeScript' "$work/gcp-ts-refuse"
[[ ! -s "$FAKE_PROVIDER_LOG" ]]

echo "HTTP function target lifecycle test passed"
