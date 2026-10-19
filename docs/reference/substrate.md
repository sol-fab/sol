# Self-Hosted Substrate Contract

Sol reconciles a declared target's Sol-owned cloud roots and Kubernetes workloads
with `sol deploy`. For a bring-your-own target, this document defines the minimum
substrate contract that must already exist. It also draws the boundary between
what Sol owns and what users provide through other infrastructure tooling.

This covers the environment *around* your containers. See
[`runtime.md`](runtime.md) for the other
direction: what the code *inside* a container must actually do, and which of
that Sol's tooling checks versus merely assumes.

## The Boundary

Sol generates **application-layer Kubernetes objects**: namespaces, service
accounts, Deployments, Services, CronJobs, Ingress objects, and NetworkPolicies.
For providers with a Sol-owned Terraform target root, `sol plan` previews and
`sol deploy` reconciles the declared cloud and platform roots before deploying
workloads. Sol only manages resources in those declared roots; it does not plan or
manage arbitrary account infrastructure. Bring-your-own targets must already
provide the substrate they use.

This boundary is intentional. Terraform remains authoritative for resources in
Sol's roots, and users may manage external infrastructure with Terraform, Pulumi,
or cloud-native tooling. Sol consumes external services but does not discover or
manage them by inference.

## Workspace-owned Terraform

For AWS and GCP targets, add user-owned Terraform to the existing target roots:

```text
sol/terraform/aws/cluster/*.tf
sol/terraform/aws/cluster/modules/**
sol/terraform/aws/platform/*.tf
sol/terraform/aws/platform/modules/**
```

Use `gcp` in place of `aws` for GCP. Root `.tf` and `.tf.json` files, plus files
under the root's `modules/` directory, are composed into that root for `sol plan`
and `sol deploy`. Terraform then plans and applies them with Sol's resources in
the same dependency graph and state. Removing a custom resource declaration is
an ordinary Terraform deletion, subject to the same plan review and state guards.
The `cluster` root is for cloud resources; the `platform` root is for Kubernetes
and Helm resources after the cluster exists. The durable bootstrap and fenced
authorization roots do not accept workspace overlays.

Custom files can use the stable `local.sol_target` object. In the cluster root it
contains `provider`, `region`, `cluster_name`, `cluster_endpoint`, `network_id`,
and `private_subnet_ids`; in the platform root it contains `provider`,
`base_domain`, `cluster_issuer`, and `platform_profile`. These values are a
provider-neutral interface; generated Terraform module and resource addresses
remain implementation details. Declare ordinary Terraform `output` blocks for
values your own configuration needs to publish; those outputs belong to the same
Terraform root and state.

---

## What You Bring

The following substrate inputs must exist before running `sol deploy`.

### Kubernetes Cluster and Context

- A reachable Kubernetes cluster (k3d locally, EKS, GKE, or any CNCF-conformant
  cluster in production).
- A kubeconfig context that can reach the cluster (`kubectl cluster-info` must
  succeed).
- Cluster admin or a namespace-scoped role with permission to create
  Deployments, Services, CronJobs, Ingress, ServiceAccounts, ConfigMaps,
  Secrets, and NetworkPolicies.

### Container Registry Prefix

- A registry that the cluster's nodes can pull from.
- Pass the prefix via `sol deploy <env>/<provider>/<region> --registry <prefix>`,
  or set it as the target file's own `registry` (used as the default when
  `--registry` is omitted).
  Example: `123456789.dkr.ecr.us-east-1.amazonaws.com`
- The cluster must have image-pull credentials configured (imagePullSecret,
  IRSA, or workload identity). Sol does not create pull credentials.

### Kafka Brokers and Schema Registry

