# Sol Escape Hatches

Sol is opinionated by default. Every generated Deployment enforces non-root
containers, read-only root filesystems, and ClusterIP-only services. These
invariants are not negotiable at any escape-hatch level.

When those defaults are correct but specific deployment parameters need tuning,
Sol provides a four-level escape-hatch hierarchy. Use the lowest level that
solves your problem.

---

## The four-level hierarchy

### Level 1 — `sol.toml` high-level overrides (recommended)

For common per-service customisation. Validated by `sol` at plan time; invalid
values are rejected with a clear error before anything is applied. Values stay
in version control alongside the service source code.

See the [Supported `sol.toml` overrides](#supported-soltoml-overrides) table
below.

### Level 2 — Environment target inputs

For substrate-specific values that differ between environments (e.g. ECR
registry URL, Kubernetes cluster name, base domain). Passed through
`Sol_cli_env_target.t` when building a deployment plan. These are not
per-service — they apply to the entire workspace for a given environment.

Use `sol deploy <env>/<provider>/<region> --registry <url> --image-tag <tag>`
or the equivalent environment target configuration
(the target's own `registry` in `sol/environments.yml`, used as the default
when `--registry` is omitted).

### Level 3 — GitOps emit (`sol deploy --emit-to`)

For advanced manifest patching outside Sol's model. `--emit-to <dir>` writes
the complete generated YAML to a directory; a GitOps tool (Argo CD, Flux) or
Kustomize overlay can then patch it before application.

Sol owns the base manifests. Your overlays own the delta. Changes made via
overlays are not visible to `sol plan` — treat them as a
seam, not a primary workflow.

### Level 4 — Raw Kubernetes / Terraform (self-managed)

For teams that have outgrown Sol's model entirely. Write your own Deployments,
Services, and Terraform modules. Sol does not generate or manage these
resources. You retain full control and full responsibility.

This is the same boundary stated as a principle: Sol plans and reconciles only
the resources its contracts declare, and integration with infrastructure you
manage outside Sol is yours to arrange through the stable identities, roles,
service accounts, namespaces and endpoints Sol exposes. See
[ADR 0005](../architecture/adr/0005-sol-owns-only-its-contract-boundary.md).

---

## Supported `sol.toml` overrides

All overrides live under sections in the per-service `sol.toml` file. The keys and
tables below are the whole schema: **an unknown key or table is an error** that names
it, so a typo such as `replica = 3` or `[infra.sacle]` stops `sol plan`/`sol deploy`
instead of silently deploying the default. Only the contents of `config`,
`extra_labels` and the volume names under `[infra.volumes]` are yours to choose.

### `[service]`

| Key     | Type     | Default | Description                                    |
|---------|----------|---------|------------------------------------------------|
| `calls` | string[] | `[]`    | Explicit service dependencies, e.g. `["checkout/checkout_svc"]`. |

Each `calls` entry must be `domain/service_name` and must point at another
`-svc` in the workspace. Sol resolves it to
`http://<service>.<workspace>-<domain>.svc.cluster.local`, adds
`<SERVICE>_URL` to the caller's ConfigMap, and opens only that caller/target
NetworkPolicy path. Cross-domain event messages remain the default integration
style; use `calls` only when a synchronous request is intentionally part of the
contract.

### `[infra.scale]`

| Key        | Type    | Default   | Description                              |
|------------|---------|-----------|------------------------------------------|
| `replicas` | integer | `1`       | Pod replica count                        |
| `cpu`      | string  | `"100m"`  | CPU request and limit (same value)       |
| `memory`   | string  | `"128Mi"` | Memory request and limit (same value)    |

### `[infra.volumes.<name>]`

Each entry declares one durable filesystem belonging to one `-svc` or `-worker`
instance:

```toml
[infra.volumes.data]
mount_path = "/var/lib/data"
size = "10Gi"
access_mode = "ReadWriteOnce"
```

Sol's `-svc` and `-worker` replicas are interchangeable Deployments. A workload
volume does not give replicas stable identities and is therefore supported only
with `replicas = 1`. Shared filesystems and per-replica volumes are not yet Sol
capabilities; use managed storage outside the workload when multiple replicas
need durable data. Functions do not support workload volumes.

| Workload | Replicas | Volume support |
|----------|----------|----------------|
| `-svc`, `-worker` | `1` | One PVC per declared workload volume |
| `-svc`, `-worker` | Any value other than `1` | Rejected before rendering |
| `-fn` | n/a | Rejected before rendering |

`access_mode` accepts `ReadWriteOnce`, `ReadOnlyMany`, or `ReadWriteMany`, but
describes the generated PVC only; it does not opt into a shared-volume semantic.

### `[infra.env]`

| Key      | Type          | Default | Description                                      |
|----------|---------------|---------|--------------------------------------------------|
| `config` | inline table  | `{}`    | Extra ConfigMap entries: `{ KEY = "value", ... }` |

Keys in `config` are added to the service ConfigMap alongside Sol's built-in
cluster defaults (Kafka brokers, Loki URL, etc.). They must not override
Sol's reserved keys (`KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL`, `LOKI_URL`,
`PUSHGATEWAY_URL`).

