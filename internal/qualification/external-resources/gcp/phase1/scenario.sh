#!/usr/bin/env bash
# Shared-runner adapter for the GCP external-resource Phase 1 fixture.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$HERE/ws"
PROJECT=sol-qualification
REGION=us-central1
TARGET=extqual-gcp-1/gcp/us-central1
JOB=extqual-gcp-fn
REPOSITORY=sol-extqual-gcp-1
TOPIC=sol-extqual-gcp-1-jobs
SUBSCRIPTION=sol-extqual-gcp-1-jobs-worker
BUCKET=sol-extqual-gcp-1-uploads-819835583654
UNRELATED_TOPIC=sol-extqual-gcp-1-unrelated
UNRELATED_BUCKET=sol-extqual-gcp-1-unrelated-819835583654
TAG="$(printf '%s' "${ATTEMPT:-extqual}" | tr '[:upper:]_' '[:lower:]-' | cut -c1-40)"
IMAGE="$REGION-docker.pkg.dev/$PROJECT/$REPOSITORY/extqual-gcp-fn:$TAG"

scenario_plan() {
  ( cd "$WS" && "$SOL" check )
  printf 'target=%s\njob=%s\nimage=%s\ntopic=%s\nsubscription=%s\nbucket=%s\n' \
    "$TARGET" "$JOB" "$IMAGE" "$TOPIC" "$SUBSCRIPTION" "$BUCKET"
}

scenario_inventory() {
  gcloud pubsub topics describe "$TOPIC" --project "$PROJECT" --format='value(name)'
  gcloud pubsub subscriptions describe "$SUBSCRIPTION" --project "$PROJECT" --format='value(name)'
  gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT" --format='value(name)'
  gcloud artifacts repositories describe "$REPOSITORY" --project "$PROJECT" --location "$REGION" --format='value(name)'
  gcloud run jobs describe "$JOB" --project "$PROJECT" --region "$REGION" --format='value(name)'
  gcloud pubsub topics describe "$UNRELATED_TOPIC" --project "$PROJECT" --format='value(name)'
  gcloud storage buckets describe "gs://$UNRELATED_BUCKET" --project "$PROJECT" --format='value(name)'
}

scenario_prepare() {
  gcloud pubsub topics create "$TOPIC" --project "$PROJECT"
  gcloud pubsub subscriptions create "$SUBSCRIPTION" --project "$PROJECT" --topic "$TOPIC"
  gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT" --location "$REGION"
  gcloud pubsub topics create "$UNRELATED_TOPIC" --project "$PROJECT"
  gcloud storage buckets create "gs://$UNRELATED_BUCKET" --project "$PROJECT" --location "$REGION"
  gcloud artifacts repositories create "$REPOSITORY" --project "$PROJECT" \
    --location "$REGION" --repository-format docker
  gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet
  docker build -t "$IMAGE" "$WS/app/extqual/extqual_gcp_fn"
  docker push "$IMAGE"
}

scenario_execute() {
  ( cd "$WS" && XDG_DATA_HOME="$LOG_DIR/xdg" "$SOL" deploy "$TARGET" \
      --image-tag "$TAG" --image-ref "extqual_gcp_fn=$IMAGE" ) >"$LOG_DIR/deploy.json"
}

scenario_assert() {
  python3 - "$LOG_DIR/deploy.json" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
assert release["kind"] == "fn" and release["provider"] == "gcp", release
assert release["execution"], "deploy returned no execution"
assert release["service_account"], "deploy returned no runtime service account"
PY
  local execution
  execution="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["execution"])' "$LOG_DIR/deploy.json")"
  gcloud logging read \
    "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"$JOB\" AND labels.\"run.googleapis.com/execution_name\"=\"$execution\"" \
    --project "$PROJECT" --limit 50 --format='value(textPayload)' >"$LOG_DIR/positive.log"
  grep -q '"status": "ok"' "$LOG_DIR/positive.log" || { echo "positive execution did not report success" >&2; return 1; }
  gcloud run jobs update "$JOB" --project "$PROJECT" --region "$REGION" \
    --update-env-vars "NEGATIVE_TOPIC=$UNRELATED_TOPIC,NEGATIVE_BUCKET=$UNRELATED_BUCKET" --quiet
  gcloud run jobs execute "$JOB" --project "$PROJECT" --region "$REGION" --wait --format=json >"$LOG_DIR/negative-execution.json"
  execution="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["name"])' "$LOG_DIR/negative-execution.json")"
  gcloud logging read \
    "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"$JOB\" AND labels.\"run.googleapis.com/execution_name\"=\"$execution\"" \
    --project "$PROJECT" --limit 50 --format='value(textPayload)' >"$LOG_DIR/negative.log"
  grep -q '"denied": \["publish", "object-write"\]' "$LOG_DIR/negative.log" || {
    echo "negative execution did not report both denials" >&2; return 1; }
}

scenario_cleanup() {
  local sa=""
  if [ -s "$LOG_DIR/deploy.json" ]; then
    sa="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("service_account", ""))' "$LOG_DIR/deploy.json")"
  fi
  APPROVED=1 RUNTIME_SERVICE_ACCOUNT="$sa" "$HERE/cleanup.sh"
  gcloud pubsub topics delete "$UNRELATED_TOPIC" --project "$PROJECT" --quiet || true
  gcloud storage rm --recursive --quiet "gs://$UNRELATED_BUCKET" || true
}

scenario_absence() {
  ! gcloud pubsub topics describe "$TOPIC" --project "$PROJECT" >/dev/null 2>&1
  ! gcloud pubsub subscriptions describe "$SUBSCRIPTION" --project "$PROJECT" >/dev/null 2>&1
  ! gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT" >/dev/null 2>&1
  ! gcloud artifacts repositories describe "$REPOSITORY" --project "$PROJECT" --location "$REGION" >/dev/null 2>&1
  ! gcloud run jobs describe "$JOB" --project "$PROJECT" --region "$REGION" >/dev/null 2>&1
  ! gcloud pubsub topics describe "$UNRELATED_TOPIC" --project "$PROJECT" >/dev/null 2>&1
  ! gcloud storage buckets describe "gs://$UNRELATED_BUCKET" --project "$PROJECT" >/dev/null 2>&1
  echo "all Phase 1 GCP resources are absent"
}

scenario_evidence() {
  printf 'scenario=external-gcp-phase1\nprovider=gcp\ntarget=%s\n' "$TARGET"
  for file in deploy.json positive.log negative.log absence.txt cleanup-verdict.txt inventory-before.txt inventory-after.txt; do
    [ -f "$LOG_DIR/$file" ] && printf 'evidence=%s\n' "$file"
  done
}
