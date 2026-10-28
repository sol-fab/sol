# The Sol developer experience

This document is the product's statement of the experience Sol is building
toward: what a first deployment feels like, what becomes routine, what stays the
user's responsibility, and where the open-source product ends. It is written for
someone deciding whether Sol is for them, and for an engineer deciding what to
build next.

It is a *contract of intent*, not a status report. Every capability below is
marked with where it stands today, so a reader is never told that something
planned already works. The decisions this document rests on are recorded in the OSS developer
experience contract) and `DEC-019` (the OSS/hosted boundary); the implementation
of anything marked **Target** is tracked by a ticket, listed in
[§ Where this is tracked](#where-this-is-tracked).

**Status key**

| Marker | Meaning |
|---|---|
| **Today** | Implemented and usable on current `main`. |
| **Partial** | Some of it exists; the linked ticket names the gap. |
| **Target** | Designed and agreed, not yet built. |

---

## 1. The promise

Deploying and operating a production backend should feel as simple as a modern
PaaS. The resulting infrastructure should remain yours — in your cloud account,
your registry, your database, your DNS — and should keep running whether or not
you continue to use Sol.

The abstraction Sol sells is **the factory, not the substrate**. Sol owns the
repeatable machinery around a backend — scaffolding, build conventions,
containerization, deployment-plan synthesis, provisioning, migrations,
observability wiring, release inspection and rollback — while the infrastructure
stays in the account you already pay for.

**Sol is not "easy Kubernetes" and not "easy Terraform".** A user should interact
with Sol concepts — workspaces, domains, services, workers, functions,
environments, targets — and should not need to understand the implementation
underneath for ordinary deployment and operations. Kubernetes and Terraform are
implementation details of the factory, not its user interface.

> **What Sol does not remove.** Sol removes the need to *operate* Terraform,
> Helm, Kubernetes, image wiring, certificates or CI deploy glue. It does not
> remove the need to make sound engineering decisions, or to own the
> consequences of running a production system.

---

## 2. What Sol owns, and what you own

The line is deliberate, and it is the reason a Sol deployment is portable.

The boundary is also where Sol stops: Sol plans and reconciles only the
resources its contracts declare, not every resource in your account. You may
provision additional infrastructure with your own tooling — Terraform, Pulumi,
provider CLIs — and integrate it yourself, for example by granting a Sol
workload's stable identity access to a bucket you manage. See
[ADR 0005](architecture/adr/0005-sol-owns-only-its-contract-boundary.md).

| Sol owns | You own |
|---|---|
| The lifecycle engine: plan, provision, reconcile, build wiring, deploy, verify | The cloud account, its billing, and its quotas |
| The conventions: workspace/domain/unit layout, typed events, naming, labels | The application code and its domain logic |
| The generated substrate shape: namespaces, services, ingress, RBAC, secrets references | The images, in your registry |
| Observability *wiring*: logs, metrics, traces, dashboards | The data, in your databases and storage |
| Release inspection, rollback, and the release contract | The domain name, and the registrar/NS delegation to Sol |
| The installation's durable state, identities and delegated zone | The decision to run, keep, or tear down the environment |

Ownership is not a slogan; it is a set of guarantees:

- Cloud resources live in **your** account.
- Application images live in **your** registry.
- Application data lives in **your** databases and storage.
- DNS remains under **your** domain ownership.
- Terraform/provider state has an explicit, durable ownership model you can
  inspect and take over.
- **Stopping use of Sol does not stop your running infrastructure.** There is no
  Sol-operated runtime in the request path of your application.

> **The self-hosted promise.** Everything Sol does for the happy path can be
> executed by the Sol CLI, your CI system, or resources Sol installs into your own
> cloud account. A Sol-hosted service is optional, and exists only where an
> always-available Sol-operated actor creates value those mechanisms cannot.

---

## 3. The two units of the system: installation and environment

Most confusion about deployment lifecycles comes from conflating these two.

| | **Installation** | **Environment** |
|---|---|---|
| What it is | Sol's durable, account-level setup | One deployable target |
| Examples | Terraform state backend, provisioner/deploy/operator identities, the delegated DNS zone | Network, cluster, database, registry use, the deployed application |
| Lifetime | Outlives every environment | Disposable; can be destroyed and recreated |
| Removed by | An explicit `sol uninstall <target>` | `sol destroy <target>` |
| Contains billable resources | Some (the delegated zone, the state bucket) | Yes (the cluster, database, load balancers) |

This distinction is the whole point of the model:

> **`sol destroy <target>` destroys an environment. It does not uninstall
> Sol.** The state backend and the delegated DNS zone survive, so redeploying the
> same environment does not require re-doing registrar or DNS work.

A lifecycle stage chart, from the outside in:

```text
durable Sol installation           ← once per account/workspace
  ├─ Terraform state + locking
  ├─ provisioning / deploy / operator identities
  └─ delegated DNS zone
        │
        ▼
preflight                          ← refuse before spending money
        │
        ▼
environment provisioning           ← disposable: network, cluster, database
        │
        ▼
platform                           ← Argo CD, observability, Redpanda, cert-manager
        │
        ▼
application                        ← build, migrate, deploy, verify, endpoints
```

Internally, Sol has explicit `bootstrap`, `preflight`, `provision`, `platform`,
`migration`, `deployment`, `verification` and `reconciliation` stages. Those
stages exist for correctness and diagnosis. **They are not user-facing
complexity**: on the happy path the user runs one command. The stage model is
defined by the
`bootstrap → preflight → apply` contract `DEC-043` left open.

**Today:** the stages exist as code and as separate commands
(`sol plan`, `sol deploy`, `sol destroy`, `sol migrate`). The durable
installation among them is guided in place: a first `sol deploy` observes it and
offers to set it up (FEAT-106). The environment stage is driven in place too: a
`sol deploy` that has no destination it can reach reconciles the environment
itself — the same `Sol_cli_environment_stage` `sol deploy` drives, not a
second implementation — and then reaches the cluster it created as the target's
own deploy identity (DEC-058), continuing into migration and application without
the user invoking another command. The explicit stages remain for diagnosis and
for work a deploy is not asked to do.

---

## 4. One-time installation

Installation is the durable account-level layer that makes later deployments
boring. It is deliberately small, and deliberately separate from every
environment.

### 4.1 What installation creates

- **State and locking.** A durable Terraform state backend — on AWS an
  S3 bucket with versioning, encryption and a public-access block plus a
  DynamoDB lock table; on GCP a GCS bucket with native locking. A configuration
  cannot create the backend that stores its own state, which is exactly why this
  is a separate durable layer rather than part of an environment.
- **Identities.** Least-privilege identities for provisioning, cluster access,
  deploy, and observation, distinct from the cluster-creator admin. Sol owns the
  *policy contract* and you own the role: reconciling the durable root writes each
  generated policy document to the root's own working directory and prints its path,
  so the role can be created from it without reading Terraform outputs by hand. How a
  given provider realises the identities differs, and the provider-symmetric contract
  is a target of the installation work.
- **The delegated DNS zone,** when Sol is responsible for one, with durable
  ownership separate from disposable target state (`DEC-042`).

### 4.2 It is triggered inline, not by a separate ritual

**UX requirement:** a user should not have to learn or manually invoke a
separate bootstrap command to get started. An explicit administrative workflow may exist, but the ordinary path is that `sol deploy`
detects an uninitialised account and guides the user through initialisation in
place. The user experiences one command.

**Today.** `sol deploy <target>` does exactly this for the durable installation:
when it cannot reach the target's cluster it observes the instance at the
provider, reports what it found, and offers to set it up — reconciling the
durable root, printing the one external action (the delegation, with the exact
records), waiting for the delegation to become visible and confirming it from a
public resolver, then re-observing rather than assuming. Declining, or running
where no one can answer (CI, `--dry-run`, `--emit-to`), prints the same
explanation and the command that establishes it (`sol deploy <target>`) instead of prompting or silently skipping. Once the installation is
established the same run continues into the environment stage: it reconciles the
target's environment (`provision` → `platform`) and then reaches the cluster as
the deploy identity DEC-058 selected for that provider, rather than naming a
separate command. Where the provider has no deploy identity — today, GCP — the
run stops after provisioning and names the operator's two steps: the kubeconfig
command the root prints, and the `kube_context` to declare.

### 4.3 Inspecting and reconciling the installation

The installation is one stage with one owner, and it is observable before it is
changed. `sol plan <target>` resolves the installation from the
target's own declaration, observes each durable prerequisite at the provider, and
reports it — never inferring health from configuration, and never promoting a
prerequisite it could not observe:

```text
$ sol plan prod/aws/us-east-1
Installation (CloudBootstrap) -- the durable prerequisites that outlive every environment:

  resolved configuration
  state bucket             acme-tfstate
  state prefix             bootstrap/aws
  region                   us-east-1
  lock table               acme-tflock
  provisioning identity    arn:aws:iam::111122223333:role/sol-provisioner
  cluster-access identity  arn:aws:iam::111122223333:role/sol-cluster-access
  deploy identity          arn:aws:iam::111122223333:role/sol-deploy
  operator identity        arn:aws:iam::111122223333:role/sol-operator
  zone domain              api.acme.com
  zone ownership           sol-created (durable: Sol creates it and only an explicit uninstall removes it)

  terraform state backend      Established
  terraform state lock         Established
  provisioning identity        Established
  cluster-access identity      Established
  deploy identity              Established
  operator identity            Established
  delegated DNS zone           Established
```

The target declares who owns the zone (`dns_zone_ownership: sol | user | external`) and Sol
does not guess it from the fact that a zone exists. `sol` means the installation creates and
owns it; `user` means you created it and Sol never removes it; `external` means the parent is
yours and Sol asks for the delegation instead of owning the zone.

Every line after that is an **observation**: the bucket was looked for, the lock table was
described, each role was fetched, and the zone is only looked for when the installation owns
it — an externally delegated zone is reported `UNKNOWN`, naming what remains to be confirmed,
rather than being counted as a missing prerequisite. `Unmet` means the provider
answered that it is not there; `UNKNOWN` means Sol could not look, and it fails
closed — an unobservable installation is never reported healthy.

`--apply` reconciles the durable root instead of only reporting it: the root is
planned, a plan that would **replace or destroy** a durable resource stops the run
and asks a human, and a root already at its declared state applies nothing, so a
second run is a no-op. The state backend is the one prerequisite whose presence is
checked first, because a root cannot create the backend that stores its own state.

The identities are the one part of the installation Sol deliberately does not create
(`AUDIT-072`): it generates the least-privilege policy documents, and the operator
creates the roles and declares their ARNs. A reconciliation writes those documents to
the durable root's working directory — `identity-contracts/` beneath it — and the
report prints, for each identity not yet established, the ARN field to declare and the
path of its contract:

```text
  the identities are yours to create: Sol owns each policy contract
  (AUDIT-072), you create the role and declare its ARN — Sol looks the role
  up by the name in that ARN:
    provisioning identity        declare aws.provisioner_role_arn
      contract: ~/.local/share/sol/terraform/aws-bootstrap-…/identity-contracts/provisioner_policy_json.json
```

That is the whole hand-over: the contract's contents are the operator's to attach, and
Sol never creates, attaches or rotates a role.

### Create or adopt, never duplicate

When the target declares that Sol owns the domain (`dns_zone_ownership: sol`), reconciling the
durable root either creates the zone or **adopts the one that is already there** — it asks the
provider first, because creating a second zone with the same name would give the domain different
nameservers than the ones already delegated, and the delegation would silently point nowhere:

```text
The durable root already owns the zone for api.acme.com; nothing to create or adopt.
A zone for api.acme.com already exists and the durable root does not own it: adopting it
(/hostedzone/Z0123...) instead of creating a second zone with different nameservers.
No zone exists for api.acme.com yet, so the durable root creates it.
```

A provider CLI Sol cannot run is an error here rather than a guess: without an answer about
whether a zone exists, Sol would risk creating the duplicate.

### Delegation: one action, then verification

A zone Sol owns is only reachable once the zone that publishes it delegates to it, and that step
is the one a user cannot guess. Reconciling the durable root therefore ends by naming the exact
records to add, with both zones named:

```text
One action is required at the zone that publishes api.acme.com (acme.com):
add these NS records for api.acme.com,
or let the durable root create the delegation when that zone is in this account.
  NS  ns-1.awsdns-08.org
  NS  ns-2.awsdns-08.org
```

Which of the two applies is **observed, not assumed**: Sol asks the provider whether the zone that
publishes the domain is in this account. When it is, the durable root writes the NS delegation
itself and the operator has nothing to do; when it is not, the records above are the action. Nothing
is printed for a zone Sol does not own (`user`, `external`): delegating is not Sol's to do there, and
a question Sol cannot put to the provider is reported rather than answered with a guess. And because a written delegation is not evidence, the delegation is confirmed by
**observing public resolution, never by configuration**:

```bash
sol deploy prod/aws/us-east-1 --await-delegation=120
```

That waits in bounded five-second checks for the domain to answer with NS records from a public
resolver, printing each attempt so the wait is visible, and exits non-zero when the delegation
is still not visible. A resolver it cannot query is `UNKNOWN`, never a silent success
(`DEC-052`).

### 4.4 DNS and domain onboarding

DNS is an unavoidable external boundary: Sol can automate everything it has
authority over, and must ask for only the part that lives outside that authority.

- Accept the desired production hostname/domain during setup.
- Create or adopt the appropriate managed zone.
- If Sol can manage the parent zone, create the delegation automatically.
- If the parent DNS is external, display the **exact** NS records to add.
- **Wait for and independently verify public delegation**, rather than trusting
  configuration alone.
- Preserve the delegated zone across ordinary environment destruction.
- Treat externally supplied zones as user-owned, and never delete them as part of
  ordinary teardown.
- Surface ownership clearly: Sol-created durable zone, user-supplied zone, or
  externally managed parent delegation.

**Today:** the product-level flow exists (FEAT-107, decided in
`DEC-042`/`DEC-043`): the durable root creates or adopts the delegated zone and
records whose it is, prints the exact NS records to add when the publishing zone
is elsewhere, and then waits for the delegation and confirms it **from a public
resolver** rather than from written configuration (`sol deploy <target>`, bounded by `--await-delegation`). A resolver Sol cannot query is
UNKNOWN, never a silent success. The ownership rules are enforced at teardown: a
zone you supplied is never deleted.

---

## 5. The first deployment

The target first-run experience, for a fresh account (illustrative output; the
target is given in Sol's settled grammar — see §12):

```text
$ sol deploy prod/aws/us-east-1

Welcome to Sol.

AWS account detected: acme-prod
Region: us-east-1

Sol has not been initialized for this account.
Set up Sol now? [Y/n]

✓ State backend
✓ Deployment identities
✓ DNS zone

Production domain?
> api.acme.com

One action required:
Delegate api.acme.com to these nameservers:
  ns-...
  ns-...
  ns-...
  ns-...

Waiting for DNS delegation... ✓

✓ Network
✓ Database
✓ Kubernetes
✓ Observability
✓ TLS
✓ Application

Production is ready:
https://api.acme.com
```

Two properties matter more than the wording:

1. **Sol does the work and asks only for the irreducible external action.** The
   user is told exactly which DNS records to add and why, and nothing else.
2. **The expensive work happens after the cheap, knowable prerequisites.** Sol
   validates DNS/TLS prerequisites *before* provisioning when they are knowable,
   so the user does not wait through a costly provisioning run for a blocker it
   could have named immediately.
3. **Automated work and human actions are visually distinct.** The run should
   never make a user wonder what is happening or where they are needed.

**Today:** direct and GitOps cloud deployment work
(`sol deploy <target> --image-tag … --registry …`), and the durable installation
is guided inline by the first run (FEAT-106): the run reports what it observed,
separates the work Sol does from the one external action, and names the exact
records to add. The environment's own provisioning is driven in place as well:
when the run has nothing it can reach, it reconciles the environment and
establishes this run's own deploy-identity cluster access, then continues into
migration and deployment (DEC-058).

---

## 6. Everyday deployment

After installation, deployment is one command. The user should never have to
coordinate Terraform, Kubernetes, registries, migrations, certificates or
observability by hand.

```text
$ sol deploy prod/aws/us-east-1

✓ Built
✓ Pushed
✓ Migrated
✓ Deployed
✓ Verified

https://api.acme.com
```

The lifecycle behind that output:

1. **Preflight** — validate the repository/application contract, cloud identity,
   target, and durable prerequisites.
2. **Plan** — compute the intended infrastructure and application changes, and
   refuse unsafe or impossible configurations before mutation.
3. **Provision/reconcile** the cloud substrate as required.
4. **Install or reconcile** the Sol platform.
5. **Reach a meaningful Ready state**, defined by the selected profile.
6. **Build** application units and push images to *your* registry.
7. **Migrate** the database using the intended deployment identity.
8. **Establish namespace-scoped deployment substrate/RBAC** before mutation.
9. **Deploy** services, workers and functions.
10. **Verify** the deployed application contract — not merely that commands
    exited zero.
11. **Return stable endpoints** and a concise result.

**Today:** steps 1–11 exist across `sol plan` and `sol deploy`, with direct and GitOps modes (`DEC-043`, ADR 0002/0003). The
installation among them is inline, and so is the environment: a first
`sol deploy` observes the installation, offers to set it up, reconciles the
environment, and continues into migration and deployment as the target's deploy
identity (FEAT-106, DEC-058). What remains **Target** is the residue: a provider
without a deploy identity (GCP) stops after provisioning and names the operator's
kubeconfig steps.

---

## 7. Day-two operations

Sol verifies the operations it initiates. Routine diagnosis remains with
Kubernetes, observability systems, and cloud-provider tools.

| Command / capability | Expected experience | Today |
|---|---|---|
| `sol deploy <target>` | Build, provision/reconcile, migrate, deploy, verify, return endpoints | **Today** (first run guides the installation, drives the environment and reaches it as the deploy identity — FEAT-106, DEC-058) |
| Routine health inspection | Kubernetes and provider tooling | Sol verifies readiness during operations it initiates |

| `sol rollback` | Return to a recorded known release via Sol's release contract | **Today** |
| `sol check` | Diagnostics against the selected target/scope, with explained failures | **Partial** — declaration validity today; target/scope diagnostics **Target** |
| Ongoing telemetry queries | Use the configured Grafana/Loki/Prometheus interface | Sol wires telemetry into the selected backend |
| `sol destroy <target>` | Remove disposable environment resources and verify absence | **Today** |
| `sol uninstall <target>` | Remove Sol's persistent installation, explicitly | **Today** |

---

## 8. CI and git-push deployment without Sol hosting

Continuous deployment does not require a hosted Sol service. The user's existing
CI system is a first-class execution environment.

```text
git push
   ↓
GitHub Actions / other CI
   ↓
Sol CLI
   ↓
short-lived cloud identity
   ↓
customer-owned AWS/GCP infrastructure
```

Requirements:

- Provide a generator such as `sol ci init github` that creates a supported CI
  workflow for an existing workspace.
- Prefer **short-lived / OIDC** cloud authentication over long-lived credentials.
- Run the **same Sol lifecycle engine** in CI as locally. There is no separate CI
  deployment implementation.
- Support merge-to-main → `sol deploy` as a straightforward OSS workflow.
- Keep CI output and artifacts as diagnosable as local output, preserving the
  same lifecycle and safety invariants.

**Today:** `sol new workspace` scaffolds the GitHub Actions workflow, and
`sol ci init github` writes it into an existing workspace. The workflow installs
the release, uses GitHub OIDC, builds and pushes images, applies migrations,
deploys by digest and runs workload authorization through a separate gated
identity. See [CI and continuous deployment](deployment/ci.md).

---

## 9. Portability and exit

Sol should prefer standard provider resources and clear ownership over hidden
Sol-side state. Concretely:

- The infrastructure, images and data are yours (§2).
- Terraform state is durable and inspectable; the location is documented.
- A release is recorded with enough identity to roll back (DEC-018).
- A fresh machine or CI runner can operate the same environment using documented,
  provider-native authentication.
- If you stop using Sol, the running environment keeps running.

The acceptance test for this section: **an operator who stops using Sol can
still describe, inspect, and continue operating what was built**, without a Sol
binary in the loop.

**Today:** largely true for the customer-cloud path. The deploy-identity
mechanism is implemented for AWS (DEC-058); GCP still names its operator
kubeconfig step, and that gap is tracked in the support table.

---

## 10. Lifecycle, destroy, and uninstall

Destroy should be safe, predictable and scoped. The user should always understand
which of three things they are doing.

| Operation | Removes | Leaves intact |
|---|---|---|
| `sol destroy <target>` | Environment X's network, cluster, database, workloads | The installation: state backend, identities, delegated DNS zone |
| `sol uninstall <target>` | Sol's durable installation for the account/workspace | Externally supplied zones, the identities the operator created, and any resources Sol does not own |
| `terraform destroy` (advanced) | Whatever that root manages | Everything else |

Rules:

- `sol destroy <target>` removes resources belonging to that environment
  through supported lifecycle operations.
- Destroy **verifies absence independently**; it does not declare success from a
  command's exit code.
- Durable account bootstrap and the delegated DNS zone remain unless explicitly
  uninstalled.
- Externally supplied resources are preserved.
- Sol reports which resources were retained and why.
- An uninstall is a **separate explicit operation**, with an additional
  confirmation specifically for externally consequential DNS removal: removing
  the zone means the NS records at the user's provider become stale, and the
  exact domain affected is named.
- After uninstall, Sol independently verifies which Sol-owned resources are
  absent, and reports what was intentionally retained or is externally owned.

`sol uninstall <target>` prints what it will remove and what it will keep, and it
changes nothing without `--confirm`:

```text
$ sol uninstall qual/aws/us-east-1 --confirm --confirm-dns-zone qual-aws.example.test
Uninstall plan for qual/aws/us-east-1 -- the durable installation that outlives every environment:

  remove  terraform state backend
  remove  terraform state lock
  remove  delegated DNS zone
  retain  qual-aws.example.test -- the NS records at your registrar still point at this zone's nameservers; a recreated zone gets different ones
  retain  provisioning identity -- the durable root does not create it; the operator does, so Sol does not remove it
  removing the zone for qual-aws.example.test needs its own confirmation, because the delegation at your registrar becomes stale and a recreated zone would have different nameservers: --confirm-dns-zone qual-aws.example.test

Removed and independently observed absent:
  terraform state backend
  terraform state lock
  delegated DNS zone

Retained:
  qual-aws.example.test -- ...
  provisioning identity -- the durable root does not create it; ...
Done. The installation's Sol-owned durable resources are gone; nothing else was touched.
```

Removing a Sol-created zone needs its **own** confirmation naming the exact
domain, because the delegation at the operator's registrar becomes stale and a
recreated zone gets different nameservers. A user-supplied or externally
delegated zone is never removed. The Terraform state facility is the one
structural exception — a root cannot destroy the backend that stores its own
state — so Sol takes it out of the root's state before the destroy and retires it
explicitly afterwards. The provisioning / cluster-access / deploy / operator
identities are created by the operator from the durable root's policy output, so
uninstall never deletes them; it reports them as retained, with the reason.
Absence is observed through the installation's own probes, never inferred from an
exit code: an unqueryable answer is UNKNOWN and fails closed.

**Today:** environment destroy and absence verification exist (`sol
destroy`, `DEC-044`), and installation removal exists (`sol uninstall <target>`,
`FEAT-108`).

---

## 11. Readiness, preflight, and failure

Simplicity requires failures to happen at the right layer. Sol should reject an
impossible configuration early, rather than provisioning expensive
infrastructure and then waiting forever for a prerequisite that could never
succeed.

- Validate DNS/TLS prerequisites before expensive provisioning when they are
  knowable.
- Define **Ready** from the selected profile/configuration, not from
  unconditional checks of capabilities that are disabled.
- On ambiguous cloud outcomes, independently observe provider reality and
  reconcile only with exact attribution.
- **Fail closed** when ownership or attribution is ambiguous.
- Explain user-actionable external blockers directly — for example, missing NS
  delegation.
- Do not expose implementation trivia when Sol can repair the condition itself.
- A successful provider command is not sufficient evidence: verify the resulting
  state that matters to the user.

Readiness is **observed, never inferred**. A configuration that says a thing
should work is not evidence that it does. These rules are already decided and
enforced in places (`DEC-052`, `DEC-040`, ADR 0002); §11 states them as part of
the experience because the UX depends on them.

---

## 12. Addressing: environment, target, and why there is no `--env`

The experience is expressed in terms a user thinks in — "deploy production" —
but Sol's interface is **target-addressed**, and that is deliberate.

```text
sol deploy <env>/<provider>/<region>      # e.g. prod/aws/us-east-1
sol plan <target>
sol deploy <target>
sol destroy <target>
```

The environment is a **property of the resolved target**, not a flag. There is
no current target and no default: selection is explicit and fails closed
(`DEC-016`). Target, scope and view are three separate axes; the target is not a
scope, and the target is the positional on target-primary commands (`DEC-032`,
`DEC-031`).

An earlier shorthand of the form `sol deploy --env production` is therefore *not*
part of the design and no `--env` flag should be added: `--env` would allow
naming an environment that disagrees with the cluster, provider, hostname and
secrets the target already carries. The resolution is that Sol may offer a
**target shorthand within the target grammar** (for example, resolving the single
target that belongs to an environment) — a convenience *for* the target model,
never a second way to select a deployment. Whether such a shorthand is worth
adding is `DEC-016`'s call, not this document's.

Internally the middle segment names a **driver** — whose lifecycle behaviour Sol
owns — with `byo` for a cluster Sol did not provision (`DEC-051`).

---

## 13. Non-goals and anti-requirements

Sol will not:

- Require a Sol-operated SaaS control plane for basic deployment, DNS, TLS, CI,
  observability or teardown.
- Make users understand Terraform, Kubernetes, Helm or cert-manager for the happy
  path.
- Reserve convenience for a hypothetical paid tier when it can run locally or in
  customer-owned infrastructure.
- Conflate environment destruction with uninstalling Sol.
- Delete externally owned DNS or other user-supplied resources.
- Hide persistent cloud credentials in Sol when provider-native short-lived
  identity is available.
- Create a second hosted deployment engine that diverges from the CLI lifecycle.
- Claim "five minutes to production" by defining away unavoidable setup: the
  product distinguishes **one-time installation** from **repeat deployment**, and
  names the small number of external actions (today, DNS delegation) a human must
  perform.

---

## 14. When a hosted control plane would earn its existence

A hosted offering is optional, not a prerequisite for the core product. Its
natural boundary is functionality that requires a continuously available,
Sol-operated coordination point:

- an always-available web dashboard independent of a laptop or CI run;
- receiving webhooks and queueing work continuously;
- organisation/team RBAC and centralised SSO;
- deployment approvals and multi-user workflow coordination;
- centralised audit history and organisation-wide policy;
- continuous drift/health monitoring performed by Sol rather than by
  customer-hosted agents;
- cross-environment coordination requiring durable shared state;
- notifications or workflows that must run when no customer-controlled runner is
  active.

Even these could potentially be self-hosted. The boundary arises from the cost and
operational value of Sol running a reliable service, **not** from withholding
local convenience.

**The guiding test for any proposed hosted dependency:**

> Can this capability instead be executed by the Sol CLI, the user's CI runner,
> or software/resources Sol installs into the user's own cloud account?
>
> - If **yes**: prefer the OSS / customer-owned implementation.
> - If **no**: name the specific always-on coordination, durable shared state, or
>   operational responsibility that requires Sol-hosted infrastructure. That
>   requirement — not monetisation by itself — is the justification.

This is the same one-way boundary recorded in `DEC-019`: the hosted platform is a
separate product and repository; this repository is the open-source tool plus the
interface a hosted service may consume, and nothing here may depend on anything
private.

---

## 15. Success criteria

The experience is achieved when:

1. A capable backend developer can reach production without prior Kubernetes or
   Terraform expertise.
2. The first run clearly distinguishes automated work from the small number of
   unavoidable external actions.
3. After one-time account/domain setup, normal deployment is essentially
   `sol deploy <target>`.
4. A fresh machine or CI runner can operate the same environment using
   documented, provider-native authentication.
5. Destroying an environment does not force DNS reconfiguration before
   redeploying.
6. Users can understand what Sol owns, what they own, and what remains after
   destroy or uninstall.
7. The complete backend stack remains in the user's cloud account and can
   continue running without a Sol-hosted service.
8. Any future hosted offering improves always-on coordination/collaboration
   rather than being required to make the core deployment experience pleasant.

---

## Where this is tracked

| Area | Record |
|---|---|
| The experience contract and its decisions | this document |
| OSS / hosted boundary | `DEC-019` |
| Target addressing (no `--env`) | `DEC-016`, `DEC-032`, `DEC-031` |
| Installation lifecycle implementation | INFRA-096 |
| Inline first-deploy onboarding | FEAT-106 |
| DNS onboarding | FEAT-107 |
| `sol uninstall` and zone ownership | FEAT-108 |
| CI bootstrap | FEAT-109 |
| Portable release/state | FEAT-110, AUDIT-075/077 |
| Guided documentation set | [docs/README.md](README.md), DOCS-026…030 |
| Delegated zone lifetime | `DEC-042` |
| Substrate observed, not asserted | `DEC-052` |
| Convergence and verified absence | `DEC-044`, ADR 0004 |

If this document and a decision record disagree, the decision record wins and
this document is corrected.
