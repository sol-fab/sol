# Serverless execution

This page records the serverless execution modes inside the v0.1
`production-single-region/v1` contract. Inclusion in the contract is not a
qualification claim: the matrix below records evidence, and the production gate
in [`compatibility.md`](compatibility.md) remains open where a cell is not
`prod`.

## Support matrix

Evidence columns name what actually exists: a fake-provider lifecycle regression,
a bounded live run, or an explicit gap. A live run creates only the resources it
needs and independently verifies their absence afterwards.

| Capability | Local | Kubernetes | GCP Cloud Run | AWS Lambda |
|---|---|---|---|---|
| `-svc` HTTP | native `sol local run` | supported | target + standalone; live | target + standalone; live |
| `-worker` | native run with explicit Kafka/Postgres | supported | not supported | not supported |
| `-fn` run-once | `sol local invoke` | CronJob | target deploy/execute/rollback/destroy; live | target deploy/invoke/rollback/destroy; fake + live |
| `-fn` HTTP (public) | `sol local run` | Deployment + Service + Ingress | target deploy/rollback/destroy; fake | target deploy/rollback/destroy; fake |
| `-fn` HTTP (internal) | not local | Deployment + Service, workload auth | target deploy/rollback/destroy; fake | refused: no network-private Lambda HTTP endpoint |
| Queue/trigger | explicit Kafka/Postgres only | Kafka/Postgres | none | none |
| Secrets/dependencies | injected locally | supported | env/identity proven; `uses:` refused | env/identity proven; `uses:` refused |
| Identity | local explicit | supported | `-svc`: Google workload token, explicit callers; `-fn`: execution service account only, no incoming callers | `-svc`: Google app token, explicit callers; `-fn`: execution role only, no incoming callers |
| Observability | app logs/metrics | supported | provider/app logs; no Sol acceptance | provider/CloudWatch logs; no Sol acceptance |
| Target deploy | n/a | supported | `-svc` and `-fn` live, including scheduled `-fn` | `-svc` and `-fn` live, including scheduled `-fn` |
| Target rollback | n/a | release based | `-svc` live; `-fn` execution-history live | `-svc` and `-fn` live |
| Target destroy/absence | n/a | supported | `-svc` and `-fn` live | `-svc` and `-fn` live |
| Plan projection | n/a | supported | fail closed | fail closed |
| Post-deploy execution smoke | n/a | readiness/rollout | `-svc`: readiness 200 + unauth 401; `-fn`: one completed Cloud Run Job execution | `-svc`: readiness 200 + unauth 401; `-fn`: invoke through the live alias returns `{"status":"ok"}` |

The `-fn` row covers the run-once contract only; no scheduler, event trigger, or
`uses:` dependency is created by any serverless target. Those are explicit v0.1
limits, not an implied capability. Serverless observability is provider-native
today; Sol acceptance of provider logs/metrics is an open production gate, not
a claim.

## Observability acceptance

Serverless targets use **provider-native observability**. For v0.1 the accepted
boundary is:

- CloudWatch Logs for AWS Lambda / SQS and Cloud Logging for GCP Cloud Run
  services/jobs, queried by the provider resource identity;
- provider-native invocation, error, duration, queue/topic, and DLQ metrics;
- task logs carrying the stable `task_id`, `kind`, and `acknowledged`/`retry`
  outcome;
- DLQ inspection through the AWS DLQ or Sol's GCP pull subscription.

Sol does **not** install Grafana on a serverless target, does not claim a
Sol-managed log/metric/trace acceptance layer, and does not propagate W3C trace
context through task envelopes. Those are explicit boundaries, not silently
missing features. The Kubernetes/local target's Grafana, TLS, OIDC, and
dashboard evidence is separate and remains a production-profile gate.

The production gate requires a live provider log/metric query for each
serverless/task mode. The demo's evidence uses, for example:

```sh
aws logs filter-log-events   --log-group-name /aws/lambda/pluto-tasks-task   --filter-pattern task_consumer

gcloud logging read   'resource.type="cloud_run_revision" AND resource.labels.service_name="pluto-tasks-gcp-task" AND textPayload:"task_consumer"'   --project <project> --limit 20 --freshness 1d
```

