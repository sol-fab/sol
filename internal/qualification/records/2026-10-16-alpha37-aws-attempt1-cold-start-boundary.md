# AWS attempt `a37-aws-1` on `v0.1.0-alpha.37` — cloud phase failed at the cold-start boundary read; absence independently verified (2026-10-16)

**Verdict: no application-contract claim is established by this attempt.** The AWS lifecycle was
started on candidate `v0.1.0-alpha.37`, provisioned a fresh target, and reached its documented
cold-start refusal; the `cloud` phase then **failed closed** on its own cold-start boundary read.
`transport`, `app`, `destroy` and `verify` were not run as designed: the attempt went straight to
teardown, which reached independently verified absence. Every AWS matrix row this attempt touched
stays `NOT RUN` or `FAIL`; none is passing.

Two findings, one root cause. The harness's boundary read and Sol's own destroy release
precondition both need to observe a declared namespace that the scoped deploy identity holds no
grant in, and Kubernetes answers `Forbidden` — not `NotFound` — so both fail closed on a state
that is in fact empty.

## Run identity

| Field | Value |
|---|---|
| Sol revision | `d15e0bfb0afffdc9ab73ffaeea97ed8c272a7ee6` (tag `v0.1.0-alpha.37`, `origin/main` tip) |
| Candidate document | `/home/logan/qual-alpha37/candidate.json` |
| Bundle | `sol-v0.1.0-alpha.37-linux-x86_64.tar.gz`, sha256 `03d0ef9a…d691` (verified == archive) |
| Migration runner | `ghcr.io/sol-fab/sol-migration-runner@sha256:13d40186dd13e28490b8a1aefbf43f53816a6edc19f54b25be4bc67b740da22b` |
| Harness revision | `e731323262c7367bf7e6fb25ea8b93d625327142` (squash merge of #1485 on `main`; reviewed head `73e400db`, merged content identical) |
| Harness corrections | #1485: publisher-session publication (SEC-011) and explicit teardown destination |
| Account / region | `876701109436` / `us-east-1`, SSO `AdministratorAccess` operator session |
| Target / cluster | `qual-a37-aws/aws/us-east-1` / `sol-qual-aws-a37` |
| Attempt / state key | `a37-aws-1` / `sol/qual-a37-aws/aws/us-east-1/cloud.tfstate` |
| Workspace | `/home/logan/Code/sol-cloud/sol-a37-harness/examples/pluto` (candidate revision materialized by `candidate-binding.sh`; 11 framework pins at `d15e0bfb`) |
| Evidence bundle | `/home/logan/qual-alpha37/aws-a37-1/`, failure diagnosis `/home/logan/qual-alpha37/cloud-failure-diagnosis.txt` |
| Operator inputs | `TF_VAR_db_password` from the operator's credential store; `PHASE_TIMEOUT` raised 2400 → 5400 s (per-command hang bound) |

Preflight: no pre-existing target-owned resource of any of the 16 classes (independently ABSENT),
no ECR repository and no EKS cluster in the account, egress CIDR == `24.10.239.81/32`, quotas
sufficient, six scoped identities assumable, candidate bundle byte-verified. Staging corrections:
the target declared no platform `shape` (the phase's first `sol plan` refused), and the attempt's
evidence directory held the operator's preflight inventory with no `attempt.txt` (the harness
refuses an unidentified bundle); both were corrected before provisioning, with the preflight
evidence preserved under `/home/logan/qual-alpha37/preflight-a37/`.

## Phases

| Phase | Result | Evidence |
|---|---|---|
| prepare | PASS | five images built from the candidate revision, `row-20261016-060916`; `candidate-binding.txt` |
| cloud | **FAIL** | see below — `cloud.run.log`, `cloud-apply.log`, `cloud-apply-resume.log`, `cold-start-pluto-payments.err` |
| transport | NOT RUN | the campaign stopped at cloud |
| app | NOT RUN | the campaign stopped at cloud |
| destroy | PASS (with 1 degraded preparation, recorded by Sol) | `destroy-aur.run.log`: `Done, with 1 degraded preparation(s),. Destruction reached verified absence.` |
| verify | PASS | all 16 classes independently ABSENT (`aws-inventory-verdict.txt`) |

### What the cloud phase did establish

- **Fresh provisioning.** `lifecycle phase: CloudBootstrap`; the cluster root created EKS, the
  managed node group, VPC/NAT/EIP and Multi-AZ RDS from an empty account (the independent
  inventory attributed 4 EC2 instances, 1 VPC, 1 NAT gateway, 1 EIP, 6 EBS volumes, 1 RDS
  instance, 1 subnet group, 5 IAM roles, 5 IAM policies, a dashboard and a log group to this
  target).
- **The durable installation is established, observed at the provider** — `Sol observed the
  installation for qual-a37-aws/aws/us-east-1 at the provider: every durable prerequisite is
  established` — and the recorded deployment identity was the operator's SSO session (the durable
  roles are assumed by Sol itself).
