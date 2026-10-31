# Resource bindings

**Audience:** Contributors changing how a resource's connection reaches a unit or a generated Job.
**Scope:** The durable model — what a unit requires, how a target resolves it, who may read it, and how
a runtime delivers it. Provider defects and remaining delivery support gaps live in
the issues; this document states the model.

---

## 0. The model

> **A unit declares its dependencies and application secrets. The target resolves their sources. The
> runtime delivers exactly the inputs that unit requires.**

The standard for an ordinary case: **declaring a dependency is enough for Sol to provision it, connect
it, and operate it.** A developer configures exceptions and supplies their own application values.

| Situation | The developer supplies | Sol handles |
|---|---|---|
| Sol-managed database or Kafka | A resource declaration and `uses` | Provisioning, appropriate credentials, connection wiring |
| Application API key | The key's name and value | Authoritative storage, scoped delivery, explicit activation |
| Existing external database or Kafka | A complete connection binding and credential references | Delivery to declared consumers |
| A future runtime | The same dependency and application-secret declarations | Runtime-specific access, retrieval and initialization |

Derived rules, used throughout:

- **Dependency-scoped delivery.** A unit receives an input only for a dependency it declared, or because
  it declared the application secret itself.
- **One producer per input.** Conflicting producers fail at plan; no precedence and no last-value-wins.
- **One writer per delivered object.**
- **Atomic selection.** An override replaces a resource's whole binding selection.
- **Planning selects the source; execution obtains the value.**
- **Honest failure.** Uncertainty, absence and partial success are reported as such.

## 1. Requirements

Nothing new is introduced. Requirements are declared where they already are:

```yaml
# sol.yml
resources:
  app_db:
    type: postgres
services:
  charge_svc:
    uses: [app_db]
```

```toml
# app/payments/charge_svc/sol.toml
[infra.env]
secrets = ["SOL_API_KEY"]
```

**The resource name is the identity, used end to end** — declaration, binding, delivery, evidence.
`uses` is the dependency edge. Resource *shape* (`type`, keys, indexes) belongs in `sol.yml`; an
environment or target may adjust sizing, omission, and the **binding selection**.

## 2. Resolved connections

A **binding** is an entry in the existing deployment plan — not a new configuration object.

| Part | Meaning |
|---|---|
| **Resource identity** | The declared name and type, preserved for evidence and diagnostics |
| **Ownership** | Sol provisions the resource, or it is externally managed |
| **Credential source** | Where each authoritative value comes from — the provisioning configuration and its output, or an external store with a remote path |
| **Connection contract** | The complete set of inputs a consumer needs in order to connect, **carrying the credential-class dimension, with a source declared per class** (§3), and expressed in the model's own terms — brokers, authentication, password, trust, schema registry — not in delivery names |
| **Delivery** | How the value reaches *this* consumer (§4) |

The connection contract is complete, or it is not a contract: credentials without endpoints describe
nothing connectable, and today's Kafka endpoints are fixed Redpanda addresses in the renderer, so a
credential-only binding would authenticate to one system and connect to another.

**The model owns the connection semantics and the source references; the renderer consumes them.**
`keys:` — the map from an application contract key (`POSTGRES_URL`, `KAFKA_SASL_PASSWORD`) to a remote
path — **stays in the plan**: it is the application's own interface, and it is the contract keys that
name the inputs a unit reads. Moving the *type* into the deployment model does not move the mapping.
The reverse dependency (the deployment model depending on a renderer-owned secret-source type) is the
defect this replaces.

**Planning selects the source; execution obtains the value.** A plan names `app_db`'s provisioning
output without containing it, and an external reference is valid without the planner reading the
secret. Plans, records, GitOps output and diagnostics carry **references and non-secret metadata**,
never confidential values. A **pending source** (declared, not yet created) and an **invalid
requirement** (no declared resource) are different outcomes, with different diagnostics.

**Overrides are atomic, at the selection boundary.** Ownership, the credential sources and the
connection contract form one value inside the resource configuration; an override replaces it whole,
while unrelated attributes (type, size, indexes) keep field-level merging. Replacing the whole resource
would discard an inherited type; field-merging the selection could pair an inherited source with a new
connection.

