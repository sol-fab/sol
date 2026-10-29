# Execution boundaries

This page maps the execution architecture: workload kinds, their local and
deployed runtimes, the CLI lifecycle layers, and the provider adapters. It is a
current-state map, not a new abstraction. The verification map is
[`internal/ci/README.md`](../../internal/ci/README.md); the execution-backend
decision is [ADR 0010](adr/0010-execution-backends.md).

## Workload kind and execution backend are separate

A workload kind describes the application contract. The backend describes where
and how Sol runs it. They are not interchangeable.

| Kind | Application contract | Local / Kubernetes | Managed/serverless |
|---|---|---|---|
| `-svc` | HTTP request/response, `/readyz`, identity-checked routes | Deployment + Service | AWS Lambda through the request adapter (target `execution: serverless`); GCP Cloud Run |
| `-worker` | Long-running Kafka consumer group, `Ack`/`Fail`, drain on SIGTERM | Deployment | **No managed mapping.** SQS/Pub/Sub are not substituted for Kafka semantics |
| `-fn` | Run-to-completion; scheduled locally | CronJob | AWS Lambda run-once; GCP `-fn` target dispatch is not implemented and is refused |
| `-jobs` (`sol-jobs`) | Durable leased Postgres jobs; retry/backoff, terminal failure, retention | Hosted by a `-worker` | No separate provider mapping; a cloud worker hosts the same loop |
| `-task` (`sol-task`) | Durable task handler: stable `task_id`, `Ack`/`Retry`, at-least-once, provider-managed terminal delivery | Hosted by a `-worker` over `sol-jobs` (`sol-task.local`) | AWS SQS + Lambda (`sol-task.lambda`); GCP Pub/Sub + Cloud Run (`sol-task.pubsub`) |

`-jobs` and `-task` are libraries, not deployment primitives. A task handler is
not a renamed Kafka `-worker`, and a `sol-jobs` row is not a generic queue. The
provider task lifecycle commands are standalone experimental lifecycles; target-
scoped dispatch does not yet create task queues/triggers.

## Package and library ownership

### Application framework

| Package | Owns | Depends on |
|---|---|---|
| `sol-svc-core` | Shared HTTP/auth/lifecycle contracts, identity and observation types | `jose`, `yojson` |
| `sol-svc` | HTTP server runtime, routing, response/request handling, auth cache | `sol-svc-core`, `sol-obs`, `sol-runtime`, Eio/Cohttp |
| `sol-worker` | Kafka consumer runtime, offset/ack/drain lifecycle | `kafka-eio`, `kafka-eio-service`, `sol-obs`, `sol-runtime` |
| `sol-fn` | Run-once Lambda runtime and scheduled function plumbing | `lambda-eio`, `sol-env`, `sol-obs`, `sol-runtime` |
| `sol-jobs` | Postgres durable jobs, leasing, retry/backoff, terminal/retention, metrics | `pg-eio`, `caqti`, `sol-retry`, `sol-obs`, `sol-runtime` |
| `sol-task` core | Task envelope/identity/outcome contract only | `yojson`, `unix`, `threads` |
| `sol-task.local` | Postgres task runtime over `sol-jobs` | `sol-task`, `sol-jobs` |
| `sol-task.lambda` | SQS/Lambda event runtime, batch item failures | `sol-task`, `lambda-eio` |
| `sol-task.pubsub` | Pub/Sub push HTTP runtime, 200/500/400 mapping | `sol-task`, `cohttp-eio`, `sol-runtime` |
| `sol-obs` | Metric/log/trace conventions and provider plumbing | obs/OTel packages |
| `sol-env` | Environment/config plumbing | Eio |
| `sol-runtime` | Shared Eio runtime plumbing | Eio |
| `sol-retry` | One bounded retry policy vocabulary | Eio |

The direction is: application runtime packages depend on shared contracts and
plumbing; they do not depend on the CLI. `sol-task` core has no provider
dependency; provider runtimes are separate libraries in the same package.

### CLI lifecycle layers

| Layer | Owns | Examples |
|---|---|---|
| `sol_cli_base` | Config, manifests, errors, process/JSON/FS plumbing, build info | `sol_cli_config`, `sol_cli_manifest`, `sol_cli_process` |
| `sol_cli_workspace` / `sol_cli_kube` | Workspace discovery/rendering and Kubernetes/kubectl operations | `sol_cli_workspace`, `sol_cli_kubectl` |
| `sol_cli_local` | Local substrate/up/run orchestration | local platform commands |
| `sol_cli_cloud` | Shared cloud lifecycle policy and provider adapters | serverless lifecycle/target common, ownership reconciliation, AWS/GCP cluster/serverless/Cloud Run/Lambda/Terraform adapters |
| `sol_cli_deploy` | Deployment plan/selection, release store, rollback, migration gate, authorization | `sol_cli_deploy_run`, `sol_cli_release`, `sol_cli_rollback`, `sol_cli_migration_gate` |

