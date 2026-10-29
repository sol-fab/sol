# Compatibility contract — `production-single-region/v1`

This is the exact supported set for the one product contract described in
[ADR 0009](../architecture/adr/0009-one-product-contract.md). It covers local
development and the AWS and GCP production targets, in OCaml and TypeScript, for
`-svc`, `-worker` and `-fn`.

**The contract applies to every combination.** A target that selects the profile
and resolves outside the set below fails preflight before anything is mutated;
there is no "accepted but unverified" outcome (DEC-026 §4).

The production preflight currently admits a provider or language only when its
evidence exists. Today it admits AWS and OCaml and refuses GCP and TypeScript.
That refusal is an **evidence gate, not a support tier**: the README's
[Support and conformance](../../README.md#support-and-conformance) table records
which cells are proven, partial or missing. A provider or language is admitted
when its row becomes production evidence; the contract does not change when that
happens.

## v0.1 contract freeze

Status: frozen for v0.1 on 2026-10-29 under ADR 0009. The profile identity and
the supported set below are the release boundary; changing either requires a new
profile version rather than an implicit expansion.

The v0.1 **production claim** is local development plus the AWS and GCP
production profile, in OCaml and TypeScript, for `-svc`, `-worker`, and `-fn`.
Durable tasks are a library, not a fourth primitive. Local and Kubernetes
`sol-task.local` handlers hosted by a `-worker` are in the application contract;
the standalone `sol task aws` and `sol task gcp` provider lifecycles remain
**experimental** and are not part of the production claim.

The following are explicitly outside the v0.1 production claim:

- target `execution: serverless` for `-svc` and `-fn`;
- provider-native task lifecycles (`sol task aws|gcp`);
- serverless triggers, schedules, and dependencies;
- BYO as a production target, the hosted factory floor, a central
  cross-environment observability plane, and an availability SLA.

These surfaces may ship and are documented as experimental, but they do not
block and cannot satisfy production qualification.

### Admission and release gate

A provider/language combination is production-qualified only when all of the
following hold:

- every workload cell for that combination in the README product matrix is
  `prod`, not `live` or `partial`;
- every lifecycle row required by the production profile has live evidence;
- every production-profile row has live evidence, including database recovery,
  Kafka durability, availability, alert delivery, and observability access;
- the security and observability gates in the qualification matrix pass;
- the installed candidate passes the AWS and GCP campaigns on the same harness
  revision, and the release policy can read and verify the resulting records.

The current non-`prod` cells in the README matrix are therefore open v0.1 gate
items, not evidence that a lower support tier is acceptable. Release promotion
also remains blocked independently: the release policy currently refuses before
reading qualification assets. That is an implementation gap, not a capability
waiver.

The known blocker classes are: the AWS/GCP preflight evidence gate admits only
AWS and OCaml today; cloud rollback, uninstall, and target Grafana/telemetry
visibility lack live evidence; database recovery, Kafka recovery, availability,
and alert delivery are partial or unmeasured; and the release-promotion path
must consume and verify the qualification records. The current rows and gaps are
generated from `internal/qualification/product-matrix.json`, and the release
gate is in `internal/tooling/release/README.md`.

## Guarantee layers

- **Functional:** the same workspace, `sol.yml`/`sol.toml` and code work
  unchanged; the same commands and primitive behavior; the same telemetry
  vocabulary and failure semantics.
- **Lifecycle:** build from the shipped artifact, deploy, update, migrate, roll
  back, destroy, verify absence; release records, secrets and grants.
- **Production profile:** the provider-neutral requirements are observed with
  each provider's native capabilities — state and identities, immutable
  artifacts, Postgres HA/backup/restore, Kafka durability, availability and
  recovery, credentials, alert delivery, control-state recovery and independent
  absence.

Production-profile conformance is configuration and measured recovery evidence,
not an end-to-end availability SLO. Sol does not promise an availability
percentage. The numeric bounds in the qualification matrix are targets to
measure.

## Supported combinations

| Environment | OCaml | TypeScript |
|---|---|---|
| local (`sol local deploy`, `sol local run`) | `-svc`, `-worker`, `-fn` | `-svc`, `-worker`, `-fn` once `@sol-fab/worker@0.2.0` and `@sol-fab/fn@0.1.0` are published |
| AWS (`aws/<region>` target) | `-svc`, `-worker`, `-fn` | `-svc`, `-worker`, `-fn` once the TypeScript packages are published and the generated-workspace/live evidence lands |
| GCP (`gcp/<region>` target) | `-svc`, `-worker`, `-fn` | `-svc`, `-worker`, `-fn` once the TypeScript packages are published and the generated-workspace/live evidence lands |

Local is development by design. AWS and GCP are both contracted at the production
profile. BYO is a development/experimental driver, not a production target.

`-fn` is a run-once execution primitive. On a Kubernetes target it is a CronJob
that can run on a schedule or be invoked manually as a Job created from the
CronJob. On an AWS target with `execution: serverless` it is a Lambda function
invoked on demand, using the `Fn.Lambda` runtime contract; Sol does not create a
trigger or schedule for it. It is not a Kafka worker. Provider-native serverless
execution is an experimental slice documented in
`docs/deployment/serverless-experimental.md`, not part of the production profile.

A target's observability is one Grafana, reachable at a TLS-protected URL and
gated by OIDC. Anonymous access is disabled; Google OIDC is the default and any
standard OIDC provider is configurable at the target level. The deploy reports
the URL, and the dashboards must show the target's real logs, metrics and
traces. This is a per-target boundary; a central cross-environment observability
plane is outside this contract. The platform requires TLS+OIDC SSO for every
installed Grafana and guards the anonymous/admin shape; live login and dashboard
verification remain the qualification evidence.

## Pinned inputs

The inputs below are pinned in the repository, not floating. A workspace consumes
the framework from workspace-owned, immutable opam/npm versions (DEC-025); it
does not need `$SOL_HOME` or a Sol source checkout to build.

| Input | Supported | Pinned in |
|---|---|---|
| Sol CLI | the built `sol --version` value (`git describe --tags --always --dirty` at build) | `cli/bin/dune` |
| OCaml | `>= 5.4.0` (qualified on 5.4.1) | `dune-project`, `sol-*.opam` |
| Node | `>= 20` (the `@sol-fab/*` packages' engine floor) | the workspace and package manifests |
| Kubernetes (EKS) | 1.36 | `platform/cloud/aws/cluster/variables.tf` (`kubernetes_version`) |
| Kubernetes (GKE) | `REGULAR` release channel; the exact version is observed at run time and is not yet a pinned qualification input | `platform/cloud/gcp/cluster/main.tf` (`release_channel`) |
| Provider module | AWS and GCP (`platform/cloud/aws/cluster/`, `platform/cloud/gcp/cluster/`) | `Sol_cli_provider_capabilities`, the provider roots |
| cert-manager chart | v1.14.4 | `platform/cloud/modules/platform/main.tf` |
| ingress-nginx chart | 4.10.1 | `platform/shared/components.json` (`versions`) |
| Argo CD chart | 6.7.3 | `platform/cloud/modules/platform/main.tf` |
| Redpanda chart | 26.1.11 | `platform/shared/components.json` (`versions`) |
| PostgreSQL chart | 18.8.17 | `platform/shared/components.json` (`versions`) |
| Loki chart | 18.12.1 | `platform/shared/components.json` (`versions`) |
| Grafana chart | 13.2.1 | `platform/shared/components.json` (`versions`) |
| Alloy chart | 1.12.1 | `platform/shared/components.json` (`versions`) |
| Tempo chart | 2.3.0 | `platform/shared/components.json` (`versions`) |
| Prometheus chart | 25.20.1 | `platform/shared/components.json` (`versions`) |
| TypeScript framework | `@sol-fab/svc` 0.3.0, `@sol-fab/worker` 0.2.0, `@sol-fab/fn` 0.1.0, `@sol-fab/kafka` 0.5.2, `@sol-fab/obs` 0.4.0, `@sol-fab/jobs` 0.1.2, `@sol-fab/outbox` 0.2.0, `@sol-fab/retry` 0.1.0 | the workspace manifests; all are published on npm |
| TypeScript `-fn` | `@sol-fab/fn` 0.1.0 is published; a generated workspace installs and builds, but no CronJob scenario has run | tracked in the README support table |
| Workspace framework deps | per-workspace immutable pins (DEC-025) | the workspace's `dune-project`, `*.opam`, `package-lock.json` |

`dev` runs the same charts at single-replica scale, so the component versions
above are the ones local development exercises too. The shared charts' versions
are declared once in `platform/shared/components.json`; both the local platform
and the production module project them from that one declaration, so there is
nothing to drift. The production-only charts (cert-manager, Argo CD) stay pinned
in the module.

## Current evidence gaps

These are gaps in the evidence table, not exclusions from the contract:

- GCP now has a namespace-scoped `sol-deploy` ServiceAccount token identity;
  live evidence of its use is still required.
- GCP managed Kafka and partial-state teardown are unverified (#1603, #1605).
- TypeScript function and worker readiness are published
  (`@sol-fab/worker@0.2.0`, `@sol-fab/fn@0.1.0`); a generated workspace installs
  and builds. No live CronJob or worker-readiness scenario has run yet.
- AWS's independent Kafka delivery observation is blocked (#1593).
- Per-target Grafana TLS+OIDC configuration is implemented and guarded; live
  login and dashboard visibility remain the qualification evidence.
- Both providers are declared production-qualified under the redefined
  profile (ADR 0009), including TypeScript; full production-profile live
  evidence (Postgres failover/restore, availability, alerts, GCP profile) is
  still tracked by #1725 and #1727.

A target that needs an unproven cell is not yet conformant; the README table says
which cell, and the linked issue says why. This is not a lower product tier.

## Provider realizations

The contract is the guarantee; the implementation is provider-native:

| Guarantee | AWS | GCP |
|---|---|---|
| Compute | EKS managed node group | GKE (REGULAR release channel) |
| Database | RDS PostgreSQL, Multi-AZ in the production profile | Cloud SQL PostgreSQL, Regional HA and deletion protection in the production profile; failover/restore evidence pending |
| Registry | ECR, one repository per workspace/unit | Artifact Registry, one repository per cluster |
| DNS | Route 53 delegated zone | Cloud DNS delegated zone |
| State | S3 + DynamoDB lock | GCS + native state locking |
| Identities | provisioner, cluster-access, deploy, operator, publisher roles (OIDC) | provisioner impersonation, `sol-deploy` KSA token identity, repository-scoped publisher; live evidence pending |
| Secrets | Secrets Manager / Kubernetes Secrets | Secret Manager / Kubernetes Secrets |

These are implementation differences. A difference becomes user-visible only
through an explicit provider-difference entry.

## Provider-difference register

No user-visible guarantee difference is approved. A proposed difference must
name the guarantee, the provider behavior, the workaround and the profile
version; "not implemented yet" is a gap, not an entry.

## Operator-supplied External Secrets Operator

External authority values are delivered by ESO, which Sol neither installs nor
upgrades, so ESO is not part of the pinned set above. Sol renders
`external-secrets.io/v1`; that API was introduced in ESO v0.16, and v0.17 stopped
serving the older `v1beta1` API. The v0.16 requirement is an API-compatibility
floor, not an upgrade-support range.

Direct deploy, rollback and `sol secret status` share one readiness predicate:
`Ready=True` with reason `SecretSynced` and a generation-bound
`status.syncedResourceVersion` whose prefix is `metadata.generation`. Missing,
unrecognized or lagging evidence is refused as not ready. Re-run the
external-secrets qualification with the new ESO/controller version after an
upgrade; the live evidence owner is
[`internal/qualification/external-secrets/README.md`](../../internal/qualification/external-secrets/README.md).

## Scope

One exact supported set is sufficient for maturity A. N/N-1 upgrades, skew
policy, fleet waves and broad provider matrices are out of scope; adding a
second supported set is a later, explicit decision. A central cross-environment
observability plane and an end-to-end availability SLA are outside this
contract.