**Provisioning follows effective declarations; delivery follows consumer requirements.** The two must
agree for a target, but neither derives from the other. Migration and contract Jobs are consumers with
internally declared, named dependencies. **Removing a `uses` edge removes that unit's inputs and never
deletes the resource.**

## 3. Authoritative storage and access ownership

Three decisions, related but not interchangeable:

| Decision | Values |
|---|---|
| **Who manages the resource** | Sol provisions it, or it is externally managed |
| **Where its credential comes from** | The provisioning configuration and its output, or an external store |
| **How the unit receives it** | Whatever the runtime delivers (§4) |

### 3.1 Authoritative storage, stated rather than implied

**A Sol-managed application secret is currently stored in the Kubernetes Secret that `sol secret set`
writes; there is no other authoritative store for it.** The provisioning path's credential authority
is the target's provisioning configuration and its output. So a "Sol-managed secret" today means
"stored in Kubernetes" — a fact this document states rather than leaves implicit.

**Generated Kafka credentials on managed AWS/GCP targets have an accepted provider-backed
storage decision:** [ADR 0008](adr/0008-managed-kafka-credential-authority.md). Implementation is
tracked by #1344; this decision does not claim that provider-backed generation or recovery already
exists. The provisioning path generates once through Terraform, provider stores preserve the
authority across Kubernetes replacement, and Sol projects inputs only to authorized consumers.
Terraform state also contains sensitive credential material; provider storage is not the only copy.

Application-secret migration, PostgreSQL credential migration and automatic rotation remain separate
work under #1360. Ordinary application values and the generated PostgreSQL DDL/DML authority still
use their existing Kubernetes storage. External bindings retain explicitly declared store authority.

Whatever the store, **one secret has exactly one authoritative source**, and every projection of it is a
representation.

### 3.2 Access ownership: the consumer's role determines its credential class

Dependency-scoped delivery answers *who receives a credential*. It does not answer *what that
credential authorizes*. Today the provisioning output is the database's **administrative** credential,
so delivering it to declared consumers would hand ordinary workloads administrative access.

| Credential class | Held by | Delivered? |
|---|---|---|
| **Provisioning** (administrative) | Sol's provisioning path | **Never delivered to a consumer** |
| **DDL** (schema changes) | The migration Job | To the migration Job only |
| **DML** (ordinary operations) | Application workloads | To declared consumers |

**The class is derived from the consumer's role, not declared by the user.** The migration Job is
Sol-generated and workloads are units, so the class falls out of what Sol already knows. There is no
permission DSL and no new declaration.

- **A workload never receives the provisioning or DDL credential** — even when the database is bound and
  the workload consumes it, the class it receives is DML.
- **A unit cannot request a higher class.** A genuine need for a consumer requiring more is a new
  consumer *kind*, not a new user-facing declaration.

A resource therefore has one identity and several consumer credentials, one per class — which is the
model's "one writer per delivered object" rule applied per class.

**The writer differs by ownership; the delivered objects do not.** Sol writes the class Secrets for a
database it provisions, from the provisioning output. When the database is bound externally, the
target names the store and a remote path **per class**, and the delivery controller writes the *same
objects* — the same names, under the same consumer key — from that store:

```yaml
# the target, e.g. sol/prod/aws/us-east-1.yml
target:
  resources:
    app_db:
      binding:
        ownership: external
        store: vault-production
        credentials:
          ddl: secret/production/app-db-migrator
          dml: secret/production/app-db-app
```

The class is the outer dimension of that selection — one delivered object per class — because a
contract with classes resolves one contract key to a *different* remote path per class: the database
URL is the migrator's in `ddl` and the application's in `dml`. **Every class the contract has must be
delivered**: a consumer credential that is simply absent is indistinguishable from a target that has
no database at all. The reader asks for a class Secret by name and never learns the ownership; a
consumer that branched on ownership would be the dual-interpretation this model rejects.

### 3.3 Ownership transitions

