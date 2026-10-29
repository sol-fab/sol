# Changelog

Sol is pre-alpha (`~/Code/CLAUDE.md`): no backward-compatibility guarantee, and
breaking changes are made freely when they improve the design. This file
tracks user-visible behavior and API changes worth calling out explicitly,
not a full commit log — see `git log` for that.

## Unreleased

- **New:** `sol-task` defines the durable task handler contract shared by the
  local Postgres `sol-jobs` runtime (`sol-task.local`), AWS SQS + Lambda
  (`sol-task.lambda`), and GCP Pub/Sub push + Cloud Run (`sol-task.pubsub`).
  Tasks have a stable `task_id`, application payload and optional idempotency
  key, and handlers return `Ack` or `Retry`; delivery is at-least-once and
  terminal dead-lettering is provider-managed. `sol local task enqueue` inserts
  an envelope into the local queue for development.
- **Behavior change:** `sol new workspace` pins the Sol framework packages in the
  generated `*.opam` to the exact revision the CLI was built from, instead of
  `github.com/sol-fab/sol.git#main`. A generated workspace is now reproducible
  and builds without a Sol checkout; the release build refuses a dirty tree, so
  the pin names the revision the release actually contains. To test uncommitted
  framework changes, install the framework from a checkout with
  `platform/local/scripts/prepare-framework-deps.sh`; that changes the local
  switch, not the workspace pin.

- **Breaking (FEAT-119):** the contract projection entry point is now a
  language-neutral executable, `contract/run`, invoked by Sol as
  `sh ./contract/run <--json|--check|--apply> --scope <scope>`. A workspace whose
  events are OCaml supplies a one-line `contract/run` that runs the generated
  `contract/contract.exe`; a TypeScript workspace supplies its own projection
  program. `sol up`, `sol deploy` and `sol plan` drive both the same way, and the
  in-destination reconciliation runs one Job per language in the deploy's scope
  (every app image installs the program at `/usr/local/bin/contract`). A
  workspace with no `contract/run` has no projection and is skipped. Because a
  runtime only reads the registry, `sol local run` reconciles the scope's
  contract before it starts a unit, the way `sol up` does before it applies.
- **Breaking (FEAT-119):** `@sol-fab/kafka` no longer registers at runtime.
  `connectTopic` provisions the topic and resolves the registered schema
  read-only (failing when the declared contract is not registered);
  `registerContract` is the only write path, and `runContractCli` implements the
  projection program's `--json`/`--check`/`--apply`. `registerTopic` is removed.
