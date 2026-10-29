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
schedule, input event, or trigger. The GCP path is fake-provider tested; live
GCP evidence is pending operator approval.

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
consumer acknowledges the same synthetic payload; use the provider record and
the log to distinguish the two demos.

Destroy both task lifecycles when finished:

```sh
sol task aws destroy --profile <aws-profile> --region us-east-1 \
  --service pluto-tasks --record ./pluto-task-ocaml.json --apply
sol task aws destroy --profile <aws-profile> --region us-east-1 \
  --service pluto-tasks-ts --record ./pluto-task-ts.json --apply
```

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

The probes are also runnable as local Kubernetes CronJobs: the OCaml probe
selects the `Cron` trigger when `AWS_LAMBDA_RUNTIME_API` is absent, and the
TypeScript image entrypoint runs `index.js` once when that API is absent. Create
a local test Job from each CronJob to exercise it without AWS. No live AWS
resources are created by these local commands.