`sol_cli_deploy` depends on `sol_cli_cloud`; the cloud library does not depend on
the deploy library. That is the intended direction: provider adapters and
shared cloud lifecycle mechanics sit below deployment policy, which sits below
the CLI command surface.

Within `sol_cli_cloud`:

- **Shared policy:** `sol_cli_serverless_lifecycle` (target-scoped dispatch),
  `sol_cli_serverless_target_common` (target/identity/refusal policy),
  `sol_cli_provider_registry`/`sol_cli_provider_capabilities` (provider
  capabilities), `sol_cli_ownership_reconciliation`, and the Terraform/cluster
  lifecycle modules. Release records and rollback policy live in
  `sol_cli_deploy`.
- **Provider adapters:** `sol_cli_aws_*`, `sol_cli_gcp_*`, `sol_cli_cloud_run`,
  `sol_cli_aws_lambda*`, and the task-specific `sol_cli_aws_task` module.
  Shared Lambda function/version/alias mechanics are in
  `sol_cli_aws_lambda_common`; Cloud Run service mechanics are in
  `sol_cli_cloud_run`. Providers do not call each other's adapters. The task
  provider lifecycles are standalone; they are not part of target-scoped
  dispatch.
- **Target serverless scope:** AWS supports `-svc` and `-fn`; GCP supports
  `-svc`; both refuse `-worker`. GCP refuses `-fn`. This is explicit in the
  adapters, not inferred from a service name.

## Where shared invariants live

- Workload identity/auth: `sol-svc-core` for HTTP; provider-native identity in
  the serverless adapters; no shared "identity provider" abstraction.
- Task envelope, identity and outcome: `sol-task` core. Delivery semantics are
  provider-specific and documented in the package spec.
- Durable retry/lease/terminal behavior: `sol-jobs`; task-local reuses it rather
  than duplicating the queue.
- Release records, ownership and rollback shape: `sol_cli_deploy` + provider
  adapters; provider-native identity (Lambda version/alias, Cloud Run revision,
  SQS/SNS/Pub/Sub ARNs) is recorded by the adapter.
- Ownership proof: `docs/architecture/ownership.md`; provider adapters must
  refuse foreign resources and establish absence independently.

## Why this map does not introduce a package split

The audit found the existing package/library split meaningful: framework
runtimes depend on shared contracts and plumbing, not on the CLI; provider
adapters sit below deployment policy; and the task core/provider runtimes are
separate libraries. The concrete defect found was not a package boundary but a
missing development dependency (`sol-task` was absent from
`prepare-framework-deps.sh`); that is fixed. No new package, repository or
universal execution abstraction is introduced merely to make the map tidier.

## Known limitations (current revision)

- `sol_cli_cloud` is one Dune library containing both shared lifecycle policy and
  provider adapters. The coarse boundary is deliberate for now: no concrete
  dependency direction or testability failure has justified splitting it into
  multiple libraries. A split would be a broad, cross-cutting refactor and is
  not made merely to match this map.
- `sol_cli_base` is broader than its name: it also carries migration execution,
  scaffold templates, provider/credential types and process helpers. No split is
  made here; it has no dependency cycle, and the command-boundary tests cover
  its consumers. Moving migration execution into the deploy layer is a
  cross-cutting change that should be justified by a concrete failure, not by
  the map alone.
- Target-scoped serverless dispatch covers `-svc` and, on AWS, `-fn`; it does not
  cover `-worker` or the standalone task lifecycle. A task queue/trigger is not
  created by `sol deploy`.
- The AWS task lifecycle is an experimental standalone command with its own
  ownership record; it is not yet integrated with the target release store. The
  `sol-task.pubsub` runtime exists, but the target-scoped dispatch does not yet
  create task queues or triggers.
- Live provider behavior is qualified separately and is not part of ordinary PR
  CI; see [`internal/qualification/README.md`](../../internal/qualification/README.md).
- `sol-task` supports the task runtime on all three environments, but the
  current provider mapping and its evidence are not a parity claim: local,
  SQS/Lambda and Pub/Sub/Cloud Run have different delivery windows, counters,
  retention and terminal destinations.

## Verification

Use [`internal/ci/README.md`](../../internal/ci/README.md) for the suite map,
change-category matrix, required check, measured step costs, and limits. The
authoritative full path is the CI `test` job plus the advisory jobs; focused
local commands are complements, not substitutes.