- Comma-separated broker addresses, e.g. `broker-1:9092,broker-2:9092`.
- A Confluent-compatible schema registry URL, e.g. `http://schema-registry:8081`.
- Sol workers and services read `KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL` and the
  required `KAFKA_SECURITY_PROTOCOL` (plus `KAFKA_SSL_*`/`KAFKA_SASL_*` when used) from
  their environment. The generated ConfigMap points at Sol's in-cluster
  Redpanda defaults. On the `local` shape that is
  `KAFKA_SECURITY_PROTOCOL=plaintext`; on the **durable shape** Sol declares
  `KAFKA_SECURITY_PROTOCOL=sasl_ssl` with the HTTPS schema-registry and admin
  URLs, `KAFKA_SASL_MECHANISM=SCRAM-SHA-256` and `KAFKA_SSL_CA_LOCATION`, and
  mounts the CA from the workload Secret as `KAFKA_SSL_CA_CERT`. A durable-shape
  workload Secret must therefore also carry `KAFKA_SASL_PASSWORD` and
  `KAFKA_SSL_CA_CERT`; an ordinary deploy fails closed when either is missing.
  For an external Kafka substrate, override those values via
  `[infra.env] config = { ... }` in each service's `sol.toml` or through a
  GitOps overlay.
- Sol's workspace scan discovers topic intent from `events/**/sol.toml`, but
  it does not create an external Kafka cluster for you.

### Postgres Connection

- A database is delivered to its consumers by the deploy, from the target's
  `postgres` binding — Sol-provisioned or externally bound. There is no
  operator-held `POSTGRES_URL` to set.
- A Sol-provisioned database's setup step writes `<target>-db-credentials`
  (the target's record of the DDL and DML passwords, never delivered to a
  workload), `<target>-ddl-creds`
  (the migration Job's namespace), `<target>-dml-creds` (consuming units'
  namespaces) and the `<target>-db-ca` ConfigMap. A unit that declares
  `uses: [app_db]` reads `POSTGRES_URL` from `<target>-dml-creds`; the migration
  Job reads it from `<target>-ddl-creds`. The record is written *pending* before
  the setup Job runs and promoted to *established* only after that Job succeeds;
  a deploy repairs from it only when it is established, and otherwise re-runs the
  bootstrap — which refuses a role that already exists rather than replacing its
  password.
- An externally bound database publishes the same class Secret names through an
  ESO `ExternalSecret` per class, and no CA ConfigMap (the provider's own trust
  chain applies). A unit that merely declares `POSTGRES_URL` as an application
  secret keeps reading its own unit-scoped Secret.
- The contract key is **`POSTGRES_URL`**, not `DATABASE_URL`. There are no
  `postgres_secret_name`, `kafka_secret_name`, or `tls_secret_name` fields in
  `sol.toml`; per-workload Secret names are derived as `<service>-secrets`, and
  `sol.toml` declares only secret *keys* under `[infra.env] secrets`.
- Sol does not create the database in the application deploy path, run
  migrations at cluster startup, or manage credentials rotation.
  `sol migrate apply <target>` requires a deploy to have run first, so
  `<target>-ddl-creds` exists.
