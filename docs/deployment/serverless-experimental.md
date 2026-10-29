# Experimental serverless execution

This page records the current, deliberately narrow serverless slice. It is not
part of the `production-single-region/v1` contract.

## Support matrix

Evidence columns name what actually exists: a fake-provider lifecycle regression,
a bounded live run, or an explicit gap. A live run creates only the resources it
needs and independently verifies their absence afterwards.

| Capability | Local | Kubernetes | GCP Cloud Run | AWS Lambda |
|---|---|---|---|---|
| `-svc` HTTP | native `sol local run` | supported | target + standalone; live | target + standalone; live |
| `-worker` | native run with explicit Kafka/Postgres | supported | not supported | not supported |
| `-fn` | `sol local invoke` | CronJob | not supported | target deploy/invoke/rollback/destroy; fake + live |
| Queue/trigger | explicit Kafka/Postgres only | Kafka/Postgres | none | none |
| Secrets/dependencies | injected locally | supported | env/identity proven; `uses:` refused | env/identity proven; `uses:` refused |
| Identity | local explicit | supported | Google workload token; explicit callers | `-svc`: Google app token, explicit callers; `-fn`: execution role only, no incoming callers |
| Observability | app logs/metrics | supported | provider/app logs; no Sol acceptance | provider/CloudWatch logs; no Sol acceptance |
| Target deploy | n/a | supported | `-svc` live | `-svc` and `-fn` live |
| Target rollback | n/a | release based | `-svc` live | `-svc` and `-fn` live |
| Target destroy/absence | n/a | supported | `-svc` live | `-svc` and `-fn` live |
| Plan projection | n/a | supported | fail closed | fail closed |
| Post-deploy execution smoke | n/a | readiness/rollout | readiness 200 + unauth 401 | `-svc`: readiness 200 + unauth 401; `-fn`: invoke through the live alias returns `{"status":"ok"}` |

No serverless production claim is made. The `-fn` row covers the run-once
contract only; no scheduler or event trigger is created by any serverless target.

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
successful run. The image must be an immutable ECR digest and the execution role
must already exist. Sol creates neither the ECR repository nor the role.

```yaml
production:
  targets:
    aws/us-east-1:
      execution: serverless
      aws:
        profile: production
        lambda_role_arn: arn:aws:iam::123456789012:role/sol-lambda-fn-exec
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

## GCP Cloud Run HTTP

The Cloud Run lifecycle uses the same application container and a Google OIDC
application-audience token; its deploy/verify/rollback/destroy behavior is
covered by the provider CLI and prior bounded live evidence. Cloud Run is also a
standalone experimental command and a target execution backend for `-svc`.

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
        lambda_role_arn: arn:aws:iam::123456789012:role/sol-lambda-exec
        serverless_callers: checkout/checkout_svc=1234567890
```

The target field names are explicit; no ECR repository, role, or IAM policy is created.
`serverless_callers` is required for a `-svc`: an empty application-authentication
policy is refused. `sol deploy production/aws/us-east-1 --image-ref
checkout_svc=...@sha256:...` uses the verified Lambda lifecycle and writes
`serverless-release.json` in the deploy run log with `"kind":"svc"`.

Current limits: exactly one `-svc` or `-fn` per target deploy, no mixed-primitive
deploy, no service dependencies, apply only (no dry-run/emit), and the application
token for `-svc` remains the Google demonstration identity rather than AWS-native
incoming identity.

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
coordinates; Cloud Run creates no execution role. The same limits apply: one
dependency-free HTTP `-svc`, apply only, and application authentication remains explicit.
A GCP serverless target with a `-fn` fails closed: Cloud Run Jobs is not implemented
and is not assumed to have AWS Lambda parity.

## Target-scoped destroy

Serverless targets destroy through the same target command:

```text
sol destroy <target> --apply --service checkout_fn --record <serverless-release.json>
```

`--apply`, `--service`, and the ownership record are required. The record must match the
target's provider, region/project, service, and provider function name. For AWS the
record's `kind` selects the HTTP or run-once lifecycle; a missing or unknown kind fails
closed. Inventory failure or an ambiguous provider answer fails closed; absence is
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
```

For AWS the record's `kind` selects the rollback lifecycle and the record must match the
target, service, and provider function name before the alias moves. The record is updated
immediately after the alias move, before the post-rollback smoke, so a failed smoke leaves
the record naming the version that is actually live rather than the previous version. The
post-rollback check performs the same execution smoke as deploy: readiness plus
authorized/unauthorized requests for `-svc`, or an invoke through `live` returning
`{"status":"ok"}` for `-fn`. Kubernetes rollback continues to require `RELEASE_ID`.

## Explicitly unsupported serverless combinations

These are deliberate exclusions, not missing dispatch:

- **`-worker` on Cloud Run or Lambda:** the existing worker contract is Kafka/Postgres
  delivery with explicit acknowledgement and consumer-group semantics. Neither provider
  offers those semantics directly; SQS/Pub/Sub are not a drop-in substitute. No portable
  queue abstraction is introduced to make the matrix symmetrical.
- **`-fn` on Cloud Run:** a GCP serverless target refuses `-fn`. Cloud Run Jobs is a
  different execution model and is not assumed to match the verified AWS Lambda
  function lifecycle; it requires its own audit and implementation.
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

`sol plan` currently refuses `execution: serverless` targets rather than projecting them as
Kubernetes. Use `sol deploy` (serverless dispatch), `sol rollback`, and `sol destroy` for
the target lifecycle; the provider commands remain available for diagnostics.
