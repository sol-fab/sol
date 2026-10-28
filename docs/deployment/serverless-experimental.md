# Experimental serverless execution

This page records the current, deliberately narrow serverless slice. It is not
part of the `production-single-region/v1` contract.

## Support matrix

| Capability | Local | Kubernetes | GCP Cloud Run | AWS Lambda |
|---|---|---|---|---|
| `-svc` HTTP | native `sol local run` | supported | `sol cloud-run`; live-proven | `sol lambda`; live-proven |
| `-worker` | native run with explicit Kafka/Postgres | supported | not supported | not supported |
| `-fn` | `sol local invoke` | CronJob | not supported | not supported |
| Queue/trigger | explicit Kafka/Postgres only | Kafka/Postgres | none | none |
| Secrets/dependencies | injected locally | supported | env/identity proven | env/identity proven |
| Identity | local explicit | supported | Google workload token | Google app token; no AWS-native identity |
| Observability | app logs/metrics | supported | app/provider logs | app/CloudWatch logs |
| Upgrade/rollback | n/a | supported | revision/traffic | version/alias |
| Destroy/absence | n/a | supported | live-proven | live-proven |

The serverless commands are experimental provider commands. They are not yet
target-scoped `sol deploy` execution, and no serverless production claim is made.

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

## GCP Cloud Run HTTP

The Cloud Run lifecycle uses the same application container and a Google OIDC
application-audience token; its deploy/verify/rollback/destroy behavior is
covered by the provider CLI and prior bounded live evidence. It uses the same application container and a
Google OIDC application-audience token. Cloud Run is also a standalone
experimental command, not yet a target execution backend.

## Not implemented

- serverless `-worker` or queue delivery;
- serverless `-fn` or cron/event triggers;
- target-scoped `execution` selection;
- AWS-native workload identity;
- managed ECR/IAM/secret provisioning for the Lambda path;
- production-profile qualification.

## Target execution selection (foundation)

Targets can declare execution explicitly:

```yaml
production:
  targets:
    aws/us-east-1:
      execution: serverless
```

`execution: kubernetes` is the default. The value is validated and merged with
environment/target overlays. `sol deploy` currently **fails closed** when a target
selects `serverless`: it refuses rather than planning or mutating Kubernetes for a
target whose execution backend is not wired yet.

This is a schema/refusal foundation, not target-scoped serverless deployment.
The provider lifecycle commands remain the supported experimental path until the
`sol deploy` dispatch is implemented.

## Target-scoped AWS Lambda HTTP (stacked implementation)

An AWS target can now select `execution: serverless` and deploy one HTTP `-svc` with an
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
`sol deploy production/aws/us-east-1 --image-ref checkout_svc=...@sha256:...` uses the
verified Lambda lifecycle and writes `serverless-release.json` in the deploy run log.

Current limits: exactly one HTTP `-svc`, no service dependencies, apply only (no
dry-run/emit), and the application token remains the Google demonstration identity
rather than AWS-native incoming identity.

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

## Target-scoped destroy

Serverless targets destroy through the same target command:

```text
sol destroy <target> --apply --service checkout_svc --record <serverless-release.json>
```

`--apply`, `--service`, and the ownership record are required. The record must match the
target's provider, region/project, and service. Inventory failure or an ambiguous provider
answer fails closed; absence is positively checked. `--plan` is refused for serverless
targets rather than pretending a read-only destroy plan is authoritative. Rollback remains
a standalone provider lifecycle command until the target release model can identify a
previous serverless release.