- **Runtime and build-time keys are separate declarations.**
  `[infra.env] secrets` lists the keys a workload needs while it runs; they are
  delivered through `<service>-secrets`. `[infra.env] build_secrets` lists the
  keys whatever builds the image needs instead (a private registry token, a
  private-package credential). Sol never delivers a build-time key to the
  workload, and exports only its *name* — in the deployment plan
  (`--emit-plan-to`, as each service's `build_secret_keys`) and never its value.
  A key listed in both is a validation error, because a build that can read a
  runtime secret is a build that can leak it.

### Observability Endpoints

- **Loki**: HTTP push URL, e.g. `http://loki.monitoring.svc:3100`.
  The generated ConfigMap defaults `LOKI_URL` to Sol's in-cluster Loki service.
- **Prometheus Pushgateway**: HTTP URL for `sol fn` metrics push, e.g.
  `http://pushgateway.monitoring.svc:9091`.
  The generated ConfigMap defaults `PUSHGATEWAY_URL` to Sol's in-cluster
  Pushgateway service.
- **Tempo**: OTLP/HTTP URL, defaulted as `TEMPO_URL` when Tempo is installed.
- Override these with `[infra.env] config = { ... }` if you use external
  observability endpoints.
- There are no `loki_url` or `pushgateway_url` fields in `sol.toml`. These are
  ConfigMap values (`LOKI_URL`, `PUSHGATEWAY_URL`, `TEMPO_URL`) with Sol
  defaults, overridden through `[infra.env] config` rather than a dedicated
  `sol.toml` key.

### Base Domain and TLS (Optional)

- A DNS name under which services are exposed, e.g. `myapp.example.com`.
  Set `ingress_host` in `[infra.deploy]` of each service's `sol.toml` to
  enable host-specific TLS for that service.
- When `ingress_host` is set, Sol generates an Ingress object for the `-svc`
  with a host rule, a per-service TLS secret, and cert-manager annotations.
  Override the ClusterIssuer with `target.cluster_issuer`; it defaults to
  `letsencrypt-prod`, matching `platform/cloud/modules/platform`.
- If a service has no `ingress_host`, Sol still generates an Ingress, but gives
  it a per-service dev host, `<k8s-name>.<namespace>.localhost`, and leaves TLS
  and HTTPS redirect off. The namespace is part of the host so several services
  — and several workspaces sharing one cluster — never collide.
- **No DNS record is created for you.** `platform/cloud/modules/platform` installs
  ingress-nginx, and `platform/cloud/aws/cluster` can create the Route53 zone, but
  Sol does not run external-dns: an `ingress_host` only resolves once its
  record exists. Find the controller's address with
  `kubectl get svc -n ingress-nginx ingress-nginx-controller` (the
  `EXTERNAL-IP`) and create an `A`/alias or `CNAME` record for each
  `ingress_host` in that zone (`route53_zone_id` / `route53_nameservers` are
  `platform/cloud/aws/cluster` outputs; on GCP use the Cloud DNS zone). A wildcard
  record such as `*.acme.com` covers every service in one entry.
- Locally, `sol local deploy` installs the same ingress-nginx chart (NodePort) and
  forwards the controller to `http://localhost:8088`. Reach a service there
  with its dev host as the `Host` header, e.g.
  `curl -H 'Host: charge-svc.acme-payments.localhost' http://localhost:8088/health`
  — browsers resolve `*.localhost` to loopback, so on many systems the host
  works in the URL directly. No DNS or TLS is involved.

---

## Each Input as an Observation

The list above is what you bring; this is how Sol checks it. Every input is a predicate
Sol reports per target with the same three-valued vocabulary the durable prerequisites
use — `Established`, `Unmet` (the answer says it is not there) or `UNKNOWN` (Sol could
not look) — and **an answer Sol could not obtain is never promoted to satisfied**
(`DEC-052`).

| Input | Statement | How Sol observes it | Reported by |
|---|---|---|---|
| Kubernetes cluster | a reachable cluster and a kubeconfig context that reaches it | `kubectl cluster-info` through the target's context; a connection-level failure is `Unmet`, a refused or unauthenticated answer is `UNKNOWN` | `sol target show <target> --check` |
| Container registry | a registry prefix the cluster's nodes can pull from | the prefix is read from the target; **pullability is not observable from the CLI**, because only a node in the cluster pulls | `sol target show <target> --check` |
| Kafka and schema registry | broker addresses and a schema-registry URL the workloads reach, with `KAFKA_SECURITY_PROTOCOL` set (`SEC-007`) | the addresses are workspace configuration (`[infra.env] config`); reachability and the broker's security posture are properties of the cluster's network, which the CLI does not sit in | `sol deploy` (the workloads observe it at runtime) |
| Postgres connection | a database delivered to its consumers by the deploy from the target's binding | the deploy writes the class Secrets (`<target>-dml-creds`, `<target>-ddl-creds`) and the consuming unit mounts them; `sol target show <target> --check` reports the database connection `UNKNOWN`, because the target surface does not observe whether the selected database accepts it | `sol deploy` (the workloads and migration Job observe it at runtime) |
| Observability endpoints | Loki and Pushgateway endpoints the workloads reach | the URLs are workspace configuration; reachability is again a property of the cluster's network | `sol deploy` (the workloads observe it at runtime) |
| Base domain and TLS | a certificate Issuer and a DNS entry when a service declares an ingress host | the Issuer lives in the cluster and the record in the DNS provider, neither of which the deploy check reads | `sol deploy` (`--check` reports it `UNKNOWN`, with the reason) |

Two consequences worth stating plainly, because they are what this contract refuses:

- **Nothing here is asserted in YAML.** A `substrate:` block saying `database: managed`
  or `tls: yes` would be a declaration Sol cannot check, and a wrong one would be
  undetectable; where a fact can be observed, configuration may only say how to look
  (`DEC-052`). `DEC-053` is where the set of keys that exist at all is settled, so a key
  that asserts a discoverable substrate fact is refused there rather than honoured here.
- **The unobservable half is named, not hidden.** The entries whose reachability only
  the cluster's own network can answer are reported `UNKNOWN` with that reason, and the
  first unit of this contract (`DEC-052`) adds the predicates Sol can observe today
  rather than inventing a check that would pass.

---

## What Sol Generates

Running `sol deploy` (or `sol local deploy` locally) produces the following Kubernetes
objects for each service in your workspace:

| Object | When generated |
|---|---|
| Namespace | Always. One namespace per `<workspace>-<domain>` pair. |
| ServiceAccount | Always. One per service, in its namespace. |
| ConfigMap | Always. Contains Sol's platform defaults plus any `[infra.env] config` keys from `sol.toml`. |
| Secret | Sol-owned values are written to each unit's `<unit>-secrets` object by `sol secret set TARGET <domain>/<unit>/<KEY>`. External values are delivered by a namespaced ESO `ExternalSecret` into `<unit>-external-secrets`; both deployment modes render the same references and no values or placeholder Secret objects. Sol platform Jobs use a separate `sol-secrets` object for target-level inputs. |
| Deployment | For every `-svc` and `-worker`. |
| Service (ClusterIP) | For every `-svc`. |
| CronJob | For every `-fn`, using the `schedule:` field from `sol.toml`. |
| Ingress | For every `-svc`; TLS and HTTPS redirect only when `ingress_host` is set in `sol.toml`. |
| NetworkPolicy | Always. Denies NodePort egress, enforces non-root containers. |

Sol's artifact is the set of YAML manifests. In direct mode (`sol deploy`
without `--emit-to`) Sol applies them via `kubectl apply`. In GitOps mode
(`sol deploy --emit-to <dir>`) Sol writes them to a directory for Argo CD or
Flux to apply.

