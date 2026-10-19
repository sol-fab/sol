# ADR 0008: Provider-backed authority for managed Kafka credentials

## Status and scope

Accepted for managed AWS/GCP targets under #1360. Implementation is tracked by #1344.
This decision covers Sol-generated Kafka credentials only. Application-secret migration,
PostgreSQL credential migration and credential rotation remain separate work.

## Decision

Sol's existing Terraform provisioning path generates a stable Kafka password and stores it
in AWS Secrets Manager or GCP Secret Manager. The provider secret is the durable credential
authority; Kubernetes Secrets are runtime delivery objects. Neither cluster replacement nor
ordinary reconciliation authorizes generating a different password.

Use the existing target identity and declared Kafka resource to identify the provider secret.
Plans and release records carry that reference and nonconfidential connection metadata, never
credential values. Provisioning declares the reference; delivery and destruction consume it
rather than reconstructing an independent naming convention.

Terraform owns the native secret, its version and generation. Use Terraform's existing state
and locking, not another credential database, initializer lock, lifecycle engine or rotation
controller. A generated password has no deployment timestamp or other changing keeper.

### Confidentiality and permissions

The provider store is **not the only persisted copy**. Terraform state ordinarily contains the
password. Marking an attribute sensitive redacts ordinary display; it does not encrypt state.
Historical state versions and backups retain the same sensitivity after a secret is deleted.

Sol's AWS bootstrap configures an encrypted, versioned state bucket with public access blocked;
GCP configures versioning, uniform bucket-level access and public-access prevention. Those are
storage properties, not proof of least-privilege access. Provisioning must establish the actual
backend policy and transport restrictions; an externally supplied backend must satisfy the same
confidentiality boundary. Workload identities must not read Terraform state. Do not claim that
these configuration checks establish live backend security without provider qualification.

The provisioning principal needs scoped creation/version-write/observation/deletion authority.
The deployment principal needs only scoped credential retrieval and the existing Kubernetes
projection authority. Application workload identities receive neither secret-store write access
nor Terraform-state access; they consume their authorized Kubernetes projections. Do not add
cloud read permissions to workloads merely because the credential originates in a provider store.
External Kafka retains its explicitly declared external-store authority and existing ESO delivery.
Sol does not install ESO or SecretStores as a prerequisite for managed Kafka.

Credential retrieval and Kubernetes writes use confidential process input/output, never command
arguments. Credential values must not enter Sol plans, release records, logs, GitOps output or
committed/generated configuration files. Preserve original provider error codes and diagnostics
while redacting sensitive values. Keep KAFKA_SSL_CA_CERT in Secret delivery, including mounted
CA material, as the existing resource contract requires.

Terraform state and saved binary plans are authorized sensitive execution surfaces. Binary plans
must live outside diagnostic archives, shared CI artifact directories and caches, in private
0700 directories with 0600 files. Clean up on success, failure and handled interruption; report
cleanup failures without reading or exposing contents. A hard kill or machine crash can leave
artifacts behind: keep those private under the host's temporary-file retention policy and document
safe operator cleanup after confirming the operation is no longer running. Do not promise
unconditional deletion. Tests must establish permissions, cleanup and public-output confidentiality.

### Initialization, reuse and recovery

| Observed situation | Required behavior |
|---|---|
| Fresh target with no prior broker, persistent broker infrastructure or authority | Generate once under Terraform locking; persist before installing authenticated Redpanda |
| Ordinary apply with intact authority and generation state | Reuse the same credential; no password or version churn |
| Kubernetes replacement with intact provider authority and Terraform state | Retrieve the existing value and recreate owned delivery objects |
| Partial generation state loss, secret recreation or proposed credential replacement | Refuse automatic regeneration for an existing broker; do not interpret a create plan as proof of first installation |
| Broker/PVC/infrastructure survives but authority is missing, unreadable, pending deletion or inconsistent | Fail closed before changing broker credentials or starting consumers; report recovery requirements |
| Both authoritative value and recoverable state are lost | Explicitly unsupported automatic recovery; require an operator recovery or intentional destructive reprovisioning decision |

Use existing ownership evidence, Terraform change inspection and provider observations to establish
these cases. Unknown is not fresh. Recovering a recorded value is distinct from adopting an arbitrary
pre-existing provider secret. Identity, ownership and target scope must be established before use.
A surviving broker must never be assigned a new password merely because its delivery Secret or
Terraform random-resource entry disappeared. Restoring verified historical state is recovery;
silently rotating the broker is not.

### Delivery and consumers

Resolve one concrete typed Kafka binding through the existing resource-binding abstraction.
Planning, provisioning, generated Jobs, direct deployment, status and rollback share that selection.
Rollback resolves the current target's authority for the historical release's declared requirements;
it must not restore stale credential assumptions or serialized secret values.

Only declared Kafka consumers and authorized generated Jobs receive authentication and connection
material. Generated Jobs receive only their required keys, not every application secret. Each
delivered object has one writer. Conflicting application-key declarations and unsupported source
combinations fail before mutation. Managed GitOps is refused unless confidential materialization
from this authority is actually supported; rendering a reference alone does not establish delivery.
Local development retains deliberate plaintext transport and dependency-scoped local inputs.

### Destruction and retention

The target owns the provider secret independently of Kubernetes. Cluster replacement preserves it;
intentional full target destruction removes it. This increment does not introduce implicit secret
retention. AWS native secrets use deletion without a recovery window on intentional target teardown;
that authorizes deletion, not a claim that asynchronous deletion already finished.

A successful deletion request, a disabled/inaccessible version, or AWS's pending-deletion timestamp
is not established absence. Product destruction and independent qualification must observe the
provider secret's actual absence. Pending deletion remains present; an unreadable observation remains
unknown. Carry known identities through final verification so disappearing labels cannot erase the
obligation. Existing lifecycle retries may re-observe; do not add an independent secret-deletion loop.
Where a provider guarantees that versions cannot survive the parent, delegate version absence to
verified parent absence rather than inventing a separate version inventory.

Provider-resource recovery mappings, executable inventory requirements, ownership attribution and
independent qualification must account for the new surviving resource class in the same feature.
Do not enable provisioning while leaving teardown or qualification coverage to a later PR.

## Evidence required before completion

Offline behavioral tests must reject credential churn, missing/denied authority, partial state loss,
foreign target identity, conflicting writers, consumer leakage, stale rollback authority and secret
value disclosure. Exercise both provider implementations and explicit unsupported modes. Deletion
fixtures must distinguish present, pending deletion, absent and unknown. Semantic IAM tests check
operations, resource scope, conditions and relevant denials for each principal.

Live AWS/GCP qualification remains separate evidence. No offline suite establishes that provider
permissions, eventual deletion or cluster-loss recovery have been qualified in a live deployment.

## Sources

- Existing [resource bindings](../resource-bindings.md), [ownership](../ownership.md) and
  [credential classes](0007-credential-classes-for-resource-connections.md).
- AWS and GCP bootstrap roots: platform/cloud/{aws,gcp}/bootstrap/main.tf.
- [Terraform sensitive values](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)
  and [saved plans](https://developer.hashicorp.com/terraform/tutorials/cli/plan).
- [AWS DeleteSecret](https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_DeleteSecret.html).