### `[infra.deploy]`

| Key                 | Type   | Default          | Description                                             |
|---------------------|--------|------------------|---------------------------------------------------------|
| `rollout_strategy`  | string | `"RollingUpdate"`| Deployment rollout strategy. Accepted: `"Recreate"`, `"RollingUpdate"`. |
| `ingress_host`      | string | _(match all)_    | Hostname for the Ingress rule. Omit to match all hosts. |
| `ingress_path`      | string | `"/"`            | Path prefix for the Ingress rule.                       |

`rollout_strategy` accepts exactly two values. Any other value is rejected at
plan time:

```
sol.toml: unsupported rollout_strategy "Blue/Green" — valid values are "Recreate" and "RollingUpdate"
```

`ingress_host` and `ingress_path` only affect `-svc` primitives. Workers and
functions do not produce an Ingress resource.

### `[infra.labels]`

| Key            | Type         | Default | Description                                            |
|----------------|--------------|---------|--------------------------------------------------------|
| `extra_labels` | inline table | `{}`    | Additional pod-template labels: `{ key = "value", ... }` |

Extra labels are added to the pod template's `metadata.labels` block alongside
the required `app: <name>` label.

**Guardrail:** Keys starting with `sol.dev/` are reserved for Sol internals.
Attempting to set them raises an error:

```
sol.toml: extra_labels key "sol.dev/owner" is reserved — keys may not start with "sol.dev/"
```

### `[infra.rollout]` — Progressive delivery (Argo Rollouts)

> **Requires Argo Rollouts installed in the cluster.**
> Without it, `kubectl apply` will fail because the `argoproj.io/v1alpha1` CRD
> does not exist. Sol validates the configuration at plan time but cannot verify
> cluster readiness.