- **The documented pre-platform credential boundary, handled as documented.** The first
  whole-target deploy stopped with `the platform install cannot start: the operator-supplied
  Secret redpanda-users is absent from namespace redpanda`; the harness created the Secret
  through the cluster-access identity (`platform_credential_source: generated-for-this-run`, no
  value recorded) and resumed the same deploy.
- **The cold-start artifact refusal.** `The environment for qual-a37-aws/aws/us-east-1 is
  reconciled.` followed by `Deployment incomplete: infrastructure is reconciled and no workload
  has moved … none is published yet`, naming the five `pluto/<unit>` repositories. The
  repositories did not exist before the deploy (`ecr-sol-repositories-before.txt`: five ABSENT)
  and existed afterwards (the failed destroy's inventory read all seven `pluto/*` repositories
  PRESENT), so the deploy created them.
- **No workload moved and no release was recorded** — established by independent reads, **not** by
  the phase's own assertion: `pluto-payments` and `pluto-comms` do not exist (the cluster-access
  identity holds cluster-wide namespace read and its listing omits them; the deploy identity's
  filtered listing omits them too), so no Deployment and no `sol.dev/type=release` ConfigMap can
  exist. This is the same fact the failed assertion was trying to read.

### The failure

`cold_start_moved_nothing` reads the declared namespaces with the **deploy identity** and treats
anything other than "not found" as UNKNOWN. It received:

```
Error from server (Forbidden): deployments.apps is forbidden: User
"arn:aws:sts::876701109436:assumed-role/sol-qual5-deploy/EKSGetTokenAuth" cannot list resource
"deployments" in API group "apps" in the namespace "pluto-payments"
```

The declared namespaces do not exist yet — Sol creates them, and the deploy identity's grant in
them, when it moves workloads, which the artifact gate deliberately prevents. RBAC for the
namespaced resource is evaluated before namespace existence, so an identity with no grant in the
namespace gets `Forbidden`, never `NotFound`. The phase failed closed (UNKNOWN is never absence),
which is the harness behaving as designed, and no application-contract step ran.

## Findings

Filed as **#1488** — F1 and F2 share the root cause; the issue carries the probes and the
directions for a decision.

**F1 — product (blocking): a target whose workloads were never deployed cannot be destroyed
without `--accept-unreleased`.** `sol destroy` releases the target's workloads before dropping the
substrate and refuses when the release cannot be established. With the scoped deploy identity it
cannot be established for a namespace the identity holds no grant in — `Forbidden` is
`Read_unestablished`, a hard failure, not the `No_cluster` degradation. So a target that fails
before its first application deploy (exactly this attempt, and any cold-start failure) stops at
`the application workloads could not be established as released … nothing was destroyed and no
absence is claimed`, and the operator must re-run with the documented `--accept-unreleased`,
which Sol records as a degraded preparation. Verbose evidence: `destroy.run.log`,
`failed-destroy-inventory/` (13 of 16 classes PRESENT — the inventory is not vacuous),
`destroy-aur.run.log`.

