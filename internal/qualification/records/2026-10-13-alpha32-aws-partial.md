# AWS 2b acceptance attempt `2b-a32` — partial evidence, not a qualified window (2026-10-13)

**This is a partial record.** The attempt proved several claims on a probed target and then
stopped on a product defect it could not route around. It is **not** a provider verdict and
does not qualify `v0.1.0-alpha.32`. It is the third attempt in this pattern (see
`2026-10-13-alpha29-aws-partial.md` and `2026-10-13-alpha31-aws-partial.md`).

## Run identity

| Field | Value |
|---|---|
| Sol revision | `53cd14e350dbfa538c4f332ec89b7c0d14fee743` (tag `v0.1.0-alpha.32`) |
| Candidate document | `/tmp/sol-window/a32/candidate.json` |
| Sol install prefix | `/tmp/sol-window/a32/sol-v0.1.0-alpha.32` |
| Migration runner image | `ghcr.io/sol-fab/sol-migration-runner@sha256:9eb85ee5118a36514f36d241f103a5cbcd180cd354ddac7bc6f2daff08077259` |
| Profile | `production-single-region` |
| Target | `qual-2b-a32/aws/us-east-1` (fresh, cold) |
| Cluster | `sol-qual-aws-2b-a32` |
| Attempt | `2b-a32` |
| Evidence bundle | `/tmp/sol-aws-row-2b-a32/` (outside the repository) |

Ancestry of the tagged revision: #1407, #1410, #1412, #1414, #1416, #1420, #1421, #1431,
#1435, #1436 all precede it.

## What the attempt established

| Claim | Result | Evidence |
|---|---|---|
| `prepare` publishes immutable artifacts into run-owned repositories | PASS | `sol-runs/2b-a32/<unit>` digests in `app-image-refs.txt` |
| The whole target reconciles from cold | PASS | `cloud-apply*.log`: `The environment for qual-2b-a32/aws/us-east-1 is reconciled.` |
| The operator-secret stop fires, and resume works | PASS | `cloud-apply.log` stops naming `redpanda/redpanda-users`; the harness supplies it; `cloud-apply-resume` reaches `Ready` |
| The post-setup migration gate fires fail-closed | PASS | `app-deploy-gate.log`: `error: the required migration set is not applied. Missing: 001_notifications … 007_orders_ts_traceparent` |
| The database setup delivers the credential classes | PASS | `pluto-checkout`: `qual-2b-a32-aws-us-east-1-ddl-creds`; `pluto-comms`, `pluto-payments`: `…-dml-creds` |
| **The authority state is `established` with owner and target identity** | **PASS** | live read, below |
| `sol migrate apply` reads the DDL class Secret | PASS | `Migrations: OK -- 7 declared migration(s) present in schema_migrations` |
| The deploy applies the workloads and reconciles the contract | PASS | `app-deploy.log`: `Contract: reconciled in the destination with image …` |
| **A unit secret can be written before its workload exists** | **PASS** | ten `Secret updated for <domain>/<unit>/KAFKA_*` writes, none failing |

### The authority state, read live

`pluto-checkout/qual-2b-a32-aws-us-east-1-db-credentials`:

```
labels:     {"app.kubernetes.io/managed-by":"sol"}
annotations: sol.io/target: qual-2b-a32-aws-us-east-1
SOL_AUTHORITY_STATE = established
```

### The explicit-activation contract, observed live

Supplying the ten per-unit Kafka keys (`#1438`'s fix) succeeded with **no restart and no
failure**, on a target where the Deployments were already applied and in a refused state —
`#1436`'s *set writes; activation is explicit* exercised on real infrastructure. Under the old
behaviour every one of those ten writes would have failed with `could not be restarted`.

## Where it stopped

| Finding | Class | Status |
|---|---|---|
| `#1438` — the row supplied only the platform scope, but this workspace also declares the keys per unit | harness | fixed in `#1439` (merged) |
| `#1440` — a deploy writes a release record its own content does not rederive, and every later deploy refuses to read it | **product** | **open; blocks the window** |

`#1440` is deterministic, not residue: after deleting `default/sol-release-current-pluto`, the
next deploy wrote the **same** id `r-e6e9941698228f9b` and the same mismatch, so the target
cannot be deployed to again by any route the product offers.

## Window shape (disclosed)

The app phase ran three times on this target:

1. **Pass 1** (harness at `53cd14e3`) proved the gate refusal, `sol migrate apply`, and the
   platform-store secret refusal in order, then stopped at the final deploy on the unit-scope
   refusal — `#1438`.
2. The harness fix (`#1439`) was applied, and the ten per-unit keys were supplied by hand —
   the operator action the harness performs.
3. **Pass 2** proved the unit-scope writes and the deploy's apply + contract reconcile, then
   stopped on `#1440`.
4. **Pass 3**, after removing the corrupt current-release pointer (restoring the target to the
   state a fresh target has), stopped on `#1440` again — which is what shows it is
   deterministic.

So the refusals were each proven, but **not in a single uninterrupted cold pass**, and the
window did not reach its assertions. A qualified window needs a target that gets past `#1440`.

## Teardown and independent absence

The first two destroy attempts failed at `terraform init` because the AWS SSO session had
expired mid-run (`InvalidGrantException: failed to refresh cached SSO token`). The harness
records that as a failure and then lets the independent inventory decide:

```
[11:27:49] the independent inventory does not read ABSENT, so teardown is not complete
```

EKS, RDS, four EC2 nodes, the VPC/NAT/elastic IP, six volumes and the whole IAM surface read
PRESENT at that point. After re-authentication the destroy completed:

```
[12:33:52] destroy returned success; the independent inventory decides absence
[12:34:09] the independent inventory reads ABSENT for every required disposable class
verdict: ABSENT (every required disposable class is independently ABSENT)
```

Independent account reads afterwards: 0 EKS clusters, 0 RDS instances, 0 manual snapshots,
0 non-default VPCs, 0 available NAT gateways, 0 elastic IPs, 0 volumes, 0 load balancers,
0 ECR repositories — including the seven `pluto/*` application repositories this target's own
platform created, and the run-owned `sol-runs/2b-a32/*` repositories removed by `cleanup`.

Carry as stated risk: **the run cannot tear itself down across an SSO expiry**, and the failure
mode is a live, cost-bearing substrate with no automatic retry. Two identical `terraform init`
failures were required before the session was refreshed.

## What this attempt does not establish

- `app_verify_database_delivery` — **NOT REACHED**.
- The application transaction — **NOT REACHED**.
- The populated teardown — **NOT REACHED**; absent was verified on repositories that were never
  populated.
- Anything about `v0.1.0-alpha.32` as a release: no provider verdict, and no promotion.
