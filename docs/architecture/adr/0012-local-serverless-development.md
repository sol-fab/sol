# ADR 0012: Local development for serverless execution

- **Status:** Proposed
- **Date:** 2026-10-28
- **Decision owner:** operator
- **Related:** ADR 0009 (one product contract), ADR 0010 (execution backends),
  ADR 0011 (provider-native workload identity),
  `docs/architecture/proposals/serverless-execution.md`

## Context

Sol's current local workflows are not a cloud emulator:

- `sol local deploy` creates a local k3d cluster and the local Postgres,
  Redpanda/Kafka, Loki, Tempo and related platform components. It deploys the
  normal Kubernetes workload shapes, including a CronJob for `-fn`.
- `sol local run` discovers declared units and runs them as native processes.
  It builds OCaml with one workspace-wide `dune build`, builds TypeScript with
  `npm run build`, launches the resulting entry directly, injects declared
  local secrets and resource endpoints, and supervises every process until all
  long-running processes exit or one fails. It does not build or use a provider
  container image.
- PostgreSQL and Kafka are injected only for units that declare those resources.
  `sol-jobs` is a Postgres-backed leased job library hosted by a `-worker`; it is
  not a fourth primitive and is not interchangeable with Kafka.
- The Cloud Run adapter executes an HTTP `-svc`; it does not yet execute
  `-worker`, `-fn`, queues, or a serverless trigger model.

The `-fn` contract is run-once and scheduled today (ADR 0009, ADR 0010). The
local runner currently launches a `-fn` like any other process, but it has no
invocation input, no one-shot result observation, and no distinction between a
scheduled function and a future event trigger. A process that exits once is not
an invocation contract.

This ADR decides what local development promises when production execution is
serverless. It does not add serverless deployment support.

## Evidence from the current implementation

- Local unit selection/build/launch and supervision:
  [`cli/lib/local/sol_cli_local_run.ml`](../../../cli/lib/local/sol_cli_local_run.ml),
  [`cli/bin/cmd_local.ml`](../../../cli/bin/cmd_local.ml).
- Local k3d platform components and endpoint injection:
  [`cli/lib/local/sol_cli_local_platform.ml`](../../../cli/lib/local/sol_cli_local_platform.ml),
  [`cli/bin/cmd_local_deploy.ml`](../../../cli/bin/cmd_local_deploy.ml).
- Current local workflow documentation:
  [`docs/guides/tutorial.md`](../../guides/tutorial.md) § *Local iteration with `sol local run`*.
- Postgres-backed leased jobs:
  [`framework/ocaml/sol-jobs/sol-jobs.md`](../../../framework/ocaml/sol-jobs/sol-jobs.md).
- Cloud Run adapter scope and execution-backend direction:
  [`cli/lib/cloud/sol_cli_cloud_run.ml`](../../../cli/lib/cloud/sol_cli_cloud_run.ml),
  ADR 0010, and
  [`docs/architecture/proposals/serverless-execution.md`](../proposals/serverless-execution.md).
- `-fn` run-once/scheduled semantics: ADR 0009 §4 and ADR 0010 §3.

The local runner has no function-invocation interface today; the
`sol local invoke` interface in this ADR is proposed, not implemented.

## Decision

### 1. Local development remains first-class and provider-neutral

The application artifact and application contract are the same locally and in
production. Local development must not require a cloud deployment or provider
credentials.

Cloud Run changes where the same HTTP application runs; it does not change how
the developer builds, launches, or tests that application's logic. A developer
may optionally run the production HTTP container locally, but that is not a
replacement for the native local loop and is not required.

The local runtime does not reproduce the cloud control plane.

### 2. Three development tiers

| Tier | Execution | Establishes | Does not establish |
|---|---|---|---|
| **Native local** | `sol local run`, native binaries / Node | Application logic, HTTP behavior, function invocation, local dependency integration | Cloud identity, IAM, provider triggers, managed networking, production delivery |
| **Local Kubernetes** | `sol local deploy` on k3d | Kubernetes workload shapes, CronJob/worker integration, local Postgres/Kafka/Loki wiring | Cloud provider configuration, real IAM, cloud-managed delivery |
| **Real-cloud integration** | A disposable target using the selected execution backend | Provider identity, permissions, networking, invocation, retry and delivery semantics | Production-profile qualification unless separately established |

A local pass is never evidence for a stronger tier. A cloud deployment is not a
substitute for the fast local loop and is never provisioned automatically as a
fallback.

### 3. Primitive semantics are preserved

- **`-svc`** remains an HTTP service. Local native execution and a Cloud Run
  container run the same application contract.
- **`-worker`** remains a long-running background process. Kafka-workers use
  explicit Kafka semantics; a Postgres-backed `sol-jobs` worker uses explicit
  Postgres/leased-job semantics. A worker is not silently converted into a
  queue-triggered serverless function.
- **`-fn`** remains run-once. Scheduling is a deployment concern, not the
  meaning of the primitive. A future event/queue trigger is a distinct,
  explicit contract; it must not be inferred from a provider's service name or
  from `execution=serverless`.

No provider-specific trigger is added to the application model by this ADR.

### 4. Proposed local function invocation

Add a one-shot invocation interface, without assuming a Lambda-style handler or
event schema:

```text
sol local invoke <domain/name> [--event <file>]
```

Contract:

- The unit is resolved from the same declared workspace inventory as
  `sol local run`; it must be a `-fn`.
- Sol builds the unit using the same local build recipe as `sol local run` and
  executes it exactly once, not under the long-running supervision used for
  services and workers.
- `--event <file>` supplies the file's raw bytes on standard input. Omitting it
  supplies empty input. Sol does not interpret or validate a JSON schema;
  reading and decoding an event is application-owned until a separate event
  contract exists.
- The process exit status is the invocation result: `0` success, non-zero
  failure, and the existing interrupted status behavior. Standard output and
  standard error are passed through with the unit label; Sol does not invent a
  structured result envelope.
- The command does not execute the unit's schedule, simulate CronJob retries, or
  invoke more than once. Those are deployment/qualification concerns.
- Local secrets and resource endpoints follow the same declared-dependency rules
  as `sol local run`.
- If the existing `-fn` implementation cannot accept event input, the first
  implementation may run it with empty input and return a clear unsupported
  result for `--event`; it must not silently drop supplied bytes.

`sol local run` should not claim that its current treatment of `-fn` is
invocation. The first implementation must make `-fn` explicit in local
selection: either exclude it from long-running supervision or invoke it through
the contract above. This is a local-runtime correction, not a change to
production `-fn` semantics.

### 5. Messaging stays explicit

- Kafka and Postgres `sol-jobs` remain separate, explicit contracts.
- No portable queue abstraction is introduced. SQS, Pub/Sub, Cloud Tasks and
  Kafka have different delivery, acknowledgement, retry and subscription
  semantics; they must not be presented as interchangeable.
- Local application/distribution tests may use the existing local Kafka broker
  or local Postgres jobs, because those are the declared mechanisms.
- A provider-specific emulator (for example LocalStack or the Pub/Sub emulator)
  is an **opt-in integration mechanism**, not a default dependency and not a
  substitute for cloud evidence. Emulator limitations must be stated.
- Real retry, dead-letter, IAM, trigger and delivery semantics require a real
  cloud integration test. A local in-memory queue is not a substitute.

### 6. Cloud boundaries

A local success does not establish:

- workload identity or caller authorization;
- IAM/permission correctness;
- provider trigger delivery, retries, duplicate execution or dead-lettering;
- managed networking, service discovery or ingress;
- autoscaling, concurrency or instance lifecycle;
- production-profile qualification.

Sol must not silently create cloud resources, require cloud credentials for the
normal local loop, or fall back to cloud execution. A real-cloud integration
step is explicit and separately authorized.

## Alternatives rejected

- **A general cloud emulator.** It would become a second implementation of
  provider behavior without establishing the real provider's configuration,
  identity or delivery guarantees.
- **Provider-local tooling as the Sol development contract.** SAM, the Pub/Sub
  emulator and similar tools may be useful integration aids, but requiring them
  for every local iteration couples development to a provider and does not
  cover application logic consistently.
- **A portable queue abstraction now.** No second demonstrated requirement
  establishes shared semantics, and a lowest-common-denominator queue would
  hide Kafka ordering, Postgres job leasing, and provider subscription
  differences.
- **Automatic cloud fallback.** It makes the development loop dependent on
  credentials, cost and network availability.
- **Reinterpreting `-fn` as a serverless handler.** It contradicts ADR 0009 and
  would make a scheduled run-once task indistinguishable from a provider event
  handler.

## Consequences

- The local runner remains source-native for fast iteration; production
  containers are optional local checks, not the default loop.
- A local invocation command and its tests must be added before more
  serverless-specific behavior is built. This ADR does not implement it.
- Local docs must state the three tiers and the non-guarantees; cloud
  integration docs must state which real-provider properties are tested.
- Provider-specific queue work remains gated on an explicit contract and
  acceptance tests, not on a generic abstraction.
- `sol local deploy` remains the Kubernetes integration tier, not a local
  Cloud Run emulator.
- No deployment-plan or execution-backend refactor is justified by this ADR.

## Acceptance criteria

| Criterion | Evidence |
|---|---|
| Local HTTP | The existing demo HTTP service runs via `sol local run` and handles the same application request without cloud credentials |
| Local `-fn` | One-shot invocation accepts optional raw event bytes, runs once, propagates exit status and output, and refuses/consistently handles unsupported event input |
| Worker | A Kafka worker runs against local Kafka; a Postgres jobs worker runs against local Postgres with real claim/lease semantics |
| Messaging boundary | No in-memory queue silently replaces Kafka or Postgres; provider emulator use is explicit and documented as non-production evidence |
| Cloud boundary | Local success is never reported as IAM, identity, networking or delivery evidence; no automatic cloud provisioning |
| Tier documentation | The local, local-Kubernetes and cloud-integration guarantees and limits are documented together |

## First implementation step

The smallest validation is:

1. run the existing TypeScript HTTP service with `sol local run` and issue the
   same application request used by the Cloud Run experiment;
2. invoke one `-fn` once with an empty input and one fixture file, asserting
   exit status and output;
3. run a Postgres jobs worker against local Postgres and a Kafka worker against
   local Kafka;
4. verify that a local pass does not claim Cloud Run identity or delivery
   evidence.

The first code change should be the local `-fn` invocation contract and the
local runner's explicit handling of `-fn`; no execution-backend refactor is
authorized by this ADR.
