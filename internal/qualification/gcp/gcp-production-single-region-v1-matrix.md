# GCP qualification matrix

The authoritative GCP claim inventory is
`gcp-production-single-region-v1-matrix.tsv`. Each row names the invariant, required evidence
class, falsifiable scenario, pass condition, and evidence expected from a conformant run.

This document defines only the result contract. Historical attempts and defect investigations
belong in their immutable records and Git history.

## Result contract

A run result is tab-separated:

```text
invariant_id	result	evidence_class	evidence_ref	note
```

A conformant complete run contains exactly one result for every matrix row and no unknown rows.
Every result is `PASS`, its evidence class exactly matches the row requirement, and
`evidence_ref` resolves to an artifact inside the run bundle. A failure, block, skip, unknown,
or unexecuted row makes the complete profile non-conformant; its evidence may still be useful.

Validate a result with:

```sh
internal/qualification/gcp/verify-matrix.sh path/to/results.tsv
```

The verifier fails closed on missing/duplicate/unknown rows, insufficient evidence classes,
missing references, and references that escape the bundle. Its mutation suite is
`test-verify-matrix.sh`.

## Evidence requirements

Behavioral rows require observation against the real GCP target and named execution identity.
Mechanism rows may use executable/rendered evidence, never documentation alone. Provider
documentation describes the expected provider contract; it cannot establish Sol behavior.

The bundle identifies the installed Sol release, target, GCP project/region, timestamp, execution
identity, deviations, and teardown verdict. Secrets are not evidence.

Application behavior is established by the reference scenario's transactions plus independent
provider/Kubernetes/database/broker observations required by the corresponding row. A successful
HTTP request does not implicitly pass infrastructure or messaging claims.

## Lifecycle and absence

Exercise cloud lifecycle through the installed `sol` release. The harness may capture provider
and Kubernetes observations but must not reproduce Terraform/Helm orchestration owned by Sol.

After teardown, query target-owned GCP resource classes through provider APIs. Every required read
must positively establish absence (or explicitly approved durable retention). Permission errors,
timeouts, malformed output, unavailable APIs, or unrecognized responses are `UNKNOWN` and fail
the absence verdict.

The durable state/DNS bootstrap is a prerequisite, not disposable target state; verify that target
teardown leaves required durable prerequisites intact.

## Running

`live-qual.sh` owns the current executable GCP run. Use a fresh `ATTEMPT` and evidence
directory, an installed release selected with `SOL_INSTALL`, the provider/project inputs named
by the script, and explicit operator authorization before creating billable resources. The host
needs `script` (util-linux) on `PATH`: the harness drives the whole-target deploy's first-run
installation offer through a pty, and a fresh account's deploy refuses rather than sets the
installation up without one.

The production profile's broker SASL credential is a pre-platform operator input. `sol deploy`
creates the `redpanda` namespace in its prerequisite stage, then checks the
`redpanda-users` Secret exists before the platform apply and stops naming it when absent
(`docs/deployment/production-bootstrap.md` § *Production Kafka transport (SASL_SSL)*). The
harness stands in for the operator: it generates a run-scoped `sol-workloads` SCRAM credential
(or uses `KAFKA_SASL_PASSWORD` when supplied), creates the Secret with the documented
`kubectl create secret generic redpanda-users -n redpanda` shape at that boundary, records that
it supplied the input without its value in `prerequisites.txt`, and re-runs `sol deploy`
to resume — the same ordered steps the bootstrap guide gives the operator. Credential creation
failing fails the phase rather than letting the platform apply proceed without the
prerequisite.

Run only the phases needed for the claims being exercised. On any blocker while billable
resources exist, preserve evidence, destroy through Sol, independently verify provider absence,
then stop.

## Operator preflight (read-only)

Everything in this section is a provider read. It is what to finish before requesting
authorization for a billable window; none of it creates a resource.

### What the harness drives

