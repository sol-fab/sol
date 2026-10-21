> Historical snapshot taken 2026-09-18. Its present-tense inventory claims are not current. See `../gcp/gcp-bootstrap-inventory.md` for durable rules and per-run inventories for current state.

> File names here are historical: `qual-aws-row.tfvars` and `qual-gcp.tfvars` are now `qual.tfvars`, `live-row.sh` is now `live-qual.sh`, and `test-live-row.sh`/`test-live-qual.sh` are now `stubbed-qual-test.sh`.

# GCP bootstrap inventory and lifecycle proposal

> **Where the work stands — read this first.** This document is the GCP
> qualification workstream's record and decision log; **HARDEN-004** is its ticket
> and entry point. The sections below are chronological, so they are archaeology:
> accurate, but they describe how the present was reached rather than what it is.
>
> **Canonical state:** `main` @ `8d85c7ce` (2026-09-19). Nothing is running; the
> qualification target is `Absent`, verified independently.
>
> **Qualified behaviourally** (observed live): cloud bootstrap through Sol's own
> lifecycle on GCP; the provisioner identity, impersonation by the declared caller,
> ephemeral cluster access, and the install window opened *and revoked*; the platform
> stage running under that identity (424s of in-cluster work); destruction of a
> **partially installed** platform through the documented lifecycle, then the cloud
> layer, then absence verified through the provider's API; the service-networking
> peering abandonment, twice observed.
>
> **Not qualified, and not claimed:** platform `Ready` (never reached), GCP
> readiness/convergence checks, any HARDEN capability scenario, TLS issuance
> (**BLOCKED** — no delegated qualification zone), Workload Identity wiring, Cloud
> SQL regional HA, production capacity/headroom, GCS durable-observability wiring,
> and GCP retention semantics (refused by name rather than approximated).
>
> **Next action:** a fresh disposable target whose first objective is to get past
> `helm_release.cert_manager` and reach platform `Ready` — and whose *first task* is
> to capture why that release's post-install `startupapicheck` Job fails, from the
> check container's own output, before helm deletes the Job and its reason with it.
> See HARDEN-004's "Current frontier". The standing rules — the absolute cost rule,
> the `Absent` postcondition, do-not-build-cert-manager-speculatively, no static
> service-account keys, do-not-weaken-AWS — are listed there too.
>
> **Executable contract:**
> `internal/qualification/gcp/gcp-production-single-region-v1-matrix.md` and its adjacent
> TSV map every provider-neutral invariant to a GCP scenario. The verifier makes
> missing, failing, or insufficiently evidenced rows fail the run; the matrix is
> not evidence that any currently unqualified capability passes.
>

**Inventory date:** 2026-09-18 (America/Denver)

**Project:** `sol-qualification` (project number verified against the supplied
value)

**Scope:** read-only bootstrap qualification; no APIs, IAM, billing, DNS, or
infrastructure were changed.

## Result

The project is not ready for a live Sol qualification. Billing is not linked,
the required infrastructure APIs are disabled, exact quotas therefore cannot
be read, and no qualification service accounts exist. The bootstrap user has
project Owner, so project IAM and API enablement authority are available, but
access to a billing account is a separate prerequisite.

Do not implement the current `platform/cloud/gcp/cluster` root as-is. It predates
Sol's qualified lifecycle and does not meet the current production contract:

- `sol cloud` deliberately fails closed for GCP and its output contract is
  AWS-specific.
- the root creates GKE Autopilot, while the `node-failure-tolerant` production
  tier requires qualified capacity and explicit node-failure headroom that the
  current root cannot declare or prove;
- Cloud SQL defaults to zonal rather than required regional HA;
- the platform root defaults to the AWS `gp3` StorageClass contract;
- both cert-manager `ClusterIssuer` resources are hard-wired to Route 53
  DNS-01 and cannot issue on GCP as written;
- GCS-backed Loki/Thanos resources exist, but the platform charts are still
  wired for S3 and reject durable GCP observability; and
- DNS creates a zone but no application or wildcard record.

These are implementation gaps, not bootstrap-project defects.

## Read-only inventory

### Principal, project, and Terraform authentication

| Check | Observed | Verdict |
| --- | --- | --- |
| Active gcloud principal | `lbendtlynielsen@gmail.com` | usable bootstrap user |
| Active gcloud project | `sol-qualification` | correct |
| Project lifecycle | `ACTIVE`; created `2026-09-19T04:36:38.151Z` | correct |
| Resource ancestry | project only; no folder or organization returned | no inherited org/folder IAM was visible |
| Local ADC | `authorized_user`, quota project `sol-qualification`; access-token mint succeeded | usable by the Google Terraform provider |
| Terraform | `1.9.8` | satisfies the GCP root's `>= 1.6` constraint |
| Long-lived keys | none created or downloaded | required posture |

Google recommends ADC for Terraform and supports ADC backed by service-account
impersonation. Bootstrap may use the current user ADC; routine Terraform should
impersonate the provisioner service account with short-lived credentials.

### Billing

`billingEnabled` is `false` and `billingAccountName` is empty. This blocks the
billable qualification infrastructure; some API activation can still occur
without billing, but it would not make the target provisionable. Project Owner
does not imply permission to attach an arbitrary billing account; the operator
also needs suitable authority on the selected billing account.

### APIs

Currently enabled:

```text
analyticshub.googleapis.com
bigquery.googleapis.com
bigqueryconnection.googleapis.com
bigquerydatapolicy.googleapis.com
bigquerydatatransfer.googleapis.com
bigquerymigration.googleapis.com
bigqueryreservation.googleapis.com
bigquerystorage.googleapis.com
cloudapis.googleapis.com
cloudtrace.googleapis.com
dataform.googleapis.com
dataplex.googleapis.com
datastore.googleapis.com
logging.googleapis.com
monitoring.googleapis.com
servicemanagement.googleapis.com
serviceusage.googleapis.com
sql-component.googleapis.com
storage-api.googleapis.com
storage-component.googleapis.com
storage.googleapis.com
telemetry.googleapis.com
```

Minimum APIs for the proposed substrate, to enable only after approval:

| API | Why |
| --- | --- |
| `compute.googleapis.com` | VPC, subnets, private service access, GKE nodes, disks, addresses, and load balancers |
| `container.googleapis.com` | GKE |
| `artifactregistry.googleapis.com` | Docker repository |
| `sqladmin.googleapis.com` | Cloud SQL PostgreSQL |
| `servicenetworking.googleapis.com` | private Cloud SQL service connection |
| `dns.googleapis.com` | only if Sol owns a Cloud DNS zone |
| `iam.googleapis.com` | service accounts and IAM bindings |
| `iamcredentials.googleapis.com` | service-account impersonation and linked GKE workload identities |
| `sts.googleapis.com` | external Workload Identity Federation for CI/operator automation |
| `storage.googleapis.com` | already enabled; remote state and durable telemetry objects |
| `logging.googleapis.com`, `monitoring.googleapis.com` | already enabled; provider/GKE telemetry |

`cloudresourcemanager.googleapis.com` and `serviceusage.googleapis.com` are also
bootstrap dependencies. Secret Manager and Cloud KMS are optional choices, not
requirements of the current Sol contract; enable them only if the implementation
actually adopts them.

### IAM and bootstrap capability

The project policy has one binding:

```text
user:LBendtlyNielsen@gmail.com -> roles/owner
```

