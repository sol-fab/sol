# AWS 2b acceptance attempt `2b-a29` — partial evidence, not a qualified window (2026-10-13)

**This is not a provider verdict and does not qualify `v0.1.0-alpha.29`.** It records what a
cold profiled AWS attempt established before it was blocked, so the two harness defects it
surfaced can be fixed and the row re-run. It is deliberately separate from any `alpha.30`
record.

## Run identity

| Field | Value |
|---|---|
| Sol revision | `da51ecbe8b49b5d5db594c30c42a6ea431f52ce3` (tag `v0.1.0-alpha.29`) |
| Candidate document | `/tmp/sol-window/a29/candidate.json` (version `v0.1.0-alpha.29`, revision `da51ecbe`) |
| Sol install prefix | `/tmp/sol-window/a29/sol-v0.1.0-alpha.29` |
| Migration runner image | `ghcr.io/sol-fab/sol-migration-runner@sha256:02fe7278d770939a992a63a2ba41578f5da3ebdf366c75c474a6506a59d3cd91` |
| Profile | `production-single-region` |
| Target | `qual-2b-a29/aws/us-east-1` |
| Target file | `examples/pluto/sol/environments.local.yml` in the run worktree, sha256 `0d9d6fef5b717bb82a3b91c447db4a8bc57cdb575f642566271d7590d0b0d0bd` |
| Account / region | `123456789012` (documented placeholder — the real account id is in the evidence bundle, not tracked) / `us-east-1` |
| Cluster | `sol-qual-aws-2b-a29` |
| Attempt | `2b-a29` (`/tmp/sol-aws-row-2b-a29/attempt.txt`) |
| Started / finished (UTC) | `2026-10-13T03:26:24Z` / `2026-10-13T05:48:12Z` |
| Evidence bundle | `/tmp/sol-aws-row-2b-a29/` (outside the repository) |

## What the attempt established (observed, verbatim logs in the evidence bundle)

| Claim | Result | Evidence |
|---|---|---|
| `prepare` publishes immutable artifacts into run-owned repositories | PASS | `app-image-refs.txt`; digests under `sol-runs/2b-a29/<unit>` |
| `cloud-plan` names those digests on a cold target (cold skip removed) | PASS | `cloud-plan.log` (issued from `prepare`'s digests) |
| The whole target reconciles | PASS | `cloud-apply*.log`: `The environment for qual-2b-a29/aws/us-east-1 is reconciled.` |
| The operator-secret stop fires and resume works | PASS | `Lifecycle phase: PlatformInstalling` → stopped naming `redpanda-users` → supplied → `cloud-apply-resume` reached `Ready` |
| The database setup delivers the credential classes | PASS | `pluto-checkout`: `qual-2b-a29-aws-us-east-1-ddl-creds`; `pluto-comms`, `pluto-payments`: `…-dml-creds` (kubectl reads recorded in `k8s-*`) |
| A consumer reads the class Secret, not its own | PASS | the consumer's unit Secret carries no `POSTGRES_URL`; `sol migrate apply` read the DDL class Secret and applied all 7 migrations (`migration Job logs: Applying migrations from /migrations… Done.`) |
| The post-setup migration gate fires fail-closed | PASS | `error: the required migration set is not applied. Missing: 001_notifications … 007_orders_ts_traceparent` |

The ordering claim `gates → database_setup → post_setup_gates` is the one this attempt did
establish: the setup step wrote `<target>-ddl-creds` before the migration gate read it.

## Where it stopped, and why

`phase_app` could not complete. Two harness defects, both written against the pre-2b surface,
block it:

- **#1418** — `app_secret_set` calls the removed `sol secret set <KEY> --target … --domain …`
  form; the installed release's CLI takes `TARGET ADDRESS` and rejected the flags
  (`sol: unknown option --target unknown option --domain`).
- **#1419** — `phase_app` expects the first deploy's refusal to be the absent-secret stop; on
  a fresh profiled target the post-setup migration gate fires first, so the phase aborted with
  `FAILED: the bootstrap deploy did not reach the secret prerequisite`.

A third, **product** defect blocked the database setup itself until it was worked around:

- **#1417** — Sol's service-file emitter single-quotes values containing `#`, and libpq's
  service-file parser takes those quotes literally, so the setup Job authenticated with the
  quotes included (`FATAL: password authentication failed for user "postgres"`).

**Disclosure (deviation).** The master password was set to a value without `#`. Sol's
service-file emitter quotes values containing `#` in a way libpq reads literally, so the setup
Job would authenticate with the quotes included (#1417). The defect is in Sol, not the window;
it is filed separately and does not affect the paths this row exercises. The value was never
recorded; only its absence of `#` is a deviation from the operator's original input.

## Teardown and independent absence

`sol destroy qual-2b-a29/aws/us-east-1 --apply` reached `Done … Destruction reached verified
absence.` (one degraded preparation: the harness's kubeconfig context named the cluster being
destroyed — reported, not residue). The independent inventory (`aws/absence.py`, read-only)
then read:

```
verdict: ABSENT (every required disposable class is independently ABSENT)
```

for eks-cluster, rds-instance, rds-subnet-group, rds-snapshot, ec2-instance, vpc, nat-gateway,
elastic-ip, ebs-volume, load-balancer, ecr-repository, iam-role, iam-policy, s3-bucket,
cloudwatch-dashboard and cloudwatch-log-group; `durable-hosted-zone` retained. Independent
account reads confirm zero ECR repositories (the run-owned `sol-runs/2b-a29/*` repos were
removed by the destroy phase's own cleanup) and zero cost-bearing resources.

## What this attempt does not establish

- The delivered-form assertion (`app_verify_database_delivery`, the consumer-is-not-the-source
  check as the harness states it) — NOT REACHED.
- The application transaction (B1/B3/B4) — NOT REACHED.
- The ADR 0004 populated teardown (`app_populate_sol_repositories`) — NOT REACHED.
- Anything about `v0.1.0-alpha.29` as a release: no provider verdict, and no promotion.
