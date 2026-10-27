# ADR 0010: Execution backends are target-scoped adapters

- **Status:** Accepted (architecture direction); provider mappings and
  numerical queue defaults remain provisional
- **Date:** 2026-10-27
- **Decision owner:** operator
- **Related:** ADR 0009 (one product contract), ADR 0011 (provider-native workload identity), DEC-022 (language parity),
  DEC-026 (production profile), DEC-047 (configuration placement),
  `docs/deployment/compatibility.md`

## Context

Sol's application declarations are largely portable: `sol.yml` names services and
resources, and `-svc`, `-worker`, and `-fn` are the developer-facing primitives.
The deployment machinery is not portable. The deployment plan carries Kubernetes
names, namespaces, replicas, ingress, rollout strategy, and CronJob fields; the
executor applies Kubernetes objects; release records use Kubernetes resource
identity; rollback and cleanup reconstruct Kubernetes objects.

ADR 0009 currently says `-fn` is a Kubernetes CronJob, `Fn.Lambda` is
framework-only, and Lambda/Cloud Functions deployment is a non-goal. A serverless
execution option is therefore a product-direction change that needs an explicit
replacement decision, not an inferred extension of `-fn`.

The storage qualification campaign is a separate investigation: it measures the
resource envelope of the current Kubernetes backend. Its results inform this
decision but do not determine it, and this ADR creates no storage or cloud work.

## Decision

The architectural principles are accepted. Provider mappings, the task-queue
defaults, the lifecycle seam's eventual shape, and production qualification are
**not** accepted by this ADR; each remains a spike/qualification decision.

### 1. One target-scoped execution choice

A target may declare:

```yaml
targets:
  aws/us-east-1:
    execution: kubernetes   # default
  gcp/us-central1:
    execution: serverless
```

`execution` is target-scoped rather than environment-scoped. The target already
owns the provider, region, profile, shape, cluster, registry, and identity, and
one environment may carry multiple targets. An environment-wide default may be
synthesized later, but the stored authority is the target.

The initial scope is one execution choice per target. Mixed execution within an
environment or per-service execution overrides is deferred until a second
adapter demonstrates the need.

### 2. Application primitives do not change

`-svc`, `-worker`, and `-fn` remain the application concepts. Their current
Kubernetes meanings are not silently redefined:

- `-svc` is an HTTP service.
- `-worker` is a long-running background process; today it is a Kafka consumer
  group.
- `-fn` is a run-to-completion task, scheduled today.

A serverless mapping must either preserve the runtime contract or declare a
different trigger/runtime contract explicitly. In particular, a Kafka consumer
group is not interchangeable with an SQS, Cloud Tasks, or Pub/Sub event handler.
If an explicit trigger distinction is needed, it belongs in the workload
contract (`sol.toml`) and must be versioned; it must not be inferred from the
cloud service name.

### 3. Profiles remain guarantee claims

`profile` continues to describe the operational guarantees Sol claims, not the
compute technology. A serverless target may select
`production-single-region/v1` only when the existing profile preflight can
establish its required capabilities. Until then, the target's profile evidence
is incomplete and the preflight must fail closed.

There is no `serverless-production` profile that sounds equivalent without
meeting the same guarantees. Genuine differences must be recorded as explicit
capabilities, not hidden in a new profile name.

### 4. Fail closed on unsupported combinations

The target resolver, before any build or mutation, must refuse:

- an unknown `execution` value;
- `serverless` with an unsupported primitive, trigger, resource, or profile
  capability;
- `serverless` with Kafka unless a long-running worker mapping is explicitly
  qualified;
- a missing adapter, with a named reason rather than a Kubernetes fallback.

An adapter implements the contract; it does not silently weaken it.

### 5. Keep Kubernetes and Kafka explicit

`resources.events: type: kafka` remains explicit Kafka semantics. A generic
`queue` resource is not introduced. A future `task_queue` resource is a **durable
work queue**: at-least-once delivery, stable task identity, application
idempotency, bounded retries, dead-lettering, no global ordering, and no claim of
exactly-once external side effects. Its retry budget counts **handler attempts**,
not provider deliveries, with pre-handler delivery failures reported separately.
Its detailed contract and provider acceptance tests are in the proposal.

