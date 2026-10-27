# Proposal: minimal serverless execution boundary and task-queue contract

Status: **proposal — no implementation authorized.**

This proposal accompanies [ADR 0010](../adr/0010-execution-backends.md). It
defines the smallest questions to settle before code, using the current
Kubernetes implementation as evidence rather than inventing a universal
abstraction.

## 1. Minimum lifecycle boundary

The boundary describes outcomes Sol already promises; it does not prescribe
provider APIs.

| Operation | Required outcome | Current Kubernetes evidence |
|---|---|---|
| Plan | Resolve the target's execution, profile, workloads, resources, and unsupported combinations before mutation. | `Sol_cli_deployment_plan` and profile preflight |
| Apply/update | Create or update the workload and return its owned identities. | `Sol_cli_executor.apply_workload_phased` |
| Verify | Establish readiness/health for the primitive and report a failed operation with provider context. | `wait_for_workload_ready`, rollout diagnosis |
| Release/rollback | Bind an immutable release identity and restore the prior owned configuration. | release records, `sol rollback` |
| Own/cleanup | Remove only resources the release owns; preserve unknown or unowned resources. | owned-object records, prune |
| Absence | Independently establish absence of the target's owned classes. | provider inventory and `sol destroy` |
| Diagnose | Preserve the provider's error, not a generic replacement. | rollout/error capture |

The first adapter should expose these operations while delegating to the current
Kubernetes implementation. Do not move Kubernetes fields out of
`service_spec` until a second adapter shows which fields are actually shared.
The boundary may initially be an executor-level seam plus a provider-neutral
plan validation step; that is acceptable if no serverless provider detail leaks
into `sol.yml` or `sol.toml`.

## 2. Task-queue contract decision

The initial use case is a **durable work queue**, not a general event bus:

- enqueue one unit of work;
- deliver it to exactly one handler (subject to at-least-once redelivery);
- acknowledge only after the side effect succeeds;
- retry failures with bounded backoff;
- move exhausted work to a dead-letter destination;
- require handlers to be idempotent because redelivery is possible;
- do not promise global ordering;
- expose bounded concurrency and payload limits;
- report delivery/retry failure without claiming success.

This contract is deliberately narrower than Kafka. It does not replace
`resources.events: type: kafka`.

### Candidate comparison

| Requirement | AWS SQS | GCP Cloud Tasks | GCP Pub/Sub |
|---|---|---|---|
| Durable enqueue | Yes | Yes | Yes |
| At-least-once delivery | Yes | Yes | Yes |
| Visibility/lease | Visibility timeout | Retry/lease semantics | Ack deadline |
| Native dead-letter | Redrive policy/DLQ | No native equivalent established; requires handler/adapter work | Dead-letter topic |
| Delivery model | Poll (Lambda event source or worker) | HTTP push | Pull or push subscription |
| Ordering | Standard queue does not guarantee global ordering | Queue/HTTP delivery, not a general event bus | No global ordering by default |
| Fit for first contract | Strong | Possible, but DLQ/ack parity needs proof | Strong with one subscription used as a work queue |

**Recommendation:** define `task_queue` as the durable work queue above, and use
**SQS + Pub/Sub** for the first cross-provider proof. Cloud Tasks remains a
candidate for an HTTP task-dispatch contract, but is not the first mapping
because it is not a native dead-letter queue and its delivery contract differs.

This is a proposal, not an accepted resource type. `task_queue` must not be added
to `sol.yml` until the contract is accepted and both adapters are qualified.

### Handler/runtime implication

A queue handler is not the current Kafka `Worker.Make` contract. The existing
`Ack`/`Fail` business outcome may be reusable, but the runtime must own
queue-specific acknowledgement, retry, visibility, and duplicate behavior.
Whether this is an explicit `trigger` on `-worker`/`-fn` or a separate runtime
contract is a product decision to resolve with the task-queue contract; do not
silently treat Kafka and queue delivery as the same lifecycle.

## 3. First experimental slice

Use one HTTP `-svc`, managed PostgreSQL, one task queue, and one queue handler.
Do not include Kafka in the first slice.

- AWS: API Gateway/Lambda HTTP + RDS + SQS + Lambda consumer.
- GCP: Cloud Run HTTP + Cloud SQL + Pub/Sub push + Cloud Run handler.

The application source and declared intent should be the same on both providers.
Acceptance criteria:

- HTTP request and database transaction work;
- enqueue and handler delivery work;
- duplicate delivery is idempotent;
- retry and dead-letter behavior match the contract;
- identity, secrets, logs, metrics, and traces identify the workload;
- deploy, update, rollback, destroy, and independent absence work;
- unsupported combinations refuse before mutation;
- no production-profile claim until separately qualified.

Provider order is decided by a short adapter spike: compare the cost of adapting
the existing `sol-svc` listener for Lambda against running its container on
Cloud Run, including the lessons each provides for the shared boundary. Do not
choose a provider only because it is first.

## 4. Open decisions before code

1. Target execution field shape and validation messages.
2. Whether `-worker`/`-fn` gain an explicit trigger, or a new primitive is
   warranted for queue handlers.
3. Task-queue payload, max attempts, backoff, DLQ, and idempotency details.
4. The minimum lifecycle seam and whether release identity can remain
   provider-neutral without a broad plan refactor.
5. Serverless profile evidence and refusal criteria.
6. Provider spike outcome and first adapter.