No user-managed service accounts exist. Project Owner provides broad project
resource/IAM authority, including the ability to establish narrowly scoped
runtime identities. It does not prove billing-account authority, domain/DNS
authority, organization-policy authority, or permissions inherited through an
organization. The final bootstrap must test those separately rather than infer
them from Owner.

### Existing relevant resources

- Cloud Storage enumeration succeeded and returned no buckets.
- No user-managed service accounts exist.
- Compute Engine, GKE, Artifact Registry, Cloud SQL, and Cloud DNS cannot be
  enumerated while their APIs are disabled. Their inventories are therefore
  **unknown**, not confirmed empty.
- Cloud Asset Inventory was not enabled, so no shadow inventory was attempted.

Immediately after the approved API-enable step, repeat all resource queries
before the first Terraform plan. A supposedly disposable project must still
fail closed on unexpected pre-existing resources or name collisions.

### Candidate region

Use `us-central1` as the first qualification candidate: it is the repository's
current GCP default and keeps GKE, Artifact Registry, Cloud SQL, and GCS regional
placement aligned. Keep `us-east1` and `us-west1` as alternatives only if
latency, availability, or quota checks favor them. Do not select a final region
until billing is attached and regional quotas plus required GKE/Cloud SQL
features are queryable.

This is a qualification choice, not a new cross-region abstraction. One region
is enough for `production-single-region/v1`.

### Attempt 5 (2026-09-22) and its residue

The attempt applied the cloud root cleanly (592.2s, 14 resources) and then stopped:
`sol cloud destroy --apply` refused the same target that `sol cloud apply --apply` had
just accepted, in the `PreparingDestroy` phase (`FND-0029` / `INFRA-067`). Everything
billable was torn down and verified absent through the provider's API. Full chronology
and inventory: `internal/qualification/records/2026-09-22-gcp-attempt5.md`.

**Residue resolved (2026-09-23).** The Cloud DNS zone `qual-gcp-sol-fab-dev` is now owned
by the durable root, `platform/cloud/gcp/bootstrap`, beside the state bucket -- both
adopted by `terraform import`, which preserves the nameservers, so the delegation pasted at
the registrar keeps working. That is `DEC-043`'s narrow ownership decision, taken after
Attempt 5 showed what the previous arrangement cost: the zone was created by the disposable
cloud root, so destroying the target either destroyed the delegation or required removing
the zone from state by hand.

The target root no longer manages the zone (`create_dns_zone = false` in
`internal/qualification/gcp/qual-gcp.tfvars`): two roots must never manage one zone.
Adopting the two resources produced a plan of *0 to add, 2 to change, 0 to destroy* -- the
bucket's `sol-role` label and the zone's description, metadata only -- left **unapplied at
adoption time** deliberately, since these are live durable resources and the bucket holds
every root's state. A target run **reconciles** the durable root rather than merely checking that it exists
(`DEC-043`): presence was adequate while the root's only job was to create a backend, but
it is not ownership now that the root declares bucket policy and the delegated zone. A plan
that would replace or destroy either resource is refused rather than applied, since a
recreated zone gets different nameservers and a recreated bucket is the state store for
every root.

## Quotas and blockers

**Correction (2026-09-22).** This section used to say quota usage "could not be
obtained because billing and the Compute, GKE, Artifact Registry, Cloud SQL, and DNS
APIs are disabled". That is no longer the project's state and was already wrong when
re-read: `sol-qualification` has **billing enabled** and **39 APIs enabled**,
including all five named — verified directly, not inferred:

```bash
gcloud services list --enabled --project sol-qualification      # 39 APIs, incl. the five
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://cloudbilling.googleapis.com/v1/projects/sol-qualification/billingInfo"
# -> {"billingEnabled": true, "billingAccountName": "billingAccounts/01EADC-…"}
```

The honest statement is narrower: **these quotas were never read**, not that they
could not be. Nothing here has been bootstrapped away, so the checks below are still
outstanding work — validate them before apply:

**Read 2026-09-22 — the prerequisite is now evidence rather than a gap.** Region
`us-central1` (the repository's first qualification candidate), project
`sol-qualification`:

| Quota | Limit | Usage |
| --- | --- | --- |
| `CPUS` | 200 | 0 |
| `N2_CPUS` | 200 | 0 |
| `E2_CPUS` | 24 | 0 |
| `INSTANCES` | 24 | 0 |
| `IN_USE_ADDRESSES` | **8** | 0 |
| `STATIC_ADDRESSES` | **8** | 0 |
| `SSD_TOTAL_GB` | 500 | 0 |
| `DISKS_TOTAL_GB` | 4096 | 0 |
| `INSTANCE_GROUPS` | 100 | 0 |
| `REGIONAL_INSTANCE_GROUP_MANAGERS` | 150 | 0 |
| `NETWORK_ENDPOINT_GROUPS` | 100 | 0 |
| `SNAPSHOTS` | 1000 | 0 |

```bash
gcloud compute regions describe us-central1 --project sol-qualification \
  --format='csv[no-heading](quotas.metric,quotas.limit,quotas.usage)'
```

Two things this establishes. **The project is idle and cost-clean**: every quota
reads `usage = 0`, which is the independent check the cost rule asks for *after* a
teardown has been recorded as `Absent` — a `destroy` that succeeds is not itself
evidence of cost-cleanliness. And **the headroom is ample in one place and tight in
another**: CPU, memory-family, disk and instance limits sit far above one regional
cluster plus Cloud SQL, but `IN_USE_ADDRESSES` and `STATIC_ADDRESSES` are both **8**,
the tightest constraint on this project and the one to watch during an attempt — an
ingress `LoadBalancer`, a Cloud NAT gateway and any reserved address all draw on it.
Exhausting them is a quota request, not a defect.

The table below remains the *conceptual* list to walk per attempt; the numbers above
satisfy the "read them first" step, not the per-attempt validation.

| Area | Qualification check |
| --- | --- |
| GKE | regional cluster/control-plane limits; Standard node count; Pods; total/SSD persistent-disk capacity |
| Compute | regional CPUs for the chosen machine family; instance groups; routes; forwarding rules; regional/static addresses; health checks; backend services |
| Network | VPCs, subnets, alias IP ranges, routers, Cloud NAT gateways/IPs, firewall rules, private-service-access peering ranges |
| Storage | GCS buckets and request quotas; regional persistent-disk capacity and snapshots |
| Load balancer | forwarding rules, target proxies, URL maps, backend services, health checks, and external IPv4 addresses |
| Cloud SQL | regional instances, CPUs, SSD storage, connections, and private-service networking |
| Artifact Registry | repositories and storage/request quota |

Current hard blockers are unlinked billing, disabled APIs, unread quotas, and
the Sol implementation gaps listed above. A new project may also start with
low CPU/address quotas; do not treat a successful API enable as capacity proof.

### Artifact Registry prerequisites

Required: billing, Artifact Registry API, a regional Docker repository, a
publisher with repository-scoped `roles/artifactregistry.writer`, and a pull
identity with `roles/artifactregistry.reader` if same-project GKE defaults do
not already cover the selected node identity. CI should authenticate through
Workload Identity Federation and service-account impersonation; interactive
qualification may use a short-lived gcloud access token or credential helper.
No JSON service-account key is needed.

Sol must continue deploying immutable digests. Repository creation/lifecycle is
provisioner authority; pushing or replacing image content is publisher
authority.

### DNS and TLS prerequisites

GCP does not require Cloud DNS if an existing provider can create records for
the chosen base domain. When qualification includes a workload with
`ingress_host` and TLS issuance, Sol requires:

- control of a qualification subdomain;
- either delegated Cloud DNS nameservers or an external DNS operator;
- an A/AAAA or CNAME record strategy from application/wildcard names to the
  ingress load-balancer address; and
- a publicly resolvable hostname and Let's Encrypt contact email for the
  cert-manager `ClusterIssuer` path; and
- replacement of the current Route 53 DNS-01 solver with a qualified Cloud DNS
  solver and scoped workload identity, or a solver for the chosen external DNS
  provider.

No zone, delegation, record, or certificate was changed. Zone creation alone
is insufficient: registrar delegation and ingress records remain explicit
operator prerequisites. Google-managed certificates are not an automatic
replacement for Sol's current cert-manager contract.

**External input identified (2026-09-22).** The owner controls **`sol-fab.dev`**,
so the "control of a qualification subdomain" prerequisite above can be met rather
than remaining blocked. `DEC-042` now **decides** the shape: a **dedicated
per-cloud subdomain delegated as its own DNS zone** — `qual-gcp.sol-fab.dev` for
this profile, with `qual-aws.sol-fab.dev` reserved for AWS if that profile ever
requires the same capability — created by Sol's cloud root rather than by hand, with
the ACME staging directory qualified before a single production issuance. The
product's own names — the apex and every name it serves — are not delegated and stay
outside the qualification project's authority; deleting the NS records revokes the
whole grant. This is one HARDEN-004 row (public TLS issuance); the identity/authority
rows and reaching `Ready` do not depend on it.

**The delegation requirement is symmetric; only the qualification scope is not.**
Any profile that must prove public DNS → ACME → TLS needs to control a real zone, on
Cloud DNS or Route 53 alike. The AWS profile does not carry that row (its matrix's
I14 states `Ready` does not require an external ACME round trip) and Sol's AWS cloud
root already offers the identical opt-in zone and registrar hand-off
(`create_route53_zone` / `route53_nameservers` / `cert_manager_irsa_arn`, with a
Route 53 DNS-01 solver), so nothing needs building for it — the reservation is a name
and a delegation, not a design. What is genuinely GCP-only is the missing **solver**
(`FND-0007`).

**Operator runbook once `DEC-042` is accepted (drafted 2026-09-22).** The exact
nameservers are **assigned by GCP when the zone is created** — they cannot be
known in advance. Any `ns-cloud-a1…a4.googledomains.com` in an example is
illustrative: the letter/number vary per zone, so they must be read from the
zone, not assumed. The order is therefore fixed:

1. **Create the zone — with Sol, not by hand.** `dns.googleapis.com` is already
   enabled in `sol-qualification` (verified 2026-09-22), and the zone is declared in
   the cloud root (`google_dns_managed_zone.main`, gated on `create_dns_zone`), so
   the zone is created by the cloud bootstrap:
   `sol cloud apply … --var create_dns_zone=true --var base_domain=qual-gcp.sol-fab.dev`.
   Running `gcloud dns managed-zones create` instead would place the zone outside
   Terraform state and collide with the product's own declaration of the same DNS
   name on the next apply.
2. **Read its nameservers.** `terraform output dns_nameservers` on the cloud root,
   or `gcloud dns managed-zones describe <zone> --format='value(nameServers)'` (or
   the console's zone detail page). There are four; copy them exactly.
3. **Delegate at the registrar — four `NS` records**, name `qual-gcp`, data = the
   four nameservers from step 2. At Squarespace the Name field takes the label
   only (`qual-gcp`) and the domain is appended automatically; entering
   `qual-gcp.sol-fab.dev` would produce `qual-gcp.sol-fab.dev.sol-fab.dev`. TTL of
   1h keeps the initial propagation quick. **Add nothing else under `qual-gcp` at the
   registrar:** once delegated, every name below `qual-gcp.sol-fab.dev` — wildcard
   included — is answered by the Cloud DNS zone, so a record there would be
   ignored at best and confusing at worst.
4. **Verify the delegation.** `dig NS qual-gcp.sol-fab.dev +short` from a public
   resolver returns the four nameservers, and
   `dig NS qual-gcp.sol-fab.dev @<parent-nameserver>` shows the hand-off from the
   authoritative parent.
5. **Then the child-zone records and the solver.** The application/`*` A or
   CNAME to the ingress address live **in the Cloud DNS zone** (the "ingress
   records remain explicit operator prerequisites" gap above), and the
   cert-manager Cloud DNS solver is built against the zone with its scoped
   identity.

Two caveats. If the parent zone (`sol-fab.dev`) is **DNSSEC-signed**, the
delegation also needs a matching **DS record** for the child zone (Cloud DNS
publishes the child DNSKEY); if the registrar cannot hold a subdomain DS, either
turn off parent DNSSEC or record the delegation as insecure deliberately. And a
Cloud DNS zone is a **persistent, minimally-billable** resource (~$0.20/month
plus queries) — small, but unlike the rest of a torn-down target it does not
reach `Absent` on destroy unless the zone is removed too.

**That persistence is a requirement, not a side effect.** Because the four
nameservers are copied into a parent zone no API can update (Squarespace), a zone
that is destroyed and recreated comes back with *different* nameservers, and the
pasted delegation silently points at a zone that no longer exists — the resulting TLS
failure names nothing close to the cause. So the delegated zone is a standing
prerequisite that must outlive target teardown; if it is ever removed, the delegation
must be redone by hand before the next issuance, and the run record should say so.

### GKE Workload Identity Federation prerequisites

Workload Identity Federation for GKE is always enabled on Autopilot. If the
production contract selects GKE Standard for fixed capacity/headroom, enable it
on the cluster and node pools. In either mode:

- enable IAM Service Account Credentials;
- grant each Kubernetes service account only the target API permissions it
  needs, preferably directly to its workload principal;
- use a linked Google service account only where an API/tool requires service
  account semantics; and
- preserve Sol's default of no ambient Kubernetes token for workloads that do
  not need Kubernetes API access.

The existing GCP root's Loki/Thanos service-account bindings are a valid
starting mechanism, but they are not complete until the platform charts use
GCS and the live workload principal is verified.

### Organization policies and project constraints

Project ancestry returned only the project. The Organization Policy API is
disabled, so effective constraints could not be enumerated without mutation.
Before provisioning, enable/read it with approval and check at least service
account key creation, allowed regions, external IPs, VPC peering, public load
balancers, uniform bucket access, domain-restricted sharing, and required CMEK.

The proposed design already avoids service-account keys. Any stronger policy
must be treated as an input to Terraform/preflight, not bypassed.

## Three kinds of prerequisite

### Objectively required by GCP

- linked billing for billable services;
- enabled service APIs;
- sufficient regional/global quota;
- non-overlapping VPC, Pod, Service, control-plane, and private-service-access
  CIDRs;
- IAM permissions to create/use each resource and impersonated identity;
- GKE authentication plus Kubernetes authorization;
- Artifact Registry authentication/authorization; and
- DNS authority only if the chosen implementation uses Cloud DNS.

### Required by Sol's current production contract

- encrypted, versioned, locked remote Terraform state recoverable by a clean
  runner, with separate cloud and platform state objects;
- named, scoped provisioner, publisher, deployer, and operator semantic
  authorities distinct from a standing cluster-creator admin;
- qualified capacity and explicit node-failure headroom when a workload selects
  the `node-failure-tolerant` tier;
- a privileged platform-install window through verified readiness, followed by
  a non-escalatable steady-state provisioner;
- Cloud SQL regional HA, PITR, deletion protection during `Ready`, and a
  rehearsed restore path when Postgres is used; the live guarantee requires
  Cloud SQL's API-level deletion protection, not only Terraform's provider-side
  `deletion_protection` guard;
- immutable image digests;
- cert-manager, ingress, storage, Redpanda, Argo CD, and observability readiness
  predicates equivalent to the qualified AWS contract;
- control of a qualification hostname, DNS reachability, and public CA issuance
  when qualifying a workload's public-ingress/cert-manager capability;
- a configured and actually delivered/acknowledged alert receiver; and
- resumable destruction from every phase that may contain infrastructure.

### AWS assumptions not to carry into GCP

- four AWS roles mapping one-to-one to four Google service accounts;
- ARN, STS AssumeRole, IRSA, EKS access-entry, or managed EKS access-policy
  vocabulary;
- S3 plus DynamoDB for state locking;
- ECR repository/login mechanics;
- Route 53 ownership of DNS;
- EBS CSI and a `gp3` StorageClass;
- ALB hostname behavior;
- RDS final-snapshot mechanics or identifier rules;
- CloudWatch dashboards as the managed-resource observability contract; and
- EKS managed-node-group/AZ behavior as proof that GKE Autopilot or Standard
  satisfies Sol capacity and failure tests.

## Proposed GCP capability mapping

Do not create a generic identity abstraction or force the AWS count. Preserve
semantic boundaries and use the fewest principals that enforce them.

| Sol capability | Proposed GCP implementation |
| --- | --- |
| Bootstrap authority | Temporary human/group authority for approved project bootstrap. The current Owner can serve for qualification, then becomes break-glass rather than the routine operator credential. No standing cluster admin. |
| Operator authority | Bounded identity for supported day-to-day operations, with impersonation only of a dedicated operator service account if one is needed. Destructive lifecycle approval uses the separate bootstrap/destroy authority. GCP IAM cannot restrict Token Creator to a Sol command or phase, so anyone allowed to impersonate a stronger identity is honestly treated as holding that identity's full authority. |
| Provisioner | One user-managed service account impersonated only by approved bootstrap/provisioning automation. Give it the minimum GCP roles for the cloud root and explicit Kubernetes RBAC for the platform root. Temporarily grant installation authority only during `PlatformInstalling`/`PlatformUpdating`; revoke and verify it before `Ready`. Splitting cloud and platform provisioners is unnecessary until trust owners differ. |
| Publisher | Repository-scoped service account with Artifact Registry writer only. CI obtains it through external Workload Identity Federation; humans may impersonate it for qualification. |
| Deployer | Identity authorized to fetch GKE credentials plus Sol's namespace-scoped deploy RBAC, but unable to push images or provision infrastructure. CI may use the same external identity provider as publisher while impersonating a different service account for each operation. |
| Workload identity | Workload Identity Federation for GKE, direct principal IAM grants where supported; linked Google service accounts only for APIs/tools requiring them. |
| Remote Terraform state | Dedicated GCS bucket with uniform access, versioning, encryption, public-access prevention, and native backend locking. Use deterministic `sol/<target>/cloud.tfstate` and `sol/<target>/platform.tfstate` prefixes. Bootstrap state remains the unavoidable separate bootstrap boundary. |
| Kubernetes access | Ephemeral kubeconfig from `gcloud container clusters get-credentials`, isolated per phase. GKE evaluates RBAC first and Google IAM as a fallback, so the provisioner's custom IAM role is deliberately limited to cluster discovery, credential retrieval, and control-plane connection; scoped Kubernetes-object authority comes from RBAC. Never use ambient kubeconfig. |
| Database | Private-IP Cloud SQL for PostgreSQL 16, regional HA, PITR/backups, API-level `settings.deletion_protection_enabled` in `Ready`, and an explicit destroy preparation. Terraform's top-level `deletion_protection` is a useful second guard but is not the live GCP protection predicate. Keep credentials out of plans/logs; choose password rotation or IAM database authentication deliberately during implementation. |
| Registry | Regional Artifact Registry Docker repository, digest deployment, repository-scoped writer/reader permissions. |
| DNS/TLS | Conditional on workloads declaring `ingress_host`. Use Cloud DNS only when Sol is delegated the qualification zone; otherwise consume operator-managed records. Keep ingress-nginx plus cert-manager/ACME for contract parity, but replace the hard-coded Route 53 DNS-01 solver with Cloud DNS plus a scoped GKE workload identity, or with the selected external provider's qualified solver before TLS capability qualification. **Delegation decided (2026-09-22, `DEC-042`):** `qual-gcp.sol-fab.dev` as its own Cloud DNS zone in `sol-qualification`, created by Sol's cloud root (`create_dns_zone`), delegated from the Squarespace-managed parent by hand, with a scoped cert-manager identity and staging before production issuance. `qual-aws.sol-fab.dev` is reserved for the AWS profile if it ever requires the same capability — the delegation requirement is a property of proving ACME, not of GCP. |
| Observability/storage | GKE persistent disks through a GCP StorageClass; GCS for durable Loki/Thanos after completing the existing chart wiring; Cloud Logging/Monitoring for GCP/GKE control-plane signals, not as an unqualified replacement for Sol's platform observability. |

GCS backend locking is native; do not add a lock database. Terraform remains
authoritative for its own resources and dependency graph. Sol only sequences
the two roots, validates their typed outputs, applies phase policy, and verifies
live postconditions.

## Provider-neutral lifecycle on GCP

Every operation re-derives progress from Terraform state and live GCP/GKE
observations. No persisted Sol phase pointer and no second resource-level DAG
is introduced.

| Transition | Required authority | GCP mechanism | Preconditions | Verified postconditions | Recovery/idempotency |
| --- | --- | --- | --- | --- | --- |
| `Absent -> CloudBootstrap` | approved bootstrap authority using user ADC | enable the approved API set; create GCS state facility and scoped identities/WIF; then use impersonation | correct project/number; billing already linked by an authorized account operator; no conflicting resources; readable constraints; no service-account keys | remote state is versioned/encrypted/locked; identities can be impersonated; required APIs and quota are present | bootstrap resources have deterministic names and import/reconcile cleanly; re-run observes existing state rather than recreating it |
| `CloudBootstrap -> PlatformInstalling` | impersonated provisioner plus temporary installation authority | cloud-root Terraform creates VPC/private service access, GKE, Artifact Registry, Cloud SQL, storage and optional DNS; Sol reads typed outputs, writes an ephemeral kubeconfig, and opens the bounded privileged install window | initialized cloud state; valid CIDRs/quotas; required secrets and DNS decision; provider output contract | cloud root applies; GKE/API reachable as the named provisioner; database/registry/network outputs validate; install authority is effective | re-run the same cloud root; Terraform reconciles partial resources; later platform plan remains `Deferred` until outputs/access exist |
| `PlatformInstalling -> Ready` | provisioner with temporary cluster-install privilege | staged platform-root Terraform: cert-manager first, verify CRDs, then remaining charts/RBAC/storage; revoke installation grant after live readiness | cluster reachable; cloud outputs valid; platform backend initialized | Kubernetes-native convergence passes; ingress has an address; GCP StorageClass works; bounded provisioner positive permissions pass and `escalate`/`bind` fail; temporary privilege is gone. External ACME/issuer readiness does not gate this transition; actual TLS issuance is qualified separately when used. | repeat incomplete Terraform stages and readiness checks; do not de-escalate early; failed install remains destructible |
| `Ready -> PreparingDestroy` | approved bootstrap/destroy authority impersonating the provisioner | apply Destroy policy through Terraform: disable both Cloud SQL API-level and Terraform-side deletion protection; establish final-backup behavior; explicitly retain/adopt or empty and unprotect durable telemetry buckets; stop applying Production policy | target may be Ready or any infrastructure-bearing partial phase; backend/state accessible; retention/destruction choice approved | Cloud SQL API protection is observably disabled; bucket retention/unprotect state is verified; final-backup inputs are valid if required; no subsequent Ready policy runs | safe to repeat; an interrupted preparation remains in Destroy policy and resumes destruction; `PreparingDestroy -> Ready` is illegal |
| `PreparingDestroy -> Destroying` | bootstrap/destroy authority | destroy platform root, then cloud root, in reverse semantic dependency order | preparation verified; state locks obtainable; durable buckets are either adopted outside the target root or explicitly empty/unprotected; no Ready reconciliation | platform resources absent before GKE/network dependencies; cloud destruction underway/complete; retained backups/storage/state are reported | repeat `terraform destroy`; missing resources are no-ops; refresh/import repair handles drift; never hand-build a resource deletion DAG in Sol |
| `Destroying -> Absent` | destroy authority for verification; state operator for approved cleanup policy | live absence checks for GKE, SQL, registry, network/LB/storage/DNS resources; retain or separately retire the bootstrap/state facility per policy | both root destroys completed or are resumable | all target-owned runtime resources absent; no temporary IAM/install grants; retained state/backups are named; destroy of an already absent target succeeds | re-run verification/destroy until absent; keep state versions for recovery/audit; bootstrap facility cleanup is a separate explicit operation |

Destruction remains an abort edge from `CloudBootstrap`,
`PlatformInstalling`, `Ready`, and any interrupted destroy phase. A privileged
platform update after `Ready` similarly uses the existing provider-neutral
`PlatformUpdating` re-entry even though it is not part of the abbreviated
qualification sequence above.

## Approval gates before implementation

1. Link billing and confirm the bootstrap operator can use the selected billing
   account.
2. Approve the minimum API list, then repeat inventory, effective-policy, and
   quota checks.
3. For qualification of `node-failure-tolerant`, choose GKE Standard or define
   and prove how Autopilot supplies the contract's declared failure headroom;
   the current root provides no such evidence.
4. Supply a qualification subdomain/delegation strategy and Let's Encrypt
   contact without changing DNS yet; select and wire a non-Route-53 cert-manager
   solver before qualifying a workload that uses public TLS.
5. Decide Cloud SQL credential handling and destroy/final-backup semantics.
6. Decide whether durable telemetry buckets are retained or explicitly emptied
   during approved destruction; the current `prevent_destroy = true` resources
   cannot participate in a complete target destroy as written.
7. Implement the GCP cloud output contract and GCS observability/storage wiring,
   then qualify through the public `sol cloud` lifecycle rather than a shadow
   Terraform/Helm harness.

## Implementation progress

**Updated:** 2026-09-18 (America/Denver). Read-only re-check of the bootstrap
prerequisites. No resource, API, IAM, billing, DNS, or infrastructure change was
made or left behind.

### Preflight re-check

| Check | Observed | Verdict |
| --- | --- | --- |
| Active principal | `lbendtlynielsen@gmail.com` | unchanged |
| Active project | `sol-qualification`, number matches the supplied value | unchanged, `ACTIVE` |
| Billing linked | `billingEnabled = false`, `billingAccountName` empty | **blocked** |
| Enabled APIs | the same 22 services listed above, byte for byte | unchanged |
| Project IAM | one binding: `user:LBendtlyNielsen@gmail.com` → `roles/owner` | unchanged |
| User-managed service accounts, GCS buckets | none | unchanged |
| Long-lived service-account keys | none created or downloaded | required posture held |

Two billing accounts are visible to this principal, one open and one closed. The
open one is the candidate; neither is named here, for the same reason the rest of
this file names no account-level identifier.

**The blocker is stronger than the original inventory implied, and that changes
what "prerequisite" means here.** Unlinked billing does not merely block the
billable qualification resources — it blocks the *bootstrap* step:

```text
ERROR: (gcloud.services.enable) FAILED_PRECONDITION: Billing account for project
'<project-number>' is not found. Billing must be enabled for activation of
service(s) 'artifactregistry.googleapis.com, compute.googleapis.com,
container.googleapis.com, dns.googleapis.com,
containerregistry.googleapis.com' to proceed.
  reason: UREQ_PROJECT_BILLING_NOT_FOUND
```

So the API-enable step in the lifecycle table (`Absent -> CloudBootstrap`) is
itself gated, and the "repeat all resource queries before the first Terraform
plan" instruction above is not reachable. Quota, capacity, and the inventories
that need Compute/GKE/Cloud SQL/DNS APIs stay **unknown**, not empty. The refused
enable left the project untouched — the enabled-service list is identical to the
one recorded above.

**Action required, and only this: link an open billing account to
`sol-qualification`.** That is an account-level relationship outside Sol's
project-scoped bootstrap authority, and this work is not authorized to change it.
Everything else in the preflight is ready: principal, project, ADC, Terraform, and
the Owner binding that can create the qualification-scoped identities and
resources. Once billing is linked, the next attempt resumes at the API-enable
step.

### Code landed without a live project

Four changes bear on this work. One of them — the destroy invariant — landed as
INFRA-037 / ADR 0004 rather than here. All four are validated offline only:
static/configuration and mechanism/renderability evidence, not behavioural
evidence. None is reachable on GCP yet, because the GCP lifecycle still fails
closed in `sol cloud`.

- **Provider-specific Kubernetes storage and readiness.** `Ready` asserted `gp3`
  and `ebs.csi.aws.com` literally in a module that is meant to be
  provider-neutral. The provider's storage facts are now data
  (`Sol_cli_cloud_lifecycle.platform_storage`), the check asserts the provider's
  class is the *sole* default and is backed by the provider's block-storage CSI
  driver, and the AWS guarantee is unchanged. EKS ships no default class so Sol
  creates one; GKE ships `standard-rwo` already defaulted, so Sol adopts it —
  creating a second default class would leave the cluster with two, which
  Kubernetes resolves arbitrarily.
- **Provider-selected remote state and platform roots.** `backend_config` is
  provider-aware (S3 + DynamoDB locking, GCS with native locking), the cloud
  target no longer requires an AWS role ARN of a GCP target, and
  `platform/cloud/gcp/platform` is a GCP platform root declaring the GCS backend
  and calling the shared platform definition as a module.
- **A disposable target must be able to reach `Absent`** — landed independently as
  INFRA-037 / **ADR 0004**, and deliberately *not* duplicated here. `prevent_destroy`
  is gone from both providers' durable telemetry buckets, the ECR repositories take
  `force_delete`, and `internal/ci/check_destroy_completeness.py` asserts the rule
  rather than the resources that violated it. GCP inherits the invariant concretely
  (the same two buckets) instead of the AWS spelling of it. The retention toggle —
  whether `sol cloud destroy` discards a target's telemetry by default — is
  deliberately left undecided by that change, and a branch here that had decided it
  by accident (a `durable_storage_force_destroy` variable defaulting to `false` and
  set `true` by the Destroy policy) was **withdrawn rather than merged** for exactly
  that reason.

- **GCP's own output and input contract.** `gcp_outputs` and `gcp_outputs_of_json`
  are a separate type rather than a relabelled `aws_outputs`, because the two
  providers publish different facts: a GCP root names the project and region that
  address every API call *and* derive the cluster credential, and names no role
  ARN, because a caller there impersonates a service account through short-lived
  credentials. `cloud_outputs` is what the lifecycle carries, and
  `platform_terraform_vars` emits only the target provider's own variable set — an
  AWS variable handed to the GCP root is an undeclared-variable error, not a
  no-op. The mapping is fallible by design: a GCP target that declares
  `cluster_issuer` is refused with the missing solver named (gap 1), rather than
  being given a platform whose issuers cannot issue.

The Destroy policy became provider-shaped in the same change, and that part is
*not* covered by ADR 0004. It was returning `rds_deletion_protection`,
`rds_skip_final_snapshot` and `rds_final_snapshot_identifier` for *every* provider,
which the GCP root does not declare — so a GCP destroy would have failed on an
undeclared variable the moment the GCP path opened. The neutral part is that a
Destroy policy exists and the phase names it; the levers are the provider's, and
GCP's are still unimplemented (gap 4).

### Structural finding: a Terraform root cannot carry two backends

This is the first case where the provider-neutral model had to change rather than
gain a branch. A backend's *type* is part of a Terraform root's own
configuration — `-backend-config` sets attributes, never the type — so a single
platform root cannot serve S3 state for AWS and GCS state for GCP. The
resolutions considered:

1. **Per-provider roots over a shared definition** (chosen). The definition stays
   where it is and each provider's root supplies only what a root can. A module's
   own `terraform` block is ignored with a warning, which is what makes this work
   without moving 1,500 lines.
2. **Extract the definition into its own module** and make both providers' roots
   thin wrappers. Cleaner and symmetric, but it changes every AWS resource address
   (`module.platform.*`) on a path that is live-qualified — churn without evidence
   to justify it today. This remains the better long-term shape and is the natural
   follow-up once the GCP path is qualified.
3. **One backend type for both providers.** Rejected: it would change AWS's state
   contract (S3 + DynamoDB locking is a named requirement) to accommodate GCP.
4. **S3-compatible access to GCS** (`endpoints { s3 = ... }` plus HMAC keys).
   Rejected: it requires long-lived credentials, which the posture above forbids.

The mirroring in option 1 introduces one liability — a variable added to the
definition and forgotten in the GCP root — so
`internal/ci/check_production_infra.py` now fails if the wrapper does not mirror
every declared variable except the AWS-only ones, and fails if it declares one the
definition does not.

### Reconciliation onto post-#351/#353/#354 main, and the destroy investigation

Attempt 1's branch was re-applied rather than rebased mechanically, because three
parallel changes landed in the same places: INFRA-039 (#351, credentials resolved per
mutating stage), DEC-033 (#353, destruction states what it keeps) and HARDEN-003
(#354, evidence identity). What current main means, and how GCP implements it:

- **Credential resolution is a per-mutating-stage guarantee, and it applies to GCP.**
  INFRA-039 implemented it for AWS through `aws configure export-credentials`. On GCP
  the credential is Application Default Credentials, resolved through
  `gcloud auth application-default print-access-token` before each mutating stage —
  including the same failure message, because the reasoning is identical: a destroy
  that cannot authenticate leaves billable infrastructure standing *and* disables the
  only supported path to remove it. Plan remains read-only.
- **Deletion protection, retention and preparation are three things**, and the
  reconciliation keeps them apart rather than letting them collapse into one
  `force_destroy`-shaped concept:

  | | what it is | AWS | GCP |
  |---|---|---|---|
  | deletion protection | a safety guard on a resource that exists | `rds_deletion_protection` | `sql_deletion_protection`, **`gke_deletion_protection`** |
  | retention (DEC-033) | what a destroy deliberately keeps | final snapshot | **not expressible yet** |
  | preparation | the applied, verified transition that makes destruction legal | targeted apply on the RDS resource | targeted apply on both guarded resources |

  Because GCP cannot express retention — Cloud SQL deletes its backups with the
  instance — a GCP target whose `destroy_retention` is the `final-snapshot` **default**
  is refused rather than destroyed, and a disposable target opts in with
  `destroy_retention: none`. Letting the default quietly become "discard the recovery
  data anyway" is the laundering DEC-033 exists to prevent, so Sol asks instead of
  deciding.

**Two gaps in DEC-033 itself, both found while doing this:**

1. **The setting never reached a target.** `merge_target` was not extended, so
   `destroy_retention` was dropped on the only path a real target is resolved
   through: `{ a with ... }` keeps the *base*'s value and discards the target file's.
   A target saying `destroy_retention: none` was silently ignored and every destroy
   took the production default. DEC-033's tests build `target_empty` directly and so
   never crossed the merge. Fixed, with a test that crosses it on purpose.
2. **The report was never called.** `retention_report` and its tests existed, and
   nothing invoked it — so the decision reached the Destroy policy and never reached
   the operator. Wired into the destroy, for both providers.

### The service-networking destruction failure: what it actually was

Attempt 1's teardown could not reach `Absent` through the lifecycle, and the first
question is whether that was a modelling error or a temporal one. The log answers it:

```text
google_sql_database_instance.postgres: Destruction complete after 2m2s
google_service_networking_connection.sql: Destroying...
google_service_networking_connection.sql: Still destroying... 20s
Error: Unable to remove Service Networking Connection ... Producer services
       (e.g. CloudSQL, Cloud Memstore, etc.) are still using this connection.
```

**The graph was right.** The instance is a dependent of the peering, so reverse order
destroys it first, and the log shows exactly that. What GCP requires is a *wait*
between the two: it releases the servicenetworking producer reference asynchronously,
after the instance's delete reports complete. Terraform orders operations; it cannot
express a wait between them through an ordinary dependency, and a wait is what the
provider demands.

So the fix is in the graph, not in Sol: a `time_sleep` the instance depends on and the
peering is a dependency of, which on destroy becomes instance → *wait* → peering.
Hand-rolling "delete Cloud SQL, wait, delete the peering" in `sol cloud destroy` would
be Sol reimplementing the DAG it delegates to Terraform.

The window is a variable, not a constant, because the number is the part a live
observation should correct: GCP does not document it, and Attempt 1 measured only that
~2.5 minutes after the instance's delete was still too early. Default 300s, to be
measured in Attempt 2.

Two further defects from the same teardown, both fixed: the reconciliation apply was
not inside a run phase and `require_terraform_success` exited **silently**, so the
failure's terraform output existed nowhere and the reason had to be reconstructed by
hand — it now prints, and the apply is a recorded stage like every other.

### Attempt 2 (2026-09-19): scoped authority, and where it stopped

Attempt 2 ran from a fresh disposable target against the merged scoped-authority
work. **The cloud layer applied in 600.9s with the install window open on the cloud
root** (`-var=provisioner_bootstrap_admin=true`), creating GKE, Cloud SQL, Artifact
Registry, Cloud DNS, NAT and — for the first time — the provisioner service account
and its temporary cluster-admin binding. Sol then reported GKE `RUNNING` and Cloud
SQL `RUNNABLE`.

It stopped immediately afterwards, at cluster access, and that failure is two
distinct defects:

1. **`--kubeconfig` does not exist on `gcloud container clusters get-credentials`.**
   Sol passed it, so access died at argument parsing with
   `unrecognized arguments: --kubeconfig`. gcloud writes the kubeconfig named by
   `$KUBECONFIG`, which Sol already exports for the child (its own help says so: "You
   can provide an alternate path by setting the KUBECONFIG environment variable").
2. **Impersonation was denied.** Reproduced by hand:
   `PERMISSION_DENIED: Failed to impersonate [sol-qual-provisioner@…].
   Permission 'iam.serviceAccounts.getAccessToken' denied`. The cloud root *created*
   the provisioner identity and nothing granted the bootstrap caller the right to
   **use** it — creating an identity is not the same as letting anyone enter the
   window, and without the grant the authority model cannot be entered at all.

**The harness could not have caught the first one, and that is the durable lesson.**
Its `gcloud` stub accepted the flag because it was written from the implementation.
A stub cannot falsify the interface it was modelled on, so "the harness passed"
was not evidence about gcloud. `internal/ci/check_gcloud_interface.sh` now asks the
real CLI: it matches every flag Sol passes against `gcloud <subcommand> --help`,
asserts the absent flag really is absent, and checks that the impersonation grant is
scoped to the named service account and the caller the target declares.

**Sol's documented destroy could not complete**, for the same reason: it lifted both
deletion guards by a targeted applied transition and verified them (21s — that part
is now qualified), ran the reconciliation apply, then failed at cluster access. So
Attempt 2's destruction path is **non-conformant**, recorded as a failure, and
cleanup finished through the documented emergency path.

**The `time_sleep` was the wrong mechanism, and Attempt 2 measured it.** It waited
its full five minutes and the peering *still* refused, and it still refused twenty
minutes later on manual retries. What releases the peering is deleting the *network*,
which the same root owns and the same destroy deletes — so the correct reading was
never "the window is longer than 300 seconds", it was "GCP will not delete this
object while a producer is registered at all". The connection is now abandoned
(`deletion_policy = "ABANDON"`) and `verify_gcp_destroy` asks the provider for the
peering *and* the network afterwards, because abandonment gives up Terraform's own
confirmation and that is only defensible against a check that can see the thing
being abandoned.

**Absence verified independently:** no GKE, no Cloud SQL, no target VPC/subnet/
router/NAT/address, no disk, no forwarding rule, no DNS zone, no Artifact Registry
repository, **no provisioner service account**. Remaining: the empty state bucket and
the project's automatic `default` network.

The fixes above are Now In Progress; the peering abandonment's destruction behaviour
remains **unqualified** until a live destroy observes both the connection and the
network absent.

### Attempt 3 (2026-09-19): the authority model worked; the host was missing a plugin

Attempt 3 is the first run under the *real* scoped authority model, and the first
two objectives are met:

- **CloudBootstrap applied in 574.1s** with the install window open on the cloud
  root, creating the provisioner service account, the impersonation grant for the
  caller the target declares, and the temporary cluster-admin binding.
- **Provisioner impersonation and ephemeral cluster access worked.** Sol obtained
  credentials as `sol-qual-provisioner@…` and reached the cluster: the platform
  stage's first API call is logged against the GKE endpoint
  (`Post "https://34.44.114.57/apis/rbac.authorization.k8s.io/v1/clusterroles"`).
  That is a real transition from "the authority model is written" to "the authority
  model is entered", which is what §"scoped authority" above could only claim
  statically.
- **The window was revoked on the failure path** (`provisioner-bootstrap-access-remove`
  ok in 8.7s), which is the first observation that the close half works too.

**First meaningful failure:** `exec: executable gke-gcloud-auth-plugin not found`.
The kubeconfig gcloud writes names `gke-gcloud-auth-plugin` as its client-go exec
credential plugin, and the host did not have it — so every Kubernetes call fails,
including the platform apply. Two things are wrong with that as a product:

1. it is a **host prerequisite in the same class as terraform**, and it was
   discovered *inside* the platform apply — after GKE and Cloud SQL were
   provisioned and billable. Sol now checks it before the first platform call and
   fails closed naming the plugin and the command to install it.
2. the failure was only reachable because the platform work starts after a
   multi-minute apply that cannot help but be paid for. The check costs nothing
   and runs before the first platform call.

**Second finding, filed rather than fixed: a failed platform install is not
destroyable through the lifecycle.** Sol's documented destroy ran
(`gcp-destroy-prepare` ok, `PreparingDestroy`, reconciliation apply ok) and then
`platform-destroy` failed with `API did not recognize GroupVersionKind from
manifest (CRD may not be installed)` — the platform root's state referenced
CRD-backed resources whose CRDs were never installed, because the install never got
that far. So a partially-installed platform cannot be destroyed by the documented
path, which is the ADR 0004 invariant reached through a third mechanism (not
`prevent_destroy`, not a provider default, but a resource whose API does not
exist). The install window was still revoked, and the cloud layer was removed by
the documented emergency path.

**Absence verified by the provider API, not by Terraform's exit status** — which is
the specific requirement Attempt 3 was also meant to settle:

| checked | result |
|---|---|
| GKE cluster | absent |
| Cloud SQL instance | absent |
| target VPC network (`sol-qual`) | absent |
| **service-networking peering on that network** | **absent** |
| reserved peering address | absent |
| subnet / router / NAT | absent |
| provisioner service account | absent |
| platform Terraform state | empty (0 resources) |

**The peering abandonment is now behaviourally qualified for one observation.** The
destroy completed in 6m14s with exit 0, the connection's removal took 0s (it was
abandoned, not deleted), and deleting the network is what removed the peering —
which the API confirms independently. This establishes *that attempt* reached
Absent; it does not establish an upper bound on GCP's producer-reference release
behaviour, and the `deletion_policy = "ABANDON"` trade remains: Terraform no longer
confirms the peering is gone, so `verify_gcp_destroy` must (`gcloud services
vpc-peerings list` for the network, plus the network itself).

### INFRA-042: destroying a partially installed platform

Attempt 3's install failed partway, and the documented destroy could not finish:
Terraform cannot delete a resource whose API does not exist, and the platform root's
state held the two cert-manager `kubernetes_manifest` ClusterIssuers while their
CRDs had never been installed. The cloud layer behind it stayed billable, and the
teardown finished through the emergency path — which is what INFRA-042 is about,
because a *failed* install is the state a target is most likely to be in.

The fix attempts Terraform's destroy first, in full, with its own ownership and
ordering, and only on failure considers which state entries cannot correspond to an
object. The proof is the cluster's own discovery, and it is deliberately narrow:

- only `kubernetes_manifest`, whose stored manifest states its kind verbatim.
  Native `kubernetes_*` resources are not handled, because deriving their kind means
  mapping a Terraform type to a Kubernetes kind by convention — and a mapping wrong
  in the wrong direction forgets a resource that exists;
- only when the cluster does not serve that kind with `delete`. A served kind means a
  resource that may exist, so nothing is forgotten, the destroy is retried, and a
  second failure is the failure.

Each forgotten address is printed with the kind that proved it absent. The offline
harness reproduces Attempt 3 exactly — the missing-CRD failure, the recovery, the
retry, and the completion — and pins the limit in the other direction: with the CRD
served, no `state rm` happens and the destroy fails closed. Both directions are
mutation-tested.

### Attempt 4 (2026-09-19): the platform stage runs as the provisioner, and stops at cert-manager

The primary objective is met, and then some.

- **CloudBootstrap applied in 571.2s** with the install window open, and — for the
  first time — the impersonation grant for the *declared* caller reached the root:
  `-var=provisioner_impersonators=["user:…"]`.
- **The platform stage ran as the provisioner for 424.2s.** This is the transition
  Attempts 2 and 3 could not make: real in-cluster work — namespaces, CRDs, RBAC —
  performed by the scoped identity, authenticated by impersonation.
- **The window was revoked** (`provisioner-bootstrap-access-remove`, 8.1s), so the
  open/close pair is now observed on a run that actually did platform work.
- **The documented destroy completed the entire teardown**, including the partially
  installed platform: `platform-destroy ok (80.0s)`, then `terraform-destroy ok
  (342.6s)`, then verification. That is INFRA-042's scenario live, through the
  documented lifecycle, with no emergency cleanup.

**Next boundary: `helm_release.cert_manager` — "failed post-install: timed out
waiting for the condition".** The platform prerequisites apply stopped there. What
the cluster says is precise and matters for the fix: cert-manager itself is
**healthy** — `cert-manager`, `cert-manager-cainjector` and `cert-manager-webhook`
all `1/1 Running` for 9m, six CRDs installed — and the failure is the chart's
post-install **`startupapicheck` Job**, `Failed 0/1` after 7m49s with
`BackoffLimitExceeded` at 117s.

That distinction is worth keeping rather than acting on quickly. Disabling the
startup check would make the release succeed; it would also discard the one
signal that says whether the webhook is reachable, which is the thing certificate
issuance depends on. The next attempt should establish *why* the check fails (the
container's own output, not the Job's status) before deciding whether the fix is a
values override or a real GKE/Autopilot incompatibility.

**A defect in Sol's own absence verification, found by this run.** The destroy
removed everything and then reported failure:

```
error: GCP GKE cluster verification failed: ERROR: (gcloud.container.clusters.describe)
  ResponseError: code=404, message=Not found: projects/.../clusters/sol-qual
```

The check recognised `NOT_FOUND` and `was not found`; gcloud's actual answers are
`code=404 … Not found:` and `HTTPError 404: The Cloud SQL instance does not exist`.
It failed closed, which is the right instinct, but a check that cannot recognise
absence makes `Absent` unreachable — the postcondition the whole lifecycle is
measured against. Fixed, and the harness stub now answers with the **real** wording
rather than the wording the implementation happened to expect (the `--kubeconfig`
lesson applied to a stub of my own): with the old needles the harness fails, with
the provider's wording it passes.

**Absence verified independently** after that teardown: no GKE, no Cloud SQL, no
target network, **no service-networking peering**, no address, no disk, no
provisioner service account; only the project's default network and default service
account, and the empty state bucket. The peering abandonment worked again, and for
the second time the peering and the network were confirmed absent through the
provider's API rather than Terraform's exit status.

**TLS issuance remains BLOCKED**, not qualified: `sol-qual.dev` is not delegated to
the qualification project, so DNS-01 cannot complete. It becomes qualified only by a
delegated hostname, and Attempt 4 did not reach issuance in any case —
cert-manager's own release did not finish installing.

### Remaining gaps

Ordered by what unblocks the next one. **Closed items stay visible so the decision is
recorded — do not re-do them.** This list is the work list; the attempt narrative
above is the evidence behind it.

1. **The current frontier: `helm_release.cert_manager`'s post-install check**, and
   with it platform `Ready`. Attempt 4's prerequisites apply failed on
   `failed post-install: timed out waiting for the condition` while cert-manager
   itself was healthy; the failing object was the chart's `startupapicheck` Job
   (`BackoffLimitExceeded`). The next attempt establishes *why*, from the check
   container's own output, before deciding between a GCP-shaped values override and a
   real GKE/Autopilot incompatibility. Disabling the check is not the default answer:
   it is the only signal about webhook reachability, which issuance depends on.
2. **GCP cert-manager solver and Workload Identity wiring.** The shared definition's
   `ClusterIssuer`s are hard-wired to the Route 53 DNS-01 solver. Needs a Cloud DNS
   solver plus scoped Workload Identity — built **when the frontier reaches them**,
   not before. A real TLS qualification is additionally blocked on a delegated
   qualification hostname; until this lands, a GCP target declaring `cluster_issuer`
   is refused by name rather than handed an issuer that cannot work.
3. **Cloud SQL regional HA for the production profile**, and the production profile's
   capacity contract proven on the selected GKE mode (the current root is Autopilot,
   which cannot declare the `node-failure-tolerant` headroom).
4. **GCS durable-observability chart wiring** — the Loki/Thanos values are still
   S3-shaped and `OBS-034`'s gate still rejects `gcp + self_hosted_durable`
   (INFRA-005).
5. **(Closed) Provider-neutral `sol cloud` plan/apply/destroy for GCP.** Closed by
   #355/#356/#358: the provider gate is gone, GCP runs the real phases, cluster
   access is `gcloud get-credentials` with declared impersonation, the
   `PlatformInstalling` window opens on the cloud root and is revoked, and platform
   targets address `module.platform.*`.
6. **(Closed) GCP destruction preparation and the undeletability invariant.** Closed
   by #355/#358 and ADR 0004: both guards (Cloud SQL's and the GKE cluster's
   provider-default one) are lifted by a targeted applied transition that is then
   verified, `check_destroy_completeness.py` enforces "a routed guard must be
   liftable by the Destroy policy", and the peering is abandoned rather than deleted
   because GCP will not delete it while a producer is registered. **Still unqualified
   for GCP: retention.** Sol refuses a GCP target whose `destroy_retention` is the
   `final-snapshot` default, because Cloud SQL destroys its backups with the instance
   and "closest available behaviour" would discard recovery data silently.
7. **(Closed) Offline qualification/preflight coverage and executable contract
   for the GCP path.** The
   lifecycle harness runs GCP plan and destroy against stubs that model the real
   tools, including the credential fail-closed path, the missing-toolchain refusal,
   and the INFRA-042 partial-install recovery with its fail-closed opposite.
   `gcp-production-single-region-v1-matrix.tsv` now carries one executable row per
   provider-neutral invariant. `internal/qualification/gcp/verify-matrix.sh`
   rejects incomplete, failing, unknown, duplicate, evidence-less, and weakly
   evidenced results; its mutation test pins those failure directions. Rows describe
   the contract even when the current GCP implementation cannot pass them.
8. **(Closed) Typed GCP cloud outputs and platform input mapping.** `gcp_outputs`,
   its parser and its platform variable set are provider-shaped, and `cloud_outputs`
   is the one thing the lifecycle carries; a capability the provider's root cannot
   wire is a refusal naming the gap.

## References

- [Terraform authentication on Google Cloud](https://cloud.google.com/docs/terraform/authentication)
- [Workload Identity Federation for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [Artifact Registry Docker authentication](https://cloud.google.com/artifact-registry/docs/docker/authentication)
- [Terraform GCS backend](https://developer.hashicorp.com/terraform/language/backend/gcs)
