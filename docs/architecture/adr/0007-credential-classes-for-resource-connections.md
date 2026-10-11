# ADR 0007: Credential classes for resource connections

## Status

Accepted. Gates #1344d PR 2 (role-separated delivery).

The setup step is accepted as the mechanism because no cheaper honest alternative exists — the
alternatives are enumerated below and each is rejected for a stated reason. **There is no fallback:**
if the setup step proves infeasible on investigation, the honest outcome is *"credential classes are
deferred, and workloads still receive a credential above their role"* — stated as such. It is never
*"classes exist but mean nothing"*.

## Context

Dependency-scoped delivery answers *who receives a credential*. It does not answer *what that
credential authorizes*, and today the two are conflated in a way that is a security defect, not a
scoping detail:

- Both providers' `postgres_url` output is
  `postgresql://postgres:${var.db_password}@…` — the same `db_password` used to create the instance
  and its master user. **It is the administrative credential.**
- The migration Job consumes it (`verify_runtime_secret ~required_keys:["POSTGRES_URL"]`), and every
  unit requires it (`default_secrets = ["POSTGRES_URL", ""]`).

So "deliver the bound connection to declared consumers" would have handed ordinary workloads
administrative database access. `docs/architecture/resource-bindings.md` §3.2 fixes the shape:

| Class | Held by | Delivered? |
|---|---|---|
| Provisioning (administrative) | Sol's provisioning path | Never delivered to a consumer |
| DDL (schema changes) | The migration Job | To the migration Job only |
| DML (ordinary operations) | Application workloads | To declared consumers |

The class is **derived from the consumer's role**, so there is no user declaration and no permission
DSL. This record settles the four mechanics the model leaves open.

**Constraints found in the current implementation**, which decide the design:

- `platform/cloud/{aws,gcp}` declare **no additional PostgreSQL users**: only the master. PostgreSQL
  roles require SQL; no Terraform resource creates them.
- The database is **private** (GCP `ipv4_enabled = false`; the AWS instance is in private subnets), so
  an out-of-cluster Terraform SQL provider cannot be assumed to reach it.
- There is **no install-time Job machinery**; the only in-cluster one-shot runner is the migration Job
  (`sol_cli_migration_job.ml`: render, apply, wait, clean up).
- The migration Job is a **consumer**. It must not hold the provisioning credential, or the property
  this ADR establishes is defeated at the first step.

## Decision

### 1. Roles and grants

| Class | Role | Grants |
|---|---|---|
| **Provisioning** | The provider's master user (`postgres`, `var.db_password`) | Instance administration. Held by the provisioning path; never delivered |
| **DDL** | `sol_migrator` | Create and alter objects in the application schema |
| **DML** | `sol_app` | DML on the application schema; no DDL |

**No DML sub-classes yet** — read-only/read-write or per-table grants are deferred until a concrete
consumer requires one.

### 2. Source per class

**Sol-provisioned resource.** The provisioning configuration produces only the master credential. A
**database setup step** then runs *in-cluster*, with the master credential, to create or update
`sol_migrator` and `sol_app` with Sol-generated passwords, and records them in the target's
Sol-managed Secret. The binding's connection contract carries **one source per class** pointing at
those entries, and delivery reads the source for the class the consumer's role implies. Sol generates
the passwords — the operator supplies nothing.

**External resource.** The binding declares **one remote path per class** (the store holds one
credential per class), or a single path carrying a field per class. An external resource with no
source for a class simply has no consumer of that class; a consumer needing a class with no source
fails the plan (§3).

### 3. Enforcement

- The class is a **property of the consumer kind**: migration Job → DDL; unit → DML.
- The check lives in **resolution, beside the one-producer rule** (`Sol_cli_resource_binding.resolve`
  today): a resolved binding must offer a source for exactly the class the consumer's role implies.
  A consumer whose role implies a class the binding cannot source **fails at plan**; the provisioning
  class is never selectable by a consumer.
- Criterion 19 is the test: a workload's rendered inputs never contain the DDL or the provisioning
  credential, and the migration Job's never contain the DML credential.

### 4. Writers

**One delivered object per class per consuming namespace**, each with exactly one writer: Sol's
provisioning/database-setup path for a Sol-provisioned resource, ESO for an external one. A class with
no consumer in a namespace is not delivered, so a target that declares no migrations has no DDL object.

