# Pluto serverless components

This demo extends the Pluto workspace with the two provider-native serverless
surfaces Sol supports:

| Unit | Language | Surface | Deployment |
|---|---|---|---|
| `probe_fn` | OCaml (`Fn.Lambda`) | run-once function | `serverless/aws/us-east-1` target |
| `probe_ts_fn` | TypeScript (AWS Node Lambda) | run-once function | `serverless/aws/us-east-1` target |
| `serverless/task_consumer_ocaml` | OCaml (`Sol_task_lambda`) | SQS queue consumer | standalone `sol task aws` |
| `serverless/task_consumer_ts` | TypeScript (AWS Node Lambda) | SQS queue consumer | standalone `sol task aws` |

The two probes are the **serverless function execution** path. The two task
consumers are **another serverless function** consuming the durable queue. The
queue lifecycle is deliberately standalone: target-scoped `sol deploy` creates
no SQS queue, event-source mapping, schedule, or trigger.

The TypeScript task consumer is provider-native rather than a published
framework runtime: `@sol-fab/task` does not exist yet. It parses the shared task
envelope and returns `batchItemFailures`; the OCaml consumer uses the published
`sol-task.lambda` runtime. Both speak the same wire contract.

## Build the images

Lambda accepts Docker v2 manifests, not OCI indexes. Build and push every
serverless image with `buildx` and `oci-mediatypes=false`:

```sh
push_lambda_image() {
  docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
    --output "type=image,name=$1,push=true,oci-mediatypes=false" -f "$2" .
}

cd examples/pluto
push_lambda_image <ecr>/pluto/probe-fn:demo app/ops/probe_fn/Dockerfile
push_lambda_image <ecr>/pluto/probe-ts-fn:demo app/demo_ts/probe_ts_fn/Dockerfile
push_lambda_image <ecr>/pluto/task-consumer:demo serverless/task_consumer_ocaml/Dockerfile
push_lambda_image <ecr>/pluto/task-consumer-ts:demo serverless/task_consumer_ts/Dockerfile
```

Use the resulting immutable digests. The demos use an existing ECR repository
and Lambda execution role; Sol does not create either.

## Serverless functions

Replace the placeholder profile and role in the `serverless` environment of
`sol/environments.yml`, then push both probe images:

```sh
sol deploy serverless/aws/us-east-1 \
  --image-ref probe_fn=<ecr>/pluto/probe-fn@sha256:<digest>
sol deploy serverless_ts/aws/us-east-1 \
  --image-ref probe_ts_fn=<ecr>/pluto/probe-ts-fn@sha256:<digest>
```

The target's `-fn` lifecycle creates an immutable Lambda version and moves the
`live` alias, invokes `{}` through the alias, and requires `{"status":"ok"}`.
It creates no Function URL, schedule, or event source.

Roll back or destroy through the target lifecycle:

```sh
# `sol deploy` writes the serverless ownership record into the run log; use
# that path as <serverless-release.json>.
sol rollback --target serverless/aws/us-east-1 \
  --record <serverless-release.json> --service probe_fn --to-version <version>
sol destroy serverless/aws/us-east-1 --apply \
  --service probe_fn --record <serverless-release.json>

sol rollback --target serverless_ts/aws/us-east-1 \
  --record <serverless-release.json> --service probe_ts_fn --to-version <version>
sol destroy serverless_ts/aws/us-east-1 --apply \
  --service probe_ts_fn --record <serverless-release.json>
```

The TypeScript probe uses the `serverless_ts` environment for the same reason:
the serverless dispatch deploys one `-fn` per target. It uses the AWS
Lambda Node.js base image, not `@sol-fab/fn`: that package is the Kubernetes
CronJob runtime and is not a Lambda runtime.

## GCP Cloud Run Jobs functions

The same probe images run on Cloud Run Jobs. Set `gcp.project_id` in the
`serverless_gcp` and `serverless_gcp_ts` environments (and the target region),
push the images to Artifact Registry, then deploy one probe per target:

