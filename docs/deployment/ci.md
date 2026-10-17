# CI and continuous deployment

Sol does not host CI: a workspace's own GitHub repository builds, tests and deploys
through one generated workflow. There is exactly one canonical copy,
[`platform/shared/templates/workspace/.github/workflows/sol-ci.yml`](../../platform/shared/templates/workspace/.github/workflows/sol-ci.yml):
`sol new workspace` scaffolds it, and `sol ci init github` writes it into an existing
workspace (refusing to overwrite an edited workflow unless `--force`). The checked-in
example is [`examples/pluto/.github/workflows/sol-ci.yml`](../../examples/pluto/.github/workflows/sol-ci.yml).

The workflow is a thin wrapper around the same lifecycle a human runs locally:

```bash
sol deploy <target> --registry "$SOL_REGISTRY" --image-tag "$SHA"
sol migrate <target>
```

There is no CI-only manifest path and no second deployment engine. Target selection is
explicit: `SOL_TARGET` is a repository variable passed to `sol deploy` verbatim, and the
workflow never infers a destination from the branch or the event (`DEC-016`).

## Jobs

| Job | Runs when | What it does |
|---|---|---|
| `build-and-test` | every push and pull request | `dune build`, `dune runtest`; the schema gate needs the `SCHEMA_REGISTRY_URL` secret |
| `build-images` | push to `main` | assumes the deploy identity, builds and pushes each `app/**/Dockerfile` |
| `authorize` | push to `main`, under the `sol-authorization` environment | assumes the reconciler identity, runs `sol grants plan` then `sol grants apply` |
| `deploy` | push to `main`, after `authorize`, under the `production` environment | assumes the deploy identity, runs `sol deploy` then `sol migrate` |

The `deploy` job depends on `authorize`, so a workload cloud grant is established before
the deploy that consumes it. If a grant is declared but not effective, `sol deploy` fails
at plan time, naming the unit, the grant and the reconciliation to run (`DEC-062` rule 3)
— it never creates or repairs the grant itself.

## The two identities

Deployment and workload authorization use **different** identities, and that separation is
the point of `DEC-062` rule 1: the identity that deploys cannot grant cloud authority.

| Identity | Environment | Repository variable | May |
|---|---|---|---|
| **deploy** | `production` | `SOL_DEPLOY_ROLE_ARN` / `SOL_DEPLOY_SERVICE_ACCOUNT` | push images, render and apply the deploy, and *observe* effective workload access read-only |
| **reconciler** | `sol-authorization` | `SOL_AUTHORIZATION_ROLE_ARN` / `SOL_AUTHORIZATION_SERVICE_ACCOUNT` | reconcile the target's workload roles and grants, fenced per `DEC-062` rule 2 |

Because the two jobs run under different GitHub environments, they present different OIDC
subjects, so the deploy identity cannot be assumed from the authorization job and vice
versa. The deploy identity holds no IAM-mutating permission at all; a structural guard
(`internal/ci/check_deploy_identity_iam.py`) enforces that.

## Repository variables

| Variable | Provider | Meaning |
|---|---|---|
| `SOL_TARGET` | both | `<env>/<provider>/<region>`, e.g. `prod/aws/us-east-1`; must be declared in `sol/environments.yml` |
| `SOL_REGISTRY` | both | image registry prefix, e.g. `123456789.dkr.ecr.us-east-1.amazonaws.com` |
| `SOL_DEPLOY_ROLE_ARN` | AWS | the target's `deploy_role_arn`, assumed through OIDC |
| `SOL_DEPLOY_SERVICE_ACCOUNT` | GCP | the deploy service account, impersonated through Workload Identity |
| `SOL_AUTHORIZATION_ROLE_ARN` | AWS | the target's `reconciler_role_arn` |
| `SOL_AUTHORIZATION_SERVICE_ACCOUNT` | GCP | the target's `reconciler_service_account` |
| `SOL_WORKLOAD_IDENTITY_PROVIDER` | GCP | the Workload Identity provider pool |
| `SOL_AWS_REGION` | AWS | the region to assume roles in |

The `authorize` job's steps are skipped when neither authorization variable is set, so a
workspace that has not adopted workload cloud grants still deploys.

## Provider-side trust

**AWS.** Create an IAM OIDC identity provider for `token.actions.githubusercontent.com`
(audience `sts.amazonaws.com`), then two roles whose trust policy scopes the subject to
the right environment:

- deploy role: `repo:<owner>/<repo>:environment:production`;
- reconciler role: `repo:<owner>/<repo>:environment:sol-authorization`.

The reconciler role is assumed by the authorization job and holds the fenced permissions
`sol deploy` uses for the target's authorization root. The deploy role is the
target's `deploy_role_arn` and holds only read-only IAM visibility plus cluster
description, so it can observe effective access but never widen it.

**GCP.** Create a Workload Identity Federation pool and provider bound to the repository,
then two service accounts: the deploy service account (the target's
`deploy_sa`) and the reconciler service account (the target's
`reconciler_service_account`). Set `SOL_WORKLOAD_IDENTITY_PROVIDER` to the provider
resource name.

## Environments

Configure two GitHub environments (Settings -> Environments):

- **`sol-authorization`** — add required reviewers. The `authorize` job runs under it, so
  adopting, dropping or widening a workload cloud grant is an approved action, separate
  from a merge.
- **`production`** — optionally add reviewers or branch restrictions for the deploy.

## Secrets

The workflow holds no long-lived cloud credentials (`DEC-057`) and no workload secret
values (`FEAT-053`). The only repository secret is `SCHEMA_REGISTRY_URL`, used by the
schema-compatibility gate; the schema check reports "NOT CHECKED" when it is absent.
Workload values are supplied without placing them in argv or CI logs. For an
automated Sol-owned key, pipe the secret source to:

```bash
your-secret-tool get payment-api-key \
  | sol secret set "$SOL_TARGET" payments/charge_svc/PAYMENT_API_KEY --from-stdin
```

Database access needs no CI step. A unit that declares `uses: [app_db]` reads the
target's deploy-delivered `<target>-dml-creds` class Secret, and the migration
Job reads `<target>-ddl-creds`; Sol does not accept an operator- or
CI-supplied `POSTGRES_URL`. The only target-scoped platform inputs CI writes are
the Kafka credentials a TLS contract Job needs, and only until #1344c binds them:

```bash
your-secret-tool get kafka-sasl-password \
  | sol secret set "$SOL_TARGET" @platform/KAFKA_SASL_PASSWORD --from-stdin
```

This writes only the target's `sol-secrets` objects used by internal Jobs. It
does not populate any application unit Secret.

The target explicitly maps every required key to `sol` or `external`. An external
key is delivered by a namespaced ESO `ExternalSecret`; the deploy applies the workload
only after ESO reports `Ready=True` / `SecretSynced`, and fails closed if it never does.
Generation freshness is part of that same readiness gate: the deploy requires
`status.syncedResourceVersion` to name the applied generation and fails closed when it is absent
or lagging (see the deployment guide).
