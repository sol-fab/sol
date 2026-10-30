# sol-worker — Worker Primitive

## What it is

`sol-worker` is the Kafka consumer primitive. A `-worker` is a long-running process that subscribes to a topic, processes each message, and emits per-message metrics automatically.

There is one tier: `Make`. `handle` returns `outcome`, which has exactly two cases — `Ack` and `Fail`. A worker cannot express retry, delay, or "transfer this record elsewhere": those outcomes do not exist in the type.

Kafka distributes facts. A fact Sol cannot apply is not retried on the stream — the offset stays uncommitted and the consumer stops, so the fact is redelivered on the next start and the condition is operator-visible instead of a fact the runtime quietly skipped. Work that must be retried later, independently, with a caller-visible schedule belongs to `sol-jobs` (DEC-021/FEAT-077), a library hosted by an ordinary `-worker` binary: enqueue the job in the same transaction as the state change that caused it. That handoff is why message-level retry was removed (DEC-021's 2026-09-29 amendment). Neither primitive requires the other, but this is the endorsed composition for independently retryable work.

## Module types

```ocaml
type outcome =
  | Ack
  | Fail

module type WORKER = sig
  module Message : Kafka_service.MESSAGE

  val group_id : string
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> outcome
end
```

- `Message` — the event contract. Defines topic name, JSON schema, partition count, key, encode/decode.
- `group_id` — Kafka consumer group ID. Must be stable across restarts.
- `handle` — called once per decoded message. `trace_ctx` carries the upstream W3C `traceparent` header from the Kafka message — pass it as `?parent:trace_ctx` to `Obs_eio.with_span` to link spans. There is no `ack` to call — see [ack semantics](#ack-semantics). `Ack` applies the fact; `Fail` declines it and stops the consumer — see [Fail stops the consumer](#fail-stops-the-consumer).

## Entrypoints

```ocaml
module Make (W : WORKER) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> config:Kafka_service.config
    -> ?decode_error_policy:decode_error_policy
    -> ?ot:Sol_obs.t
    -> ?metrics_port:int
    -> ?on_ready:(unit -> unit)
    -> ?stop:unit Eio.Promise.t
    -> ?max_messages:int
    -> unit
    -> (unit, run_error) result
end
```

- `ot` — when provided, emits `sol_worker_messages_total{status}` and `sol_worker_message_duration_seconds` per message, and exposes `GET /metrics` on `metrics_port` for Prometheus scraping.
- `metrics_port` — default `9090`. Only binds when `ot` is provided; pass `0` for an OS-assigned port when running more than one `-worker`/`-svc` in the same process.
- `on_ready` — called exactly once when the broker assigns partitions to this consumer.
- `stop` — external stop signal. Resolve to request graceful shutdown; checked alongside the worker's own SIGTERM/SIGINT handling, not in place of it.
- `max_messages` — stop cleanly after this many successfully processed messages. Useful in tests.
- `decode_error_policy` — what happens to a source record the framework cannot decode. Defaults to `Route_to_dlq`; `Ack_and_drop` is an explicit opt-in that discards it. See [error handling](#error-handling).

`run` owns the full lifecycle: `Kafka_service.create` → `register` → `consume`. It returns when `max_messages` is reached, when a `Fail` or a fatal consumer error stops the consumer, or when a shutdown signal is received (SIGTERM, SIGINT, or `stop` resolving).

## Fail stops the consumer

`Fail` is not error handling; it is the offset invariant stated plainly: **Sol must not advance past a fact it did not successfully consume.** When `handle` returns `Fail`, the worker:

1. does **not** commit the offset;
2. emits `sol_worker_messages_total{status="fail"}`;
3. logs an error; and
4. returns `Kafka.Consumer.Stop`, ending the consume loop.

`run` then returns `Ok ()` — a normal exit — so a supervisor restarts the process from the last committed offset. A contract failure (a permanent semantic mismatch, an unsupported domain version, an invariant violation) is evidence that the consumer, the deployment, or the contract is wrong, and surfaces as a stopped consumer plus an alert rather than a skipped fact. There is no retry policy, attempt budget, backoff schedule, retry header, retry topic, or relay, and no application-level dead-letter outcome.

Transient failures of a *dependency* are handled at the operation level — a bounded, jittered retry around the dependency call (FEAT-114) — not by re-running the whole handler. Work that must be retried later, independently, belongs in `sol-jobs`, enqueued in the transaction that caused it:

```ocaml
let handle msg ~trace_ctx:_ =
  match
    Pg_db.transaction pool (fun tx ->
      let open Result.Syntax in
      let* () = Orders.insert pool msg in
      Jobs.enqueue tx ~dedupe_key:msg.order_id EmailJob.{ order_id = msg.order_id })
  with
  | Ok () -> Worker.Ack
  | Error _ -> Worker.Fail
```

`dedupe_key` is the fact's stable id, backed by a uniqueness constraint, so a redelivery after a successful enqueue but a failed offset commit repeats the enqueue as a no-op (FEAT-112). See [`sol-jobs.md`](../sol-jobs/sol-jobs.md).

## Lifecycle

```
Make(W).run ~env ~config ?decode_error_policy ?ot ()
  │
  ├─ Register metrics if ot provided
  │    sol_worker_messages_total{status}        [counter]
  │    sol_worker_message_duration_seconds      [histogram]
  │
  └─ Switch.run (outer)
       ├─ fork_daemon: signal handler → stop requested  (self-pipe)
       │
       └─ Kafka_service.create → register → consume
            per message:
              if stop requested or max_messages reached → Stop  (graceful drain)
              else W.handle msg ~trace_ctx
                Ack                                → ack() (the framework's, not W.handle's)
                                                        Ok ()                  → metrics ok, Continue/Stop
                                                        Error e, is_fatal e    → metrics ack_failed, Error e (Stop + raise)
                                                        Error e, not fatal     → metrics ack_failed, Continue
                Fail                               → metrics fail, log, Stop  (offset not committed)
```

After `run` returns:
- If `Kafka_service.create` failed → returns `Error (`Create ...)`
- If `register` failed → returns `Error (`Register ...)`
- If the consumer failed → returns `Error (`Consume ...)`
- On `Fail`, SIGTERM/SIGINT, `stop` resolving, or `max_messages` reached → returns `Ok ()`

Both stop sources are joined into one handle passed to the consumer, so an *idle*
worker — an empty topic, malformed-only traffic, or a stop requested while the
final message is in flight — returns promptly too, rather than waiting for the
next decoded message. `stop_handle`/`join_stop` resolves once, from whichever
source fires first; a handler already running still completes and acknowledges
before the loop ends.

## Signal handling

Self-pipe trick (same pattern as `sol-svc` and `sol-fn`), implemented once in `Sol_runtime` and shared by every service primitive:
1. `Unix.pipe ~cloexec:true` + `Unix.set_nonblock w`
2. `SIGTERM`/`SIGINT` handler: `Unix.single_write w "\x00"` (async-signal-safe)
3. `Fiber.fork_daemon ~sw`: `Eio_unix.await_readable r` → resolve the stop promise

The stop condition is checked at the top of the message handler, so the consumer finishes the current message before stopping (graceful drain) rather than aborting mid-message.

## Metrics

When `?ot` is provided:

| Metric | Type | Labels | Description |
|---|---|---|---|
| `sol_worker_messages_total` | counter | `status` | Messages processed, by outcome. `status` is exactly one of `ok`, `fail`, `ack_failed`; those values are part of the contract. |
| `sol_worker_message_duration_seconds` | histogram | — | Per-message processing latency |

- `ok` — `handle` returned `Ack` and the offset commit succeeded.
- `fail` — `handle` returned `Fail`: the offset was not committed and the consumer stopped. A rising `fail` series means a worker is not consuming facts it received — see the [message-drop runbook](../../../docs/deployment/alert-runbooks.md#message-drop--diversion).
- `ack_failed` — `handle` returned `Ack` (the side effect happened) but the offset commit itself failed. Distinct from `fail`: the work is done, only the bookkeeping failed. See [ack semantics](#ack-semantics).

A source record the framework cannot decode never reaches `handle`, so it is counted on `sol_worker_decode_errors_total`, not as a `sol_worker_messages_total` status.

Metrics are registered once at startup. Emitter functions are called in the handler closure on each message.

## Usage examples

A worker consumes a fact and hands independent, retryable work to a job in the same transaction:

```ocaml
module NotifyWorker = struct
  module Message = Events.Payments.Charged

  let group_id = "comms-notify-worker"

  let handle msg ~trace_ctx:_ : Worker.outcome =
    match
      Pg_db.transaction Config.pool (fun tx ->
        let open Result.Syntax in
        let* () = Notifications.insert pool msg in
        Jobs.enqueue tx ~dedupe_key:msg.charge_id EmailJob.{ charge_id = msg.charge_id })
    with
    | Ok () -> Worker.Ack
    | Error _ -> Worker.Fail
end

let () =
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let obs =
      Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
        ~service:NotifyWorker.group_id ()
    in
    match Kafka_service.config_of_env () with
    | Error e -> failwith (Kafka_service.error_to_string e)
    | Ok config ->
      Worker.Make(NotifyWorker).run ~env ~config ~ot:obs ()
      |> Result.map_error Worker.run_error_to_string
      |> function Ok () -> () | Error msg -> failwith msg
```

The email job is delivered by a `sol-jobs` runner in the same process (or another replica of it); see [`sol-jobs.md`](../sol-jobs/sol-jobs.md) for the runner side of the pair.

## ack semantics

`W.handle` does not receive (or call) an `ack`. `run` commits the Kafka offset itself, and only after `W.handle` returns `Ack` — never before, and never on `Fail`. This removes an entire class of app-level bugs: forgetting to ack, acking in the wrong branch, or acking before a side effect that can still fail. For at-least-once semantics this is the correct default; at-exactly-once is not supported in v1.

A failed commit is **not** treated like a handler failure. The side effect in `W.handle` already succeeded, so re-running the handler risks duplicating it. Instead:

- The commit failure is logged (`Warn`, or `Error` if fatal) and counted as `sol_worker_messages_total{status="ack_failed"}`.
- If `Kafka_error.is_fatal e` — a broken consumer, not a transient hiccup — it escalates to an `Error`, stopping the worker the same way a `Fail` does.
- Otherwise, the worker **stops after the failed commit** and lets the broker redeliver the uncommitted message. A later successful commit would be cumulative and supersede the failed offset, so continuing would silently lose the fact; stopping preserves at-least-once delivery and exposes the retry through the normal consumer loop.

### Acknowledgement ownership invariant

> **Sol must not acknowledge failed work unless responsibility for that work has durably transferred to another valid destination.**
>
> This applies to the one path that transfers responsibility: a source record Sol cannot decode is published to the consumer group's DLQ, and its source offset is acknowledged only once that publish succeeds. If the publish fails, the record stays unacknowledged and the failure is surfaced.
>
> There is no other transfer. A decoded fact the handler declines to apply is not dead-lettered — `Fail` leaves it unacknowledged for redelivery — and logging an error or deciding not to process a message does not itself constitute durable transfer.

A source-topic record that cannot be decoded is covered too (BUG-051): the default `decode_error_policy = Route_to_dlq` publishes the raw record (payload, key, headers) to the group-scoped DLQ and acks only once that publish succeeds. Acking it without a transfer is the explicit opt-in `Ack_and_drop`, never a silent default where a destination exists.

## Error handling

- `W.handle` returning `Fail` does not commit the offset, emits `sol_worker_messages_total{status="fail"}`, logs, and stops the consumer — see [Fail stops the consumer](#fail-stops-the-consumer).
- `W.handle` returning `Ack` but the subsequent ack failing: see [ack semantics](#ack-semantics) above — handled separately, via `ack_failed`.
- Decode errors on the source topic follow `decode_error_policy` (BUG-051). By default, `Route_to_dlq` publishes the raw record (payload, key, headers) to the group-scoped DLQ with `X-Sol-Decode-Error` and `X-Sol-Origin-Group`, and acks only once that publish succeeds; a failed publish leaves it unacked and stops the consumer. `Ack_and_drop` (log, count, ack) is the explicit opt-in.
- Lifecycle errors (`create`, `register`, Kafka error) are returned as `run_error` values.

## Test injection

`?test_consume_loop` (on `Worker.For_testing.Make`) bypasses `Kafka_service.create`/`register`/`consume` entirely, driving the wrapped handler with synthetic messages. Used in unit tests — not intended for production.

```ocaml
let fake_loop ~handler () =
  let _ = handler { id = "test-msg" } ~ack:(fun () -> Ok ()) ~trace_ctx:None in
  ()

Worker.For_testing.Make(W).run ~env ~config ~test_consume_loop:fake_loop ()
```