**Secret values are never in the rendered output:** Sol does not emit a unit's
Sol-managed Secret, in either direct apply or GitOps emission, and there is no
placeholder Secret to populate. Create it before the workload with
`sol secret set <TARGET> <domain>/<unit>/<KEY>`; the workload's environment
references the key, and the deploy fails closed when the Secret or a declared key
is missing rather than applying a workload that cannot start.

External authority keys are delivered by the External Secrets Operator. Sol
renders a namespaced `ExternalSecret` into the bundle's prerequisites and applies
the workload only after ESO reports it synced, verifying that the sync names the
spec it applied (see the deployment guide). For a target bound to an external
database the same wait covers the class `ExternalSecret`s (`<target>-ddl-creds`,
`<target>-dml-creds`) before the migration gate and the workloads that read them
run. Platform Job inputs use the reserved
`@platform/<KEY>` address and write only `sol-secrets`. Do not commit manifest
files that contain real secret values.

No per-service manifest hand-editing is required or expected. If a generated
manifest does not fit your needs, open an issue or add a `sol.toml` escape
hatch rather than editing generated YAML.

---

## What Sol Does Not Generate

Sol deliberately does not provision:

- **VPCs, subnets, security groups, firewall rules** — use Terraform, Pulumi,
  or your cloud console.
- **IAM roles, service accounts (cloud), OIDC providers** — use your cloud
  provider's IAM tooling or the Terraform modules in `platform/cloud/aws/cluster/` and
  `platform/cloud/gcp/cluster/` as a starting point.
- **Managed databases (RDS, Cloud SQL)** — use cloud-native managed services or
  the Terraform modules in `platform/cloud/modules/platform/`.
- **Managed Kafka clusters (MSK, Confluent Cloud, Redpanda Cloud)** — use the
  managed service directly. Point `KAFKA_BROKERS` at the bootstrap endpoint.
- **DNS zones, A/CNAME records** — use Route 53, Cloud DNS, or your DNS
  registrar.
- **TLS certificates** — use cert-manager, ACM, or your cloud provider's
  certificate service.
- **Container registries (ECR, GCR, Docker Hub)** — create the registry once
  via Terraform or the cloud console and pass the prefix to Sol.
