# Durable task handlers

A task is an independent unit of work that must be delivered until it succeeds
or reaches its provider-managed limit. Use a task when the work must happen but
does not need Kafka's per-key ordering: sending a welcome email, generating a
report, retrying a webhook. Use a Kafka `-worker` when ordering or replay of a
fact matters. Use `-fn` for a run-once scheduled or manually invoked function.

Tasks are a library, not a fourth primitive. The same handler module runs:

- locally and on Kubernetes in a `-worker` over the Postgres `sol-jobs` queue;
- on AWS in a Lambda function triggered by SQS;
- on GCP in a Cloud Run service receiving Pub/Sub push requests.

The full contract and API are in
[`sol-task.md`](../../framework/ocaml/sol-task/sol-task.md).

## Define the handler

One module covers every task kind in the workspace:

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

  let decode text = (* parse the JSON and return (t, string) result *)

  let handle ~task_id ?idempotency_key = function
    | Send_welcome_email { user_id } ->
      (match Emails.send_welcome ~idempotency_key user_id with
       | Ok () -> Sol_task.Ack
       | Error message -> Sol_task.Retry message)
    | Generate_pdf _ -> (* ... *)
end

module Tasks = Sol_task_local.Make (T)
```

`Ack` means the side effect committed. `Retry` means the task remains eligible
for another delivery. An exception is a `Retry`. Delivery is at-least-once, so
the handler must be idempotent; use the `idempotency_key` where the external
effect supports one.

## Add the queue migration

The workspace must create the `sol_jobs` table. Copy the DDL from
[`sol-jobs.md`](../../framework/ocaml/sol-jobs/sol-jobs.md) into a migration:

```sql
CREATE TABLE IF NOT EXISTS sol_jobs (
  id           SERIAL      PRIMARY KEY,
  workspace    TEXT        NOT NULL,
  kind         TEXT        NOT NULL,
  payload      TEXT        NOT NULL,
  status       TEXT        NOT NULL DEFAULT 'pending',
  attempts     INT         NOT NULL DEFAULT 0,
  run_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_until TIMESTAMPTZ,
  last_error   TEXT,
  dedupe_key   TEXT,
  inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS sol_jobs_claim_idx
  ON sol_jobs (workspace, run_at)
  WHERE status = 'pending';

CREATE UNIQUE INDEX IF NOT EXISTS sol_jobs_dedupe_idx
  ON sol_jobs (workspace, kind, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS sol_jobs_terminal_idx
  ON sol_jobs (finished_at)
  WHERE status <> 'pending';
```

## Host the local runtime

A `-worker` binary owns the loop. Declare the workspace's Postgres resource in
`sol.yml` so local runs receive `POSTGRES_URL`:

```yaml
services:
  task_worker:
    type: worker
    path: app/comms/task_worker
    uses: [app_db]
    language: ocaml
```

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    match Pg_db.of_env ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
    | Ok pool -> pool
    | Error error -> failwith (Pg_error.to_string error)
  in
  let ot = Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
      ~service:"task-worker" () in
  match Tasks.run ~env ~pool ~ot ~metrics_port:0 () with
  | Ok () -> ()
  | Error error -> failwith (Sol_jobs.run_error_to_string error)
```

`Tasks.run` is the existing `sol-jobs` loop: it claims one due row, renews the
lease, retries with backoff, marks a terminal failure, and exposes the
`sol_jobs_*` metrics. Task handling does not change those semantics.

## Enqueue

In application code, enqueue in the transaction that caused the work:

```ocaml
Db.transaction pool (fun tx ->
  let* () = Orders.insert tx order in
  Tasks.enqueue tx ~idempotency_key:order.id (Send_welcome_email { user_id }))
```

For a local development loop, enqueue from the CLI:

```text
sol local task enqueue --kind send_welcome_email \
  --payload '{"user_id":"u-1"}' --idempotency-key order-42
```

Then start the worker with `sol local run`. The handler runs, the row becomes
`completed`, and the job metrics/logs identify the `task_id` printed by the
enqueue command.

## Cloud runtimes

::: status
The Lambda and Pub/Sub **runtime handlers** are implemented and unit-tested by
this package. The target-scoped provider deploy/verify/destroy lifecycle for
tasks is being implemented next; do not treat the runtime entrypoint as a
supported cloud deployment workflow yet.
:::

The handler module and `Sol_task.TASK` contract are unchanged in the cloud.
The runtime is selected by the deployment, not by the application code:

- **AWS:** `Sol_task_lambda.Make(T).run` handles SQS records and returns
  `batchItemFailures`; the event source mapping must enable
  `ReportBatchItemFailures`. SQS owns the dead-letter queue.
- **GCP:** `Sol_task_pubsub.Make(T).run` serves the Pub/Sub push endpoint
  (`200` ack, `500` retry, `400` malformed). Cloud Run IAM authenticates the
  Pub/Sub push service account; Pub/Sub owns the dead-letter topic.

The shared guarantees are stable task identity, at-least-once delivery,
acknowledge-after-success, retries, a provider-managed dead-letter budget, and
the 256 KiB portable envelope. Concurrency, visibility/ack deadlines, retention
windows, and the concrete retry schedule are provider-specific.
