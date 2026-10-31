# Component and platform-service contracts

**Audience:** contributors changing manifests, deployment planning, provider adapters, or
observability/resource delivery.

This page records the contracts Sol has today. It is deliberately smaller than a universal
component framework: each contract below has a current consumer, and a new abstraction is added
only when a provider backend must translate a real declaration.

## 1. Compute component contract

A unit is declared once in `app/<domain>/<name>_<kind>/` and `sol.yml`. The kind is the
application contract:

| Kind | Contract | Kubernetes | Target-scoped serverless |
|---|---|---|---|
| `_svc` | HTTP server, `/healthz`, `/readyz`, auth per route | Deployment + Service | AWS Lambda; GCP Cloud Run |
| `_worker` | Kafka consumer, ack/fail, drain | Deployment | not supported |
| `_fn` | run-to-completion / schedule | CronJob | AWS Lambda run-once; GCP Cloud Run Jobs |

A serverless target deploys every selected `_svc`/`_fn` unit; `_worker` is refused rather than
silently mapped to a different delivery semantic.

## 2. Requirements and capabilities

The canonical requirement model is `Sol_cli_grant`:

- a unit has zero or more `requirement` values;
- each requirement has a provider-independent capability and an opaque resource identity;
- the current realized capability is `Secret_access`;
- provider backends translate that requirement into their native grant.

Application secrets remain declared in `sol.toml`; they are not a second authorization model.
The authorization root receives the resulting requirements and emits provider IAM/service-account
grants. Unsupported capability/provider combinations must fail closed in the CLI before apply.

## 3. Dependencies

- `uses` is a dependency on a declared resource (`postgres`, `kafka`, and their bindings).
- `calls` is a service-to-service HTTP dependency and projects a caller env var plus identity
  context.
- Resource bindings decide ownership (Sol or external), credential source, and delivery; the
  resource name is the identity end to end.
- Removing `uses` removes delivery, never deletes the resource.

A general component dependency graph (queue/storage/third-party service) is **not** contracted
yet; do not represent it as one of the existing edges.

## 4. Configuration

- `sol.toml` owns application intent: scaling, env config, declared secrets, calls, schedule,
  rollout.
- The target file owns destination and backend selection.
- Provider-specific target fields belong in the provider block; the CLI may not infer them from
  application code.
- The renderer takes the resolved plan, not provider-specific reconstruction of it.

## 5. Identity

- Kubernetes workloads use the platform workload identity and declared callers.
- Target-scoped AWS Lambda and GCP serverless units receive one runtime identity per unit from the
  authorization root.
- The Pub/Sub push identity is separate from the runtime identity.
- Identity is recorded in the release record and verified against the live provider resource
  during deploy, rollback, and destroy.

## 6. Lifecycle and provenance

- Deployment planning resolves units, images, requirements, dependencies, and identity before
  mutation.
- A release record carries the provider identity, artifact identity, runtime identity, and the
  rollback identity needed to reverse it.
- Destroy verifies ownership and identity before removing resources and independently establishes
  absence.
- Provider release records still have provider-specific fields; a shared schema is a remaining
  gap.

## 7. Backend matrix

| Platform service | Current backends | Contract status |
|---|---|---|
| Compute | Kubernetes, AWS Lambda, GCP Cloud Run/Jobs | Contracted for `_svc`/`_fn`; no managed `_worker` |
| Database | Sol-managed PostgreSQL, external binding | Contracted through `uses` and resource bindings |
| Queue | Kafka/Redpanda; standalone SQS/Pub/Sub task lifecycles | Not unified with target-scoped components |
| Storage | provider/application-specific | No provider-independent resource contract yet |
| Logs | in-cluster Loki or external Loki | Target URLs/usernames; passwords remain Terraform secrets |
| Metrics | in-cluster Prometheus or external remote-write | Target URLs/usernames; passwords remain Terraform secrets |
| Traces | in-cluster Tempo or external OTLP/HTTP | Target URL; header auth via `TEMPO_HEADERS` secret |

External observability is a Kubernetes-platform contract:

- `observability_backend`, `observability_logs_url`,
  `observability_metrics_url`, `observability_traces_url`, and the two
  non-secret usernames are target fields;
- basic-auth passwords remain Terraform secret inputs;
- `TEMPO_HEADERS` (comma-separated `Name=Value`) is a unit secret for
  header-authenticated OTLP exporters;
- empty `observability_traces_url` disables tracing rather than targeting an
  absent in-cluster Tempo;
- serverless targets use provider-native observability and do not apply this
  Kubernetes-platform validation.

## 8. What is intentionally not abstracted

- No universal component interface spanning services, jobs, queues, and storage.
- No provider-specific IAM vocabulary in application manifests.
- No second lifecycle for a backend that already has a provider-native one.
- No speculative storage/queue capability until a backend translation and consumer exist.

The next justified improvements are the ones that convert an existing concrete declaration into
one of these contracts: target-scoped task components, a storage capability with a provider
translation, and a shared release-record schema.
