# Proposal: minimal serverless execution boundary and task-queue contract

Status: **proposal for design review — no implementation authorized.**

This proposal accompanies [ADR 0010](../adr/0010-execution-backends.md). It
turns the two unresolved design questions into testable contracts, using the
current Kubernetes implementation as evidence rather than designing a universal
abstraction.

## 1. Minimum lifecycle seam

The seam describes operations Sol already performs; it does not enumerate every
Kubernetes object. Its purpose is to prove, against a second adapter, that the
operations can be expressed without lying about ownership, verification or
failure.

| Operation | Owner | Evidence | Failure semantics |
|---|---|---|---|
| Plan/refuse | Target resolver + plan | Target execution, selected workload/trigger/resource matrix, profile findings | Unsupported combination refuses before build or mutation; refusal names the reason. |
| Apply/update | Execution adapter | Provider identity of each created/updated workload and resource | Partial apply reports what exists and what is unknown; it never reports success. |
| Verify | Execution adapter | Primitive-specific readiness/health observation with timestamp and identity | Failed/unreadable readiness is failed/UNKNOWN, never success. |
| Release | Release store + adapter | Immutable release content identity and provider revision/version identity | A release is not current until verification succeeds. |
| Rollback | Release store + adapter | Previous release identity, owned identities, and post-rollback verification | Unknown ownership or incompatible provider revision refuses; provider error is preserved. |
| Destroy | Execution adapter | Owned-resource inventory and provider responses | Partial destruction is reported with surviving/unknown identities; never "clean" without evidence. |
| Absence | Independent inventory | Every required provider class queried | Unreadable/timeout/malformed result is UNKNOWN, never absent. |
| Diagnose | Adapter | Provider-native error/status plus Sol operation context | Do not replace the provider error or infer an unverified root cause. |

The first implementation may put this seam at the executor/lifecycle-command
boundary and keep `service_spec` as the Kubernetes-shaped plan. Moving
Kubernetes fields out of the plan is deferred until a second adapter shows which
fields are actually shared.

The seam is only accepted if a real serverless deployment can satisfy every row
without weakening an existing guarantee.

## 2. Durable task-queue contract

The initial messaging use case is a **durable work queue**, not an event bus and
not Kafka.

### 2.1 Task identity and payload

- Sol assigns a stable `task_id` at enqueue time; it remains the same across
  retries and redeliveries.
- The application supplies an idempotency key or derives one from the task's
  business identity. Sol carries the value; **Sol cannot enforce application
  idempotency**.
- The portable payload limit is **256 KiB**. A larger task is refused at
  enqueue; it is not silently truncated or stored in an out-of-band location.
- The queue does not promise global ordering. A handler must not rely on
  ordering across tasks.
- The target/queue name is part of the declared contract and is not inferred
  from the handler name.

### 2.2 Delivery and acknowledgement

- Delivery is **at-least-once**. A task may be delivered more than once.
- A handler acknowledges success only after its business side effect has
  committed.
- Acknowledgement is queue bookkeeping, not part of the business transaction.
  If the side effect succeeds and acknowledgement fails, redelivery is expected.
  The handler must make that redelivery safe through the idempotency contract.
- Sol does **not** claim exactly-once external side effects. At-least-once
  delivery plus application idempotency is the contract.
- A handler that cannot determine whether its side effect committed must not
  report success; the task is retried or left for operator diagnosis.
- A failed acknowledgement leaves the task eligible for redelivery. It must not
  be reported as acknowledged.

### 2.3 Handler outcome

The queue-handler runtime distinguishes:

- **Ack** — side effect committed; acknowledge.
- **Retry** — transient failure; redeliver under the retry policy.
- **Dead-letter** — permanent/declared failure; move to the dead-letter
  destination without further ordinary retries.

An uncaught failure is treated as **Retry**, not as Ack. The application may
choose a different policy only where the provider can honor it explicitly.

### 2.4 Retry, exhaustion and dead-lettering

#### What counts as an attempt

Sol counts **handler attempts**, not provider deliveries:

> An attempt begins when the queue runtime has validated the task envelope and
> invokes the application handler for one task. It includes handler timeouts,
> cancellation, crashes and abnormal exits. It does not include a delivery or
> transport failure that occurs before the handler is entered.

This definition matters because providers may count deliveries differently. The
adapter must expose both counters separately:

