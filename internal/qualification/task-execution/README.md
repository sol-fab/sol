# Durable task execution — qualification and live procedures

This page owns the **execution** evidence for `sol-task`: local Postgres
`sol-jobs`, AWS SQS + Lambda, and GCP Pub/Sub push + Cloud Run. It does not
replace the provider production matrices; it records what was actually
observed for this capability.

## Status

| Surface | Implementation | Automated evidence | Live evidence |
|---|---|---|---|
| Local Postgres | `sol-task.local` + `sol local task enqueue` | envelope/local unit tests; `sol-task local Postgres integration` (Ack, Retry→terminal, duplicate delivery + idempotent effect, idempotent enqueue); manual CLI enqueue | disposable Docker Postgres only |
| AWS SQS + Lambda | `sol-task.lambda` + `sol task aws` | envelope/Lambda unit tests; fake-provider lifecycle (deploy, enqueue, verify, rollback, destroy, partial-create cleanup) | **mechanism-level record**: [`2026-10-29-task-aws-live.md`](../records/2026-10-29-task-aws-live.md) |
| GCP Pub/Sub + Cloud Run | `sol-task.pubsub` + `sol task gcp` | envelope/PubSub unit tests; fake-provider lifecycle (deploy, enqueue, verify, rollback, destroy, partial-create cleanup) | **mechanism-level record**: [`2026-10-29-task-gcp-live.md`](../records/2026-10-29-task-gcp-live.md) |
| Target-scoped `sol deploy` | not implemented | none | none |
| Observability acceptance | logs only (task_id/kind/outcome) | unit tests assert mapping | provider logs inspected; no Sol-managed metrics/traces claim |

Runs are evidence only for the rows they exercise. A fake-provider test is not
live evidence; a checkout-build live exercise is not a released-candidate
qualification.

## Observability and diagnosis

| Surface | Signals | What is not claimed |
|---|---|---|
| Local | `sol-jobs` metrics/backlog/logs plus `task_id`/`kind`/outcome lines | no separate task metric; no trace context |
| AWS | CloudWatch Logs `/aws/lambda/checkout-task`; SQS source/DLQ depth; Lambda invocation/error/duration | provider-native only; no Sol task metric or trace |
| GCP | Cloud Logging `cloud_run_revision`; Pub/Sub undelivered/ack; Cloud Run request/instance | provider-native only; no Sol task metric or trace |

Diagnosis starts from the `task_id` printed by enqueue and the provider log
store. Dead-letter inspection is provider-native; there is no replay command in
this contract. The local `sol_jobs_failed`/retry metrics are the local analogue
of the provider DLQ. A provider unreadable/timeout result is UNKNOWN, not
absence.

## Shared procedure

Build the handler fixture once:

```sh
eval "$(opam env)"
dune build internal/fixtures/task-handler/task_handler.exe
ctx=$(mktemp -d)
cp _build/default/internal/fixtures/task-handler/task_handler.exe "$ctx/task_handler"
cp internal/fixtures/task-handler/Dockerfile "$ctx/Dockerfile"
docker build -t sol-task-handler:local "$ctx"
```

The fixture acknowledges payload `ack` and returns `Retry` for payload `fail`.
It selects `Sol_task_lambda` or `Sol_task_pubsub` from `SOL_TASK_RUNTIME`.

## Local Postgres

The automated integration test is the authoritative local exercise:

```sh
# disposable Postgres; the test creates its own schema and sol_jobs table
docker run --rm -d --name sol-task-pg -e POSTGRES_PASSWORD=dev \
  -e POSTGRES_DB=sol_dev -p 55432:5432 postgres:16
_build/default/framework/ocaml/sol-task/test/test_sol_task_local_pg.exe \
  'postgresql://postgres:dev@localhost:55432/sol_dev'
```

It asserts Ack→completed, Retry with `max_attempts=1`→failed, idempotent
enqueue, and the duplicate-delivery case: the first delivery of a flaky task
commits an idempotent effect keyed by `task_id` and returns `Retry`; the
redelivery sees the same `task_id`, does not reapply the effect, and returns
`Ack`. The test asserts two handler entries, one `task_id`, one effect, and a
completed row after two attempts. For the CLI path, create the `sol_jobs` table
from
[`sol-task.md`](../../../framework/ocaml/sol-task/sol-task.md) and run:

```sh
sol local task enqueue --kind ack --payload ack --postgres-url "$POSTGRES_URL"
```

Then run a `-worker` hosting `Sol_task_local.Make(T).run`; the row status and
`sol_jobs_*` metrics/logs are the observation.

## AWS SQS + Lambda live procedure

**Status: executed 2026-10-29.** The mechanism-level result is in
[`2026-10-29-task-aws-live.md`](../records/2026-10-29-task-aws-live.md). The
procedure below records the current sequence, including the packaging
requirement and the failures found during that run.

Prerequisites: AWS profile with ECR, IAM, Lambda, SQS, and CloudWatch Logs;
an immutable image; an execution role trusted by `lambda.amazonaws.com` with
`AWSLambdaBasicExecutionRole` and `AWSLambdaSQSQueueExecutionRole` (or an
equivalent policy covering source-queue receive/delete and logs).

1. Push the fixture image to ECR and record the digest. **Lambda requires a
   Docker v2 manifest, not an OCI image index.** The live run initially pushed
   an OCI index and `CreateFunction` rejected it; build with
   `oci-mediatypes=false`:

   ```sh
   aws ecr create-repository --repository-name sol-task-live
   aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
   docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
     --output "type=image,name=<ecr>/sol-task-live:live,push=true,oci-mediatypes=false" \
     "$ctx"
   aws ecr describe-images --repository-name sol-task-live --image-ids imageTag=live \
     --query 'imageDetails[0].imageDigest' --output text
   ```

