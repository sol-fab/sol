# Proposal: minimal serverless execution boundary and task-queue contract

Status: **partially implemented — the shared durable-task contract, local runtime, and AWS/GCP runtimes and provider lifecycles exist. Target-scoped integration and full live qualification remain open.**

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

The implemented runtime distinguishes exactly two outcomes:

- **Ack** — the side effect committed; acknowledge.
- **Retry** — transient failure; leave the task eligible for redelivery.

An uncaught failure or exception is **Retry**. There is deliberately **no
application-selected immediate dead-letter outcome** in this contract. A
handler that wants to stop retrying uses its own durable state; terminal
delivery belongs to the provider after the configured budget. This narrowing
avoids an application API whose meaning would differ between `sol-jobs`,
SQS, and Pub/Sub.

### 2.4 Retry, exhaustion and dead-lettering

#### What counts as an attempt

The original hypothesis required Sol-owned handler-attempt counters, a stable
attempt number in the handler metadata, and an application-selected dead-letter
outcome. Implementation and provider behavior forced a deliberate narrowing:

- The handler receives stable `task_id`, `kind`, `payload`, and optional
  `idempotency_key`; it does **not** receive a delivery-attempt or
  handler-attempt number.
- Provider delivery counters (`ApproximateReceiveCount`,
  `maxReceiveCount`, `maxDeliveryAttempts`,
  `CloudPubSubDeadLetterSourceDeliveryCount`) are not handler-attempt counters
  and are not exposed as one.
- Sol does not maintain a second durable delivery-attempt record. Doing so
  would duplicate the provider's delivery state and still not make the external
  side effect exactly-once.
- At-least-once delivery plus application idempotency remains the contract.

This is not a claim that attempt accounting is unimportant; it is a statement
that the portable contract cannot promise it without provider-specific
behavior that the first implementation does not own.

#### Exhaustion and dead-lettering

- Retry uses provider-native backoff; the contract does not promise identical
  timing across providers.
- When the provider's configured delivery budget is exhausted, the **provider**
  moves the task to its dead-letter destination:
  - local `sol-jobs` → a retained terminal `status = 'failed'` row;
  - SQS → the queue's dead-letter queue (`maxReceiveCount`);
  - Pub/Sub → the subscription's dead-letter topic (`maxDeliveryAttempts`).
- The lifecycle must establish any provider permission the dead-letter path
  needs. In particular, Pub/Sub requires the Pub/Sub service agent to have
  `roles/pubsub.publisher` on the dead-letter topic; the GCP adapter grants and
  verifies it. Without that grant the subscription cannot move an exhausted
  task and keeps redelivering.
- Dead-letter retention is provider-owned and recorded in the release record;
  the first implementation defaults to 7 days where the provider permits it.
- Reprocessing dead-lettered tasks is out of scope for the first contract.
  Operators inspect them through the provider.
- Exhaustion and dead-letter publishing are observable through the provider,
  but the exact number of handler invocations is **not** promised. A bounded
  live GCP exercise with `maxDeliveryAttempts=5` observed a dead-letter
  source delivery count of 12 under rapid `Retry` responses; the task reached
  the DLQ, but the provider count did not equal the number of handler entries.

### 2.5 Concurrency and timeouts

- The target declares a bounded maximum concurrency. The adapter must enforce
  it or report the provider limitation; it must not silently run unbounded.
- The handler must finish within the provider/queue delivery window. A timeout
  is a Retry, not success; the application must be idempotent for the retry.
- Visibility/lease and ack-deadline extensions are adapter responsibilities,
  not application APIs.

### 2.6 Evidence and acceptance tests

The original table tested a contract with Sol-owned handler-attempt counters and
an application-selected dead-letter outcome. The implemented contract is
narrower: `Ack | Retry`, provider-managed terminal delivery, no handler-attempt
number. The tests below state what evidence exists, not what would be desirable.

