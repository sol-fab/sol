# Sol Product Architecture

Sol is an open-source software factory for backend systems, whose application
languages are **OCaml and TypeScript** (OCaml being the deeper-supported of the
two — the factory, its CLI and the production profile are OCaml today). It is not
only a runtime framework and not only a deployment CLI; it is the productized path
from typed domain code to running production services.

The product has four layers:

1. **User workspace repo** — the application source of truth: domain events,
   service code, workers, functions, migrations, and high-level service config.
2. **Sol open-source factory** — the framework libraries, CLI control surface,
   scaffold templates, deployment compiler, local dev tooling, and infrastructure
   modules.
3. **Generated production artifacts** — Dune projects, Docker images, Kubernetes
   manifests, GitOps output, deployment plans, release metadata, and observability
   wiring.
4. **Sol hosted factory floor** — the future managed service layer: projects,
   environments, builders, clusters, registries, secrets, deploy history, domains,
   logs, rollbacks, previews, RBAC, audit logs, and billing.

The first three layers exist today. The hosted factory floor is the product
direction: it should shape deployment architecture, but it should not force a
detailed control-plane API before the factory contract is stable.

---

## Design Principles

**Errors are values.** Every operation that can fail returns a `Result`. No exceptions for control flow. The type system enforces that failure is handled.

**One way to do things.** Sol picks conventions and enforces them. Module structure, error handling, configuration, observability — these are not decisions each service makes independently. Deviation is explicit.

**Explicit over implicit.** No magic. No hidden control flow. If something happens, there is a function call you can find. Conforming Sol HTTP adapters require workload identity by default; application code explicitly marks the routes that are external to that Sol boundary. Customer authentication remains application-owned.

**DevOps expertise, not engineering judgment.** Sol productizes the repeatable parts of platform engineering and DevOps. It removes the need to know Terraform, Helm, Kubernetes, image wiring, and CI deployment glue to ship a production service. It does not remove the need to make sound engineering decisions. Security design, data modeling, and business logic stay in the developer's hands and stay readable in the code.

**Security on Day 1.** Sol's framework types carry security configuration as a first-class concern — transport encryption, SASL authentication, and TLS are all part of the data model from the beginning, read from environment variables. The transport posture is never defaulted: `config_of_env` refuses a workload that does not set `KAFKA_SECURITY_PROTOCOL`, and Sol's rendered manifests set it explicitly (SEC-007). The **production profile** declares `KAFKA_SECURITY_PROTOCOL=sasl_ssl`: Redpanda serves TLS-encrypted Kafka, schema registry and admin API, with SASL authentication, from an in-cluster CA that cert-manager issues (FEAT-093). Workloads receive the CA and the SASL credential through their own Secret, so a deploy fails closed when either is missing. Local dev stays plaintext and says so.

**Shared components, deliberate environment differences.** Local and production
use the shared platform component definitions. Local development uses a small k3d
cluster, convenient port-forwards and plaintext Kafka; the production profile adds
TLS/SASL, durable storage and availability requirements. Local success does not
establish the production guarantees.

**FOSS infrastructure.** The full stack runs on open source primitives — Kubernetes, Redpanda, Argo CD, Prometheus, Loki, Grafana, Terraform. No vendor lock-in. Cloud providers are an infrastructure detail.

**Cloud-agnostic Kubernetes.** Sol services deploy to any Kubernetes cluster. The target is k8s, not a specific cloud provider. StorageClass abstraction, Redpanda for Kafka, and Terraform modules make the stack portable across AWS, GCP, Azure, or bare metal.

**Sol owns only its declared contract boundary.** Sol guarantees stable interfaces at its boundary; users are free to provision and integrate arbitrary infrastructure outside Sol, and Sol neither plans nor manages it. `sol plan` describes changes within the Sol-owned contract, not every resource in the account, and integration with externally managed infrastructure is the user's responsibility — through the stable identities, roles, service accounts, namespaces and endpoints Sol owns. See [ADR 0005](adr/0005-sol-owns-only-its-contract-boundary.md).

---

## Source of Truth

The **user workspace repo is always the source of truth** for application structure:

```text
events/<domain>/                 typed event contracts owned by publishing teams
app/<domain>/<name>_<primitive>/ service, worker, and function code
db/migrations/                   database migrations
sol.toml                         high-level service overrides
```

Sol compiles the workspace into runtime artifacts:

- Kubernetes namespaces, Deployments, Services, CronJobs, NetworkPolicies, and Secrets
- Kafka topics, schema registrations, consumer groups, and ACL intent
- service identity, metrics labels, log labels, and trace ownership fields
- image names and release identity
- migration plan and migration tracking table

Generated infrastructure is a build artifact. Users should not need to commit
hand-written per-service Kubernetes YAML, Dockerfiles, or CI deployment glue for
normal workflows.

---

## Factory Responsibilities

The Sol CLI is the control panel, not the whole factory. Each command triggers
one part of a larger automated pipeline:

| Factory stage | Sol responsibility |
|---|---|
| Scaffold | Generate workspaces, services, workers, functions, events, tests, Dockerfiles, and CI templates |
| Build | Compile OCaml via Dune and prepare container image inputs |
| Package | Standardize Docker image shape and registry/image naming |
| Plan | Turn workspace structure and environment inputs into a typed deployment plan |
| Synthesize | Render Kubernetes, GitOps, secret references, rollout shape, and observability wiring |
| Execute | Apply locally, emit artifacts, or submit to a future hosted executor |
| Operate | Status, logs, migrations, secrets, rollback, and release inspection |

Framework libraries (`sol-svc`, `sol-worker`, `sol-fn`) are the runtime contract
layer inside that factory. Supporting libraries (`*-eio`) are factory machinery:
their public APIs should expose domain operations and explicit results, not raw
transport handles, hidden parsers, or implementation escape hatches.

---

## Ownership Lanes

Sol should support three current ownership lanes plus one future hosted lane
over the same application model.

### Local Dev

The user runs Sol on their machine.

```bash
sol local deploy
```

Sol provisions or connects to a local k3d-backed platform, builds images, renders runtime artifacts, applies them locally, and starts port-forwards.

### Managed Customer Cloud

The customer owns the cloud account and cluster.

Sol may help provision infrastructure with Terraform wrappers or guides, but the
customer's account owns the cluster, registry, DNS, secrets backend, and cloud
bill. Sol owns the standard substrate shape and release workflow.

Deployments may be direct:

```bash
sol deploy prod/aws/us-east-1
```

### Exported Self-Managed

The customer owns apply, drift, overlays, and operations. Sol still compiles the
workspace into Terraform/manifests/GitOps artifacts, but those artifacts become
handoff output rather than a Sol-operated release.

```bash
sol deploy prod/aws/us-east-1 --emit-to <gitops-repo>
```

### Sol Hosted Factory Floor

Sol owns the hosting environment and operates the factory floor.

The user's workspace repo still remains the source of truth, but Sol owns environment resolution, builds, registries, clusters, secrets, deploy execution, release records, logs, rollbacks, domains, and billing.

The desired commercial product path is:

```text
connect Git provider
select workspace repo
create environment
deploy
observe
rollback
```

The CLI should be able to interact with this mode, but the first architectural
priority is making hosted deployment another executor over the same deployment
plan. Hosted Sol should run the same factory contract, not become a second
application model.

---

## Ownership Matrix

| Concern | Local Dev | Managed Customer Cloud | Exported Self-Managed | Future Sol Hosted |
|---|---|---|---|---|
| Application source | user workspace repo | user workspace repo | user workspace repo | user workspace repo |
| Build execution | local CLI | customer CI or CLI | customer CI or CLI | Sol |
| Deployment execution | local CLI | Sol CLI/CI in customer account | customer GitOps/apply path | Sol hosting plane |
| Cluster | local k3d | customer | customer | Sol |
| Registry | local k3d registry | customer | customer | Sol |
| Kafka / schema registry | local Redpanda | customer-managed or Sol-installed in customer cluster | customer-managed | Sol-managed |
| Postgres | local/in-cluster | customer RDS, Cloud SQL, or in-cluster | customer-managed | Sol-managed |
| Secrets | local/dev placeholders | customer secret backend | generated references/placeholders | Sol secret backend |
| Domains / TLS | localhost | customer DNS | customer DNS | Sol-managed DNS/TLS |
| Observability | local Grafana/Loki/Prometheus | customer cluster | customer-managed | Sol-hosted views backed by managed telemetry |
| Deploy history | local output | Sol release inspection over customer apply | emitted plan/artifact history | Sol release records |
| Rollback | local CLI | Sol CLI/GitOps | customer operation | Sol hosting plane |
| Billing | none | customer cloud bill | customer cloud bill | Sol |

Observability is a shared workspace surface, not one dashboard per service. See
[`observability-design.md`](observability-design.md) for the label model,
backend modes, and the boundary between deployment verification and provider-native diagnosis.

---

## Hosted Infrastructure Model

Decided by DEC-008 and DEC-010:

- Hosted infrastructure lives in a single Sol-owned AWS account. Each
  customer gets an isolated VPC/cluster (per-customer substrate, per
  DEC-002), not a separate AWS account. Hosted provisioning runs through the
  same `platform/cloud/aws/cluster` Terraform module self-hosted `sol deploy`
  uses, with per-customer Terraform state, so the Exported Self-Managed
  escape hatch stays a literal state handoff.
- Elasticity is delivered by autoscaling the existing Kubernetes primitives
  (KEDA, HPA, Karpenter, Aurora Serverless v2), turned on by default for
  Sol-hosted and available as an opt-in toggle for customer-cloud. Sol does
  not convert `-svc`/`-worker`/`-fn` to Lambda/SQS — that breaks dev/prod
  parity and cloud-agnostic Kubernetes, and degrades the Kafka event model.

