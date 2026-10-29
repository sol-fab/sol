#!/usr/bin/env bash
set -euo pipefail
sol="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/home"
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_AWS_STATE"
printf '%s\n' "$*" >> "$state/calls.log"
args="$*"

queue_name_from_url() { basename "${1%/}"; }

if [[ "$args" == *"lambda list-functions"* ]]; then
  if [[ -f "$state/function" ]]; then
    printf '{"Functions":[{"FunctionName":"checkout-task"}]}\n'
  else
    printf '{"Functions":[]}\n'
  fi
elif [[ "$args" == *"lambda get-function"* ]]; then
  [[ -f "$state/function" ]] || { printf 'An error occurred (ResourceNotFoundException)\n' >&2; exit 1; }
  owner="$(cat "$state/function-owner" 2>/dev/null || echo lambda-task-experiment)"
  if [[ "$args" == *"--query"* && "$args" == *"Configuration.FunctionArn"* ]]; then
    printf 'arn:aws:lambda:us-east-1:123:function:checkout-task\n'
  else
    printf '{"Configuration":{"Version":"%s","FunctionArn":"arn:aws:lambda:us-east-1:123:function:checkout-task"},"Tags":{"sol-owned":"%s","sol-service":"checkout-task"}}\n' "$(cat "$state/version" 2>/dev/null || echo 0)" "$owner"
  fi
elif [[ "$args" == *"lambda create-function"* ]]; then
  [[ "$args" == *"SOL_TASK_RUNTIME"* && "$args" == *"lambda"* ]] || { echo "create-function lost SOL_TASK_RUNTIME" >&2; exit 1; }
  [[ "$args" == *"sol-owned=lambda-task-experiment"* ]] || { echo "create-function lost the task ownership tag" >&2; exit 1; }
  touch "$state/function"; echo 0 > "$state/version"; printf '{}\n'
elif [[ "$args" == *"lambda update-function-code"* || "$args" == *"lambda update-function-configuration"* ]]; then
  printf '{}\n'
elif [[ "$args" == *"lambda wait function-updated"* ]]; then
  printf '{}\n'
elif [[ "$args" == *"lambda publish-version"* ]]; then
  v=$(cat "$state/version" 2>/dev/null || echo 0); v=$((v+1)); echo "$v" > "$state/version"; printf '{"Version":"%s"}\n' "$v"
elif [[ "$args" == *"lambda get-alias"* ]]; then
  if [[ -f "$state/alias" ]]; then printf '{"FunctionVersion":"%s"}\n' "$(cat "$state/alias")"; else printf 'ResourceNotFoundException: Alias not found.\n' >&2; exit 254; fi
elif [[ "$args" == *"lambda create-alias"* || "$args" == *"lambda update-alias"* ]]; then
  for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--function-version" ]]; then j=$((i+1)); echo "${!j}" > "$state/alias"; fi; done
  printf '{}\n'
elif [[ "$args" == *"lambda list-event-source-mappings"* ]]; then
  if [[ -f "$state/mapping" ]]; then
    printf '{"EventSourceMappings":[{"UUID":"%s","State":"Enabled","FunctionResponseTypes":["ReportBatchItemFailures"]}]}\n' "$(cat "$state/mapping")"
  else
    printf '{"EventSourceMappings":[]}\n'
  fi
elif [[ "$args" == *"lambda create-event-source-mapping"* ]]; then
  [[ "$args" == *"ReportBatchItemFailures"* ]] || { echo "mapping lost ReportBatchItemFailures" >&2; exit 1; }
  [[ "$args" == *"MaximumConcurrency=7"* ]] || { echo "mapping lost MaximumConcurrency" >&2; exit 1; }
  if [[ "${FAKE_MAPPING_FAIL:-0}" == 1 ]]; then echo "simulated mapping failure" >&2; exit 1; fi
  echo "mapping-1" > "$state/mapping"; printf '{"UUID":"mapping-1"}\n'
elif [[ "$args" == *"lambda update-event-source-mapping"* ]]; then
  printf '{"UUID":"mapping-1"}\n'
elif [[ "$args" == *"lambda get-event-source-mapping"* ]]; then
  printf '{"UUID":"%s","State":"Enabled","FunctionResponseTypes":["ReportBatchItemFailures"]}\n' "$(cat "$state/mapping")"
