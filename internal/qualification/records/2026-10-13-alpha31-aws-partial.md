# AWS 2b acceptance attempt `2b-a31` — partial evidence, not a qualified window (2026-10-13)

**This is a partial record.** The attempt proved several claims on a cold profiled target and
then stopped on defects it could not route around. It is **not** a provider verdict and does
not qualify `v0.1.0-alpha.31`. It is the second attempt in the same pattern as the alpha.29
partial (`2026-10-13-alpha29-aws-partial.md`), and it exists so the next attempt starts from
what is already established rather than re-proving it.

## Run identity

| Field | Value |
|---|---|
| Sol revision | `83be610b616f3b9a4d8641694a27fe37b8be5938` (tag `v0.1.0-alpha.31`) |
| Candidate document | `/tmp/sol-window/a31/candidate.json` |
| Sol install prefix | `/tmp/sol-window/a31/sol-v0.1.0-alpha.31` |
| Migration runner image | `ghcr.io/sol-fab/sol-migration-runner@sha256:217afcc6fe2c4c9a1f1db2670a37f1ce6e1f1c7d104ec0ef5c4536a27cc98085` |
| Profile | `production-single-region` |
| Target | `qual-2b-a31/aws/us-east-1` |
| Target file | `examples/pluto/sol/environments.local.yml` in the run worktree, sha256 `d0a9da03466f9566b6c9ccc5a38127f1f913fef6d4e64d751c65e1d3a943e0d0` |
| Account / region | `123456789012` (documented placeholder — the real account id is in the evidence bundle, not tracked) / `us-east-1` |
| Cluster | `sol-qual-aws-2b-a31` |
| Attempt | `2b-a31` (`/tmp/sol-aws-row-2b-a31/attempt.txt`) |
| Evidence bundle | `/tmp/sol-aws-row-2b-a31/` (outside the repository) |
| Harness revision | `45e0366c` at the point the window completed; the first app pass ran at `83be610b`'s harness |

## What the attempt established

| Claim | Result | Evidence |
|---|---|---|
| `prepare` publishes immutable artifacts into run-owned repositories | PASS | `sol-runs/2b-a31/<unit>`, digests in `app-image-refs.txt` |
| The whole target reconciles | PASS | `cloud-apply*.log`: `The environment for qual-2b-a31/aws/us-east-1 is reconciled.` |
| The operator-secret stop fires, and resume works | PASS | `cloud-apply.log` stops naming `redpanda/redpanda-users`; harness supplies it; `cloud-apply-resume` reaches `Ready` |
| The post-setup migration gate fires fail-closed | PASS | `error: the required migration set is not applied. Missing: 001_notifications … 007_orders_ts_traceparent` |
| The database setup delivers the credential classes | PASS | `pluto-checkout`: `qual-2b-a31-aws-us-east-1-ddl-creds`; `pluto-comms`, `pluto-payments`: `…-dml-creds` |
| **The authority state transition behaves live** | **PASS** | see below |
| `sol migrate apply` reads the DDL class Secret and applies the migrations | PASS | `Migrations: OK -- 7 declared migration(s) present in schema_migrations` |
| The deploy applies the workloads | PASS | `[apply] ok (124.2s)` |

### The authority state transition, observed directly

`pluto-checkout/qual-2b-a31-aws-us-east-1-db-credentials`, read with the run's deploy
kubeconfig:

- keys: `SOL_AUTHORITY_STATE`, `SOL_DDL_PASSWORD`, `SOL_DML_PASSWORD`;
- `SOL_AUTHORITY_STATE` = **`established`** — written only after the setup Job succeeded;
- label `app.kubernetes.io/managed-by: sol`;
- annotation `sol.io/target: qual-2b-a31-aws-us-east-1`.

So the bootstrap persisted the record **pending**, the Job created the roles, and the promotion
to **established** landed with owner and target identity attached — the state machine added in
`#1421` exercised cleanly on a live target.

This matters for the next attempt: **a fresh target cannot re-exercise it**, because a fresh
target has no authority and only reaches `established` after a successful Job. The evidence
for the transition is here, not there.

## Where it stopped

The app phase could not reach its final deploy. Three defects, in the order they surfaced:

1. **#1430** (harness) — `app_supply_secrets` supplied an invented `SOL_API_KEY` unit secret
   the workspace does not declare, so `sol secret set` correctly refused it and the phase
   aborted before supplying the keys the deploy requires.
2. **#1432** (harness) — same statement: the value was piped in without `--from-stdin`, which
   the CLI requires. Masked by #1430, because the address is validated before the value is read.
3. **#1433** (product) — with the declared secrets supplied, the deploy **applied the
   workloads successfully** and then failed observing them: `kubectl get <resource> -A` is a
   cluster-scoped list, forbidden for the target's namespace-scoped deploy identity
   (`can-i list deployments --all-namespaces` → no; `-n <namespace>` → yes).

All three are fixed (#1431, #1435); #1434 (a unit `authority: sol` key cannot be supplied
before its Deployment exists) is the same class and is fixed by implementing #1350 in #1436.

Because the app phase had already applied the migrations before #1430 stopped it, the resumed
pass ran with the workspace's declared secrets supplied by hand — the operator action the
harness performs — which is disclosed here as a deviation in the *sequence*, not in the
product paths exercised.

## Teardown and independent absence

`sol destroy` reached `Destruction reached verified absence`. The independent inventory
(`aws/absence.py`, read-only) read:

```
verdict: ABSENT (every required disposable class is independently ABSENT)
```

for eks-cluster, rds-instance, rds-subnet-group, rds-snapshot, ec2-instance, vpc, nat-gateway,
elastic-ip, ebs-volume, load-balancer, ecr-repository, iam-role, iam-policy, s3-bucket,
cloudwatch-dashboard and cloudwatch-log-group; `durable-hosted-zone` retained. Independent
account reads: zero EKS clusters, zero RDS instances, zero manual snapshots, zero non-default
VPCs, zero ECR repositories, zero load balancers, zero volumes, zero addresses.

## What this attempt does not establish

- The delivered-form assertion (`app_verify_database_delivery`) — NOT REACHED.
- The application transaction (B1/B3/B4) — NOT REACHED.
- The ADR 0004 **populated** teardown (`app_populate_sol_repositories`) — NOT REACHED, so the
  teardown above was verified on repositories that were never populated.
- Anything about `v0.1.0-alpha.31` as a release: no provider verdict, and no promotion.