The existing binding resolver normalizes PostgreSQL into one explicit selection:
absent, managed, external with a store and fixed DDL/DML paths, or local development.
Planning, database identity, setup, credential delivery and rollback consume that selection.
Each workload carries one database-consumption value whose credential target and trust
requirement are projected together; independently optional credential and CA targets are
not maintained. Rollback applies historical `uses` to the current selection. It validates the
current binding before acquiring the rollback lease, refreshes externally delivered DDL/DML
classes from that binding, and waits for synchronization before reading migration history
or restoring workloads. The DML destinations come from the release's historical consumers.
An omitted or removed historical resource requirement refuses the rollback, even when
another database is available. Explicit target migrations likewise refresh their DDL
class from the current binding before executing; they do not rewrite workload DML classes.
A target with no PostgreSQL selection and no migration history needs no SQL observation;
explicit migration commands against an absent database refuse before submitting a Job.

Managed setup publishes its CA. External and local delivery retain their connection's
trust contract without inventing a Sol CA; this does not establish that an external
database needs no private trust material or add support for a new trust-delivery mechanism.
External PostgreSQL currently accepts complete URL credentials in the DDL/DML classes only.
Additional `connection`, `keys`, or credential-class inputs are rejected during selection,
including separate private CA sources, because the current delivery cannot honor them.
The selection does not change password authority or database ownership transitions.

**Changing a binding never authorizes destroying or relinquishing the previous database.** With
`count = var.create_rds ? 1 : 0`, switching an existing resource to externally managed would take its
database out of Terraform's desired configuration. v1 **refuses an ownership transition for an existing
managed resource** until the operator handles its disposition through the existing lifecycle. No
migration controller is introduced.

## 4. Runtime delivery

The binding is the contract; the runtime is the mechanism, chosen per consumer and runtime — one
resource may serve a Kubernetes consumer and a future function consumer at once.

**The consumption contract is startup configuration.** Sol makes the values a unit requires available
**before the application initializes**, through the existing environment and file interfaces. Code that
reads an input at startup keeps working unchanged.

**Making that contract hold at runtime is the runtime's bootstrap work — it is not a transparency
claim.** A runtime that retrieves values from a secret store must retrieve them *before* the
application reads them; exposing a retrieval API does not make an existing environment read retrieve.
An execution role that authorizes secret retrieval is also not the same mechanism as identity-based
authentication to a database; each lives in its own connection implementation.

**Refreshable credentials are a separate connection behavior**, added when a real consumer requires one.
The startup contract does not promise transparent rotation through an interface that reads a value once.

- **Kubernetes.** Projections are per consuming namespace. The renderer chooses the object kind, name,
  mount and reference path; **the object kind is a delivery detail, not an architectural rule** — a
  public CA may travel in a Secret because the delivery controller materializes Secrets.
- **Local development.** The same bindings, delivered as process environment, with only the inputs a
  unit consumes; a missing required value fails explicitly. Local Kafka is plaintext, so no credential
  or CA is required or projected.
- **A future runtime.** The same declarations; the runtime supplies its own access, retrieval and
  initialization, satisfying the startup contract. No backend plugin system is built to anticipate it.

## 5. Deployment, activation and rollback

**Target configuration owns current bindings and secret authority.**

**Rollback is historical application requirements + current target bindings → rollback inputs.** A
rollback restores the application release and resolves *its* named dependencies and application-secret
requirements against the target's **current** bindings; it does not restore an earlier credential
source. If the release is incompatible with the current bindings, the rollback **fails explicitly**.
**Infrastructure ownership changes stay outside application rollback** — rolling back code never
re-provisions or relinquishes a database. Historical references may remain as evidence, and never
silently become the authority again.

- **One writer owns each delivered object**; a switch of writer does not delete the previous object
  until consumers are redirected.
- **Planning checks declared requirements and supported combinations** before anything is applied.
- **Execution establishes the required delivery and readiness evidence** before a workload is up.
- **Updating a source, delivering its value, and activating it are three distinct outcomes.** For
  startup-environment delivery, a changed value reaches a running process only after a restart.