elif [[ "$args" == *"lambda delete-event-source-mapping"* ]]; then
  rm -f "$state/mapping"; printf '{}\n'
elif [[ "$args" == *"lambda delete-function"* ]]; then
  rm -f "$state/function" "$state/alias" "$state/version"; printf '{}\n'
elif [[ "$args" == *"sqs get-queue-url"* ]]; then
  name=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--queue-name" ]]; then j=$((i+1)); name="${!j}"; fi; done
  if [[ -f "$state/queue-$name" ]]; then printf '{"QueueUrl":"https://sqs.us-east-1.amazonaws.com/123/%s"}\n' "$name"; else printf 'An error occurred (AWS.SimpleQueueService.NonExistentQueue) when calling the GetQueueUrl operation\n' >&2; exit 1; fi
elif [[ "$args" == *"sqs create-queue"* ]]; then
  name=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--queue-name" ]]; then j=$((i+1)); name="${!j}"; fi; done
  [[ "$args" == *"sol-owned=lambda-task-experiment"* ]] || { echo "queue lost the task ownership tag" >&2; exit 1; }
  attrs=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--attributes" ]]; then j=$((i+1)); attrs="${!j}"; fi; done
  if [[ "$name" == "checkout-task" ]]; then
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["VisibilityTimeout"]=="60"; assert json.loads(d["RedrivePolicy"])["maxReceiveCount"]=="5"' "$attrs" || { echo "source queue lost its settings or attributes are not valid JSON" >&2; exit 1; }
    if [[ "${FAKE_SOURCE_QUEUE_FAIL:-0}" == 1 ]]; then echo "simulated source queue failure" >&2; exit 1; fi
  else
    python3 -c 'import json,sys; assert json.loads(sys.argv[1])["MessageRetentionPeriod"]=="604800"' "$attrs" || { echo "DLQ lost retention" >&2; exit 1; }
  fi
  echo "https://sqs.us-east-1.amazonaws.com/123/$name" > "$state/queue-$name"
  printf 'sol-owned=lambda-task-experiment\nsol-service=checkout-task\n' > "$state/queue-tags-$name"
  printf '{"QueueUrl":"https://sqs.us-east-1.amazonaws.com/123/%s"}\n' "$name"
elif [[ "$args" == *"sqs get-queue-attributes"* ]]; then
  url=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--queue-url" ]]; then j=$((i+1)); url="${!j}"; fi; done
  name="$(queue_name_from_url "$url")"
  printf '{"Attributes":{"QueueArn":"arn:aws:sqs:us-east-1:123:%s"}}\n' "$name"
elif [[ "$args" == *"sqs list-queue-tags"* ]]; then
  url=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--queue-url" ]]; then j=$((i+1)); url="${!j}"; fi; done
  name="$(queue_name_from_url "$url")"
  owner="$(head -1 "$state/queue-tags-$name" | cut -d= -f2)"
  service="$(sed -n '2s/.*=//p' "$state/queue-tags-$name")"
  printf '{"Tags":{"sol-owned":"%s","sol-service":"%s"}}\n' "$owner" "$service"
elif [[ "$args" == *"sqs send-message"* ]]; then
  body=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--message-body" ]]; then j=$((i+1)); body="${!j}"; fi; done
  printf '%s\n' "$body" >> "$state/messages"
  printf '{"MessageId":"msg-1"}\n'
elif [[ "$args" == *"sqs delete-queue"* ]]; then
  url=""; for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--queue-url" ]]; then j=$((i+1)); url="${!j}"; fi; done
  name="$(queue_name_from_url "$url")"; rm -f "$state/queue-$name" "$state/queue-tags-$name"; printf '{}\n'
else
  printf '{}\n'
fi
FAKE
chmod +x "$work/bin/aws"
export PATH="$work/bin:$PATH" FAKE_AWS_STATE="$work/state" HOME="$work/home"
mkdir -p "$work/ws"; cd "$work/ws"
image="repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
common=(--profile test --region us-east-1 --service checkout --image "$image" --role arn:aws:iam::123:role/task --max-attempts 5 --visibility-timeout 60 --dlq-retention 604800 --concurrency 7)

