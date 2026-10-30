#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/home"
cat > "$work/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_GCLOUD_STATE"
printf '%s\n' "$*" >> "$state/calls.log"
args="$*"

if [[ "$args" == *"run deploy checkout-task"* ]]; then
  [[ "$args" == *"--no-allow-unauthenticated"* && "$args" == *"--concurrency 1"* && "$args" == *"--max-instances 7"* && "$args" == *"--timeout 60"* ]] || { echo "run deploy lost settings" >&2; exit 1; }
  [[ "$args" == *"SOL_TASK_RUNTIME=pubsub"* ]] || { echo "run deploy lost runtime env" >&2; exit 1; }
  if [[ "${FAKE_RUN_DEPLOY_FAIL:-0}" == 1 ]]; then echo "simulated run deploy failure" >&2; exit 1; fi
  v=$(cat "$state/revision" 2>/dev/null || echo 0); v=$((v+1)); echo "$v" > "$state/revision"
  touch "$state/service"; printf 'deployed\n'
elif [[ "$args" == *"run services describe checkout-task"* ]]; then
  [[ -f "$state/service" ]] || { echo "NOT_FOUND: service" >&2; exit 1; }
  owner="$(cat "$state/service-owner" 2>/dev/null || echo cloud-run-task-experiment)"
  v=$(cat "$state/revision"); printf '{"metadata":{"labels":{"sol-owned":"%s","sol-service":"checkout-task"}},"status":{"url":"https://task.example","latestReadyRevisionName":"rev-%s","traffic":[{"revisionName":"rev-%s","percent":100}]}}\n' "$owner" "$v" "$v"
elif [[ "$args" == *"run services update-traffic checkout-task"* ]]; then
  rev=""; for arg in "$@"; do case "$arg" in --to-revisions=*) rev="${arg#--to-revisions=}"; rev="${rev%=100}";; esac; done
  echo "${rev#rev-}" > "$state/revision"; printf 'updated\n'
elif [[ "$args" == *"run services delete checkout-task"* ]]; then rm -f "$state/service"; printf 'deleted\n'
elif [[ "$args" == *"run services add-iam-policy-binding"* || "$args" == *"run services remove-iam-policy-binding"* || "$args" == *"iam service-accounts add-iam-policy-binding"* || "$args" == *"iam service-accounts remove-iam-policy-binding"* ]]; then
  member=""; for arg in "$@"; do case "$arg" in --member=serviceAccount:*) member="${arg#--member=serviceAccount:}";; esac; done
  if [[ "$args" == *"run services add-iam-policy-binding"* ]]; then printf '%s\n' "$member" > "$state/run-invoker"; fi
  if [[ "$args" == *"iam service-accounts add-iam-policy-binding"* ]]; then touch "$state/sa-token-creator"; fi
  printf '{}\n'
elif [[ "$args" == *"run services get-iam-policy"* ]]; then
  if [[ -f "$state/run-invoker" ]]; then
    printf '{"bindings":[{"role":"roles/run.invoker","members":["serviceAccount:%s"]}]}\n' "$(cat "$state/run-invoker")"
  else
    printf '{"bindings":[]}\n'
  fi
elif [[ "$args" == *"iam service-accounts get-iam-policy"* ]]; then
  if [[ -f "$state/sa-token-creator" ]]; then
    printf '{"bindings":[{"role":"roles/iam.serviceAccountTokenCreator","members":["serviceAccount:service-123@gcp-sa-pubsub.iam.gserviceaccount.com"]}]}\n'
  else
    printf '{"bindings":[]}\n'
  fi
elif [[ "$args" == *"iam service-accounts create"* ]]; then
  for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--description=sol-owned=cloud-run-task-experiment" ]]; then :; fi; done
  name=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "create" ]]; then j=$((i+1)); name="${!j}"; fi; done
  echo "sol-owned=cloud-run-task-experiment" > "$state/sa-$name.description"; printf 'created\n'
