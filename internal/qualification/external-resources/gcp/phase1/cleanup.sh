#!/usr/bin/env bash
# Destructive Phase 1 cleanup. Requires explicit approval and the runtime
# service account Sol created for the function.
set -euo pipefail
: "${APPROVED:?set APPROVED=1 only after live qualification is approved}"
: "${RUNTIME_SERVICE_ACCOUNT:?set RUNTIME_SERVICE_ACCOUNT to the function identity}"
PROJECT=sol-qualification
REGION=us-central1
JOB=extqual-gcp-fn
REPOSITORY=sol-extqual-gcp-1
TOPIC=sol-extqual-gcp-1-jobs
SUBSCRIPTION=sol-extqual-gcp-1-jobs-worker
BUCKET=sol-extqual-gcp-1-uploads-819835583654
STATE=gs://sol-qualification-tfstate/sol/extqual-gcp-1/

gcloud run jobs delete "$JOB" --project "$PROJECT" --region "$REGION" --quiet || true
gcloud artifacts repositories delete "$REPOSITORY" --project "$PROJECT" --location "$REGION" --quiet || true
gcloud storage rm --recursive --quiet "gs://$BUCKET" || true
gcloud pubsub subscriptions delete "$SUBSCRIPTION" --project "$PROJECT" --quiet || true
gcloud pubsub topics delete "$TOPIC" --project "$PROJECT" --quiet || true
gcloud iam service-accounts delete "$RUNTIME_SERVICE_ACCOUNT" --project "$PROJECT" --quiet || true
gcloud storage rm --recursive --quiet "$STATE" || true

gcloud run jobs describe "$JOB" --project "$PROJECT" --region "$REGION" >/dev/null 2>&1 && exit 1 || true
gcloud artifacts repositories describe "$REPOSITORY" --project "$PROJECT" --location "$REGION" >/dev/null 2>&1 && exit 1 || true
gcloud storage ls "gs://$BUCKET" >/dev/null 2>&1 && exit 1 || true
gcloud pubsub subscriptions describe "$SUBSCRIPTION" --project "$PROJECT" >/dev/null 2>&1 && exit 1 || true
gcloud pubsub topics describe "$TOPIC" --project "$PROJECT" >/dev/null 2>&1 && exit 1 || true
gcloud iam service-accounts describe "$RUNTIME_SERVICE_ACCOUNT" --project "$PROJECT" >/dev/null 2>&1 && exit 1 || true
echo "Phase 1 GCP resources and extqual-gcp-1 state are absent"