# Foreign ownership is refused before mutation.
touch "$work/state/function"; echo 0 > "$work/state/version"; echo other > "$work/state/function-owner"
if "$sol" task aws deploy "${common[@]}" --record "$work/foreign.json" > "$work/foreign.out" 2>&1; then
  echo "deploy adopted a foreign function" >&2; exit 1
fi
grep -q 'ownership tags' "$work/foreign.out"
rm -f "$work/state/function" "$work/state/version" "$work/state/function-owner"

"$sol" task aws deploy "${common[@]}" --record "$work/release.json" > "$work/deploy.json"
grep -q '"kind":"aws-task"' "$work/deploy.json"
grep -q '"function_name":"checkout-task"' "$work/deploy.json"
grep -q '"queue_name":"checkout-task"' "$work/deploy.json"
grep -q '"dlq_name":"checkout-task-dlq"' "$work/deploy.json"
grep -q '"mapping_uuid":"mapping-1"' "$work/deploy.json"
grep -q 'lambda create-event-source-mapping' "$work/state/calls.log"

"$sol" task aws verify --profile test --region us-east-1 --service checkout --record "$work/release.json" > "$work/verify.json"
grep -q '"version":"1"' "$work/verify.json"

"$sol" task aws enqueue --profile test --region us-east-1 --service checkout --record "$work/release.json" --kind echo --payload '{"message":"hi"}' > "$work/enqueue.json"
grep -q '"message_id":"msg-1"' "$work/enqueue.json"
grep -q '"kind":"echo"' "$work/state/messages"
grep -q '"task_id"' "$work/state/messages"

"$sol" task aws deploy "${common[@]}" --record "$work/release.json" > "$work/deploy2.json"
grep -q '"version":"2"' "$work/deploy2.json"
"$sol" task aws rollback --profile test --region us-east-1 --service checkout --record "$work/release.json" --to-version 1 > "$work/rollback.json"
grep -q '"version":"1"' "$work/rollback.json"
grep -q '"version":"1"' "$work/release.json"
[[ "$(cat "$work/state/alias")" == 1 ]]

"$sol" task aws destroy --profile test --region us-east-1 --service checkout --record "$work/release.json" > "$work/destroy.out" 2>&1 && {
  echo "destroy without --apply was accepted" >&2; exit 1
}
grep -q 'requires --apply' "$work/destroy.out"
"$sol" task aws destroy --profile test --region us-east-1 --service checkout --record "$work/release.json" --apply > /dev/null
[[ ! -f "$work/state/function" ]]
[[ ! -f "$work/state/queue-checkout-task" ]]
[[ ! -f "$work/state/queue-checkout-task-dlq" ]]

# A failure after queues/function exist must leave a destroyable record.
FAKE_MAPPING_FAIL=1 "$sol" task aws deploy "${common[@]}" --record "$work/partial.json" > "$work/partial.out" 2>&1 && {
  echo "deploy accepted a mapping failure" >&2; exit 1
}
[[ -f "$work/partial.json" ]]
grep -q '"mapping_uuid":""' "$work/partial.json"
"$sol" task aws destroy --profile test --region us-east-1 --service checkout --record "$work/partial.json" --apply > /dev/null
[[ ! -f "$work/state/function" ]]
[[ ! -f "$work/state/queue-checkout-task" ]]
[[ ! -f "$work/state/queue-checkout-task-dlq" ]]

# A failure after the dead-letter queue exists must leave a record that can resolve and
# remove it by name, even though its URL was never observed.
FAKE_SOURCE_QUEUE_FAIL=1 "$sol" task aws deploy "${common[@]}" --record "$work/partial-queue.json" > "$work/partial-queue.out" 2>&1 && {
  echo "deploy accepted a source queue failure" >&2; exit 1
}
[[ -f "$work/partial-queue.json" ]]
grep -q '"queue_name":"checkout-task"' "$work/partial-queue.json"
grep -q '"dlq_name":"checkout-task-dlq"' "$work/partial-queue.json"
grep -q '"queue_url":""' "$work/partial-queue.json"
"$sol" task aws destroy --profile test --region us-east-1 --service checkout --record "$work/partial-queue.json" --apply > /dev/null
[[ ! -f "$work/state/queue-checkout-task-dlq" ]]
[[ ! -f "$work/state/queue-checkout-task" ]]

echo "task AWS fake-provider lifecycle test passed"
