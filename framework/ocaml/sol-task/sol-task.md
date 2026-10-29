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
idempotent. Sol does not claim exactly-once external side effects.

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
`maxDeliveryAttempts`.

## Observability

The runtimes log structured `task_id`, `kind`, and outcome lines. Locally,
`sol-jobs` supplies handler metrics, backlog gauges, and logs. Lambda emits to
CloudWatch; Cloud Run emits to Cloud Logging. Sol does not yet claim a managed
task metric/trace acceptance layer for the cloud runtimes.

## Non-goals

- A universal queue abstraction or a second primitive.
- Exactly-once external side effects.
- Application-selected immediate dead-lettering.
- Stable delivery-attempt numbers exposed to the handler.
- Portability of provider queue settings or ordering semantics.
- Reinterpreting `-worker` Kafka consumers or run-once `-fn` as task handlers.