No dashboard or alert-delivery claim follows from a log query.

## AWS Lambda HTTP

The same `-svc` container is extended with AWS Lambda Web Adapter:

```text
FROM <sol-svc image>
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.8.4 \
  /lambda-adapter /opt/extensions/lambda-adapter
ENV AWS_LWA_PORT=8080
```

The image must be in an ECR repository and an existing Lambda execution role is
required. The adapter does not create ECR repositories, roles, IAM policies, or
other account resources.

```text
sol lambda deploy \
  --profile <aws-profile> --region <region> \
  --service checkout_svc \
  --image <ecr-repo>@sha256:<digest> \
  --role <lambda-execution-role-arn> \
  --unit checkout/checkout_svc \
  --issuer https://accounts.google.com \
  --jwks-uri https://www.googleapis.com/oauth2/v3/certs \
  --caller checkout/checkout_svc=<subject> \
  --record ./release.json

sol lambda verify ... --token-file <file>
sol lambda rollback ... --to-version <previous-version> --token-file <file>
sol lambda destroy --profile <profile> --region <region> \
  --service checkout_svc --record ./release.json
```

`deploy` creates/updates the function, publishes a version, moves the `live`
alias, creates/repairs the Function URL permissions, and records the observed
URL/version. `verify` checks readiness, authorized `/quote`, and unauthenticated
`/quote` separately. `destroy` requires the release record, checks ownership
tags, deletes the URL/function, and verifies absence by listing functions.

The web-adapter deployment preserves the HTTP application contract; the Lambda
event model and AWS-native workload identity are not yet part of Sol's contract.

## AWS Lambda `-fn`

The `-fn` container uses the framework's `Fn.Lambda` runtime contract: it serves
the Lambda runtime API and answers each invocation with `{"status":"ok"}` on a
successful run. The image must be an immutable ECR digest. Sol provisions the
per-unit execution role through the target's authorization root; the ECR repository
is not created by Sol.

```yaml
production:
  targets:
    aws/us-east-1:
      execution: serverless
      aws:
        profile: production
```

```text
sol deploy production/aws/us-east-1 \
  --image-ref checkout_fn=<ecr-repo>@sha256:<digest>
```

There is no `serverless_callers` requirement for a `-fn`: it has no incoming HTTP
request. The execution role authorizes AWS resource access; triggers, schedules,
and incoming application identity remain separate contracts.

The lifecycle is:

- **deploy** creates or updates the function, publishes an immutable version,
  moves the `live` alias, writes the ownership record, invokes `{}` through
  `live`, and requires the response body `{"status":"ok"}`. A provider
  `FunctionError`, a non-200 `StatusCode`, or a different body fails the deploy,
  but the record still names the alias that is live so the resource remains
  destroyable. The ownership record carries `"kind":"fn"`.
- **rollback** checks ownership, moves `live` to the requested version, invokes
  again, and rewrites the record from the observed version.
- **destroy** reads the record, requires kind `fn`, checks the target region,
  service, provider function name, and ownership tags, deletes the function, and
  verifies absence by listing functions. Sol does not delete the ECR repository
  or execution role; live cleanup treats those as operator-owned experiment
  resources.

No Function URL is created, and no HTTP authentication smoke is claimed. The
record deliberately has no `url` field, so it cannot be mistaken for the HTTP
lifecycle.

## HTTP-triggered `-fn`

An HTTP `-fn` is a single handler exposed by the platform rather than an
application-owned HTTP server. Declare the trigger in `sol.toml`:

```toml
[service]
http_path = "/quote"
http_exposure = "public"   # public | internal
```

The application module uses `Fn.Make_http` (`handle : Request.t -> Response.t`)
instead of the run-once `run`. The same image runs on every backend: on Lambda
it translates API Gateway/Function URL events, and elsewhere it serves the route
(with `/healthz` and `/readyz`) over HTTP.

Exposure is a declaration, not a hint:

- **public** means the target's shared API is reachable anonymously. Sol
  reconciles one public API per target: an AWS API Gateway HTTP API, a GCP API
  Gateway, or the Kubernetes ingress host shared by all public HTTP functions.
  Each function is one route on that API.
- **internal** means the endpoint is not internet-reachable **and** the handler
  keeps Sol's workload-identity check. Kubernetes renders a Service with no
  Ingress (and its NetworkPolicy); GCP renders Cloud Run with
  `--ingress internal` and injects the target's caller set. The caller set is
  `serverless_callers` on a serverless target and the declared `calls` graph on
  Kubernetes. An internal function with no callers is refused.

AWS supports public HTTP functions only. A Lambda Function URL is reachable from
the public internet even when it requires IAM, so Sol refuses an internal HTTP
function on AWS instead of creating a public endpoint that the configuration
calls internal.

### Shared endpoint and routing

Public HTTP functions in one target compose into one API:

| Backend | Shared endpoint | Route owner |
|---|---|---|
| Kubernetes | one ingress host; every public HTTP function contributes an Ingress path | Deployment + Service + path |
| AWS | API Gateway HTTP API `$default` stage | `ANY <http_path>` → Lambda `live` alias |
| GCP | API Gateway gateway host | OpenAPI path → Cloud Run service |

On Kubernetes, all public HTTP functions in a target must declare the same
`[infra.deploy] ingress_host`; two functions may not claim the same path. On
AWS and GCP, duplicate paths are refused before any provider mutation. Deploy
reconciles the complete route set: adding a function adds its route, changing a
path replaces it, and removing every public function deletes the gateway. A
failed route reconciliation leaves the function records destroyable and the
next deploy converges.

AWS HTTP functions do not get Function URLs. The API Gateway route is their
public HTTP address. GCP Cloud Run assigns a service URL to every service; the
API Gateway host is the canonical composed endpoint, but the provider-native
service URL still exists. Internal functions are never added to the public
gateway.

HTTP-function release records carry `"kind":"fn_http"`, the provider identity,
and `http_path`/`http_exposure`. Deploy writes a destroyable record before
mutation and names the observed serving revision/version before the readiness
smoke, so a partial failure is recoverable. Rollback restores the record's
serving version/revision and its route, so rolling back after a path change
serves the previous path again. Destroy removes the function's route first, then
the function; the last route removal deletes the gateway. Sol does
not delete the execution role or ECR repository.

Current limits: the HTTP-function runtime is OCaml (`Fn.Make_http`); a
TypeScript HTTP function is refused rather than deployed without a serving
contract. There is no shared **internal** HTTP gateway on AWS or GCP: internal
functions remain individually private, and AWS refuses internal HTTP functions
entirely. A complete workspace example, including a TypeScript Lambda probe
and SQS task consumers, is in [`examples/pluto/SERVERLESS.md`](../../examples/pluto/SERVERLESS.md).

## GCP Cloud Run HTTP

The Cloud Run lifecycle uses the same application container and a Google OIDC
application-audience token; its deploy/verify/rollback/destroy behavior is
covered by the provider CLI and prior bounded live evidence. Cloud Run is also a
standalone command and a target execution backend for `-svc`.

## Target-scoped AWS Lambda HTTP

An AWS target can select `execution: serverless` and deploy one HTTP `-svc` with an
immutable `--image-ref`:

```yaml
production:
  targets:
    aws/us-east-1:
      execution: serverless
      aws:
        profile: production
        serverless_callers: checkout/checkout_svc=1234567890
```

Sol provisions the unit execution role and its capability-derived IAM policy through the
authorization root; no ECR repository is created.
`serverless_callers` is required for a `-svc`: an empty application-authentication
policy is refused. `sol deploy production/aws/us-east-1 --image-ref
checkout_svc=...@sha256:...` uses the verified Lambda lifecycle and writes
`serverless-release.json` in the deploy run log with `"kind":"svc"`.

Current limits: a serverless-only target deploys exactly one `-svc` or `-fn`; a
mixed target composes the serverless function with its Kubernetes units and applies
both from one reviewed plan. In-cluster service dependencies remain unsupported
(external queue/object bindings are allowed), serverless-only deploys have no
dry-run/emit, and the application token for `-svc` remains the Google demonstration
identity rather than AWS-native incoming identity.

