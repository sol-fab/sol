# sol-jobs — Durable Leased Job Library

## What it is

`sol-jobs` is Sol's Postgres-backed durable job queue: "do this eventually, retry with backoff, don't block on it" for independent units of work, without a second broker. It is a **library**, not a fourth deployable primitive (FEAT-077, DEC-021) — `Make(J).run` is hosted by an ordinary generated `-worker` binary, the primitive with no HTTP surface and the natural home for long-running background execution. There is no `sol new jobs` app type and no separate deploy topology; a `-worker` binary that calls `Sol_jobs.Make(J).run` instead of `Worker.Make(W).run` is still a `-worker` by runtime topology, it just processes a Postgres queue instead of a Kafka topic.

**Runtime topology and programming model are separate axes (DEC-021):**

| Work model | Substrate | Primitive |
|---|---|---|
| Stream/event consumption | Kafka | `sol-worker` (`Worker.Make`) |
| Durable independent jobs | Postgres | `sol-jobs` (`Sol_jobs.Make`), hosted by a `-worker` |

`sol-worker`/Kafka says "this happened" (a fact about the world, ordered per partition, one shared log any number of consumer groups can independently replay). `sol-jobs`/Postgres says "this must happen" (a unit of work with an owner, claimed once, retried until it succeeds or is given up on). Reach for `sol-jobs` when a piece of work is independent of any other event's ordering — sending a welcome email, generating a PDF, retrying a webhook delivery — and reach for `sol-worker` when correctness depends on processing events for the same key in order. Do not use `sol-jobs` merely because a job "happens to relate to" an earlier one; that is what Kafka's partition ordering is for.

**The one thing Kafka structurally cannot give you:** transactional enqueue. `Sol_jobs.Make(J).enqueue` issues a plain `INSERT`, so calling it with the `tx` handle from inside `Db.transaction`'s callback enqueues the job in the *same* Postgres transaction as whatever application state change caused it — no dual-write hole between "the order was placed" and "the confirmation-email job exists." A Kafka publish can never join a Postgres transaction.

## Module type

```ocaml
module type JOB = sig
  type t
  val workspace : string
  val kind : t -> string
  val kinds : string list
  val encode : t -> string
  val decode : string -> (t, string) result
  val handle : t -> (unit, string) result
end
```

One `Make(J)` instance owns one workspace's rows in the shared job table and one polling loop. An app's `t` is its own sum type covering every kind of job it enqueues:

```ocaml
type job =
  | Send_welcome_email of { user_id : string }
  | Generate_pdf of { report_id : string }

module J = struct
  type t = job
  let kind = function
    | Send_welcome_email _ -> "send_welcome_email"
    | Generate_pdf _ -> "generate_pdf"
  let kinds = [ "send_welcome_email"; "generate_pdf" ]
  let encode t = (* Yojson.Safe.to_string ... *)
  let decode s = (* Yojson.Safe.from_string, then decode ... *)
  let handle = function
    | Send_welcome_email { user_id } -> Emails.send_welcome user_id
    | Generate_pdf { report_id } -> Reports.generate report_id
end
```

Multiple job "kinds" are just constructors of one `t` — the same way an app's Kafka `MESSAGE` type can carry a variant payload. Dispatch is `J.handle`'s own pattern match. `kind` labels metrics and logs, and it is also what a poller **claims by** (BUG-044): `kinds` lists every value `kind` can return, and a `Make(J)` poller claims only rows whose `kind` is in `J.kinds`. So separate `Make` instances with different job types can share the one table without claiming — and failing to decode — each other's jobs. Each kind is non-empty and uses only `a-z`, `0-9`, `_`, `.`, `-`; `run` refuses anything else with `` `Config ``, and `enqueue` validates the same kind declaration and refuses a job whose `kind` is not in `J.kinds`, because no poller would ever claim it.

`decode`'s `Error _` is treated exactly like a `handle` failure: retried per the configured `retry_policy`, eventually terminal. There is no separate poison-message path the way Kafka's decode-error handling needs one — unlike a Kafka partition, one bad row can never block any other job's claim.

## Job table

`sol-jobs` does not create or migrate its own table — an app author adds a migration for it, same as any other Sol-managed table:

```sql
CREATE TABLE IF NOT EXISTS sol_jobs (
  id           SERIAL      PRIMARY KEY,
  workspace    TEXT        NOT NULL,
  kind         TEXT        NOT NULL,
  payload      TEXT        NOT NULL,
  status       TEXT        NOT NULL DEFAULT 'pending',  -- 'pending' | 'completed' | 'failed'
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

The table name (`sol_jobs`) is fixed, not configurable — one app, one job table, matching FEAT-077's non-goal against a pluggable/configurable backend surface. Two apps *can* share the database, though (AUDIT-024 is why the migration table is workspace-prefixed), so `J.workspace` is a required row identity rather than a property of the table: every enqueue writes it and the claim, retry, completion, failure, lease-renewal and retention-sweep statements all filter by it. A `Make(J)` therefore cannot claim, handle, retry or finalize another workspace's job even when both declare the same `kind` and different payload codecs, and the dedupe key is scoped per workspace too.

`J.workspace` is validated the same way `J.kinds` is, and for the same reason: `run` returns `` Error (`Config msg) `` and `enqueue` returns an error before either touches a row, so a missing, oversized (over 63 bytes) or malformed workspace refuses rather than falling back to a queue every workspace shares. Use the workspace directory name Sol already uses for the migration table and the Kubernetes namespace.

## Deduplication: the Kafka → jobs handoff

`enqueue ?dedupe_key` makes handing work from a Kafka fact to a job idempotent. The dedupe key is the **event's** stable id, not a job id:

```ocaml
Db.transaction pool (fun tx ->
  Jobs.enqueue tx ~dedupe_key:event.id (Send_confirmation_email { order_id }))
```

- The uniqueness constraint on `(workspace, kind, dedupe_key)` lives in the database, not only in `enqueue`: two concurrent enqueues of the same key insert one row.
- **A duplicate is success.** `enqueue` returns `Ok ()` whether it inserted the row or found one already there — the caller cannot, and should not have to, tell those apart. No job id is returned, so nothing else about the existing row is observable.
- Omitting `~dedupe_key` keeps the plain at-least-once insert: two calls enqueue two jobs. That is the right shape when the caller has no stable id to offer.

**How long a key stays occupied.** A finished job's row is retained for `~terminal_retention_s` (default 604800s = 7 days) and only then swept, so its dedupe key blocks a re-enqueue for that whole window. That is the point: a Kafka redelivery usually arrives after the first attempt has already finished, and deleting the row on completion would re-enqueue exactly then.

```text
enqueue evt-1 → handle → completed ─┐
                                    │  row retained: a redelivery of evt-1 is a no-op
redeliver evt-1 ────────────────────┘
```

Past the window the key is free again, so a redelivery *older than the window* enqueues a second job. **That horizon is part of the contract**: choose a window longer than the redelivery you need to absorb, and keep a handler idempotent if it must survive anything older. The alternative — retaining forever — would grow the job table with throughput.

Each sweep deletes only terminal rows in the runner's workspace and `J.kinds`. Runners accepting overlapping kinds must use compatible codecs and consistent retry and retention policies; the runtime does not coordinate or validate policies across binaries. Disjoint kinds can use different retention windows. Rows for kinds with no running consumer are not automatically swept.

Sweeping happens inside the poller (`~sweep_interval_s`, default 60s), so it needs no separate process or cron. `status = 'completed'` rows are never claimed: the claim query and its partial index both filter on `'pending'`.

## Claim, lease, and retry mechanics

Each poll tick claims at most one due job with a single atomic statement:

```sql
UPDATE sol_jobs
SET locked_until = now() + (?::float8 * interval '1 second'),
    attempts = attempts + 1
WHERE id = (
  SELECT id FROM sol_jobs
  WHERE status = 'pending'
    AND kind = ANY(string_to_array(?, ','))   -- J.kinds, comma-joined
    AND run_at <= now()
    AND (locked_until IS NULL OR locked_until <= now())
  ORDER BY run_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
RETURNING id, kind, payload, attempts
```

`FOR UPDATE SKIP LOCKED` is the whole mechanism: Postgres's own row locking gives mutual exclusion across any number of pollers (multiple replicas of the same `-worker`, or multiple distinct `Make` instances sharing the table — each claims only its own `J.kinds`) with no coordinator, no `LISTEN`/`NOTIFY`, no external lease service. This is a **polling** claim loop by design (FEAT-077 non-goal: no `LISTEN`/`NOTIFY` push) — `poll_interval_s` (default `1.0`) is how long the loop sleeps when it finds nothing claimable; it never sleeps between consecutive jobs while the queue is non-empty.

The claim query updates `locked_until` and commits immediately — `J.handle` then runs **outside** any open database transaction or connection hold. This matters for a Postgres connection pool of limited size: a slow job never ties up a pooled connection for its own duration, only for the brief claim/renew/finalize queries around it. `locked_until` (`lease_s`, default `300.0`) is the crash-recovery mechanism: if this process dies or is killed mid-`handle`, the row's lease expires and another poller can reclaim it after about one lease.