Kafka and a task queue are separate contracts. Pub/Sub, SQS, Cloud Tasks, and
Kafka must not be presented as interchangeable. SQS + Lambda and Pub/Sub +
Cloud Run are candidates to test, not accepted mappings; Cloud Tasks is not the
first mapping without native dead-letter/ack parity.

### 6. Define the lifecycle boundary before extracting it

The current Kubernetes implementation is the reference evidence for the
minimum lifecycle operations:

- deploy and update;
- readiness and deployment verification;
- release identity and rollback;
- ownership and cleanup;
- independent absence verification;
- failure reporting that preserves provider context.

The first implementation step is a design of this boundary and a thin
Kubernetes adapter around existing behavior. The seam must carry ownership,
evidence, failure semantics and provider-native diagnostics for each operation.
A broad refactor of the deployment plan is not authorized until a second adapter
demonstrates which parts are genuinely shared. The candidate boundary and its
current-code mapping are in `docs/architecture/proposals/serverless-execution.md`.

### 7. Experimental serverless first

The first serverless target and vertical slice are experimental. They do not
establish `production-single-region/v1` conformance. Production guarantees are
qualified separately, with the same evidence discipline as the current
Kubernetes campaign.

The bounded HTTP spike established the first provider order:

- **Cloud Run is the first experimental adapter.** It ran the existing `sol-svc`
  container with `/readyz` 200 and supported revision/traffic rollback.
- **Lambda is the second adapter.** It required a separate HTTP handler and
  exposed a genuine request-adapter boundary. It will validate whether the
  lifecycle seam generalizes; it is not the first implementation.

This order is limited to HTTP. It is not evidence for queues, workers, or
production qualification.

### 8. Identity is part of the runtime contract

The Cloud Run spike showed that a running container is not a healthy workload:
`SOL_UNIT` and the trusted workload issuer are required at startup, and a
protected route still rejects an unauthenticated request.

The Sol-level identity contract is:

- the workload's unit/audience;
- the callers allowed to invoke it;
- the trusted issuer for projected workload tokens;
- the provider-native mechanism that supplies the token and issuer.

These are Sol contract inputs, not a universal provider API. The current runtime
happens to read `SOL_UNIT`, `SOL_CALLED_BY`, and
`SOL_TRUSTED_WORKLOAD_ISSUER`; the adapter owns projecting them. A future adapter
may use a different native mechanism. Missing or invalid identity configuration
must fail before deployment or readiness, never produce a misleadingly healthy
deployment. Local development needs an explicit local identity/trust contract,
not the production issuer.

The identity implementation and protected-route proof are a prerequisite for the
Cloud Run slice; `/readyz` alone is not sufficient.

### 9. Lifecycle identity is provider-native

The lifecycle contract may be shared, but the identity of what was deployed is
provider-native. Cloud Run revisions and traffic assignments differ from Lambda
versions and aliases. The release record must retain the provider-native
revision/version/alias identity and the observed serving state.

Rollback and verification are accepted only when the post-operation provider
state is observed, not merely when an API call returns success.

## Consequences

- Adding `execution` is a configuration and validation change, not a claim that
  serverless is implemented.
- The existing Kubernetes executor and release model stay authoritative until a
  second adapter is proven.
- `Fn.Lambda` remains experimental and does not become the meaning of `-fn`.
- The task-queue contract and provider mapping are a separate decision; this ADR
  only records that Kafka stays Kafka and no generic queue is created here.
- The storage campaign proceeds independently; its measurements inform the
  comparison between reducing Kubernetes storage and avoiding Kubernetes nodes.

## Non-goals

- Serverless execution in this ADR.
- Serverless production qualification or promotion.
- A universal messaging abstraction.
- Mixed per-service execution.
- A new primitive or trigger mode before the task-queue decision.
- Refactoring the deployment plan ahead of a second adapter.