- **delivery failures** — provider delivery/transport failures before handler
  entry;
- **handler attempts** — handler invocations, including failures, timeouts and
  cancellation.

Rules:

- A batch is not an attempt. Each task in a batch has its own attempt count.
- A malformed task envelope that never enters the handler is a delivery/task
  failure, not a handler attempt; it is dead-lettered without silently
  acknowledging a valid task.
- A handler that times out or is cancelled still consumed its attempt.
- An infrastructure failure before the handler starts does not consume a
  handler attempt; it must be reported as a delivery failure.
- If a handler succeeds but acknowledgement fails, that success does not erase
  the task's history. If the task is redelivered, the next handler invocation is
  a new attempt; the ack failure is recorded separately.
- The attempt number is stable in the task metadata and does not reset on
  redelivery.

The initial budget is **5 handler attempts**, provisional. Provider mappings must
either permit at least that many handler entries before dead-lettering or report
a capability difference/refuse. A provider setting that counts all deliveries
(for example `maxReceiveCount`/`maxDeliveryAttempts`) must be tested against
pre-handler delivery failures; it is not assumed to equal Sol's handler budget.

#### Exhaustion and dead-lettering

- Retry uses bounded backoff supplied by the adapter; the contract does not
  promise identical timing across providers.
- When the handler-attempt budget is exhausted, the adapter moves the task to a
  provider-owned dead-letter destination.
- Dead-letter retention: **at least 7 days**, configurable within provider
  bounds; the actual retention is recorded in evidence.
- Dead-letter publishing follows the same acknowledgement invariant as the
  original task: do not acknowledge the source until the dead-letter write
  succeeds.
- **Reprocessing dead-lettered tasks is out of scope for the first proof.**
  Operators may inspect them through the provider; an automated replay command
  is a later contract decision.
- Exhaustion, dead-letter publishing failure and retention are observable and
  recorded; none is reported as success.

### 2.5 Concurrency and timeouts

- The target declares a bounded maximum concurrency. The adapter must enforce
  it or report the provider limitation; it must not silently run unbounded.
- The handler must finish within the provider/queue delivery window. A timeout
  is a Retry, not success; the application must be idempotent for the retry.
- Visibility/lease and ack-deadline extensions are adapter responsibilities,
  not application APIs.

### 2.6 Provider acceptance tests

These are behavioral tests, not configuration comparisons. Both providers must
pass the same tests before `task_queue` is accepted.

| Test | Expected result |
|---|---|
| Enqueue and process a task | Handler runs once successfully; task acknowledged; no duplicate effect. |
| Duplicate delivery | Second delivery sees the same `task_id`; application idempotency prevents a second effect; second delivery acknowledges. |
| Crash after side effect, before ack | Task is redelivered; handler's idempotency prevents a duplicate; eventual ack. |
| Crash before side effect | Task is retried and succeeds. |
| Transient failure | Retries until success, within the handler-attempt budget. |
| Exhausted handler attempts | After exactly five handler entries, the task appears in the dead-letter destination; source is not silently lost. |
| Handler timeout/cancellation | Counts as an attempt; five such outcomes exhaust the budget. |
| Pre-handler delivery failure | Reported as a delivery failure and does not consume a handler attempt; the adapter must expose the distinction. |
| Batch partial failure | Each failed task in the batch has its own attempt count; successful tasks are not retried. |
| Ack failure after success | Task may be redelivered; the next handler invocation is a new attempt; ack failure is recorded separately. |
| Permanent handler failure | Task is dead-lettered without exhausting ordinary retries. |
| Dead-letter publish failure | Source is not acknowledged; failure is exposed. |
| Payload over 256 KiB | Enqueue is refused with a clear error. |
| Concurrency limit | Observed concurrent handlers do not exceed the declared bound, or the adapter reports a capability difference. |
| No ordering assumption | The contract makes no ordering promise; a handler that requires ordering is rejected by design review, not silently serialized. |
| Partial batch accounting | In a batch, a failed task is retried/DLQ'd independently; successfully processed tasks are not retried, and each task's handler-attempt count is reported correctly. |
| Pre-handler failure accounting | A delivered-but-never-handled task does not consume a handler attempt; the adapter reports it as a delivery failure, not as a handler attempt. |
| Durable attempt identity | The attempt number is stable across redelivery. The spike establishes whether provider-native counters suffice or Sol-managed durable state is required, including duplicate-invocation/concurrency implications. |