## Target-scoped GCP Cloud Run HTTP

GCP follows the same target contract:

```yaml
production:
  targets:
    gcp/us-west1:
      execution: serverless
      gcp:
        project_id: example-project
        serverless_callers: checkout/checkout_svc=1234567890
```

`sol deploy production/gcp/us-west1 --image-ref checkout_svc=...@sha256:...` uses the
verified Cloud Run lifecycle. `gcp.project_id` and the target region supply the provider
coordinates; Cloud Run creates no execution role. The ownership record is written after
the provider deploy returns and before the target's post-deploy smoke, so a failed smoke
still leaves a destroyable record. The same limits apply: one dependency-free HTTP `-svc`,
apply only, and application authentication remains explicit.

## Target-scoped GCP Cloud Run Jobs `-fn`

Cloud Run Jobs is a distinct run-to-completion backend; it does not reproduce Lambda
aliases, event payloads, or response bodies. The target contract is:

- deploy updates the Job template to the image digest, runs one execution, and requires
  the execution to complete with one successful task and no failed/cancelled tasks;
- the record carries the project, region, service, Job name, image, generation, and
  execution name;
- rollback names a prior execution with `--to-revision`; Sol reads that execution's
  image from its immutable template, patches the Job, runs a new execution, and records
  the new execution;
- destroy removes the Job's executions and the Job, then verifies both are absent;
- no schedule, trigger, input payload, or Lambda-style `{"status":"ok"}` response is
  inferred. The application's exit status and the execution counters are the success
  signal.

```yaml
production:
  targets:
    gcp/us-west1:
      execution: serverless
      gcp:
        project_id: example-project
```

```text
sol deploy production/gcp/us-west1 --image-ref probe_fn=<repo>@sha256:<digest>
sol rollback --target production/gcp/us-west1 --record <serverless-release.json> \
  --service probe_fn --to-revision <prior-execution>
sol destroy production/gcp/us-west1 --apply --service probe_fn \
  --record <serverless-release.json>
```

The Job is configured with one task, parallelism one, zero task retries, and a 600-second
task timeout. Because the provider has no alias, rollback requires an execution name; a
Job with no retained prior execution cannot be rolled back. Partial creates remain
destroyable because the intended record is written before the Job mutation, and a failed
execution is recorded before the command fails.

This path is live-qualified on 2026-10-29 in `sol-qualification`/`us-west1`. Both probes
deployed through the target lifecycle, their Cloud Run Job executions exited 0 with the
probe log, execution-history rollback restored the first image and started a new successful
execution, and destroy left no Jobs or executions. The OCaml and TypeScript probes run
unchanged: without a Lambda runtime API they execute their run-once path and exit; with
one they use Lambda. No concurrency, timeout, or throughput measurement was made; the
600-second timeout is configured, not measured.

## Target-scoped destroy

Serverless targets destroy through the same target command:

```text
sol destroy <target> --apply --service checkout_fn --record <serverless-release.json>
```

`--apply`, `--service`, and the ownership record are required. The record must match the
target's provider, region/project, service, and provider resource name. For AWS the
record's `kind` selects the HTTP or run-once lifecycle; for GCP a Cloud Run Job record
selects the Jobs lifecycle. A missing or unknown kind fails closed. Inventory failure or an ambiguous provider answer fails closed; absence is
positively checked. `--plan` is refused for serverless targets rather than pretending a
read-only destroy plan is authoritative.

## Target-scoped rollback

Serverless rollback uses the target's ownership record and an explicit prior provider
version/revision:

```text
sol rollback --target <target> --record <serverless-release.json> \
  --service checkout_svc --to-version <lambda-version> --token-file <token>

sol rollback --target <target> --record <serverless-release.json> \
  --service checkout_svc --to-revision <cloud-run-revision> --token-file <token>

sol rollback --target <target> --record <serverless-release.json> \
  --service probe_fn --to-revision <prior-execution>
```

