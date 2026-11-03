# ADR 0009: Provider-backed authority for application and PostgreSQL secrets

## Status and scope

Implemented offline for managed AWS/GCP Kubernetes targets under #1360. Live
qualification is tracked separately (#1118) and is not claimed here. Local shapes,
externally managed secrets and the Kafka authority ([ADR 0008](0008-managed-kafka-credential-authority.md))
are unchanged.

## Decision

On a durable AWS/GCP target, AWS Secrets Manager and GCP Secret Manager are the
authoritative store for ordinary Sol-managed application values and for the generated
PostgreSQL DDL/DML passwords. Kubernetes is the delivery environment, not the authority.

A workload receives provider-backed application values as mounted files through the
Secrets Store CSI driver. Sol does not emit `secretObjects` for ordinary values, so the
provider secret is never mirrored back into a Kubernetes Secret. A deployment's
prerequisite is a per-unit `SecretProviderClass`; the workload mounts it at
`/var/run/sol/secrets` and receives `KEY_FILE` and `SOL_SECRETS_DIR`. The application
contract is file-first and provider-independent:

- `Sol_runtime.secret key` reads `<KEY>_FILE`, then `SOL_SECRETS_DIR/<KEY>`, then the
  environment variable `KEY`. Existing environment-based consumption therefore keeps
  working where no file is projected, and provider-backed values never need an
  environment value.
- `Sol_runtime.secret_result` distinguishes a readable file from an unavailable one for
  required secrets; a required value must use it rather than treating an unreadable
  projection as an absent optional value.

`KEY` remains the file name and the environment-variable name, so the change is in where
the value comes from, not in what an application calls it.

## Identity and naming

A provider secret is target-scoped, because one environment can contain more than one
target:

| Object | AWS | GCP |
|---|---|---|
| Application key | `sol/<env>/<target>/units/<domain>/<unit>/<KEY>` | `sol-<env>-<target>-units-<domain>-<unit>-<KEY>` |
| Database authority | `sol/<env>/<target>/databases/authority` | `sol-<env>-<target>-databases-authority` |

The names are defined once in `Sol_cli_provider_secret`; planning, the writer, the
authorization root, the CSI projection and the destroy inventory consume that definition.
Ownership metadata (`sol-managed-by=sol`, `sol-authority`, `sol-environment`,
`sol-target`) is written by the container creator and re-read before any write. A
same-named secret without the exact metadata is refused, never adopted.

The PostgreSQL password record is a provider secret. Its DDL/DML class URLs remain
Kubernetes delivery projections written by the deploy after the Job succeeds, so they can
be rewritten without touching the password record.

## Authorization

- Each unit's workload role receives only the exact provider secrets it declares. The
  AWS permissions boundary is narrowed to the same per-unit prefix, so a later policy
  change cannot widen a workload to a sibling unit's authority. GCP binds
  `roles/secretmanager.secretAccessor` on each exact secret to the unit's Kubernetes
  ServiceAccount through Workload Identity.
- AWS uses the EKS Pod Identity association (`usePodIdentity` in the
  `SecretProviderClass`), never node credentials.
- The deploy identity verifies that a declared authority exists, is Sol's and has a
  current version. It does not create or write application values; `sol secret set`
  (operator/provisioner identity) is the writer. The target's provisioner policy manages
  the environment's authority paths; the deploy policy only reads them.
- Workloads receive no secret-store write access and no Terraform-state access.

## PostgreSQL lifecycle

The provider record carries the existing state machine:

- `pending`: persisted before the setup Job, but not yet proven accepted by Postgres.
- `established`: a successful Job established the passwords; only this authorizes a
  repair.

An ordinary deploy re-applies an established record. A pending record re-runs the
bootstrap, whose script refuses an existing role rather than overwriting it. Missing,
unreadable, unowned or pending-deletion authority fails closed; Sol never generates a
replacement for a credential whose authority it cannot read. PostgreSQL rotation remains
an operator procedure: a deploy is a repair, not an implicit rotation. The DDL/DML class
URLs remain Kubernetes delivery projections written after the Job succeeds, the same
pattern the Kafka authority uses; they are not the password authority.

## Migration

A provider authority absent while a Sol-owned Kubernetes copy exists is adopted:
the existing value is written to the provider first and the Kubernetes key is retired
only afterwards. An interruption therefore leaves a duplicate, and the next deploy
resumes by retiring it. When both exist, the provider is the declared authority; a
disagreeing Kubernetes value is reported and retired rather than silently chosen.

The provider authority is removed only by intentional target destruction. `sol destroy`
lists the target's provider authorities by their ownership metadata, deletes them, and
re-lists the store: a successful delete request is not absence.

## Failure and refresh semantics

- A missing, unowned, unreadable, unversioned or pending-deletion authority fails the
  deploy before a Pod that needs it is applied.
- AWS ASCP rotation polling is 2 minutes; the GKE Secret Manager add-on is enabled with a
  2-minute rotation interval. The AWS add-on is pinned to `v3.1.4-eksbuild.3`, the catalog
  build selected for Kubernetes 1.36, so the run records the provider build it used. A mounted file is refreshed by the driver, so an
  application that re-reads through `Sol_runtime.secret` observes the new value.
- A process that captured the value at startup does not observe a rotation; explicit
  activation (rollout restart) remains the operator action. `sol secret set` writes and
  stops there.

## Cluster and namespace replacement

The provider authority outlives the cluster and namespace. Redeploying into a replacement
cluster re-applies the per-unit authorization and recreates the `SecretProviderClass` and
mounts; the values are read from the provider rather than regenerated. The PostgreSQL
record makes the next deploy a repair against the surviving database.

## Evidence boundary

The offline suite covers naming isolation, ownership refusal, missing and unowned
authority, projection for both providers, repeated/rotated writes, the migration
decisions (including interruption), PostgreSQL record parsing and selection, rollback
projection, and destroy inventory filtering. It does not establish live provider IAM,
CSI driver behavior, eventual deletion or file-refresh timing; those remain live
qualification work.
