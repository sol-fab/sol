# sol-task — Durable Task Handlers

## What it is

`sol-task` is the application-facing contract for a **durable task**: an
independent unit of work that must be delivered until it succeeds or reaches its
provider-managed limit. It is a library, not a fourth deployable primitive. The
same handler is hosted by:

- a `-worker` binary over the existing Postgres `sol-jobs` queue (local and
  Kubernetes);
- an AWS Lambda function triggered by SQS;
- a GCP Cloud Run service receiving Pub/Sub push requests.

The contract is deliberately narrower than a generic queue API. It standardizes
what the application can rely on and leaves delivery mechanics provider-native.

## The contract

A task has:

| Field | Meaning |
|---|---|
| `task_id` | Sol-generated stable identity, preserved across redelivery |
| `kind` | Application task kind; the local runner claims only declared kinds |
| `payload` | Application-encoded bytes, passed to the handler unchanged |
| `idempotency_key` | Optional application key; carried, not enforced by Sol |

The portable message limit is **256 KiB**, enforced on the encoded envelope at
enqueue. The contract does **not** promise ordering.

A handler returns:

```ocaml
type outcome =
  | Ack            (* the side effect committed *)
  | Retry of string (* leave the task eligible for redelivery *)
```

An exception is a `Retry`. Delivery is **at-least-once**; the application must be
idempotent. Sol does not claim exactly-once external side effects. The local
integration test commits a durable Postgres idempotency effect, crashes the
handler before acknowledgement, and proves the redelivery sees the committed
effect and applies it once; the live AWS and GCP records observe provider
redelivery. The framework does not make an application's external effect and
acknowledgement atomic; that idempotency write belongs to the handler.

There is deliberately **no application-selected dead-letter outcome** in this
first contract. Each provider moves an exhausted task to its own dead-letter
destination:

| Environment | Retry budget | Terminal destination |
|---|---|---|
| Local `sol-jobs` | `retry_policy.max_attempts` | `status = 'failed'` row, retained |
| AWS SQS | source queue `maxReceiveCount` | SQS dead-letter queue |
| GCP Pub/Sub | subscription `maxDeliveryAttempts` | dead-letter topic |

The handler receives the stable `task_id`, not a delivery-attempt number.
Provider delivery counters are not application handler counters and are not part
of the contract. Applications that need attempt-aware behavior should use their
own durable state and idempotency key.

## Semantics by environment

The contract is shared; the delivery mechanics are provider-native.

