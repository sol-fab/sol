# ADR 0011: serverless and provider tasks in the v0.1 production contract

- **Status:** Accepted
- **Date:** 2026-10-29
- **Source:** operator decision (v0.1 scope review)
- **Related:** ADR 0009 (one product contract), ADR 0010 (execution backends),
  DEC-026 (`production-single-region/v1`), DEC-022 (language parity),
  `docs/deployment/compatibility.md`, `docs/deployment/serverless.md`

## Context

ADR 0009 redefined `production-single-region/v1` as the cloud- and
language-neutral contract, but left target `execution: serverless` and the
standalone provider task lifecycles outside the production claim. The serverless
implementation has since gained live AWS and GCP evidence for `-svc`, `-fn`, and
durable task consumers, while the Kubernetes production profile still carries
open evidence gates.

The operator decision for v0.1 is that Sol must not defer a capability merely
because it is currently labelled experimental. The v0.1 production contract
therefore includes the serverless execution mode and the standalone AWS/GCP task
lifecycles, subject to the same evidence, security, and lifecycle gates as the
Kubernetes profile.

## Decision

### 1. Production scope

The v0.1 production contract covers:

- local development;
- AWS and GCP Kubernetes targets;
- AWS and GCP target `execution: serverless` targets for `-svc` and `-fn`;
- durable tasks through `sol-task.local` on a `-worker`, and through the
  standalone `sol task aws`/`sol task gcp` lifecycles.

`-worker` remains the Kafka/Postgres primitive. There is no serverless
`-worker` mapping: SQS/Pub/Sub are task delivery mechanisms, not Kafka
substitutes. Target-scoped `sol deploy` still creates no task queues or
triggers; task resources remain owned by the standalone task lifecycle.

### 2. Execution-mode matrix

| Execution mode | `-svc` | `-worker` | `-fn` | Durable tasks |
|---|---|---|---|---|
| Local | yes | yes | yes | local `sol-task` via `-worker` |
| Kubernetes (AWS/GCP) | yes | yes | yes | local `sol-task` via `-worker` |
| AWS serverless | yes | no (Kafka semantics) | yes | standalone SQS/Lambda |
| GCP serverless | yes | no (Kafka semantics) | yes | standalone Pub/Sub/Cloud Run |

### 3. Production requirements

Serverless and provider task lifecycles are not accepted merely because they
have a working demo. Each production-qualified execution mode must establish:

- immutable image identity and a declared, scoped execution identity;
- provider ownership labels/records, foreign-resource refusal, and independently
  verified absence after destroy;
- deploy, execution/invocation, rollback, and partial-failure recovery;
- the declared observability acceptance boundary, including whether Sol accepts
  provider-native logs/metrics or requires Grafana;
- the declared security boundary: incoming authentication, execution-role
  permissions, resource ownership, and secret handling;
- OCaml/TypeScript behavioral parity for every declared workload;
- live evidence through the release candidate, not a checkout demo.

The absence of serverless triggers, schedules, and dependency injection is an
explicit v0.1 limitation, not an implied capability. It does not prevent the
run-once/HTTP/task contract from being production-qualified.

### 4. Evidence gates

The production preflight, README product matrix, provider qualification
matrices, and release promotion must all consume one consistent set of evidence
classes. A serverless or task cell that is only mechanism-tested is not
production-qualified. A live demo is evidence, but it does not flip a production
gate until the release policy can verify the record and the candidate.

### 5. Relationship to ADR 0009

This ADR supersedes only ADR 0009's exclusion of serverless execution and the
provider task lifecycles from the production claim. The rest of ADR 0009,
including one workspace/contract across clouds and languages, provider-native
observability, and the one-product-contract identity, remains in force.

## Consequences

- The support and qualification matrices must gain execution-mode and task rows
  rather than treating serverless as a separate experimental appendix.
- The serverless documentation is production-scope documentation; its evidence
  table still records exactly what is live, mechanism-only, or unsupported.
- The production preflight and release promotion must be extended to admit and
  verify serverless and task evidence.
- The open production-readiness gaps remain blockers: they are not waived by
  this scope decision.