Per-account tenant isolation remains open (a future revisit, not blocking).

**Hosted interaction model (DEC-009):** Sol Cloud's eventual primary
interface is a thin first-party web control plane over service/deployment
lifecycle, with specialized operational exploration (logs, metrics, traces)
delegated to Grafana via contextual links rather than reimplemented. This is
a direction, not a current implementation commitment — building it is
explicitly deferred until DEC-008 has a working tenancy prototype and a real
hosted-executor design exists. Until then, the CLI owns deployment lifecycle and Grafana dashboards (`OBS-044`) remain the operational interface. Any future web
control plane must invoke the same scaffold generator `sol new` uses (no
parallel hosted-only template implementation), and any GitHub App capability
granting repo write access or webhook events is its own separate
security/trust-boundary decision.

---

## Deployment Compiler

Sol treats deployment as a compiler pipeline:

```text
workspace scan
  -> application model
  -> environment resolution
  -> deployment plan
  -> executor
```

Today, manifest rendering is close to:

```text
workspace scan -> YAML -> apply or emit
```

That works for local and early GitOps flows, but it will not scale cleanly to a
hosted factory floor. The key architectural object is a typed, serializable
deployment plan.

---

## Deployment Plan

A deployment plan represents what Sol intends to run for a workspace in a specific environment.

It should be:

- typed in OCaml
- serializable for CI and hosted-control-plane use
- deterministic for a given workspace, environment, and image set
- inspectable before apply
- executable by multiple deployment backends

Minimum shape:

```ocaml
type deployment_mode =
  | Local
  | Customer_cloud
  | Sol_hosted

type environment = {
  name : string;
  mode : deployment_mode;
  region : string option;
  registry : string;
  base_domain : string option;
}

type service_spec = {
  domain : string;
  name : string;
  primitive : [ `Svc | `Worker | `Fn ];
  image : string;
  config : (string * string) list;
  secrets : string list;
}

type topic_spec = {
  owner_domain : string;
  name : string;
  schema_subject : string;
}

type deployment_plan = {
  workspace : string;
  environment : environment;
  services : service_spec list;
  topics : topic_spec list;
  migrations : string list;
}
```

This is illustrative, not final API. The important point is that local deploy, GitOps deploy, customer-cloud deploy, and Sol-hosted deploy should consume the same plan.

---

## Executors

Executors apply a deployment plan.

| Executor | Input | Output |
|---|---|---|
| Local executor | deployment plan | applies manifests to local k3d cluster |
| Direct Kubernetes executor | deployment plan | applies manifests to current kube context |
| GitOps executor | deployment plan | writes manifests to a GitOps repo |
| Future Sol hosted executor | deployment plan | submits or applies through Sol hosting plane |

Executor differences should be operational, not architectural. If two executors need different application models, the compiler pipeline is leaking.

---

## Environment Resolution

Environment-specific values must be separated from application source.

Application-owned:

- service primitive and domain
- route definitions and application-owned authentication
- event contracts
- migrations
- high-level overrides in `sol.toml`

Environment-owned:

- registry
- image tag
- cluster
- region
- base domain
- Kafka endpoint and security
- Postgres URL
- observability endpoints
- secret values
- managed service placement

For local and customer-cloud modes, environment config can live in local files or CI variables. For Sol-hosted mode, environment config comes from the hosting plane.

---

## Hosted Factory Floor Direction

The hosted factory floor should eventually manage:

- accounts and teams
- projects and workspace repo connections
- environments
- builds and image registry
- deployment plans
- releases and rollback history
- secrets
- managed databases, Kafka, and observability
- custom domains and TLS
- billing and usage

Do not build or over-specify this layer before the deployment plan is stable.
The near-term goal is to make hosted deployment possible by ensuring deployment
is compiled into a stable plan that a future control plane can execute and
record.

---

## Near-Term Implementation Priorities

1. Add a typed `Deployment_plan` module.
2. Refactor manifest rendering to consume a deployment plan instead of raw discovered services.
3. Make `sol local deploy` and `sol deploy --emit-to` use the same plan.
4. Add an environment config model for local and customer-cloud deploys.
5. Keep Sol-hosted deployment as a documented executor direction until the plan shape is stable.

---

## Open Decisions

These are intentionally not settled yet:

- Whether Sol-hosted builds pull directly from Git providers or receive artifacts from customer CI.
- Whether hosted runtime clusters are single-tenant, multi-tenant, or mixed by customer tier.
- Which secrets backend Sol-hosted mode uses.
- Whether customer-cloud mode is a first-class product path or an advanced/self-managed path.
- How custom domains and TLS are provisioned in Sol-hosted mode.
- How billing maps to projects, environments, services, usage, and managed resources.
- Whether GitOps remains a core hosted mechanism or only a customer-cloud option.

The current product bias is:

- local dev should be excellent;
- Sol-hosted should become the paid managed factory floor;
- customer-cloud should remain possible, but should not complicate the default user experience.