While `J.handle` runs, a sibling fiber renews the lease every `lease_s / 3` using the claimed row's `id` and `attempts`. The claim is the fence, not the lease clock: a renewal succeeds while that row is still `pending` with the `attempts` value the claim returned, so a heartbeat that wakes after the lease lapsed re-extends it rather than surrendering a claim no other poller has taken, and a long handler that yields to Eio stays exclusive. If renewal loses the claim — another poller advanced `attempts`, or the row left `pending` — it logs the loss and requests cancellation of the handler. The loop waits for the handler and its cleanup to exit, never finalizes the lost attempt (even if cancellation is caught and the handler returns success), and only then can claim more work. This is cooperative cancellation: blocking code, protected cleanup or cancellation-resistant handlers may continue. Handlers must join all their attempt work before returning; detached side effects are outside this lifecycle. A renewal query error establishes unknown ownership, so it is logged and retried while execution continues; it is not treated as confirmed claim loss. A handler that blocks the Eio domain, or a database unavailable long enough for another poller to claim the lapsed lease, can still lose exclusivity; keep handlers cooperative and idempotent.

Fenced finalization protects the queue if a lease is lost:

The claim increments `attempts` and returns it, and the complete, retry and fail statements all match `id = ? AND attempts = ?`. A stale holder's finalize therefore matches no row: it cannot complete the new holder's job or clear its lease. The loss is logged (`sol-jobs: lease lost`, with `job_id`, `attempt`, `action`), and the stale outcome is not recorded — the new holder's is.

Deduplicating enqueue does not deduplicate execution. A handler may run concurrently with an older attempt after lease expiry, and a crash after an external side effect but before completion may repeat the effect. Put a stable business operation ID in the payload and use it as the external provider's idempotency key across all attempts. An attempt number is not an idempotency key. Same-database effects can use a transaction and a unique operation record; check-then-send cannot make external effects atomic. Handlers must be safe to repeat, including concurrently, or provide application reconciliation for ambiguous external results.

Warnings go through `ot` when given and stderr otherwise. Keep handlers idempotent, since crash recovery is at-least-once.

On completion:

- **`Ok ()`** — the row becomes `completed` and is retained until its retention window expires.
- **`Error msg`, attempts remaining** — `run_at` is pushed forward by the shared `Sol_retry` backoff formula (`base_delay_s * 2^(attempt-1)`, jittered by `jitter_ratio`, clamped to `max_delay_s`), `locked_until` is cleared, and `last_error` records `msg`.
- **`Error msg`, attempts exhausted** — `status` becomes `'failed'` (terminal — the claim query's `WHERE status = 'pending'` never selects it again), `last_error` records the final message. A failed row stays in the table for operator visibility, the closest thing `sol-jobs` has to a DLQ.

`retry_policy`'s shape and default (`base_delay_s = 1.0; max_delay_s = 600.0; max_attempts = 5; jitter_ratio = 0.1`) intentionally bounds retries by default — `sol-jobs` is a durable at-least-once queue, not an infinite-retry stream consumer, so a poison job lands in `'failed'` rather than retrying forever unless an app explicitly opts into `max_attempts < 0`.

An expired lease from a worker crash counts as an unfinished attempt. The next claim atomically moves the row to `'failed'` once `max_attempts` is reached, without calling the handler again; `last_error` names the unfinished attempt. Ordinary exceptions from `decode` or `handle` count as failed attempts through the same retry/fail path as returned errors. Cancellation and fatal runtime exceptions still propagate.

## Entrypoint

```ocaml
module Make (J : JOB) : sig
  val enqueue
    :  Pg_db.tx
    -> ?run_at:float
    -> ?dedupe_key:string
    -> J.t
    -> (unit, Pg_error.t) result

  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> pool:Pg_db.pool
    -> ?retry_policy:retry_policy
    -> ?poll_interval_s:float
    -> ?lease_s:float
    -> ?ot:Sol_obs.t
    -> ?metrics_port:int
    -> ?on_ready:(unit -> unit)
    -> ?stop:unit Eio.Promise.t
    -> ?max_jobs:int
    -> ?max_claim_failures:int
    -> ?terminal_retention_s:float
    -> ?sweep_interval_s:float
    -> unit
    -> (unit, run_error) result
end
```

`run`'s shape deliberately mirrors `Worker.Make(_).run` (`env`/`ot`/`metrics_port`/`on_ready`/`stop`) so a `-worker` hosting `sol-jobs` looks and behaves like any other Sol primitive: `?ot:Sol_obs.t` wires the same logs/metrics/traces facade, exposing `sol_jobs_processed_total{status,kind}` (`status`: `ok`/`retry`/`failed`) and `sol_jobs_job_duration_seconds` on `GET /metrics`, scraped by Prometheus the same way.

Metrics distinguish handler outcomes from durable transitions. `sol_jobs_handler_outcomes_total{status,kind}` counts decoder/handler returns (`ok` or `error`) before finalization, while `sol_jobs_processed_total{status,kind}` counts only database-confirmed `ok`, `retry` and `failed` transitions. A failed or fenced-out update never reports durable success. `sol_jobs_queue_errors_total{kind,action,reason}` records `renew`/`complete`/`retry`/`fail` errors with `database_error` or `lease_lost`; identifiers and error text stay in logs. `sol_jobs_job_duration_seconds{kind}` measures decoder/handler execution using the monotonic clock, excluding finalization. Cancellation does not produce a normal handler return. `max_jobs` counts confirmed terminal transitions, including crashed attempts exhausted at claim, rather than handler returns. Metrics are process-local observations, not a transactionally persisted audit: a process crash between a commit and metric emission can undercount.

`run` returns `Error (\`Config msg)` immediately, before ever touching Postgres, if `retry_policy.max_attempts = 0` — a `0` value can never mean anything valid (it isn't "no retry", `max_attempts = 1` is; it isn't "unlimited", negative is) so it is rejected up front rather than silently misbehaving the first time a job fails. Invalid `J.kinds` is the same kind of `` `Config `` error.

The same boundary validates every timing input before the first database read or signal registration (CODEX_STYLE_AUDIT-079): `lease_s` and `poll_interval_s` must be finite and greater than zero (a nonpositive lease would let a second poller reclaim a job immediately; a nonpositive interval reaches `Eio.Time.sleep`), and `retry_policy`'s `base_delay_s`/`max_delay_s` must be finite and non-negative while `jitter_ratio` must be finite and within `[0, 1]`. `0` retry delays stay valid (an app may want immediate retries), negative `max_attempts` stays valid (unlimited), and non-finite values (`nan`/`infinity`) are refused rather than reaching a sleep, `Random` or the claim SQL.

Database trouble is loud (BUG-044). `run` reads the `sol_jobs` table before its first claim and returns `` Error (`Database msg) `` if it cannot — a missing migration is a startup error, not an idle-looking loop. A claim query that fails is logged (to `ot`, or to stderr without it) and retried every `poll_interval_s`; `max_claim_failures` consecutive failures (default `30`) end `run` with `` `Database ``, so a `-worker` whose database stays unreachable exits and is restarted visibly rather than polling in silence. Every other database failure the loop meets (a failed completion, retry or terminal mark) is logged the same way.

## Example: transactional enqueue

```ocaml
let accept_order pool order =
  Db.transaction pool (fun tx ->
    let* () = Orders.insert tx order in
    Jobs.enqueue tx (Send_confirmation_email { order_id = order.Orders.id }))
```

If the transaction commits, the order row and the job row both exist. If it rolls back, neither does. There is no window where the order exists but the job was never enqueued (or vice versa) — the failure mode a Kafka publish outside the same transaction cannot close.

The guarantee is **enforced by the type, not by convention**. `enqueue` takes
`Pg_db.tx`, which only `Pg_db.transaction`'s callback can produce, so an enqueue that
would commit on its own — the shape that silently loses the atomicity — does not
compile. `Db.exec`/`find`/`collect` and the `Pg_table` accessors are polymorphic in the
capability, so the same helpers work in both places and there is no second API to keep
in step.

What the type does **not** prove: that you are *currently* inside the transaction. A
`pg_db.tx` is an ordinary value, so a callback can store it and use it after commit.
The compiler establishes that you entered a transaction, not that it is still open.
Closing that needs linearity or regions, which we do not have cheaply; treat a stored
`tx` as a bug, and keep the atomicity test — both rows commit together and roll back
together — as the behavioural check.

## Non-goals

- No RabbitMQ, ElasticMQ, or SQS-compatible abstraction — Postgres only.
- No `LISTEN`/`NOTIFY` push mechanism — polling is the ladder-correct start.
- No new deployable app suffix (`sol new jobs`) or CLI scaffold changes — `Sol_jobs.Make(J).run` is called from a hand-written or generated `-worker`'s `bin/main.ml` like any other library call.
- No configurable/pluggable job-backend, no configurable table name.
- No Kafka-style ordering, partitioning, or per-key sequencing — see "What it is" above for when that means reaching for `sol-worker` instead.