```sh
sol deploy serverless_gcp/gcp/us-west1 \
  --image-ref probe_fn=<region>-docker.pkg.dev/<project>/<repo>/probe-fn@sha256:<digest>
sol deploy serverless_gcp_ts/gcp/us-west1 \
  --image-ref probe_ts_fn=<region>-docker.pkg.dev/<project>/<repo>/probe-ts-fn@sha256:<digest>
```

Cloud Run Jobs has no Lambda event payload, alias, or response body. Deployment
updates the Job to the image, starts one execution with one task/parallelism and
zero task retries, and requires the execution to complete successfully. The
probes already handle this: without `AWS_LAMBDA_RUNTIME_API` they run once and
exit; with it they use the Lambda runtime.

Rollback names a prior execution; Sol reads its immutable image, patches the Job,
and runs a new execution:

```sh
sol rollback --target serverless_gcp/gcp/us-west1 \
  --record <serverless-release.json> --service probe_fn --to-revision <execution-id>
sol destroy serverless_gcp/gcp/us-west1 --apply \
  --service probe_fn --record <serverless-release.json>
```

A Job with no retained prior execution cannot be rolled back. There is no
schedule, input event, or trigger. The GCP `-fn` path is live-qualified on
2026-10-29 in `sol-qualification`/`us-west1`: both probes exited 0, rollback
restored the prior image and started a successful execution, and destroy left
no Jobs or executions. No concurrency/timeout measurement was made.

## Queue consumption

Create a Lambda execution role that can receive/delete from the source queue,
send to the DLQ, and write logs, then deploy the consumers. `--service` is the
task service key; it produces the deterministic function/queue names.

```sh
# OCaml consumer: sol-task.lambda
sol task aws deploy --profile <aws-profile> --region us-east-1 \
  --service pluto-tasks \
  --image <ecr>/pluto/task-consumer@sha256:<digest> \
  --role arn:aws:iam::<account>:role/<task-exec-role> \
  --max-attempts 2 --visibility-timeout 30 \
  --dlq-retention 3600 --concurrency 2 \
  --record ./pluto-task-ocaml.json

# TypeScript provider-native consumer
sol task aws deploy --profile <aws-profile> --region us-east-1 \
  --service pluto-tasks-ts \
  --image <ecr>/pluto/task-consumer-ts@sha256:<digest> \
  --role arn:aws:iam::<account>:role/<task-exec-role> \
  --max-attempts 2 --visibility-timeout 30 \
  --dlq-retention 3600 --concurrency 2 \
  --record ./pluto-task-ts.json
```

Enqueue a task and read the provider logs:

```sh
sol task aws enqueue --profile <aws-profile> --region us-east-1 \
  --service pluto-tasks --record ./pluto-task-ocaml.json \
  --kind send_welcome --payload '{"kind":"send_welcome","user_id":"u-1"}' \
  --idempotency-key welcome-u-1

aws logs filter-log-events --log-group-name /aws/lambda/pluto-tasks-task \
  --filter-pattern task_consumer
```

The TypeScript consumer returns an SQS item failure for a payload of `fail`:

```sh
sol task aws enqueue --profile <aws-profile> --region us-east-1 \
  --service pluto-tasks-ts --record ./pluto-task-ts.json \
  --kind send_welcome --payload fail \
  --idempotency-key welcome-fail
```

That record is retried to the configured budget and dead-lettered. The OCaml
consumer now also treats the `fail` payload as `Retry`, so both consumers have
the same synthetic retry path; the task id remains stable across redelivery.

Destroy both task lifecycles when finished:

```sh
sol task aws destroy --profile <aws-profile> --region us-east-1 \
  --service pluto-tasks --record ./pluto-task-ocaml.json --apply
sol task aws destroy --profile <aws-profile> --region us-east-1 \
  --service pluto-tasks-ts --record ./pluto-task-ts.json --apply
```