elif [[ "$args" == *"iam service-accounts describe"* ]]; then
  email=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "describe" ]]; then j=$((i+1)); email="${!j}"; fi; done
  name="${email%%@*}"
  [[ -f "$state/sa-$name.description" ]] || { echo "NOT_FOUND: service account" >&2; exit 1; }
  printf '{"email":"%s","description":"%s"}\n' "$email" "$(cat "$state/sa-$name.description")"
elif [[ "$args" == *"iam service-accounts delete"* ]]; then
  email=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "delete" ]]; then j=$((i+1)); email="${!j}"; fi; done
  if [[ -z "${FAKE_GCP_SA_LINGER:-}" ]]; then
    rm -f "$state/sa-${email%%@*}.description"
  fi
  printf 'deleted\n'
elif [[ "$args" == *"projects describe"* ]]; then printf '123\n'
elif [[ "$args" == *"pubsub topics create"* ]]; then
  name=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "create" ]]; then j=$((i+1)); name="${!j}"; fi; done
  touch "$state/topic-$name"; printf 'created\n'
elif [[ "$args" == *"pubsub topics describe"* ]]; then
  name=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "describe" ]]; then j=$((i+1)); name="${!j}"; fi; done
  [[ -f "$state/topic-$name" ]] || { echo "NOT_FOUND: topic" >&2; exit 1; }
  printf '{"name":"projects/p/topics/%s","labels":{"sol-owned":"cloud-run-task-experiment","sol-service":"checkout-task"}}\n' "$name"
elif [[ "$args" == *"pubsub topics add-iam-policy-binding"* ]]; then
  member=""; for arg in "$@"; do case "$arg" in --member=serviceAccount:*) member="${arg#--member=serviceAccount:}";; esac; done
  echo "$member" > "$state/dlq-publisher"; printf '{}\n'
elif [[ "$args" == *"pubsub topics get-iam-policy"* ]]; then
  member="$(cat "$state/dlq-publisher" 2>/dev/null || echo '')"
  printf '{"bindings":[{"role":"roles/pubsub.publisher","members":["serviceAccount:%s"]}]}\n' "$member"
elif [[ "$args" == *"pubsub topics update"* ]]; then printf 'updated\n'
elif [[ "$args" == *"pubsub topics delete"* ]]; then
  name=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "delete" ]]; then j=$((i+1)); name="${!j}"; fi; done
  rm -f "$state/topic-$name"; printf 'deleted\n'
elif [[ "$args" == *"pubsub topics publish"* ]]; then
  body=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--message" ]]; then j=$((i+1)); body="${!j}"; fi; done
  printf '%s\n' "$body" >> "$state/messages"; printf '{"messageIds":["msg-1"]}\n'
elif [[ "$args" == *"pubsub subscriptions create"* ]]; then
  if [[ "${FAKE_SUBSCRIPTION_FAIL:-0}" == 1 ]]; then echo "simulated subscription failure" >&2; exit 1; fi
  name=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "create" ]]; then j=$((i+1)); name="${!j}"; fi; done
  endpoint=""; attempts=""; sa=""; for arg in "$@"; do case "$arg" in --push-endpoint=*) endpoint="${arg#--push-endpoint=}";; --max-delivery-attempts=*) attempts="${arg#--max-delivery-attempts=}";; --push-auth-service-account=*) sa="${arg#--push-auth-service-account=}";; esac; done
  printf '%s\n%s\n%s\n' "$endpoint" "$attempts" "$sa" > "$state/sub-$name"
  printf 'created\n'
elif [[ "$args" == *"pubsub subscriptions describe"* ]]; then
  name=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "describe" ]]; then j=$((i+1)); name="${!j}"; fi; done
  [[ -f "$state/sub-$name" ]] || { echo "NOT_FOUND: subscription" >&2; exit 1; }
  endpoint="$(sed -n 1p "$state/sub-$name")"; attempts="$(sed -n 2p "$state/sub-$name")"; sa="$(sed -n 3p "$state/sub-$name")"
  if [[ -z "$endpoint" ]]; then
    printf '{"labels":{"sol-owned":"cloud-run-task-experiment","sol-service":"checkout-task"},"ackDeadlineSeconds":10}\n'
  else
    printf '{"labels":{"sol-owned":"cloud-run-task-experiment","sol-service":"checkout-task"},"pushConfig":{"pushEndpoint":"%s","oidcToken":{"serviceAccountEmail":"%s"}},"deadLetterPolicy":{"maxDeliveryAttempts":%s},"ackDeadlineSeconds":60}\n' "$endpoint" "$sa" "$attempts"
  fi