The run exercises the installed release through the product lifecycle only: `sol deploy`
reconciles the environment and the workloads, `sol secret set` supplies the operator inputs,
`sol migrate apply` runs the migrations, and `sol destroy` tears the target down. The
application images are built and pushed in the `app` phase into the Artifact Registry
repository the `cloud` phase's `sol deploy` created (the cluster-named repository at
`<region>-docker.pkg.dev/<project>/<cluster>/pluto/<unit>`) — not into a harness-owned
registry. The GCP row deliberately selects no profile, so it does not depend on #1413's
cold-start change: a profile-less durable target never required a pre-published digest. The
cold-start cycle (#1413) applies to a target that selects `production-single-region`, which is
AWS-only.

### GCP project prerequisites (verify read-only)

- **APIs enabled** in the project: `container`, `compute`, `sqladmin`, `artifactregistry`,
  `dns`, `iam`, `iamcredentials`, `storage`, `secretmanager`, and `servicenetworking` for the
  VPC peering.
- **Calling identity** (`IMPERSONATOR`, e.g. `user:you@example.com`) must read each class the
  inventory probes with a viewer-level role, so an absence read is `ABSENT` rather than
  `UNKNOWN`. An unreadable class fails the absence verdict.
- **Database-CA observation identity**: supply `GCP_CA_OBSERVER_SERVICE_ACCOUNT` (a dedicated
  service account the caller can impersonate) or `GCP_CA_OBSERVER_SOURCE_KUBECONFIG`. It must
  be a different principal from the deploy identity, must read Deployments, ConfigMaps and
  Jobs in every observed namespace, and must not hold Secrets, `pods/exec`, `pods/log` or
  `delete` there. The harness refuses an absent, shared or broader identity rather than
  falling back to the deploy kubeconfig.
- **Target identities**: the provisioner / cluster-access / deploy / operator contracts come
  from `docs/deployment/production-bootstrap.md`; the target names them and `sol deploy` fails
  closed without them.
- **Quotas** to confirm before the window: regional CPUs and SSD for the GKE node pool, one
  in-use regional static IP, one Cloud SQL instance of the declared tier, and Artifact Registry
  repository count.
- **Durable prerequisites**, which teardown must leave intact: the state bucket (`STATE_BUCKET`)
  and the delegated DNS zone for `BASE_DOMAIN`. These are not target residue.

### Collision inspection

Give the run a fresh `ATTEMPT` and `CLUSTER`. Every provider read first binds one caller, one
project and one region, and the inventory records them; a scope that cannot be established makes
every class UNKNOWN rather than absent. Each class is then observed by its own operation: a named
resource is decided by the provider's own not-found answer for that name, and a class is
enumerated in full and attributed in this process (the GKE cluster label, the cluster name as a
name component, a load balancer address the run observed, or the target VPC's self-link). No
absence is decided from a server-side filtered projection.

The harness records the identities it attributes before teardown (`inventory pre`) and requires
the post-teardown observation to account for them (`verify`): a resource whose name no longer
matches after destruction is still residue if the pre-inventory recorded it. That supplements
discovery; it does not replace it, because a controller can create resources after the snapshot.

A child resource read that fails naming only its parent is decided from the parent's own
observation: an absent router implies its NAT is absent, while a present router leaves the child
UNKNOWN because which resource is missing is ambiguous. The identity record the pre-inventory
writes is bound to the attempt, cluster, project and region it was taken from; a record from
another scope is ignored, and the report says so, rather than attributing another target's
resource to this one.

Two limits are stated rather than implied. An enumeration reads JSON and requires the fields it
attributes by (`name`, `IPAddress`, `network`, the GKE disk label); if a provider changes those
names the class reads UNKNOWN, not absent. And attribution still needs a declared identity: a GKE
address reserved but never attached to a forwarding rule carries no name, label, network link or
recorded address, so a complete project enumeration would not attribute it to the target.
Before provisioning, the same read-only probes (or the console) confirm no resource in the target's
class set already carries the chosen `CLUSTER` name.

### Phases and stopping conditions

The run's phases are `cloud` (provision), `app` (build/publish, deploy and the reference
transaction), `identity` (read-only mechanism facts for VERIF-021/VERIF-022), `destroy`, and
`verify`; each is a separate invocation with its own evidence directory:

| Phase | Pass condition | Stop condition |
|---|---|---|
| `identity` | the target's identities and grants are observed | an unreadable identity read is UNKNOWN |
| `cloud` | the environment is reconciled and the platform discriminator observed | a prerequisite (installation, DNS delegation, broker credential) is unmet |
| `app` | the workloads are healthy and the reference transaction completes | a deploy refuses at a prerequisite; evidence is captured, never bypassed |
| `destroy` | Sol destroys the target and the pre-teardown inventory is attributed | destroy cannot start; nothing is recorded as attempted |
| `verify` | every target-owned class is ABSENT and each durable prerequisite PRESENT | any class is PRESENT or UNKNOWN |

### Residue classes the inventory verifies

GKE-labelled **persistent disks**, the GKE cluster, networks/subnets/routers/NAT/addresses/
forwarding rules, **Cloud SQL**, the **Artifact Registry** repository, service accounts and
their bindings, the custom role, VPC peering, and the state-object namespace; the state bucket
and DNS zone are asserted PRESENT as durable prerequisites. A class the identity cannot read is
UNKNOWN and fails the verdict.

### Evidence classes

Every matrix row records its evidence class. A complete run has one result per row, each `PASS`
at the row's required class, or the profile is non-conformant. Behavioral rows need live
observation; mechanism rows need an executable or rendered artifact. A skipped, blocked, or
unread class is recorded as such, never promoted to a pass.