This section opts a service into progressive delivery using
[Argo Rollouts](https://argoproj.github.io/argo-rollouts/). Sol renders an Argo
`Rollout` resource instead of a standard `Deployment`. All other resources
(ConfigMap, Secret, ServiceAccount, NetworkPolicy) are unchanged.

This is a **typed high-level escape hatch**, not raw Argo YAML. Sol supports two
strategies with a fixed, validated parameter set. For anything beyond what is
described here, use Level 3 (GitOps overlay) to patch the generated `Rollout`
manifest.

| Key        | Type             | Required | Description                                                         |
|------------|------------------|----------|---------------------------------------------------------------------|
| `strategy` | string           | yes      | Progressive delivery strategy. Accepted: `"canary"`, `"blue-green"`. |
| `steps`    | array of tables  | canary   | Ordered canary steps (required when `strategy = "canary"`).         |

#### Canary strategy

Sol renders a canary `Rollout` with the steps you define. Each step is an inline
table with exactly one key:

| Step form                     | Argo equivalent              | Description                                                 |
|-------------------------------|------------------------------|-------------------------------------------------------------|
| `{weight = 10}`               | `setWeight: 10`              | Route 10 % of traffic to the new version.                   |
| `{pause = {}}`                | `pause: {}`                  | Pause indefinitely — requires manual promotion.             |
| `{pause = {duration = 60}}`   | `pause: {duration: 60}`      | Pause for 60 seconds then auto-promote.                     |

Weights must be integers between 0 and 100. Pause durations must be positive
seconds. An empty steps array is rejected at plan time.

```toml
[infra.rollout]
strategy = "canary"
steps = [
  {weight = 10},
  {pause = {duration = 300}},
  {weight = 50},
  {pause = {}},
  {weight = 100},
]
```

A canary `Rollout` for a `-svc` primitive still emits a single ClusterIP
`Service` and an `Ingress`, pointing at the same `app: <name>` selector.

#### Blue-green strategy

Sol renders a blue-green `Rollout` with `autoPromotionEnabled: false`, meaning
the preview version must be manually promoted. No steps are needed.

```toml
[infra.rollout]
strategy = "blue-green"
```

Blue-green emits **two** ClusterIP `Service` resources instead of one:

- `<name>-active` — receives live production traffic.
- `<name>-preview` — receives pre-promotion canary traffic.

The `Ingress` is updated to point at `<name>-active`. Argo Rollouts manages the
pod-selector swap on promotion.

#### Out of scope

The following Argo Rollouts features are not supported through `sol.toml` and
require a Level 3 GitOps overlay if needed:

- Traffic-manager integrations (Istio, NGINX, ALB, Traefik weight annotations).
- `AnalysisTemplate` / automated metric-based promotion.
- Anti-affinity, header-based routing, or mirror traffic.
- `workloadRef` pointing at an existing `Deployment`.

---

## Non-overridable invariants

The following security defaults are enforced at all times and cannot be
overridden through any escape hatch:

| Invariant                        | Kubernetes field                                          |
|----------------------------------|-----------------------------------------------------------|
| Non-root container               | `securityContext.runAsNonRoot: true`, `runAsUser: 65534`  |
| No privilege escalation          | `securityContext.allowPrivilegeEscalation: false`         |
| Read-only root filesystem        | `securityContext.readOnlyRootFilesystem: true`            |
| Seccomp runtime default          | `securityContext.seccompProfile.type: RuntimeDefault`     |
| ClusterIP only (no NodePort)     | `spec.type: ClusterIP`                                    |
| Secrets via SecretRef, not values| Secrets are emitted as `Secret` objects, never inline env |

If you need to relax any of these, use Level 3 (GitOps overlay) or Level 4
(raw Kubernetes). Be aware that relaxing them voids Sol's security baseline.

---

## Example `sol.toml`

Standard deployment with common overrides:

```toml
[infra.scale]
replicas = 3
cpu      = "500m"
memory   = "512Mi"

[infra.env]
config = { APP_ENV = "production", FEATURE_FLAGS_URL = "http://flags.internal" }

[infra.deploy]
rollout_strategy = "Recreate"
ingress_host     = "payments.example.com"
ingress_path     = "/api"

[infra.labels]
extra_labels = { team = "payments", cost-center = "billing" }
```

Progressive delivery with canary steps (requires Argo Rollouts):

```toml
[infra.scale]
replicas = 3

[infra.rollout]
strategy = "canary"
steps = [{weight = 10}, {pause = {duration = 300}}, {weight = 50}, {pause = {}}, {weight = 100}]
```

Progressive delivery with blue-green (requires Argo Rollouts):

```toml
[infra.rollout]
strategy = "blue-green"
```

---

## When to use each level

| Situation                                              | Level |
|--------------------------------------------------------|-------|
| Tune replicas, CPU, memory                             | 1     |
| Add environment variables to the ConfigMap             | 1     |
| Change rollout strategy (Recreate / RollingUpdate)     | 1     |
| Canary or blue-green progressive delivery              | 1     |
| Override ingress hostname or path                      | 1     |
| Add team/cost-centre pod labels                        | 1     |
| Point to a different registry or image tag             | 2     |
| Set a base domain for ingress hostname derivation      | 2     |
| Apply a Kustomize patch or Argo CD overlay             | 3     |
| Add sidecar containers                                 | 3     |
| Use a custom StorageClass or PodDisruptionBudget       | 3     |
| Manage your own Helm charts                            | 4     |
| Write Terraform modules outside Sol's platform/cloud/           | 4     |