### 5. The setup step is part of the provisioning path, not a consumer

> The in-cluster database setup step is part of the **provisioning path**, not a consumer. It receives
> the master credential for the duration of one Job, creates the DDL and DML roles, writes their
> credentials to target Secrets, and exits. The master credential is not persisted to a target-owned
> Secret, and the setup step **does not appear in the class model as a role**.

It is a third thing at the boundary: not provisioning-as-owner, not a consumer. Stated so it is not
reclassified later as a consumer that "happens to hold the master".

### 6. Conditions on the setup step

1. **The master credential is not persisted anywhere.** The setup Job receives it as an environment
   value or a mounted Secret that exists for the Job's lifetime, from the same source the provisioning
   path already holds it — the cluster root's output. That is delivery *to the provisioning path*, not
   to a consumer. The credential is used, the Job completes, and it is gone; nothing writes it into a
   target-owned Secret. Anything else creates a second place the master lives.

   **"Not persisted" is proven, not asserted.** A lifetime is not a guarantee: the test asserts the
   transient master Secret is **deleted after the Job completes**, not merely that it was created with
   a lifetime, and crash-mid-Job cleanup is covered by an owner reference or equivalent so a Job that
   dies before its own cleanup still has the Secret collected.
2. **Idempotent.** Re-running against a target whose roles exist is safe: no recreate, no drop, no
   password churn. Existing roles are verified and the Job exits. If rotation is ever added, this is
   where it hooks.
3. **Fail-closed.** No workload starts until the setup step **succeeded** and the DDL and DML
   credentials are delivered. Same posture as every other prerequisite: no workload comes up against a
   credential it does not have.
4. **Ordering is explicit** — a phase in the coordinator, not an implicit consequence (§7).
5. **The generated passwords are target Kubernetes Secrets in v1.** Durability, rotation and any
   provider-store migration belong to #1360 — the same honest interim as the storage truth already
   stated in the model.
6. **The master is delivered from the cluster output, not from an operator's environment variable.**
   A target with a Sol-provisioned database obtains the master by reading the cluster root's
   `postgres_url` output. **This is the property, not "the Job ran"** — and it is verified end-to-end on
   a cloud target.

   Stated as a condition because it is currently **false, not merely unverified**: no code reads the
   output. The master reaches today's deploy path only because the operator copies the output by hand
   and exports it (`ensure_postgres_url ()` requires `Sol_cli_string.env "POSTGRES_URL"`, and
   `cmd_target.ml` reads the same variable), and reaches consumers through
   `sol secret set @platform POSTGRES_URL`. Before 2c, the model's claim that the provisioning output is
   projected at install describes a mechanism that does not exist; 2c builds the first real one.

### 7. Reachability and the phase sequence

The setup Job is a *cluster* Job, so it needs the cluster, the network path and the database all ready.
Verified in the current roots:

- **AWS** — `aws_security_group.rds` admits TCP 5432 **from the EKS node security group**, and the
  instance sits in the VPC's private subnets. A Job pod on a node is therefore covered by the same rule.
- **GCP** — private services access (`google_compute_global_address.sql_peering` +
  `google_service_networking_connection.sql`) with `ipv4_enabled = false`; no firewall rule is defined
  and GCP's rules are ingress-only, so egress to the peering range is permitted.
- **The NetworkPolicy is the part that can lag** — `managed_database_egress_doc` builds the egress rule
  from the cluster root's `database_egress_cidrs` output, and the deploy creates it in its
  **prerequisites** phase.

Phase sequence:

```text
cloud/cluster apply (database + network path)
  → deploy prerequisites (namespace, NetworkPolicy incl. database egress, projections + readiness)
  → database setup step            ← creates the DDL and DML roles
  → migration Job                  ← DDL
  → workloads                      ← DML
```

**The setup Job reaches the database because no NetworkPolicy selects it.** The rendered policies —
`network_policy_doc` and `managed_database_egress_doc` — are **pod-scoped**: their `podSelector` matches
`app: <workload-name>`. That is deliberate, because an empty selector would make the namespace
egress-default-deny for every pod in it (the invariant `internal/ci/check_managed_database_egress.py`
guards). The setup Job's pod template carries no `app` label, so no policy selects it and Kubernetes
leaves an unselected pod's egress unrestricted — the same reason the migration Job reaches the database
today. It therefore needs no allowance of its own.