### Local Postgres task consumer

The same OCaml handler also supports the local `sol-jobs` runtime. With a local
Postgres that has the `sol_jobs` migration applied, enqueue through the local
CLI and run the consumer with `SOL_TASK_RUNTIME=local`:

```sh
sol local task enqueue --kind send_welcome \
  --payload '{"kind":"send_welcome","user_id":"u-local"}' \
  --idempotency-key local-welcome --postgres-url "$POSTGRES_URL"

SOL_TASK_RUNTIME=local POSTGRES_URL="$POSTGRES_URL" \
  dune exec serverless/task_consumer_ocaml/bin/main.exe
```

`Ack` leaves the row `completed`; `Retry` uses the existing `sol-jobs` backoff
and leaves a retained `failed` row after the retry budget. A repeated
`--idempotency-key` enqueue is a no-op. This is the same handler module used by
Lambda and Pub/Sub; it is a local test harness, not a provider-emulated SQS or
Pub/Sub service.

### GCP Pub/Sub consumers

The same OCaml consumer image selects `sol-task.pubsub` when
`SOL_TASK_RUNTIME=pubsub` (the GCP task adapter sets it); the AWS adapter sets
`lambda`. The TypeScript consumer has a GCP HTTP entrypoint in
`serverless/task_consumer_ts_gcp/Dockerfile`.

```sh
# OCaml: same image, Pub/Sub runtime selected by the GCP adapter
sol task gcp deploy --project <project> --region us-west1 \
  --service pluto-tasks-gcp \
  --image <region>-docker.pkg.dev/<project>/<repo>/task-consumer@sha256:<digest> \
  --max-attempts 5 --ack-deadline 30 --dlq-retention 3600 --concurrency 2 \
  --record ./pluto-task-gcp-ocaml.json

# TypeScript: Pub/Sub push HTTP server
sol task gcp deploy --project <project> --region us-west1 \
  --service pluto-tasks-gcp-ts \
  --image <region>-docker.pkg.dev/<project>/<repo>/task-consumer-ts@sha256:<digest> \
  --max-attempts 5 --ack-deadline 30 --dlq-retention 3600 --concurrency 2 \
  --record ./pluto-task-gcp-ts.json
```

Pub/Sub push delivers one message per HTTP request; there is no SQS-style
partial-batch response. The TypeScript handler maps a successful task to 200,
`Retry` to 500, and a malformed push/envelope to 400. Pub/Sub's configured
delivery budget and dead-letter topic provide terminal failure; malformed
messages are bounded by that same provider policy rather than retried forever.
The OCaml `sol-task.pubsub` runtime uses the same status mapping. Application
idempotency remains mandatory; duplicate delivery is at-least-once.

Enqueue and inspect logs:

```sh
sol task gcp enqueue --project <project> --region us-west1 \
  --service pluto-tasks-gcp --record ./pluto-task-gcp-ocaml.json \
  --kind send_welcome --payload '{"kind":"send_welcome","user_id":"u-1"}' \
  --idempotency-key welcome-u-1

gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="pluto-tasks-gcp-task" AND textPayload:"task_consumer"' \
  --project <project> --limit 20 --freshness 1d
```

Use `sol task gcp rollback --to-revision <prior-revision>` for the provider's
supported service rollback, and `sol task gcp destroy ... --apply` for cleanup.
The GCP task path is live-qualified on 2026-10-29 in
`sol-qualification`/`us-west1`: both consumers acknowledged, retried the `fail`
payload, exhausted into the dead-letter topic (verified with a temporary pull
subscription), rolled back a Cloud Run revision, and destroyed without leaving
services, topics, subscriptions, or push service accounts. No concurrency or
throughput measurement was made. Sol does not create a DLQ subscription; the
dead-letter topic is the terminal provider destination, and inspection requires
a provider subscription.

## Verification scope and remaining gaps