| Test | Evidence today |
|---|---|
| Enqueue and process a task | Local Postgres integration test (enqueue → handler → completed); bounded live GCP exercise (Ack logged and acknowledged); AWS fake-provider lifecycle only. |
| Duplicate delivery | Local idempotent enqueue/dedupe tested. Provider redelivery with a repeated `task_id` is exercised by the live GCP Retry probe; no duplicate external side effect is asserted because the probe handler has no external effect. |
| Crash after side effect, before ack | Not tested. Application idempotency remains the requirement. |
| Crash before side effect | Not tested separately; provider redelivery is observed in the GCP Retry probe. |
| Transient failure | Local `Retry` → terminal `failed` with `max_attempts=1`; GCP live `Retry` → repeated delivery → dead-letter. AWS mapping is unit/fake tested, not live. |
| Exhaustion | Local terminal `failed` row; GCP live message in the dead-letter topic; AWS redrive settings are fake tested only. The GCP live source delivery count was 12 with `maxDeliveryAttempts=5`, so the contract does not claim an exact handler-attempt count. |
| Handler timeout/cancellation | Local `sol-jobs` lease/retry behavior is covered by the existing queue package; cloud timeout/cancellation is not separately exercised. |
| Pre-handler delivery failure | Not exposed separately in the first contract. Provider counters are not presented as handler attempts. |
| Batch partial failure | AWS Lambda unit test: successful records are omitted from `batchItemFailures` and failed/malformed records are returned; not live. |
| Ack failure after success | Provider-owned; not separately tested. |
| Permanent handler failure | No application-selected immediate dead-letter outcome. Provider budget is the only terminal mechanism. |
| Dead-letter publish failure | GCP live exercise observed the failure mode: without `roles/pubsub.publisher` on the dead-letter topic, Pub/Sub kept redelivering. The adapter now grants and verifies the binding. AWS DLQ permissions are operator-supplied and not live tested. |
| Payload over 256 KiB | Envelope unit tests refuse it. |
| Concurrency limit | Settings are set in both lifecycles (SQS `MaximumConcurrency`, Cloud Run max instances + container concurrency 1); concurrent-handler measurement is not yet evidence. |
| No ordering assumption | The contract makes no ordering promise. |
| Partial batch accounting | AWS unit test covers independent item failures; no per-task handler-attempt count exists. |
| Attempt accounting | Deliberately not exposed. The GCP live provider counter (12) versus configured budget (5) is recorded as the reason provider counters are not handler attempts. |

Evidence classes in this table:

- **automated local/fake-provider:** reproducible in CI or the fake-provider
  lifecycle tests;
- **bounded live checkout-build exercise:** the GCP run recorded below, not a
  release qualification;
- **not tested:** no behavioral claim.

The live GCP exercise was run from a checkout build, not a released candidate.
It is evidence that the provider path can work; it is not a qualification row
under [`internal/qualification/README.md`](../../../internal/qualification/README.md).

### 2.7 Provider mapping status

| Requirement | SQS + Lambda | Pub/Sub push + Cloud Run | Cloud Tasks |
|---|---|---|---|
| Durable enqueue | Yes | Yes | Yes |
| At-least-once | Yes | Yes | Yes |
| Ack after handler success | Lambda success; batch-item-failure response | HTTP 200 | HTTP 2xx |
| Native dead-letter | Redrive/DLQ | Dead-letter topic | No native equivalent established |
| Retry budget | `maxReceiveCount` | `maxDeliveryAttempts` (5–100) | Retry config/max attempts |
| Concurrency bound | Event source mapping `MaximumConcurrency` | Cloud Run max instances; container concurrency 1 | Queue rate/HTTP target |
| Push/trigger auth | Lambda execution role; no inbound endpoint | Cloud Run IAM + OIDC push service account | Depends on target |
| Runtime | `sol-task.lambda`, `ReportBatchItemFailures` | `sol-task.pubsub`, 200/500/400 | Not implemented |
| Lifecycle | `sol task aws` (fake-provider evidence) | `sol task gcp` (fake + bounded live exercise) | Not used |

Cloud Tasks remains a candidate for a separate HTTP task-dispatch contract; it
is not assumed equivalent and is not part of the first provider mapping.
Pub/Sub is used with one work subscription, not as a general event bus.

**Resolved spike gate:** the original gate demanded per-task accounting under
partial failures, a pre-handler/handler-attempt distinction, and stable attempt
numbers. The spike resolved it by **narrowing the contract**, not by claiming
equivalence: the handler receives a stable task identity and no attempt number;
terminal delivery is provider-owned; provider counters are not exposed. The
remaining gate is live qualification of both providers against a released
candidate and the target-scoped lifecycle integration.

## 3. Runtime semantics: `-worker`, `-fn`, and durable tasks

The existing meanings remain unchanged:

- `-worker` is the long-running Kafka consumer (`Worker.Make`, consumer groups,
  offset commits, `Ack`/`Fail`, SIGTERM/drain).
- `-fn` is run-once and scheduled (`sol.toml` schedule, CronJob).