Projection reconciliation is idempotent and ownership-safe:

| Situation | Required behaviour |
|---|---|
| Source unavailable | Fail before mutating the projection |
| Projection missing / stale | Create / update it |
| Projection ownership unknown | Refuse adoption |
| One namespace succeeds, another fails | Report the partial failure, naming the namespace |
| Reconciliation interrupted | A subsequent reconcile repeats the operation safely |

Removals stay conservative: obsolete objects are **reported, never silently deleted**, and objects of
uncertain ownership are left in place.

**The stable guarantee:** a unit's declaration, code and connection interface — the **names, types and
semantics** of the inputs it reads — do not change when a resource's implementation changes. **Values
necessarily change** with an endpoint or credential, and generated names, paths, mounts and wiring may
change too. A provider that cannot satisfy a resource's connection contract is refused at plan, rather
than met with a provider-specific consumer or a generic adapter.

## 6. The boundary a new resource or runtime implements

**A new resource type** requires exactly three things, and nothing else: a typed connection shape in the
deployment model; a way to satisfy it (a provisioner, or an external binding); and a delivery
translation. Sol does not have to provision the resource for the type to be supported — a Sol-owned
consumer contract plus an implemented delivery path is enough.

**A new runtime** requires translating the model's connection semantics into that runtime's inputs, and
satisfying the startup contract (§4).

Non-goals, stated so a diff can be checked against them: no capability registry, runtime registration,
independent inventory or generic plugin framework; no provider-specific consumer branches; no precedence
rule for inputs; no resource DSL or parallel configuration of existing resources; no independent
reconciliation lifecycle (reconciliation stays part of target installation and the existing deployment
prerequisite handling); no migration controller, rotation controller or garbage collector; no
environment-wide impact analysis.

**Implementation discipline.** Each PR states **what it replaces** — which existing module, command,
flag, default or code path it removes or rewrites. The check is at the change level, not per new type.

## 7. Acceptance set

1. **Dependency-scoped delivery** — an input reaches a unit only for a dependency or application secret
   that unit declared.
2. **Unit isolation** — no cross-unit leakage.
3. **One producer per input** — conflicting producers fail at plan, naming both.
4. **Stable interface** — input names, types and semantics are unchanged across implementations; values
   and generated wiring may change; no provider branch in the consumer.
5. **Resource identity preserved** in the binding and the recorded evidence.
6. **References, not values** — plans, records, GitOps output and diagnostics carry no confidential value.
7. **Pending versus invalid** — distinct outcomes with distinct diagnostics.
8. **One writer per delivered object.**
9. **Atomic selection** — an override replaces ownership, sources and connection together, while
   unrelated attributes still merge as before.
10. **Ownership transitions are refused** for an existing managed resource; a binding change never
    produces a silent deletion plan.
11. **Rollback uses current bindings** — historical requirements against current target bindings;
    incompatibility fails explicitly; infrastructure ownership is untouched.
12. **No dangling references** — reconciliation is repeatable after interruption, and an incomplete
    operation never reports success. Removing a `uses` edge removes inputs and never deletes the
    resource.
13. **Every value has a named source** — no placeholder, and no fallback default when the source is absent.
14. **No additional authority** — a projection never becomes an independent source of credential authority.
15. **Observable resolution** — plan and status show the resolved source for each input and whether it
    was declared at the environment or the target; no internal representation is prescribed.
16. **Resolution is consistent** — availability, requirements and what the infrastructure actually
    provisions agree for the selected target.
17. **Partial failure is reported**, naming the affected namespace; never target-wide success.
18. **Unsupported combinations are refused at plan** — an unknown resource type, a provider that cannot
    satisfy the connection contract, or an unsupported resource count.
19. **Credential class isolation** — each consumer receives only the credential class its role implies:
    a workload's delivered inputs never include the provisioning or DDL credential, and the migration Job
    never receives the DML credential.

## 8. Out of scope

More than one database per target, whatever its ownership — the delivered class Secrets are
named for the target, so two databases cannot be told apart by their consumers; multi-target
sharing of a resource; capability types
beyond the concrete PostgreSQL and Kafka connections Sol supports today; automatic rotation; cross-cloud
portability; environment-wide change reports.