| Concern | Local `sol-jobs` | AWS SQS + Lambda | GCP Pub/Sub push + Cloud Run |
|---|---|---|---|
| Task identity | Envelope `task_id` in the job payload | Envelope `task_id` | Envelope `task_id` |
| Ack | `Ack` completes the row | `Ack` omits the record from `batchItemFailures` | `200` response |
| Retry | `Retry` uses `sol-jobs` backoff | `Retry` returns a batch item failure | `500` response |
| Terminal | `max_attempts` → retained `failed` row | `maxReceiveCount` → SQS DLQ | `maxDeliveryAttempts` → Pub/Sub DLQ topic |
| Attempt number | Not exposed | Not exposed | Not exposed |
| Payload | 256 KiB envelope cap | 256 KiB envelope cap | 256 KiB envelope cap (Pub/Sub's own limit is larger) |
| Ordering | None | None for a standard queue | None promised |
| Concurrency | One claim loop per worker process | Event source mapping `MaximumConcurrency` | Cloud Run max instances; container concurrency 1 |
| Incoming auth | Database credentials | Lambda execution role; no inbound endpoint | Cloud Run IAM + Pub/Sub OIDC push identity |
| Enqueue | Application transaction or CLI | `sol task aws enqueue` | `sol task gcp enqueue` |
| Rollback | Redeploy the worker image | Move the Lambda alias to a prior version | Move Cloud Run traffic to a prior revision |
| Delivery window | `sol-jobs` lease | SQS visibility timeout; Lambda timeout is five seconds shorter | Pub/Sub ack deadline; Cloud Run request timeout equals it |

Provider delivery counters are **not** handler-attempt counters. In a bounded
live GCP exercise with `maxDeliveryAttempts=5` and a handler that returned
`Retry`, Pub/Sub dead-lettered the task but its
`CloudPubSubDeadLetterSourceDeliveryCount` was 12. The contract therefore
promises eventual provider-managed terminal delivery after the configured
budget, not an exact number of handler invocations. The same caution applies to
SQS `ApproximateReceiveCount` and Lambda batch retries.

## Adding a task kind

1. Add a variant to the handler's `t`.
2. Add its wire name to `kind` and `kinds`.
3. Extend `encode`/`decode`; decoding returns an error for an unknown payload.
4. Handle the variant with `Ack` or `Retry`; make the side effect idempotent.
5. Add round-trip, ack, and retry tests.
6. No provider or lifecycle change is needed: the new kind flows through the
   same envelope and the same runtime.

## Adding a provider

1. Implement a `Make(T)` runtime that validates the envelope, calls
   `T.handle ~task_id ?idempotency_key`, and maps `Ack`/`Retry` to the
   provider's acknowledge/nack response.
2. Make malformed input a non-retryable response where the provider supports
   one; otherwise let it exhaust into the provider dead-letter destination.
3. Add a lifecycle adapter that owns the queue/topic, runtime, trigger, auth,
   dead-letter destination, ownership record, rollback, and destroy/absence.
4. Write the ownership record with deterministic resource names before creating
   anything, verify ownership before mutation, and update the record after each
   stage.
5. Add fake-provider lifecycle tests for foreign ownership, deploy, enqueue,
   retry/dead-letter, rollback, destroy, and partial-create cleanup, then a
   bounded live exercise. Do not claim live qualification from the fake tests.

## Package structure

```
framework/ocaml/sol-task/
  lib/
    sol_task.ml/.mli          ← envelope, outcome, TASK module type
    sol_task_local.ml/.mli    ← Postgres sol-jobs runtime
    sol_task_lambda.ml/.mli   ← SQS Lambda event runtime
    sol_task_pubsub.ml/.mli   ← Pub/Sub push HTTP runtime
  test/                       ← envelope, local mapping, Lambda/Pub/Sub mapping
  sol-task.md
```

Libraries: `sol-task` (core), `sol-task.local`, `sol-task.lambda`,
`sol-task.pubsub`.

## Local usage

Define one module covering every task kind:

```ocaml
type t =
  | Send_welcome_email of { user_id : string }
  | Generate_pdf of { report_id : string }

module T = struct
  type nonrec t = t

  let workspace = "pluto"
  let kind = function
    | Send_welcome_email _ -> "send_welcome_email"
    | Generate_pdf _ -> "generate_pdf"

  let kinds = [ "send_welcome_email"; "generate_pdf" ]

  let encode = function
    | Send_welcome_email { user_id } ->
      Yojson.Safe.to_string (`Assoc [ "user_id", `String user_id ])
    | Generate_pdf { report_id } ->
      Yojson.Safe.to_string (`Assoc [ "report_id", `String report_id ])

  let decode text = (* parse and validate *)

  let handle ~task_id ?idempotency_key = function
    | Send_welcome_email { user_id } ->
      (match Emails.send_welcome ~idempotency_key user_id with
       | Ok () -> Sol_task.Ack
       | Error message -> Sol_task.Retry message)
    | Generate_pdf _ -> (* ... *)
end

module Tasks = Sol_task_local.Make (T)
```

Enqueue through the same transaction as the state change that caused it:

```ocaml
Db.transaction pool (fun tx ->
  let* () = Orders.insert tx order in
  Tasks.enqueue tx ~idempotency_key:order.id (Send_welcome_email { user_id }))
```

The workspace's migration must create the `sol_jobs` table described in
[`sol-jobs.md`](../sol-jobs/sol-jobs.md). A `-worker` hosts the loop:

```ocaml
Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let pool = Pg_db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () in
Tasks.run ~env ~pool ~ot ~metrics_port:0 ()
```

For local development without writing an enqueue endpoint:

```text
sol local task enqueue --kind send_welcome_email \
  --payload '{"user_id":"u-1"}' --idempotency-key order-42
```

It inserts the shared envelope into the local Postgres queue and prints the
`task_id`. With `--idempotency-key`, a duplicate enqueue is a no-op; the printed
id identifies the attempted envelope, while the existing row remains.

## AWS Lambda runtime

`Sol_task_lambda.Make(T).run` reads the Lambda Runtime API. The function is
triggered by SQS and must be deployed with an event source mapping whose
`ReportBatchItemFailures` behavior is enabled. The runtime returns
`{"batchItemFailures":[...]}` for tasks that returned `Retry`, malformed
envelopes, and handler exceptions. Successful tasks are not retried; a
partially successful batch retries only its failed records. SQS owns the
dead-letter queue after `maxReceiveCount`.

The Lambda execution role authorizes SQS; there is no Function URL and no
incoming application authentication. The provider lifecycle is
`sol task aws deploy|verify|enqueue|rollback|destroy`; it creates the source
queue, dead-letter queue, function/version/alias, and event source mapping, and
writes an ownership record before resource creation so a partial create remains
destroyable. The execution role is operator-supplied and must grant the
function SQS receive/delete, dead-letter send, and CloudWatch Logs access.

## GCP Pub/Sub runtime

`Sol_task_pubsub.Make(T).run` serves an HTTP endpoint on `PORT` (default 8080):

- `POST` with a Pub/Sub push body → `200` for `Ack`, `500` for `Retry`, `400`
  for a malformed envelope or task payload;
- `GET` readiness → `200`.

The service is deployed without public invoker access and grants
`roles/run.invoker` only to the Pub/Sub push service account. Cloud Run IAM is
the incoming authentication boundary; the task runtime does not add a second
application auth layer. Pub/Sub owns the dead-letter topic after
`maxDeliveryAttempts`. The provider lifecycle is
`sol task gcp deploy|verify|enqueue|rollback|destroy`; it creates the topics,
push subscription, private Cloud Run service, and push service account, and
writes an ownership record with deterministic names before creation.

## Observability and diagnosis

The runtimes emit a line for each handler outcome with the stable `task_id`,
`kind`, and `task acknowledged` / `task requested retry`. Query by `task_id` in
the provider log store:

- Lambda / SQS: CloudWatch Logs `/aws/lambda/<function>`; SQS queue depth and
  DLQ depth are provider metrics. Lambda invocation, error, and duration metrics
  are provider metrics.
- Cloud Run / Pub/Sub: Cloud Logging `cloud_run_revision` for the service;
  Pub/Sub undelivered/ack metrics and Cloud Run request/instance metrics are
  provider metrics.

Locally, `sol-jobs` supplies handler metrics, backlog gauges, and logs; the task
runtime adds the same `task_id`/`kind`/outcome line.

These are **provider-native** signals, not a Sol-managed task metrics layer.
There is no task-specific counter in this package, and the envelope does not
carry W3C trace context, so no distributed trace claim is made. Dead-letter
inspection is provider-native (SQS DLQ, Pub/Sub dead-letter topic, local
`failed` row); there is no replay command.

## Non-goals

- A universal queue abstraction or a second primitive.
- Exactly-once external side effects.
- Application-selected immediate dead-lettering.
- Stable delivery-attempt numbers exposed to the handler.
- Portability of provider queue settings or ordering semantics.
- Reinterpreting `-worker` Kafka consumers or run-once `-fn` as task handlers.