### 2.7 Provider mapping status

| Requirement | SQS | Pub/Sub | Cloud Tasks |
|---|---|---|---|
| Durable enqueue | Yes | Yes | Yes |
| At-least-once | Yes | Yes | Yes |
| Ack after handler success | Lambda success/batch response | HTTP 2xx | HTTP 2xx |
| Native dead-letter | Redrive/DLQ | Dead-letter topic | No native equivalent established |
| Retry budget | `maxReceiveCount` | Delivery-attempt limit | Retry config/max attempts |
| Concurrency bound | Reserved concurrency | Flow control / Cloud Run max instances | Queue rate/HTTP target |
| Fit for first contract | Candidate | Candidate | Not first mapping |

The first cross-provider proof should test **SQS + Lambda** and
**Pub/Sub push + Cloud Run**. Cloud Tasks remains a candidate for a separate
HTTP task-dispatch contract; it is not assumed equivalent. Pub/Sub is used with
one work subscription, not as a general event bus. These are hypotheses to be
validated by the acceptance tests, not accepted mappings.

**Hard spike gate:** per-task accounting under partial failures, distinguishing
pre-handler delivery failures from handler attempts, and stable attempt numbers
across redelivery must be demonstrated on both adapters. If a provider cannot
enforce these without unacceptable provider-specific behavior, the adapter must
refuse qualification rather than claim equivalence. Provider-native delivery
counters are not assumed sufficient; the spike determines whether Sol-managed
durable state is needed and what that means for duplicate invocations and
concurrency.

## 3. Runtime semantics: `-worker`, `-fn`, and queue handlers

The current meanings remain:

- `-worker` is the long-running Kafka consumer (`Worker.Make`, consumer groups,
  offset commits, `Ack`/`Fail`, SIGTERM/drain).
- `-fn` is run-once and scheduled (`sol.toml` schedule, CronJob).

A queue-triggered handler is a **distinct runtime contract**, even if it shares
business logic. The existing Kafka `Ack`/`Fail` vocabulary does not map directly
to queue acknowledgement and retries.

The product decision is deferred until the task-queue contract is accepted:
either

- an explicit trigger/runtime field on `-worker`/`-fn`, with the queue runtime
  implemented as a different adapter; or
- a new primitive for queue handlers.

Until then, `execution=serverless` must refuse a Kafka `-worker` and must not
silently reinterpret `-fn`. The convenience of a Lambda mapping must not decide
the application model.

## 4. First experimental slice

One HTTP `-svc`, managed PostgreSQL, one task queue, and one queue handler. No
Kafka in the first slice.

- AWS: API Gateway/Lambda HTTP + RDS + SQS + Lambda consumer.
- GCP: Cloud Run HTTP + Cloud SQL + Pub/Sub push + Cloud Run handler.

Acceptance:

- HTTP request and database transaction work;
- enqueue/process/ack works with duplicate-delivery idempotency;
- retry, exhaustion, dead-letter and ack-failure behavior pass the tests above;
- identity, secrets, logs, metrics and traces identify the workload;
- deploy, update, rollback, destroy, and independent absence work;
- unsupported combinations refuse before mutation;
- no production-profile claim until separately qualified.

## 5. Provider-order spike

Do not choose the first provider by intuition. Compare the same workload and
acceptance criteria:

- **Cloud Run:** reuse the existing `sol-svc` container/listener; learn how much
  of the HTTP runtime survives a managed HTTP service.
- **Lambda:** adapt the request path; learn what a true invocation adapter costs
  and whether the shared boundary holds.

Record time-to-first-working-slice, code/adapters changed, provider-specific
configuration, behavioral gaps, and what each taught the lifecycle seam. The
result decides the first adapter; neither provider is assumed.

## 6. Open decisions

1. Target `execution` field shape and exact refusal messages.
2. Whether the queue runtime is a trigger on an existing primitive or a new
   primitive.
3. Confirmation of the 5-handler-attempt/7-day/256-KiB defaults, the
   delivery-vs-handler-attempt mapping, and DLQ replay scope.
4. Whether release identity can remain provider-neutral without a plan refactor.
5. Serverless profile evidence and refusal criteria.
6. The provider-spike winner.
