# ADR 0009: one product contract across clouds and languages

- **Status:** Accepted
- **Date:** 2026-10-23
- **Source:** operator decision (pre-alpha product contract review)
- **Related:** DEC-022 (language parity), DEC-025 (framework distribution),
  DEC-026 (production profile; provider/language scope superseded here),
  DEC-028 (worker readiness), DEC-057 (installation/environment and the OSS
  boundary), DEC-058 (deploy identity), DEC-062 (workload authorization),
  DEC-063 (Sol-to-Sol identity), `docs/developer-experience.md`,
  `docs/deployment/compatibility.md`

## Context

DEC-026 defined `production-single-region/v1` as an AWS/EKS, OCaml-only profile.
That was the honest first qualification target: AWS was the only substrate with
live-provisioning evidence, and TypeScript was staged behind named triggers. The
rest of the product was already language- and provider-neutral in intent, and
the qualification apparatus has since grown a separate GCP row and a TypeScript
framework.

That leaves three problems:

- **The contract is narrower than the product.** A user can write the same
  workspace in OCaml or TypeScript, and the CLI accepts `aws`, `gcp` and `byo`,
  but only one combination carries the production promise. The difference is
  presented as a support tier even where it is only an evidence gap.
- **The `-fn` definition drifted.** The docs called it a scheduled function, the
  package called it a run-once execution primitive, and the framework carries a
  `Lambda` trigger that Sol does not deploy. Readers cannot tell what a `-fn`
  is or which deployment model they are promised.
- **Observability access was not part of the contract.** The platform installs
  Grafana, but there is no supported login path for a user who does not have
  Kubernetes access, and the dashboards were never verified against a live UI.

Sol is pre-alpha. There are no customers and no compatibility obligations. This
is the point to make the contract right rather than preserve the first target.

## Decision

### 1. One contract, defined in place

`production-single-region/v1` is redefined as the cloud- and language-neutral
contract. The old AWS/OCaml-only text is development history in Git; it is not a
compatibility constraint. There is no second version and no migration path.

### 2. Supported combinations

The contract covers:

- **local** development: OCaml and TypeScript; `-svc`, `-worker`, `-fn`;
- **AWS** production target: the same six language/primitive combinations;
- **GCP** production target: the same six combinations.

The target is one complete contract across both clouds and both languages. The
current evidence for each combination is tracked separately; it is not a
different capability set.

### 3. Guarantee layers

- **Functional:** the same workspace, `sol.yml`/`sol.toml` and code work
  unchanged; the same commands and primitive behavior; the same telemetry
  vocabulary and failure semantics.
- **Lifecycle:** build from the shipped artifact, deploy, update, migrate, roll
  back, destroy, verify absence; release records, secrets and grants.
- **Production profile:** the provider-neutral production requirements are
  observed with each provider's native capabilities — state and identities,
  immutable artifacts, Postgres HA/backup/restore, Kafka durability, availability
  and recovery behavior, credentials, alert delivery, control-state recovery and
  independent absence.

Production-profile conformance is configuration and measured recovery evidence,
not an end-to-end availability SLO. Sol does not promise an arbitrary application
availability percentage. The existing numeric bounds are qualification targets
to measure, not an SLA.

### 4. `-fn`

`-fn` is a **run-once execution primitive deployed as a Kubernetes CronJob**. It
is invoked on a schedule or manually (a Job created from the CronJob). It has no
HTTP server and no Kafka consumer-group lifecycle. It exposes exit codes
0/1/130, schedule/concurrency/backoff configuration, Pushgateway metrics, logs
and traces. The same contract applies to OCaml and TypeScript, on local, AWS and
GCP.

A target may select `execution: serverless`. On an AWS serverless target, `-fn`
is mapped to a provider-native run-once Lambda function using the `Fn.Lambda`
runtime contract; it remains a run-once primitive, and Sol creates no trigger,
schedule, or HTTP endpoint for it. The mapping is provider-specific and
experimental, not part of the production profile. GCP `-fn` has no accepted
serverless mapping yet.

### 5. Observability access

A target has one Grafana, reachable at a TLS-protected URL and gated by OIDC.
Anonymous access is disabled. Google OIDC is the default; any standard OIDC
provider is configurable at the target level, so the application contract does
not depend on an identity vendor. The deploy reports the URL; the user logs in
and sees that target's logs, metrics and traces. Dashboards are verified with
real telemetry, not merely installed.

Per-target isolation is the boundary for this release. A central
cross-environment observability plane is not part of this contract.

### 6. Language parity

TypeScript has the same documented runtime contract as OCaml: readiness,
shutdown and drain, workload identity, peer calls, and the three primitives.
Implementation may differ; the user-visible contract may not. A capability is
not marked "OCaml only" merely because its TypeScript implementation is later.

### 7. Evidence, not tiers

Each provider/language/primitive combination is tracked by the evidence that
actually exists: local test, live deployment, production-profile evidence, or a
named gap. The status table is a measurement, not a product tier. AWS work may
proceed while GCP evidence is incomplete, and OCaml work may proceed while
TypeScript parity is incomplete, without redefining the contract.

A release policy may later consume the same evidence. This decision does not
create one.

### 8. Provider differences

Implementation differences are expected. A user-visible difference is allowed
only for a genuine technical limitation, and must be recorded with the affected
guarantee, the provider behavior, the workaround and the profile version.
"Not implemented yet" is a gap, not a difference.

### 9. Versioning

The profile identity remains `production-single-region/v1` until the guarantee
set itself changes. This decision changes the scope of v1, not its identity,
because there are no external commitments to preserve. A future change to the
required-guarantee set or support matrix requires the version rule in DEC-026:
the version identifies what "conformant" means, and an older bundle is never
silently reinterpreted.

## Consequences

- `docs/deployment/compatibility.md` describes the contract's combinations,
  versions and provider realizations; the README's support table records current
  evidence.
- The production matrix becomes provider-neutral with per-provider evidence.
  The AWS and GCP matrices are provider evidence, not two claim sets.
- `supported_by_profile` and `production_qualified` remain correctness gates:
  a provider or language is admitted only when its evidence exists. They are not
  permanent tiers; flip them when the evidence lands.
- TypeScript `-fn`, worker readiness and the current TypeScript lifecycle gaps
  are contract work, not optional parity.
- A target's observability access becomes part of the deployment, with OIDC
  configuration outside the application contract.
- The first implementation sequence is artifact parity, CI executability,
  status/contract tracking, TypeScript parity, authenticated observability, GCP
  parity, then production conformance.

## Non-goals

Lambda/Cloud Functions deployment, a central cross-environment observability
plane, a hosted Sol control plane, BYO as a production target, and an end-to-end
availability SLA.