Resource bindings supply database and Kafka credentials to their consumers and generated Jobs;
operator writes are unit-scoped application secrets. ADR 0008 establishes managed Kafka
authority; **#1360** retains the broader authoritative-storage decision. The GitOps limitation is **temporary** — resource ownership does not
determine delivery capability; the flow cannot yet establish prerequisite readiness for
installation-owned projections, and that is an implementation gap, not a model rule. Until it can,
`sol deploy --emit-to` **refuses a database Sol provisions at plan time**, naming the binding: the setup
step that writes its class Secrets runs only in a direct apply. An externally bound database emits its
class `ExternalSecret`s as `<target>-db-prerequisites.yaml` beside the workloads, so a fresh GitOps
deployment carries the object its units read.

## External queue and object-store bindings

`queue` and `object_store` resources are currently **external-first**. A service that
declares one in `uses` receives the binding's non-secret `connection` entries as
environment variables. Examples:

```yaml
resources:
  jobs:
    type: queue
    binding:
      ownership: external
      store: external
      connection:
        QUEUE_ENDPOINT: https://sqs.us-east-1.amazonaws.com/123/jobs
        QUEUE_NAME: jobs

  uploads:
    type: object_store
    binding:
      ownership: external
      store: external
      connection:
        OBJECT_ENDPOINT: https://objects.example.com
        OBJECT_BUCKET: uploads
```

Rules:

- managed `queue`/`object_store` bindings are refused until a provider backend and
  lifecycle are defined;
- connection values are non-secret;
- the connection contract does not promise Kafka stream semantics (ordering, replay,
  consumer groups) for queues.

### AWS authorization

AWS is the first implemented provider for external queue/object-store capabilities.
The application declares only the logical resource; the target supplies the physical
binding:

```yaml
# sol.yml - application contract, no provider identifier
resources:
  jobs:
    type: queue
  uploads:
    type: object_store

services:
  notify_worker:
    type: worker
    path: app/comms/notify_worker
    uses: [jobs, uploads]
```

```yaml
# sol/environments.yml - target-specific physical binding
targets:
  aws/us-east-1:
    resources:
      jobs:
        binding:
          ownership: external
          store: external
          connection:
            QUEUE_ARN: arn:aws:sqs:us-east-1:123456789012:jobs
            QUEUE_URL: https://sqs.us-east-1.amazonaws.com/123456789012/jobs
      uploads:
        binding:
          ownership: external
          store: external
          connection:
            OBJECT_ARN: arn:aws:s3:::uploads/*
            OBJECT_BUCKET: uploads
```

The target layer replaces the binding atomically. Changing environments changes the
physical SQS/S3 resource without changing the application's `jobs`/`uploads` references.

Required AWS connection keys:

- `queue`: `QUEUE_ARN` (must be an `arn:aws:sqs:` ARN) and `QUEUE_URL`;
- `object_store`: `OBJECT_ARN` (must be an `arn:aws:s3:::` object ARN ending in `/*`) and
  `OBJECT_BUCKET`.

Capabilities translate to AWS IAM actions scoped to those ARNs:

| Capability | AWS action |
|---|---|
| `message.publish` | `sqs:SendMessage` |
| `message.subscribe` | `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:ChangeMessageVisibility` |
| `object.read` | `s3:GetObject` |
| `object.write` | `s3:PutObject` |

The workload uses its Sol-managed AWS identity (EKS Pod Identity or Lambda execution
role), so no provider SDK credentials are emitted as plain environment variables.

Fail-closed cases:

- a missing `QUEUE_ARN` or `OBJECT_ARN`;
- `binding.keys` or `binding.credentials` (secret-reference authentication is not
  implemented for external queue/object-store yet);
- a non-AWS target;
- a managed binding.

GCP external queue/object authorization remains unsupported until Pub/Sub/GCS permission
translation is implemented. Applications still use their native provider SDK; Sol does not
provide a provider-neutral runtime client.