elif [[ "$args" == *"pubsub subscriptions update"* ]]; then
  name=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "update" ]]; then j=$((i+1)); name="${!j}"; fi; done
  endpoint=""; attempts=""; sa=""; for arg in "$@"; do case "$arg" in --push-endpoint=*) endpoint="${arg#--push-endpoint=}";; --max-delivery-attempts=*) attempts="${arg#--max-delivery-attempts=}";; --push-auth-service-account=*) sa="${arg#--push-auth-service-account=}";; esac; done
  printf '%s\n%s\n%s\n' "$endpoint" "$attempts" "$sa" > "$state/sub-$name"
  printf 'updated\n'
elif [[ "$args" == *"pubsub subscriptions delete"* ]]; then
  name=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "delete" ]]; then j=$((i+1)); name="${!j}"; fi; done
  rm -f "$state/sub-$name"; printf 'deleted\n'
else
  printf '{}\n'
fi
FAKE
chmod +x "$work/bin/gcloud"
export PATH="$work/bin:$PATH" FAKE_GCLOUD_STATE="$work/state" HOME="$work/home"
mkdir -p "$work/ws"; cd "$work/ws"
image="repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
common=(--project p --region us-west1 --service checkout --image "$image" --max-attempts 7 --ack-deadline 60 --dlq-retention 604800 --concurrency 7)

# Foreign ownership is refused before mutation.
touch "$work/state/service"; echo 1 > "$work/state/revision"; echo other > "$work/state/service-owner"
if "$sol" task gcp deploy "${common[@]}" --record "$work/foreign.json" > "$work/foreign.out" 2>&1; then
  echo "deploy adopted a foreign Cloud Run service" >&2; exit 1
fi
grep -q 'without this adapter' "$work/foreign.out"
grep -q 'run deploy checkout-task' "$work/state/calls.log" && { echo "deploy mutated a foreign service" >&2; exit 1; }
rm -f "$work/state/service" "$work/state/revision" "$work/state/service-owner"

"$sol" task gcp deploy "${common[@]}" --record "$work/release.json" > "$work/deploy.json"
grep -q '"kind":"gcp-task"' "$work/deploy.json"
grep -q '"cloud_run_service":"checkout-task"' "$work/deploy.json"
grep -q '"topic":"checkout-task"' "$work/deploy.json"
grep -q '"subscription":"checkout-task-sub"' "$work/deploy.json"
grep -q '"dlq_topic":"checkout-task-dlq"' "$work/deploy.json"
grep -q '"dlq_subscription":"checkout-task-dlq-sub"' "$work/deploy.json"
grep -Eq '"push_service_account":"checkout-push-[0-9a-f]{6}@p.iam.gserviceaccount.com"' "$work/deploy.json"
grep -q 'run services add-iam-policy-binding' "$work/state/calls.log"
grep -q 'iam service-accounts add-iam-policy-binding' "$work/state/calls.log"
grep -q 'pubsub topics add-iam-policy-binding checkout-task-dlq' "$work/state/calls.log"

"$sol" task gcp verify --project p --region us-west1 --service checkout --record "$work/release.json" > "$work/verify.json"
grep -q '"revision":"rev-1"' "$work/verify.json"

"$sol" task gcp enqueue --project p --region us-west1 --service checkout --record "$work/release.json" --kind echo --payload '{"message":"hi"}' > "$work/enqueue.json"
grep -q '"message_id":"msg-1"' "$work/enqueue.json"
grep -q '"kind":"echo"' "$work/state/messages"

"$sol" task gcp deploy "${common[@]}" --record "$work/release.json" > "$work/deploy2.json"
grep -q '"revision":"rev-2"' "$work/deploy2.json"
"$sol" task gcp rollback --project p --region us-west1 --service checkout --record "$work/release.json" --to-revision rev-1 > "$work/rollback.json"
grep -q '"revision":"rev-1"' "$work/rollback.json"
grep -q '"revision":"rev-1"' "$work/release.json"
[[ "$(cat "$work/state/revision")" == 1 ]]