| Surface | Verified | Boundary |
|---|---|---|
| Local `-svc`/`-worker`/`-fn` | order flows, Kafka/Postgres workers, local probe Jobs | no local AWS/GCP provider emulation |
| Local tasks | `sol-task.local` via `SOL_TASK_RUNTIME=local`: Ack/completed, duplicate no-op, Retry/failed row | no local SQS/Pub/Sub emulation |
| AWS `-fn` | Lambda invoke/rollback/destroy | no event input or Sol-created schedule |
| AWS tasks | SQS-triggered Lambda Ack/Retry/DLQ; Lambda-to-SQS producer is **not** a Sol-managed contract | enqueue with `sol task aws enqueue` or application code; SQS-backed `-worker` is not supported |
| GCP `-fn` | Cloud Run Jobs execute/rollback/destroy | no alias, event payload, schedule, or response body |
| GCP tasks | Pub/Sub push Ack/Retry/DLQ, revision rollback, destroy | Cloud Run service, not a `-worker`; no DLQ subscription created by Sol |
| Concurrency/timeouts | not measured | documented configuration only |

The SQS and Pub/Sub consumers are task handlers, not `-worker` equivalents.
Kafka `-worker` semantics and ordering remain the worker contract; no portable
queue abstraction is introduced. Lambda publishing to SQS would be ordinary
application code plus an execution-role permission, not a Sol lifecycle claim,
and is not verified here.

## Local checks

```sh
# OCaml probe and task consumer
dune build app/ops/probe_fn/bin/main.exe serverless/task_consumer_ocaml/bin/main.exe

# TypeScript probe and queue consumer
(cd app/demo_ts/probe_ts_fn && npm install && npm run build)
(cd serverless/task_consumer_ts && npm install && npm run build && npm test)

# Manifest and target validation
sol check
```

The GCP Pub/Sub consumers are tested locally with their HTTP runtimes:
`sol-task.pubsub` returns 200/500/400 for Ack/Retry/malformed, and the
TypeScript test suite covers the same mapping plus duplicate delivery. The
probes are also runnable as local Kubernetes CronJobs: the OCaml probe
selects the `Cron` trigger when `AWS_LAMBDA_RUNTIME_API` is absent, and the
TypeScript image entrypoint runs `index.js` once when that API is absent. Create
a local test Job from each CronJob to exercise it without AWS. No live AWS
resources are created by these local commands.

## Troubleshooting

- **A local deploy refuses Postgres because port 5432 is in use.** Set
  `SOL_LOCAL_POSTGRES_PORT` to a free port before `sol local deploy`,
  `sol local migrate`, and `sol local deploy` again. The default remains 5432.
- **GCP reports that Cloud Run Admin API is disabled.** Nothing was deployed.
  Enabling `run.googleapis.com` is a project mutation; request authorization
  and enable it before retrying. Do not treat the API error as proof that the
  adapter refused correctly.
- **GCP reports `iam.serviceAccounts.get` or a push-service-account error.**
  The task lifecycle creates and inspects a dedicated push service account.
  Report the exact principal, project, and resource; do not substitute a
  broader role or a second service account just to make the demo pass.
- **GCP `-fn` rollback cannot find an image.** The named execution must still
  exist and must expose its immutable container template. Cloud Run Jobs has no
  alias; if the execution or image is gone, there is no deployable prior state.
- **A malformed Pub/Sub message keeps redelivering.** The TypeScript adapter
  returns 400 for malformed/unsupported envelopes, and the OCaml
  `sol-task.pubsub` runtime does the same. Redelivery is bounded by the
  subscription's max-delivery-attempts/dead-letter policy; inspect the DLQ
  rather than changing a malformed message into an implicit Ack.
- **The AWS TypeScript Lambda image cannot find `task.js`.** The Lambda image
  must copy the whole `dist` directory, not only `index.js`. The demo Dockerfile
  now does this and the CI package check imports the built handler from the
  image.