**F2 — harness: the cold-start boundary assertion is expressed as a read no production identity
can perform at that point in the lifecycle.** Neither the deploy identity (namespace-scoped) nor
the cluster-access identity (`can-i list deployments -n pluto-payments` = `no`) can list
deployments in, or configmaps across, the declared namespaces before the application deploy has
run. The same guarantee is establishable as a fact an available identity can read — "the declared
namespaces do not exist", read through cluster-wide namespace access — and the assertion should
be restated that way (keeping UNKNOWN fail-closed) rather than weakening it. `cloud-failure-diagnosis.txt`
records the probes.

**F3 — harness (cosmetic):** on the cold deploy, `app_image_ref_args` reads
`$LOG_DIR/app-image-refs.txt` before it exists, so the run prints
`No such file or directory` to stderr. The resulting empty argument list is the intended cold
behaviour; only the diagnostic is wrong.

## Teardown and independent absence

1. `sol destroy --apply` (through the harness) — **refused** (`F1`); nothing destroyed, no absence
   claimed. The attempt's own kubeconfig was selected and verified against the cluster's current
   endpoint (`destroy-kubeconfig.txt`: `destroy_cluster: PRESENT`, `destroy_release_cleanup:
   attempted`).
2. `sol destroy --apply --accept-unreleased` — the documented degradation: `--accept-unreleased
   was given, so the substrate is destroyed anyway and the absence check below, not the release,
   decides the outcome`; platform destroy, de-escalation, RDS preparation (deletion protection
   disabled, final snapshot skipped per `destroy_retention: none`), `lifecycle phase: Destroying`,
   then `Done, with 1 degraded preparation(s),. Destruction reached verified absence.`
3. Independent inventory (`absence.py`, read-only, run alone by the harness `verify` phase):
   **all 16 classes ABSENT**; the durable state bucket, lock table and delegated
   `qual-aws.sol-fab.dev` zone remain (the contract, not residue).
4. `sol destroy --apply` again against the now-`Absent` target: exit 0,
   `Destruction reached verified absence.`, no preparation needed (the cluster is absent, so the
   release is not applicable) — destroy idempotence.

## What this attempt does not establish

- Any application-contract evidence: no migration ran, no workload was deployed, no transaction
  was driven, no B1/B3/B4/C/D/E row was exercised. `transport` and `app` are `NOT RUN`.
- B3 and every other Kafka-relay row; the authorization/grants dimension (the target declares no
  reconciler, so no fence exists — `E4`, `E6`, `VERIF-021`); `E5` (blocked on `FEAT-134`);
  G1–G3 alerts (placeholder receiver); the TypeScript profile, GCP, `byo`, retention, and the
  rest of the matrix.
- That the AWS cold-start lifecycle completes: it reached the artifact gate but the phase's own
  assertion could not be satisfied by the apparatus.

## Follow-up filed from this record's review

- **#1491 — product.** Establish declared-namespace existence authoritatively before the workload
  release: positively absent namespaces make it not applicable; a namespace that exists keeps the
  existing checks; an unestablishable existence keeps the refusal. Implementation: #1493 (draft,
  with the observation identity left for maintainer judgement). This is the normal
  failure-recovery path for users, not only a qualification concern.
- **#1492 — qualification harness.** Replace the unobservable cold-start Deployment listing with a
  sound namespace-absence assertion over the complete candidate-bound namespace set, under an
  explicitly validated observation identity. Implementation: #1495.
- **#1496 — the `app-image-refs.txt` diagnostic** (finding F3), separate.

The parent **#1488** keeps the common cause: a security model that grants the deploy identity
authority only where it has deployed, and consumers that need to observe an undeployed target.