"$sol" task gcp destroy --project p --region us-west1 --service checkout --record "$work/release.json" > "$work/destroy.out" 2>&1 && {
  echo "destroy without --apply was accepted" >&2; exit 1
}
grep -q 'requires --apply' "$work/destroy.out"
"$sol" task gcp destroy --project p --region us-west1 --service checkout --record "$work/release.json" --apply > /dev/null
[[ ! -f "$work/state/service" ]]
[[ ! -f "$work/state/topic-checkout-task" ]]
[[ ! -f "$work/state/topic-checkout-task-dlq" ]]
[[ ! -f "$work/state/sub-checkout-task-sub" ]]
[[ ! -f "$work/state/sub-checkout-task-dlq-sub" ]]
[[ ! -f "$work/state/sa-checkout-push.description" ]]

# A failure after topics/SA/service exist must leave a record that can clean them up.
FAKE_SUBSCRIPTION_FAIL=1 "$sol" task gcp deploy "${common[@]}" --record "$work/partial.json" > "$work/partial.out" 2>&1 && {
  echo "deploy accepted a subscription failure" >&2; exit 1
}
[[ -f "$work/partial.json" ]]
grep -q '"subscription":"checkout-task-sub"' "$work/partial.json"
grep -q '"dlq_subscription":"checkout-task-dlq-sub"' "$work/partial.json"
"$sol" task gcp destroy --project p --region us-west1 --service checkout --record "$work/partial.json" --apply > /dev/null
[[ ! -f "$work/state/service" ]]
[[ ! -f "$work/state/topic-checkout-task" ]]
[[ ! -f "$work/state/topic-checkout-task-dlq" ]]
[[ ! -f "$work/state/sub-checkout-task-dlq-sub" ]]
[[ ! -f "$work/state/sa-checkout-push.description" ]]

# A failure at Cloud Run deploy must leave the record and be destroyable even
# though the service was never created.
FAKE_RUN_DEPLOY_FAIL=1 "$sol" task gcp deploy "${common[@]}" --record "$work/partial-service.json" > "$work/partial-service.out" 2>&1 && {
  echo "deploy accepted a Cloud Run deploy failure" >&2; exit 1
}
[[ -f "$work/partial-service.json" ]]
grep -q '"cloud_run_url":""' "$work/partial-service.json"
"$sol" task gcp destroy --project p --region us-west1 --service checkout --record "$work/partial-service.json" --apply > /dev/null
[[ ! -f "$work/state/topic-checkout-task" ]]
[[ ! -f "$work/state/topic-checkout-task-dlq" ]]
[[ ! -f "$work/state/sa-checkout-push.description" ]]

# Destroy deletes the push service account. GCP keeps that ID reserved, so a
# redeploy using the same record must allocate a fresh push identity rather than
# recreating the deleted one.
old_sa=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["push_service_account"])' "$work/release.json")
"$sol" task gcp deploy "${common[@]}" --record "$work/release.json" > "$work/redeploy.json"
new_sa=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["push_service_account"])' "$work/redeploy.json")
[[ "$new_sa" != "$old_sa" ]]
grep -q 'iam service-accounts create' "$work/state/calls.log"
# A false-success service-account delete must fail independent absence.
if FAKE_GCP_SA_LINGER=1 "$sol" task gcp destroy --project p --region us-west1 --service checkout --record "$work/release.json" --apply > "$work/sa-linger.out" 2>&1; then
  echo "destroy accepted a lingering push service account" >&2
  exit 1
fi
grep -F "push service account remains after delete" "$work/sa-linger.out" >/dev/null
"$sol" task gcp destroy --project p --region us-west1 --service checkout --record "$work/release.json" --apply > /dev/null
[[ ! -f "$work/state/service" ]]
[[ ! -f "$work/state/sub-checkout-task-dlq-sub" ]]
[[ ! -f "$work/state/sa-${new_sa%%@*}.description" ]]

echo "task GCP fake-provider lifecycle test passed"