For a GCP `-fn`, `--to-revision` names the prior Cloud Run Jobs execution; no token is
required because a run-once function has no incoming HTTP identity. For `-svc` the token
remains required. For AWS the record's `kind` selects the rollback lifecycle and the record must match the
target, service, and provider function name before the alias moves. The record is updated
immediately after the alias move, before the post-rollback smoke, so a failed smoke leaves
the record naming the version that is actually live rather than the previous version. GCP
`-svc` follows the same rule for the serving revision. The post-rollback check performs the
same execution smoke as deploy: readiness plus authorized/unauthorized requests for `-svc`,
or an invoke through `live` returning `{"status":"ok"}` for AWS `-fn`; a GCP `-fn`
rollback starts and verifies a new Cloud Run Job execution. Kubernetes rollback continues
to require `RELEASE_ID`.

### Serving mutations, records, and uncertain outcomes

For serverless targets, a version or revision move is a serving-state mutation, not a
generic provider call. The lifecycle contract is:

- record the new serving identity once provider observation establishes it, and before
  the execution smoke;
- verify the application postcondition separately;
- reconcile a mutation whose CLI call reported an error by observing whether the requested
  version or revision is actually serving;
- treat a reconciled mutation as applied, keep the original provider error as a warning,
  and continue to verification;
- leave the record unchanged when the mutation did not apply, and fail closed when the
  provider state cannot be read.

This is why a failed smoke does not silently leave the record naming the previous version.

## Explicitly unsupported serverless combinations

These are deliberate exclusions, not missing dispatch:

- **`-worker` on Cloud Run or Lambda:** the existing worker contract is Kafka/Postgres
  delivery with explicit acknowledgement and consumer-group semantics. Neither provider
  offers those semantics directly; SQS/Pub/Sub are not a drop-in substitute. No portable
  queue abstraction is introduced to make the matrix symmetrical.
- **A shared `-fn` event payload or Lambda-style response body on GCP:** Cloud Run Jobs
  takes command/args/env and reports task counters, not an invocation payload or a
  response body. The two probes deliberately ignore input and use exit status.
- **Scheduling or triggers for GCP `-fn`:** the Jobs backend deploys and executes the
  Job; Cloud Scheduler is a separate resource and is not created.
- **Alias-like atomic rollback for GCP `-fn`:** Cloud Run Jobs has no version/alias
  pointer. Rollback patches the Job from a named prior execution and runs a new
  execution; it is not atomic traffic movement.
- **Triggers and schedules for serverless `-fn`:** Sol deploys the run-once function and
  verifies a direct invocation. Event sources, schedules, and their identity are a
  separate contract and are not inferred from the execution backend.
- **Incoming AWS-native identity for `-svc`:** the Lambda execution role authorizes AWS
  resource access; incoming application authentication remains the explicit Sol
  workload-token contract. The Google-token experiment does not establish AWS-native
  incoming identity.
- **Serverless dependencies:** Kafka/Postgres bindings are not projected into serverless
  targets yet; a service declaring `uses:` is refused by target dispatch.
- **Serverless observability qualification:** application/provider logs exist, but no
  Sol-managed log/metric/trace acceptance is implemented.
- **Managed ECR/IAM/role provisioning:** the adapters consume an existing repository and
  execution role; they do not create or delete account resources outside the function.

A provider target that requests one of these combinations fails closed rather than
silently changing the primitive's semantics.

## Deploy execution postcondition

A successful serverless HTTP target deploy is not reported until the deployed service
answers its public readiness probe with `200` and an unauthenticated protected request
with `401`. A successful serverless `-fn` target deploy is not reported until an
invocation through the `live` alias returns `{"status":"ok"}` with no `FunctionError`.
Authorization with a caller token for `-svc` remains an explicit post-deploy
verification step.

`sol plan` projects serverless targets from the same release records and declarations the
target deploy consumes; it never invokes a provider mutation. `sol plan --out` persists the
transition and `sol deploy --plan` refuses to apply it if the recomputed transition differs.
Use `sol deploy` (serverless dispatch), `sol rollback`, and `sol destroy` for the target
lifecycle; the provider commands remain available for diagnostics.
