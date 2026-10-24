# AWS production-single-region attempt on `v0.1.0-alpha.44` (2026-10-24)

**Verdict: promotion-eligible by the live AWS row. Not promoted.** This record is evidence for
the release gate; promotion is a separate, explicit action and was not run.

## Candidate and harness identity

| Field | Value |
|---|---|
| Candidate | `v0.1.0-alpha.44` |
| Sol revision | `8c74717712696f682d46571d3284138c015fa43e` |
| Bundle | `sol-v0.1.0-alpha.44-linux-x86_64.tar.gz`, sha256 `8a7b0479ea43a28f58ac9fb2b818206b69af968900da7b9a442dba1eb6b7f17e` |
| Migration runner | `ghcr.io/sol-fab/sol-migration-runner@sha256:d89423f0c5cb89c4173562ca23bdc614c5ff5c1d8a284bc31c0a32e0f0b0a500` |
| Harness | `2678805794fddcd16556d16b60b1f880813b35aa` (PR #1694, a descendant of the candidate) |
| Account / region | `876701109436` / `us-east-1` |
| Evidence | `/home/logan/qual-a45/aws-a45h-1/` (outside the repository) |

The application was materialized from the candidate revision; the harness revision is a
descendant because it contains the issuer-name and phase-lifecycle fixes used by the run.

## Specimen

| Field | Value |
|---|---|
| Target | `qual-a45h-aws/aws/us-east-1` |
| Cluster | `sol-qual-aws-a45h` |
| State key | `sol/qual-a45h-aws/aws/us-east-1/cloud.tfstate` |
| Attempt | `a45h-aws-1` |
| Issuer / claim | `letsencrypt-prod` / `production` |

## Phases

| phase | exit | evidence |
|---|---|---|
| `prepare` | 0 | five candidate-bound images; candidate/framework pins on `8c747177` |
| `cloud` | 0 | EKS, RDS, platform with production certificates, publisher push, cold-start boundary, whole-target plan |
| `app` | 0 | migration, transport, final deploy, database delivery, database-CA migration/application, transaction, Kafka delivery |
| `destroy` | 0 | release cleanup, substrate destroy, independent inventory |
| `verify` | 0 | independent inventory re-read ABSENT |

The phase ledger contains exactly one verdict per required phase, all `exit=0`;
`promotion_eligible=yes`, `required_phases_ok=yes`, `attempt_continuity=continuous`.

## Observations

- The platform ClusterIssuer `letsencrypt-prod` issued both `argocd-tls` and `grafana-tls`;
  production ACME is reachable. An earlier attempt (`a45g-aws-2`) used the nonexistent
  `letsencrypt-production` name and failed at platform readiness; #1693/#1694 corrected the
  qualification name. That failed attempt is not part of this specimen.
- The cold deploy reconciled the environment and refused at the artifact gate before any
  workload moved; the declared namespaces were positively absent.
- The final deploy moved all five selected units. The migration gate reported the declared
  migration set applied.
- The verification transaction was accepted, the worker consumed it, and the service read the
  worker's effect back out of PostgreSQL through the qualification transport.
- Kafka delivery observation passed: the managed credential was projected into the expected
  consumers, and the transaction establishes authentication/consumption.
- `destroy` returned success; the independent inventory read **ABSENT for every required
  disposable class**, including `eks-access-entry-policy`. The durable state bucket and
  delegated DNS zone are the documented externals, not residue.

## Non-claims

This run does not establish:

- GCP production support;
- TypeScript `-svc`, `-worker` or `-fn` behavior;
- observability SSO login or dashboard content in a browser;
- rollback, upgrade, node-loss recovery, broker durability/failover, backup/PITR or alert
  delivery;
- that the candidate was promoted. The release gate has not been run.

## Reproduction notes

- Target file: `/home/logan/Code/sol-cloud/sol-issuer-name/examples/pluto/sol/environments.local.yml`
  (untracked; `cluster_issuer: letsencrypt-prod`, roles `sol-qual5-*`, cluster
  `sol-qual-aws-a45h`, base domain `qual-aws.sol-fab.dev`).
- Commands were the normal `prepare → cloud → app → destroy → verify` row with
  `CLUSTER_ISSUER=letsencrypt-prod`, `SOL_CANDIDATE=/home/logan/qual-alpha44/candidate.json`,
  and the target's DB password supplied as `TF_VAR_db_password` from a local file (value not
  recorded).
- The successful phases retained the target by design (#1685); no `KEEP=1` was used.