A durable task handler is a **library**, `sol-task`, not a fourth primitive.
Locally and on Kubernetes it is hosted by a `-worker` binary over the existing
`sol-jobs` queue; in the cloud the same `TASK` module is hosted by the Lambda
SQS runtime or the Cloud Run Pub/Sub runtime. The Kafka `Ack`/`Fail` vocabulary
is not remapped: task `Ack`/`Retry` is a distinct contract with a distinct
queue.

The standalone `sol task` lifecycle does not yet participate in the target
`execution` field. A serverless target must continue to refuse a Kafka
`-worker` and must not silently reinterpret `-fn`. The convenience of a Lambda
mapping does not decide the application model.

## 4. First experimental slice

One HTTP `-svc`, managed PostgreSQL, one task queue, and one task handler. No
Kafka in the first slice.

Implementation status:

- **Local:** `sol-task.local` + `sol-jobs`; Postgres integration test covers
  enqueue, Ack, Retry-to-terminal, and idempotent enqueue.
- **GCP:** `sol-task.pubsub` + `sol task gcp`; fake-provider lifecycle tests and
  a bounded live checkout-build exercise (Ack, Retry-to-DLQ, rollback to a prior
  Cloud Run revision, destroy, independent absence).
- **AWS:** `sol-task.lambda` + `sol task aws`; envelope/batch unit tests and a
  fake-provider lifecycle test. Live AWS is blocked by an expired SSO session;
  it is not claimed.
- **Target-scoped integration:** not implemented. The provider commands are
  standalone experimental entry points.
- **Release qualification:** not performed for either provider. The live GCP
  exercise is not a released-candidate qualification.

## 5. Provider-order decision

The bounded HTTP spike established Cloud Run first and Lambda second for the
HTTP experimental slice:

- **Cloud Run first.** The existing `sol-svc` checkout container ran after the
  target identity inputs were supplied; `/readyz` returned 200 and
  revision/traffic rollback worked.
- **Lambda second.** Lambda required a separate HTTP handler; the existing
  listener was not reusable. Function URL policy and path handling were
  provider-specific.

That order is an HTTP-slice decision. The task capability now has both runtime
adapters; the live task exercise happened on GCP first because credentials were
available, not because GCP is the permanent primary. Neither ordering qualifies
queue support for production.

## 6. Identity contract (HTTP prerequisite; task push identity separate)

The HTTP spike proved the existing container starts only when the target
supplies `SOL_UNIT`, `SOL_TRUSTED_WORKLOAD_ISSUER`, and `SOL_CALLED_BY`.
`/quote` remained 401 without a token, so a healthy `/readyz` is not sufficient
evidence of an integrated workload.

For durable tasks, the incoming identity boundary is different and is
implemented:

- GCP: the Cloud Run service is private; the Pub/Sub push subscription uses a
  dedicated service account with `roles/run.invoker`; the Pub/Sub service agent
  can mint its OIDC token; the dead-letter topic grants the agent publisher.
- AWS: there is no inbound HTTP endpoint; the Lambda execution role authorizes
  SQS receive/delete and logs. The event source mapping invokes the function.
- Local: the worker's Postgres credentials and the `sol_jobs` workspace boundary.

The HTTP identity contract remains open and is not replaced by the task push
identity.

## 7. Lifecycle identity convention

A release records the provider-native identity, not a Kubernetes-shaped object:

- Cloud Run: service, revision, traffic allocation, URL;
- Lambda: function, version/alias, URL;
- Task AWS: queue URL/ARN, dead-letter queue, function/version/alias, event
  source mapping UUID;
- Task GCP: Cloud Run service/URL/revision, topic, subscription, dead-letter
  topic, push service account.

Verification and rollback require observed post-operation state. An API `200`
without observing which revision/version is serving is not success.

## 8. Remaining decisions

1. Target `execution` integration for tasks: standalone `sol task` versus a
   target-scoped trigger/runtime declaration.
2. Live AWS qualification (currently blocked by expired SSO) and released-
   candidate qualification for GCP.
3. Whether the release store should own the task record and provider identity,
   rather than the standalone ownership file.
4. Dead-letter replay: provider inspection only in the first contract.
5. The exact provider budget defaults. The shared envelope cap is 256 KiB and
   retention defaults to 7 days where the provider permits; local and SQS
   budgets are configurable, while Pub/Sub requires 5–100. The contract does
   not promise a common handler-attempt count.
6. Whether `sol new worker` should scaffold a task handler module and migration,
   or whether the package guide remains the integration path.
