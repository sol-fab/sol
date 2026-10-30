# v0.1 production qualification checklist

Status: **proposed, not authorized**. This page records what is already available
for a v0.1 production qualification, what is missing, and the proposed release
candidate. It does not authorize a billable campaign, a tag, or a publication.

The contract is [`production-single-region/v1`](compatibility.md), including
the serverless and provider-task scope in
[ADR 0011](../architecture/adr/0011-production-serverless-and-tasks.md). The
authoritative evidence status is the README product matrix, generated from
`internal/qualification/product-matrix.json`.

## Proposed candidate

- **Version:** `v0.1.0-prealpha.5`
- **Revision:** the `main` commit after #1803 lands. The current draft
  `v0.1.0-prealpha.4` is at `70b191f4` and predates the v0.1 scope expansion,
  TypeScript local tasks, the execution matrix, and the GCP task hardening.
- **Tag/run:** not created. Tagging is a release action and needs explicit
  authorization.
- **Build inputs:** the repository variable
  `SOL_SETUP_POSTGRES_IMAGE` is present as a digest; the migration-runner image
  at the current candidate digest resolves anonymously from GHCR.

## Verified prerequisites

These were checked read-only on 2026-10-30.

### AWS

| Item | State |
|---|---|
| Credentials | `sol-qual` profile, qualification AWS account (12-digit ID redacted), `us-east-1`; SSO administrator session |
| Qualification roles | `sol-qual5-provisioner`, `cluster-access`, `deploy`, `operator`, `publisher`, `qualifier` exist |
| State backend | `sol-qual5-876701109436-tfstate` and `sol-qual5-tflock` exist |
| DNS | Route 53 zone `qual-aws.sol-fab.dev` exists |
| Existing target | `examples/pluto/sol/environments.local.yml` has prior `qualalpha9-1`/`qualalpha8-1` attempts |
| Disposable infrastructure | no current EKS cluster, RDS instance, ECR repository, or Pluto Lambda |
| Grafana OIDC | operator-provided OAuth client JSON exists for `grafana.qual-aws.sol-fab.dev` and `grafana.qual-gcp.sol-fab.dev`; values are local and must be supplied via `TF_VAR_grafana_oidc_*` |

### GCP

| Item | State |
|---|---|
| Credentials/project | `lbendtlynielsen@gmail.com`, project `sol-qualification`, billing active |
| State | GCS bucket `sol-qualification-tfstate` |
| DNS | Cloud DNS zone `qual-gcp.sol-fab.dev` |
| Publisher identity | `sol-qualification-publisher@sol-qualification.iam.gserviceaccount.com` |
| APIs | compute/container/sqladmin/artifactregistry/dns/iam/storage/secretmanager/servicenetworking enabled; Cloud Run disabled |
| Quotas | 200 CPUs, 4096 GB SSD, 8 static/in-use addresses in `us-central1`; no existing GKE or Cloud SQL |
| Disposable infrastructure | no current GKE cluster, Cloud SQL, Artifact Registry repo, Cloud Run service, or Pub/Sub task resource |

## Missing inputs or decisions

These are genuinely blocking a production qualification; none is safely
discoverable from the existing configuration.

| Input | Why it is needed | Current state |
|---|---|---|
| Alert acknowledgement | AWS G1–G3 and the GCP alert gate require a delivered and acknowledged alert, not just a configured URL | Receiver/owner/runbook are approved for reuse; the synthetic acknowledgement is performed during the authorized campaign |
| AWS target file refresh | The existing target has no `terraform_var_file`, omits both TypeScript units, and names an old cluster | Must be regenerated/edited with the v0.1 required units and current tfvars |
| GCP target TypeScript units | The GCP live target currently declares only the OCaml units | The target generator must include `order_svc` and `fulfillment_worker` for full parity |
| AWS current egress CIDR | `cluster_endpoint_cidr` must be a narrow operator CIDR, not stale or `0.0.0.0/0` | Existing value is `73.98.203.180/32`; confirm it is still the operator's egress |
| Database password | The AWS procedure requires `TF_VAR_db_password`; GCP setup has its own credential inputs | Operator-controlled; not discoverable |
| GCP CA-observer kubeconfig/principal | The GCP matrix requires an independent read-only observer | Not present in the inspected inputs |
| Production HA choices | AWS RDS Multi-AZ and GCP Cloud SQL Regional HA are production-profile requirements; the current GCP tfvars set HA false | Must be deliberately set/changed for a production-claiming attempt |
| Cloud Run API | Serverless qualification needs `run.googleapis.com`; it is currently disabled | Needs explicit enablement authorization |
| Serverless/task live campaigns | The Kubernetes production campaign does not qualify target serverless, DLQ, or provider task lifecycles | Need scoped campaigns and records; execution rows are not `prod` |
| Promotion enablement | The typed authorization path is implemented but temporarily disabled pending a producer-generated live-qualified candidate (#1738) | Needs an authorized candidate + both provider records + verifier chain, then the release policy must be exercised |
| Cost/billable window | EKS/GKE, RDS/Cloud SQL, brokers, monitoring, and restore tests create billable infrastructure | Requires operator authorization and a time window |
| OIDC environment wiring | The local OAuth client JSONs contain secrets and must not be committed | Set `TF_VAR_grafana_oidc_client_id`/`secret` from the local files for each campaign |

## Proposed sequence

1. Land #1803. Freeze the candidate revision.
2. Build `v0.1.0-prealpha.5` through `release.yml`; leave it as a draft.
3. AWS production campaign: provision, deploy, transaction, rollback/destroy,
   recovery/availability/alerts/observability rows; independently verify absence.
4. GCP production campaign with the same harness revision; independently verify
   absence.
5. Serverless/task campaigns for AWS and GCP, including DLQ and rollback; attach
   records and evidence.
6. Exercise the typed promotion path with the candidate records; only then
   enable/publish.
7. Publish only if every required row is `prod`/behavioural; do not substitute
   `live` or a skipped row.

## Explicitly not covered by this checklist

- Concurrency, timeout, throughput, or availability-SLA measurements.
- A central cross-environment observability plane.
- Hosted Sol control plane.
- A general provider matrix beyond the one supported profile.