2. Create the execution role (trust policy for Lambda) and attach the two
   managed policies; use the role ARN in the deploy.

3. Deploy, with a short budget so the DLQ path is observable:

   ```sh
   sol task aws deploy --profile sol-qual --region us-east-1 \
     --service checkout \
     --image <ecr>@sha256:<digest> \
     --role arn:aws:iam::<account>:role/sol-task-live-exec \
     --max-attempts 2 --visibility-timeout 30 \
     --dlq-retention 3600 --concurrency 2 \
     --record ./aws-task-release.json
   sol task aws verify --profile sol-qual --region us-east-1 \
     --service checkout --record ./aws-task-release.json
   ```

4. Enqueue `ack`; wait for the source queue depth to reach zero and read the
   handler log:

   ```sh
   sol task aws enqueue --profile sol-qual --region us-east-1 \
     --service checkout --record ./aws-task-release.json \
     --kind ack --payload ack --idempotency-key aws-ack-1
   aws sqs get-queue-attributes --queue-url <queue-url> \
     --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible
   aws logs filter-log-events --log-group-name /aws/lambda/checkout-task \
     --filter-pattern task_handler
   ```

   Expected: one `task_handler` line and `task acknowledged`; the message is
   gone and the DLQ is empty. This is the duplicate-delivery observation: the
   SQS receipt and the handler log are different counters; do not equate them.

5. Enqueue `fail`; wait for the DLQ depth to become non-zero. Read the handler
   log for repeated `task requested retry` lines. Confirm the DLQ message body
   contains the same `task_id` and the original envelope. Record
   `ApproximateReceiveCount`/the DLQ source count; do not call it a
   handler-attempt count.

6. Deploy the same image again (version 2), then roll back:

   ```sh
   sol task aws rollback --profile sol-qual --region us-east-1 \
     --service checkout --record ./aws-task-release.json --to-version 1
   aws lambda get-alias --function-name checkout-task --name live
   ```

   Expected: alias version 1, event source mapping still enabled and reporting
   `ReportBatchItemFailures`. A post-rollback Ack should appear in a log stream
   whose version segment is `[1]`.

   The live run also found that an event source mapping is `Creating` before it
   is `Enabled`; the adapter now polls it. SQS `create-queue --attributes` must
   be one JSON object (the nested `RedrivePolicy` cannot use the shorthand
   form); the adapter now sends JSON.

7. Destroy and clean resources the adapter does not own:

   ```sh
   sol task aws destroy --profile sol-qual --region us-east-1 \
     --service checkout --record ./aws-task-release.json --apply
   aws ecr delete-repository --repository-name sol-task-live --force
   for p in arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
            arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole; do
     aws iam detach-role-policy --role-name sol-task-live-exec --policy-arn "$p"
   done
   aws iam delete-role --role-name sol-task-live-exec
   aws logs delete-log-group --log-group-name /aws/lambda/checkout-task
   ```

8. Independently inventory: Lambda functions, SQS queues (source + DLQ), ECR
   repository, role, and log group. A provider error or unreadable response is
   UNKNOWN, not absence.

Failure injection for the cleanup path: the fake-provider test already covers
foreign ownership refusal, mapping failure after queues/function exist, and
source-queue failure after DLQ creation. A live failure can be produced by
using a role without SQS receive permission; the deploy's event-source-mapping
creation must fail while the ownership record remains destroyable.

## GCP Pub/Sub push + Cloud Run live procedure

The executed run is recorded in
[`2026-10-29-task-gcp-live.md`](../records/2026-10-29-task-gcp-live.md). The
procedure is:

1. Enable `run.googleapis.com` only if it was disabled, create an Artifact
   Registry repository, push the fixture image, and record the digest.
2. Deploy with `sol task gcp deploy --project ... --region ... --service checkout
   --image ... --max-attempts 5 --ack-deadline 30 --dlq-retention 3600
   --concurrency 2 --record ./gcp-task-release.json`; run `sol task gcp verify`.
3. Enqueue `ack`; read Cloud Run logs for `task_handler` and `task acknowledged`.
   Enqueue `fail`; wait for repeated retries, then create a temporary pull
   subscription on the DLQ topic and pull the dead-lettered envelope. Delete
   the probe subscription.
4. Deploy again, `sol task gcp rollback --to-revision <prior>`, verify traffic
   and run a post-rollback Ack.
5. `sol task gcp destroy --apply`; delete the Artifact Registry repository;
   independently inventory Cloud Run services, topics, subscriptions, service
   accounts, and the repository. If the Cloud Run API was disabled before the
   run, disable it again **after** the inventory; a post-disable Cloud Run read
   is UNKNOWN, not absent.

The dead-letter publisher grant is required:
`roles/pubsub.publisher` on the DLQ topic for
`service-<project-number>@gcp-sa-pubsub.iam.gserviceaccount.com`. The adapter
grants and verifies it. The live run observed repeated redelivery without it.

## Non-claims

- No exactly-once external side effect, no application-selected immediate
  dead-letter, and no handler-attempt number.
- No production-profile, SLO, cost, or security-review claim.
- No released-candidate qualification. AWS and GCP each have a bounded live
  mechanism-level record, not a release verdict.
- No target-scoped `sol deploy` for tasks.
- No Sol-managed task metrics/traces acceptance; the runtimes emit logs and the
  local `sol-jobs` package exposes its own metrics.