- **Behavior change (BUG-105):** runtime schema registration is removed. `Worker.Make`
  and producer units no longer write to the schema registry: `Kafka_service.register`
  provisions the topic and resolves the declared schema (read-only), failing when the
  contract is not registered. Registration belongs to the deployment lifecycle — each
  workspace generates `contract/contract.exe`; `sol up` runs its `--apply` locally and
  `sol deploy` runs it inside the destination (a Job on the deployment's own image)
  before any workload is applied, so a failure prevents rollout. `sol plan` stays
  read-only and reports a private registry as not observed. `MESSAGE.schema` stays the
  source of truth (nothing is duplicated into the manifest), and the projection format is
  language-neutral.
- **Breaking (FEAT-113):** Kafka message-level retry and application-level
  `Dead_letter` are removed (DEC-021's 2026-09-29 amendment). `Worker.Make_with_retry`,
  `Worker.RETRYABLE_WORKER`, `retry_policy`/`default_retry_policy`,
  `Worker.Retry`/`Worker.Dead_letter`, `Kafka_service.Retry_topics`,
  `consume_partitioned`, `consumer_hooks`/`on_relay_publish`, the
  `X-Sol-Retry-Attempt`/`X-Sol-Retry-At` headers, and the retry-topic relay are
  gone. `Worker.Make` is the single tier, and `handle` returns exactly
  `Ack | Fail`. A `Fail` does not advance the offset, emits
  `sol_worker_messages_total{status="fail"}`, logs, and stops the consumer — a
  contract failure an operator sees, rather than a fact the runtime skipped.
  Independently retryable work belongs in `sol-jobs`, enqueued in the same
  transaction as the state change that caused it (`examples/pluto` and
  `internal/fixtures/venus` show the pattern). The removed
  `kafka_service_retry_topics` module is replaced by `Kafka_service.Dlq`, which
  keeps the group-scoped DLQ naming and decode-failure handling.
- **Behavior change (FEAT-113):** every `Worker.Make` worker now routes a source
  record it cannot decode to the consumer group's DLQ by default
  (`decode_error_policy = Route_to_dlq`). Previously that default belonged only to
  `Make_with_retry`; a plain `Make` worker acked and dropped. `Ack_and_drop`
  remains an explicit opt-in. Decode failures still count on
  `sol_worker_decode_errors_total`.
- **Behavior change (FEAT-113):** `sol_worker_messages_total`'s `status` vocabulary
  shrinks to exactly `ok`, `fail`, `ack_failed`. `retry`, `dead_letter`,
  `relay_published`, and `relay_failed` are gone, and the
  `SolWorkerRelayPublishFailed` and `SolWorkerDeadLetterInflow` alerts are removed
  with them, since their series can no longer occur.
- **New (FEAT-079):** `-fn`'s `sol.toml` gains `scheduled_concurrency`
  (`allow`/`forbid`/`replace`, default `allow`) and `backoff_limit` (default
  `3`), rendered as the deployed `CronJob`'s `concurrencyPolicy` and
  `jobTemplate.spec.backoffLimit`. Both previously had no Sol-level
  representation — `concurrencyPolicy` silently defaulted to Kubernetes'
  `Allow`, and `backoffLimit` was hardcoded to `3`. Omitting either field
  preserves that exact prior behavior.
- **New (FEAT-079):** `sol fn run <domain>/<name> [--target ...]` and `sol
  local fn run <domain>/<name>` manually invoke a deployed `-fn` by creating
  a Kubernetes `Job` from its deployed `CronJob`'s `jobTemplate` — the same
  execution definition a scheduled run would use. Not constrained by
  `scheduled_concurrency`, which only governs overlap between the CronJob
  controller's own scheduled runs.
- **Behavior change (BUG-031):** `-fn`'s generated `CronJob` now honors
  `sol.toml`'s `cpu`/`memory` fields, which were previously parsed but
  silently discarded in favor of hardcoded values. For a `-fn` app that
  does not set `cpu`/`memory`, the generated `resources.limits` changes
  from `250m`/`256Mi` to `100m`/`128Mi` — now equal to `resources.requests`,
  matching `-svc`/`-worker`'s existing convention (no request-to-limit
  multiplier) instead of preserving the old, undocumented 2.5x/2x ratio.
- **Breaking (FEAT-078):** `Worker.WORKER` is now Ack-only — `handle` returns
  `ack_outcome` (`Ack` only), not the full `outcome`. A worker whose `handle`
  needs to return `Retry`/`Dead_letter` must implement the new
  `Worker.RETRYABLE_WORKER` module type instead and run under the new
  `Worker.Make_with_retry` functor, which requires an explicit
  `~retry_strategy` — there is no implicit default. `Kafka_service.default_retry_strategy`
  is removed, and `Kafka_service.consume_partitioned`'s `~retry_strategy` is
  now a mandatory argument. This closes the failure mode where a missing
  retry strategy was discovered only the first time a message failed to
  process (a poison-message crash/redelivery loop), by making it a compile
  error instead.
- **Breaking:** `Kafka_service.retry_strategy`'s `Retry_topics` case now
  carries a full `Kafka.Consumer.retry_policy` (`base_delay_s`, `max_delay_s`,
  `max_attempts`, `jitter_ratio`) instead of a bare `{ max_attempts : int }`.
  `In_memory` and `Retry_topics` now share one retry-policy vocabulary.
- **Behavior change:** `Retry_topics`'s retry backoff used to be a hardcoded,
  unjittered `min(1.0 * 2^n, 600.0)`. It is now
  `base_delay_s * 2^(attempt-1)`, jittered by `jitter_ratio` and clamped to
  `max_delay_s` — the same computation `In_memory` uses
  (`Kafka.Consumer.backoff_s`, from the `kafka-eio` package's own `0.3.0`).
  A `retry_policy` with `jitter_ratio = 0.0` and the old constants
  (`base_delay_s = 1.0`, `max_delay_s = 600.0`) reproduces the old schedule.
- **Behavior change:** under `In_memory`, a handler's `Dead_letter` no longer
  acks-and-drops the message. `In_memory` has no DLQ to route it to, so it
  now fails closed — the message is left unacknowledged and treated as a
  terminal failure, exactly like an exhausted retry budget. `Retry_topics`'s
  `Dead_letter` handling (route to the DLQ, ack only after that publish
  succeeds) is unchanged.
- `kafka-eio` bumped to `0.3.0`: `Kafka.Consumer.retry_policy` gains
  `jitter_ratio`; `consume_partitioned`'s backoff is jittered; the pure
  `Kafka.Consumer.backoff_s` computation is exposed for direct testing. See
  `~/Code/kafka-eio/CHANGES.md`.