- **Cloud accounts, billing, quota increases** — out of scope.

---

## Setup Options

### k3d (Local Development)

`sol local deploy` automates the full local substrate:

```
sol local deploy
```

This command starts a k3d cluster, a local registry container at
`localhost:5000` (cluster-internal: `sol-registry:5000`), Redpanda (Kafka),
Loki, Prometheus, and Grafana via Helm. No manual substrate setup required for
local development.

### Terraform Modules (Provided as a Starting Point)

The `platform/cloud/` directory contains Terraform modules that provision typical
production substrate:

| Path | What it creates |
|---|---|
| `platform/cloud/modules/platform/` | Generic Kubernetes substrate: namespaces, RBAC, cert-manager, ingress-nginx |
| `platform/cloud/aws/cluster/` | AWS: VPC, EKS cluster, ECR registry, RDS PostgreSQL, IAM OIDC |
| `platform/cloud/gcp/cluster/` | GCP: GKE Autopilot, Artifact Registry, Cloud SQL, Workload Identity |
| `platform/cloud/delivery/argocd/` | Argo CD `Application` manifest for GitOps mode |

These modules are **starting points**. They express Sol's opinion about a
minimal, secure substrate. Modify them freely to match your organization's
standards. Sol does not require these specific modules — any substrate that
satisfies the contract above works.

### Pulumi / CloudFormation / Other IaC

Bring your own. As long as the substrate contract is satisfied (cluster
reachable, registry accessible, secrets exist), `sol deploy` works regardless
of how the substrate was provisioned.

### Manual Cloud Console (Advanced)

Possible, but not recommended for production. The substrate contract does not
mandate IaC — it mandates that the listed resources exist and are reachable.

---

## Deployment Flow

A typical `sol deploy` invocation in CI:

```bash
# 1. Build and push images (CI build job — not Sol's responsibility)
docker build -t $REGISTRY/orders-svc:$SHA .
docker push $REGISTRY/orders-svc:$SHA

# 2. Deploy — Sol's responsibility
sol deploy prod/aws/us-east-1 \
  --registry   $REGISTRY \
  --image-tag  $SHA
```

What Sol does in step 2:

1. Discovers services in `app/` (any directory with a `Dockerfile`).
2. Reads `sol.toml` for service metadata (domain, primitive type, schedule,
   secret names, config keys, `ingress_host`).
3. Resolves the registry — explicit `--registry`, falling back to the
   target file's `registry` — and fails before any build/apply step if
   neither is set. There is no hardcoded local-registry fallback: `sol
   deploy` is always the customer-cluster path.
4. Renders namespaces, service accounts, Deployments/Services/CronJobs,
   Ingress (when `ingress_host` is set in `sol.toml`), and NetworkPolicies.
5. Applies manifests via `kubectl apply` (direct mode) or writes the per-service
   YAML files plus the release artifact (`sol-release-<id>` record and
   `sol-current-release` pointer) to the `--emit-to` directory (GitOps mode), so
   the release metadata travels with the bundle.

Sol does not SSH into nodes, modify cloud resources, or touch anything outside
the Kubernetes API server.

### GitOps Mode

```bash
sol deploy prod/aws/us-east-1 \
  --registry   $REGISTRY \
  --image-tag  $SHA \
  --emit-to    ./gitops/manifests
```

Manifests are written to `gitops/manifests/`. Commit and push. Argo CD or Flux
detects the change and applies it to the cluster. Sol's role ends when the files
are written.

An externally bound database's class `ExternalSecret`s are written as
`<target>-db-prerequisites.yaml` in the same directory, so a fresh GitOps
deployment carries the object its units read. A target that provisions its
database cannot be emitted — its class Secrets are written by the setup step,
which only a direct apply runs — so `--emit-to` refuses it at plan time.

Alongside the manifests, Sol writes `sol-release-<id>.yaml` (named by the plan's
content-addressed release id — the same id every workload carries as its
`release` label) and a `sol-current-release.yaml` pointer. Both are pure
functions of the released content, so re-deploying identical content leaves the
bundle byte-identical and the diff empty. The emitted record is marked
`apply_mode: gitops`: a controller, not Sol, owns those resources, so
`sol rollback` refuses a GitOps-owned release instead of direct-applying against
the controller (see the rollback section of the pipeline doc).