This is a dependency on a default, not an exemption. A namespace-scoped default-deny egress policy would
isolate the Job, and it would then need an explicit rule; nothing in Sol renders one today. The step still
belongs after the prerequisites rather than beside the cloud apply, because it needs the namespace that
phase creates; but the guarantee is "the Job is outside the workload policy", not "the Job runs under it".

## Consequences

- **New machinery: one in-cluster database setup step.** It applies a Job with the master credential,
  waits, and records the generated credentials. It reuses the existing Job mechanics rather than
  introducing a runner concept — but it is new code and is the cost of this decision. There is no
  Terraform-only path: no role resource exists, and the database is unreachable from Terraform.
- **Storage.** The generated DDL and DML passwords are Sol-managed secrets in the target's Kubernetes
  Secret for v1 — the store the model names (§3.1). Their durability and any move to a provider store
  belong to #1360.
- **The plan gains a class refusal**, not a new declaration.
- **The migration Job's inputs change** from the master `POSTGRES_URL` to the DDL credential, and
  `default_secrets`' `POSTGRES_URL` entry goes away.
- **Sequencing: 2a → 2c → 2b.** PR 2a (model) lands first as a **pure refactor** — no behavior change, so
  existing tests pass unchanged. **2c (the setup step) lands before 2b (the delivery switch), because 2b
  consumes the roles 2c creates**: 2b without 2c fails at plan with no path to succeed, which is a broken
  intermediate state rather than a stack. 2c is additive — nothing consumes the roles yet, so the security
  property is unchanged until 2b — and **2c must be verified end-to-end on a target before 2b opens**, so
  that 2b starts from "the roles exist and work". If 2c proves infeasible, 2a remains useful, 2b never
  ships, and the fallback decision is made explicitly.

  The split is not process for its own sake: it lets each change be reverted independently. If 2c is
  infeasible, nothing landed a half-delivered state; if 2b's switch reveals an untraced consumer path, 2a
  and 2c are still correct.

  Review lens per PR: **2a** — no behavior change; if anything differs, it was not a refactor. **2c** — the
  five conditions in §6, which are its review criteria. **2b** — criterion 19 (credential class isolation)
  as the enforcement test, with "what does this delete?" as the discipline.
- **2b's deletion list** — the delivery switch must *delete*, not only add:
  - `default_secrets`' `POSTGRES_URL` entry — the mechanism that makes every unit require the master.
  - the database's `@platform` path.
  - **`ensure_postgres_url ()` and the `Sol_cli_string.env "POSTGRES_URL"` reads** (`cmd_deploy.ml`,
    `cmd_target.ml`). If these survive, the manual copy the operator performs today survives with them,
    and the model's claim stays false however well 2c delivered.
  - the operator-facing documentation that instructs copying the Terraform output into CI secrets and
    `sol.toml`.

## Alternatives considered

1. **Terraform's PostgreSQL provider** (`postgresql_role`, `postgresql_grant`) — declarative, no new
   Job. Rejected: requires network reachability to a private database from wherever Terraform runs.
2. **The migration Job creates the roles with the master credential** — rejected: it makes a consumer
   hold the provisioning credential, defeating the property; and a target with no migrations runs no
   Job, so the DML role would never exist.
3. **The operator creates the roles** — rejected: it contradicts the standard that declaring a
   dependency is enough for Sol to provision, connect and operate.
4. **One shared non-admin credential for DDL and DML** — rejected: collapses the classes and makes the
   criterion vacuous.
5. **A permission or grant DSL** — rejected: roles are enumerated by consumer kind, never configured.

## References

- `docs/architecture/resource-bindings.md` §3.1, §3.2, §4, criterion 19
- `platform/cloud/aws/cluster/outputs.tf`, `platform/cloud/gcp/cluster/outputs.tf` (`postgres_url`)
- `cli/lib/deploy/sol_cli_secret.ml` (`verify_runtime_secret`),
  `cli/lib/workspace/sol_cli_manifest_yaml.ml` (`default_secrets`)
- `cli/lib/deploy/sol_cli_migration_job.ml` (Job mechanics)
- #1344 (implementation), #1360 (authoritative storage)