Invocation provenance is deliberately not part of a release artifact: a release
record is content, so two deploys of identical content share one record and one
empty GitOps diff. Sol keeps no separate deployment-attempt history — the
retained `sol-release-<id>` records, listed by `sol releases`, are the durable
deployment record (see the pipeline doc's *Where release history lives*).

### Production Profile

A target claims a production contract only by selecting one, on its environment
or on the target itself in `sol/environments.yml`. An environment named `prod`
claims nothing.

```yaml
# sol/environments.yml
pilot:
  profile: production-single-region
  shape: durable
  targets:
    aws/us-east-1:
```

`profile` is accepted on an environment or a target, never in `sol.yml`: `sol.yml`'s
`target:` section is inherited by every target, so a profile there is rejected
rather than opting every environment in.

Every cloud target declares its platform shape (`shape: local` or `shape: durable`),
on its environment or on the target itself. `shape`, like `profile`, is rejected in
`sol.yml` for the same reason. A plan that would deploy infrastructure for a target
without a shape is refused before Terraform or the workload stage.

A target that selects `production-single-region` goes through a preflight on
every `sol deploy` (including `--dry-run`). Every guarantee whose evidence is
knowable from configuration is checked before any cluster call, lease or emitted
file, and refuses if unmet. The immutable-artifact guarantee is the one
exception: its evidence is a digest published into the target's registry, and
that registry is itself part of the target's infrastructure. On an apply, Sol
reconciles the environment — which creates the registry — and then checks the
artifacts; if none is published it reports the deployment incomplete, names the
repositories to publish into, and changes no workload. A `--dry-run` or
`--emit-to` still evaluates every guarantee, including the artifacts, before it
writes anything. Each unmet guarantee is named along with who must act: the
application, the target, or Sol itself. There is no "accepted but unverified"
outcome: the profile is unsatisfiable until Sol can establish every guarantee it
requires.

#### Shape and qualification are separate axes

A target declares two independent things, and only the first decides what Sol
renders:

- **Platform shape** (`platform_shape`: `local` or `durable`) is an explicit
  declaration on the cloud target — on its environment or on the target itself —
  not a derivation from a selected profile. `production-single-region` requires
  `durable` and is refused with `local`; the local platform that `sol local
  deploy` drives is `local` by construction and needs no target declaration. The
  shape is the input to posture that follows it: the Kafka transport is
  `sasl_ssl` on the durable shape and `plaintext` on the local one (#1308). Every
  consumer reads the one resolution (`Sol_cli_config.platform_shape`), so the plan
  and the cloud lifecycle cannot disagree.
- **Qualification** is the preflight gate above — the guarantees in the table
  below, which must be established before Sol mutates anything. The
  immutable-artifact guarantee is established as soon as the target's registry
  exists and before any workload moves; every other guarantee precedes the
  registry.

They are independent. A profile can constrain the shape without being its source,
and an unqualified provider still deploys the declared shape, so the posture a
preflight refuses is exactly the posture the plan previewed: qualification
decides *whether* a deploy may proceed, never *what* the target deploys. Deriving
the transport from the shape therefore does not imply the substrate is qualified,
and GCP stays unshippable until it has its own production qualification claim.

Every guarantee now has a real establishment branch — none is staged
(`not_yet_established` no longer exists). Preflight establishes only what is
observable offline: a declaration, a rendered configuration, or a
shape-derived setting. It never claims live behaviour; the failure and
recovery behaviour behind the numeric DEC-026 bounds is HARDEN-002's evidence.

| Guarantee | Required when |
|---|---|
| Qualified provider/substrate (AWS) | always |
| Qualified version set | always |
| Direct apply reconciliation authority | always — `--emit-to` is refused |
| Recoverable remote infrastructure state | always |
| Scoped operator identity | always |
| Alert delivery to an owner | always |
| Immutable artifact identity | always — every workload deploys by `--image-ref <service>=<repo>@sha256:<digest>` |
| Workload credential posture | always |
| Workload availability | any service or worker |
| Postgres durability | migrations or a `postgres` resource |
| Kafka durability | topics declared in `events/` `sol.toml`, or a `kafka` resource |

Only declared dependencies make a guarantee applicable. A worker's shape
implies nothing: it may consume Kafka or host `sol-jobs`. A worker that
consumes Kafka without a declared topic or `kafka` resource is not detected
yet, so declare every Kafka dependency.

The workload credential posture is a Sol-owned renderer property: every workload
gets no mounted service-account token, and runtime credentials are updated by
`sol secret set`, which writes and stops there — activation is explicit, by the
workload's Kubernetes rollout tooling. An unchanged deploy does not restart a
running process. See
[`credential-rotation.md`](../deployment/credential-rotation.md).

Recoverable state and scoped identities are target declarations: a locked,
versioned, encrypted remote state backend (`state_bucket`/`state_lock_table`,
which Sol provisions by default via `platform/cloud/aws/bootstrap`) and the named
provisioning/deploy/operator role ARNs plus a restricted public-endpoint CIDR.
See [`production-bootstrap.md`](../deployment/production-bootstrap.md) for the exact commands
and recovery procedure.

The availability guarantee is a declared semantic, not a replica count: a
workload states `single` (the default) or `node-failure-tolerant` in its
`sol.toml`, and a target declares the fixed `node_failure_headroom_nodes` that
makes restoration possible. Sol refuses a claim the workload cannot satisfy
(functions, volume-backed workloads, fewer than two replicas) before render and
fails the preflight when the headroom is missing. See
[`workload-availability.md`](../deployment/workload-availability.md).

Migration ordering is enforced live: a production deploy verifies that every
migration in the workspace's `db/migrations` is present in the authoritative
`schema_migrations` table (read-only, via a short-lived in-cluster Job) after the
static preflight and before any workload mutation, failing closed when the check
cannot be performed. `--dry-run`/`--emit-to` create nothing and report the
prerequisite as not verified. See
[`migration-ordering.md`](../deployment/migration-ordering.md).

The artifact guarantee is satisfied by how the application deploys:
`sol deploy --image-ref <service>=<repo>@sha256:<digest>` pins each workload to
immutable bytes, and the preflight rejects a mutable tag. A bare
`--image-ref <repo>@sha256:<digest>` is accepted when the scope selects exactly
one service. Each reference is checked against its registry before anything is
applied, and the resolved digest is what the release record — and therefore a
later rollback — uses, so a moved tag cannot change what a recorded release
runs.

The qualified version set is a declared framework language per workload.
Declare `language: ocaml` (or `typescript`) in the service's `sol.yml` entry —
`sol new` records it for every unit it generates, since it knows what it wrote,
and `sol check` warns about a workload in your workspace that declares none;
the profile's initial compatibility matrix qualifies OCaml only, so a
TypeScript workload fails preflight with that reason. The exact supported CLI,
language, Kubernetes, provider-module and chart versions are published in
[`compatibility.md`](../deployment/compatibility.md).

The Postgres and Kafka durability guarantees have a written operator
procedure — backup, restore, failover and integrity verification — in
[`application-data-recovery.md`](../deployment/application-data-recovery.md). Qualification
evidence for those procedures belongs to HARDEN-002; the runbook is the
procedure, not proof a target passed.

A deploy that passes preflight carries `production-single-region/v1` in its plan
(`--emit-plan-to`, with the guarantees as `evidence_requirements`). The claim is
never written into the release record: a release is content, and two targets may
deploy the same release while only one of them claims the profile.

---

## Summary

| Layer | Owner |
|---|---|
| Cloud accounts, billing | You |
| VPC, subnets, firewall | You (Terraform / cloud console) |
| IAM, workload identity | You (Terraform / cloud console) |
| Kubernetes cluster | You (Terraform / cloud console / managed service) |
| Container registry | You (Terraform / cloud console) |
| Managed Kafka, Postgres | You (Terraform / cloud console / managed service) |
| DNS, TLS certificates | You (Terraform / cert-manager / cloud console) |
| Kubernetes Secrets (values) | You (sealed-secrets, External Secrets Operator, etc.) |
| Application manifests | **Sol** (`sol deploy`) |
| Local dev substrate | **Sol** (`sol local deploy`) |
