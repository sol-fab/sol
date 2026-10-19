# Executable qualification matrix — `production-single-region/v1` (HARDEN-002)

> **Related:** `internal/qualification/gcp/gcp-bootstrap-inventory.md` — the GCP realization
> of the same contract (HARDEN-004). This matrix is the AWS profile's; the GCP rows
> are recorded separately, with TLS issuance currently BLOCKED rather than qualified.


Derived from **DEC-026 §1–§9** (the profile contract), **ADR 0002** (Sol owns the
cloud-target lifecycle), **ADR 0003** (lifecycle phases determine authority and
desired-state policy), and the merged tickets that implement them: AUDIT-078,
FEAT-050, FEAT-083, FEAT-088, AUDIT-069, AUDIT-072, AUDIT-080, SEC-004, OBS-043,
INFRA-022, INFRA-023, INFRA-025, INFRA-026, INFRA-028, INFRA-029, plus FEAT-089's
preflight.

This matrix is the *input* to the qualification harness: every row is a scenario
the harness must execute and an artifact it must retain. It is not evidence that
anything below passes.

Section **I** is the lifecycle contract (ADR 0003). Its rows are captured during
the provisioning and teardown steps of the run, not at one moment; they are
grouped by *contract* rather than by *time* so that the authority and
desired-state-policy semantics can be read — and qualified — as one thing.
Runs 3 and 4 (see HARDEN-002) found findings 13–15 by not having this contract:
rows I2, I5, I7 and I10 are the ones that would have caught them live.


## Governing rules

1. **A claim is per (target, profile version, timestamp).** Conformance is never
   a permanent certificate; the bundle is re-run when the compatibility matrix
   or any used capability's implementation changes (DEC-026 §9).
2. **Numeric values in DEC-026 are qualification targets to *measure*, not
   values to assume from configuration.** Every row with a bound records
   `target`, `measured`, and the measurement method.
3. **Static assertions cannot pass a failure scenario.** A row is only satisfied
   by observed live behaviour (HARDEN-002 acceptance criteria). Config inspection
   is recorded as `inspection` evidence and never promoted to `behavioural`.
4. **Capabilities a workload does not use are recorded as skipped, with the
   reason** — never silently omitted, never claimed (DEC-026 §9, "not
   applicable" ≠ "passed").
5. **A failed invariant stops the run.** The scenario keeps its evidence, the
   bundle is marked non-conformant, and the smallest implementation/contract
   issue is reported. No test is weakened and no contract is edited to pass.

## Where each row stands

A row's verdict lives with the claim it belongs to, and cites the record that established it:
this matrix and the run records it cites. The newest AWS evidence, and what it covers:

- `records/2026-09-30-aws-application-row-complete.md` — the whole application row on a fresh
  specimen (`sol-qual-aws-35`, `qualreg/aws/us-east-1`) with **no manual patch at any point**:
  the whole-target deploy (`CloudBootstrap` → `PlatformInstalling` → `Ready`, `Done.`),
  authority hand-off, four nodes Ready, the identity boundary, build + push, `migrate-apply`,
  the substrate prerequisite, and the application contract.
- `records/2026-09-30-aws-attempt33-…-except-network-policy-egress.md` and its attempt-32
  predecessor — the point where everything passed except one row, the network policy's egress.
- `records/2026-09-20-run8-aws.md` — the run that first reached §B from B3 and stopped at the
  transport boundary (no workload identity may port-forward into an application namespace,
  DEC-039).

Rows this run has not exercised stay `NOT RUN` in the record that covers them. Nothing in this
file restates a verdict: it holds the claim, the method and the pass condition, and points at the
record that says where the row got to.

## Run identity (recorded once, in the bundle header)

| Field | Source | Example |
|---|---|---|
| Sol commit | `git rev-parse HEAD` at run start | `<sha>` |
| Profile | target config `profile:` | `production-single-region/v1` |
| Target | `<env>/<provider>/<region>` + AWS account | `qual/aws/us-east-1` / `<acct>` |
| Reconciliation authority | DEC-027 selection (direct apply) | `direct` |
| Kubernetes version | `aws eks describe-cluster … .version` | must equal module pin (`1.36`) |
| Platform component versions | helm chart versions from the platform root's state (`platform/cloud/<provider>/platform`) | recorded verbatim |
| Framework versions | `sol-worker`/`sol-svc`/`kafka-eio`/`pg-eio` versions used by the workload image | recorded verbatim |
| Substrate module versions | terraform provider + module versions | recorded verbatim |
| Lifecycle phase per step | the `lifecycle phase:` line `sol deploy`/`sol destroy` prints, recorded verbatim per invocation | `CloudBootstrap` → `PlatformInstalling` → `Ready` → … → `Absent` |

The lifecycle-phase record is part of the run identity rather than a passing
condition on its own: section I pairs each reported phase with an independent
observation, because a phase is operational context and never infrastructure
truth (ADR 0003).

## A. Target-capability guarantees (preflight — offline, before mutation)

Positive and negative cases are both required: a check that never fails proves
nothing.

| # | Invariant (DEC-026) | Scenario / action | Pass condition | Evidence |
|---|---|---|---|---|
| A1 | Profile selection is explicit and versioned (§1) | `sol deploy <target> --dry-run` on a target with `profile: production-single-region` | plan records the profile claim | plan JSON |
| A2 | An environment named `prod` with no `profile` makes no claim (§1) | same command against a target without `profile:` | runs with no profile claim; no production guarantee asserted anywhere in plan/output | plan JSON, CLI output |
| A3 | Unsupported Kubernetes version fails before mutation (§2) | point the target at a cluster whose version ≠ the matrix | `qualified_versions` unmet, refuses, names the mismatch; **no** cluster mutation | preflight report, `kubectl` event check |
| A4 | TypeScript workload fails before mutation (§2) | target containing a `language: typescript` service | `qualified_versions` unmet naming the service + "OCaml-only (DEC-026 §2)" | preflight report |
| A5 | Unsupported substrate fails (§2) | target whose provider ≠ AWS EKS | `qualified_substrate` unmet, names the provider | preflight report |
| A6 | Mutable tag rejected before mutation (§6) | deploy without `--image-ref` (tag path) | `immutable_artifacts` unmet, refuses before any mutation | preflight report |
| A7 | Remote state + scoped identities required (§4, §6) | target missing `state_bucket`/`state_lock_table`/role ARNs/CIDR | `remote_state` + `scoped_operator_identities` unmet, each naming the declaration | preflight report |
| A8 | Alert contract required (§8) | target missing receiver/owner/runbook | `alert_delivery` unmet, naming which field | preflight report |
| A9 | Availability claim validated against the workload (§3) | deploy a `-fn` or volume-backed workload declaring `node-failure-tolerant` | `Unsupported_availability` naming the supported alternative; refuses | plan error |
| A10 | Headroom declared for every tolerant workload (§3, §4) | tolerant workload with `node_failure_headroom_nodes` absent / < count | `workload_availability` unmet naming the required headroom | preflight report |
| A11 | Durability capability only when used (§4) | workspace with a Kafka consumer but a target without RF≥3 policy | `kafka_durability` unmet for that workload only; a workspace with no Kafka is unaffected | preflight report |

Capacity for the platform's own components is no longer a target preflight
capability: Sol does not declare those charts' CPU/memory requests, so it cannot
assert a capacity envelope for an arbitrary environment. The profile still holds
the provider driver defaults to its declared sizing envelope statically, in
`internal/ci/check_node_shape_fits_platform.py` (FND-0066), verified by the
repository checks rather than this harness.

## B. Deployment, pointer and rollback (HARDEN-002 scenarios 1–3, 9, 10)

| # | Invariant | Scenario / action | Pass condition | Evidence |
|---|---|---|---|---|
| B1 | Fresh provision + normal deploy reaches a healthy recorded release (scenario 1) | provision target → `sol deploy <target> --image-ref <svc>=<repo>@sha256:<digest>` | all workloads Ready; release recorded with resolved digests | `kubectl get`, release record JSON |
| B2 | Repeat is idempotent (scenario 1) | re-run the identical B1 command | no workload restarts (same release identity), exit 0, pointer unchanged | pod `restartCount`/UID + `creationTimestamp` before/after, release id before/after |
| B3 | Representative transaction after deploy (scenario 10) | drive one real app transaction through the `-svc` (and one message through the `-worker`) | request succeeds; Kafka message observed processed; no error in logs | HTTP response, and for the `-worker` half the **application's own** evidence that it processed the record — its log line or downstream state, never broker progress such as consumer offset/lag (DEC-039 §5) |
| B4 | Deliberately failed deploy does not advance the pointer (scenario 2) | deploy a workload that cannot become ready (failing probe / bad image) | deploy exits non-zero; **prior** release remains authoritative; no new release record is written; running pods unchanged | release record before/after, `kubectl get pods`, deploy stderr |
| B5 | Rollback restores the prior compatible digest set and verifies live state (scenario 3) | `sol rollback` to the B1 release | operation refuses **before** moving the pointer unless the live workload set verifies; after: exactly the recorded digests run | rollback output, live image digests vs release record |
| B6 | Rollback refuses an incompatible migration boundary (FEAT-066) | roll back across a `contract` migration | refuses, naming the migration boundary; pointer unchanged | rollback output, release pointer |
| B7 | Drift detection/correction per DEC-027 (scenario 9) | mutate a live workload directly (surplus workload / changed replica) | `sol deploy`/`sol local deploy` reports the drift (`unexpected_workloads`), and a re-deploy converges | drift output, post-reconcile `kubectl get` |
| B8 | Retention's outcome is explicit, not a bare warning (INFRA-051) | deploy against a target whose deploy identity cannot enumerate release records (`kubectl auth can-i list configmaps -n default` = `no`) | no workload or release-identity change; the deploy prints `Retention: not run -- …` naming the missing `list` capability; no `warning: could not prune old releases`; the boundary-lease Role still grants exactly `get/create/update/delete` | deploy output; `kubectl auth can-i list configmaps -n default`; `terraform show` of the boundary-lease Role |

## C. Migration ordering (AUDIT-069, scenario 6 partial)

| # | Invariant | Scenario / action | Pass condition | Evidence |
|---|---|---|---|---|
| C1 | Deploy verifies `required ⊆ applied` against `schema_migrations` before mutation | apply all `db/migrations`, then deploy | migration step reports satisfied; deploy proceeds; mutation happens **after** the check | deploy output ordering, Job logs, timestamps |
| C2 | A missing required migration fails closed *before* mutation | add a migration file without applying it, then deploy | deploy exits non-zero naming the missing migration + `sol migrate apply <target>`; no workload mutated | deploy stderr, `kubectl get pods` churn check, Job logs |
| C3 | Unavailable verification fails closed | deploy with the DB unreachable (e.g. RDS security group closed for the Job) | deploy fails closed; does **not** assume compatibility; no mutation | deploy stderr, Job status/logs |
| C4 | `--dry-run` is side-effect free and reports "not verified" | `sol deploy <target> --dry-run` with migrations present | no Job/ConfigMap/object created; output says not verified; never "established" | `kubectl get jobs,configmaps -A` before/after, CLI output |
| C5 | Read-only verifier does not apply migrations | inspect the status Job args + DB `schema_migrations` before/after C2 | Job runs only `migrate status --json`; applied set unchanged by the failed deploy | Job manifest, `schema_migrations` dump before/after |

## D. Availability: drain, node loss, restoration (scenario 4; DEC-026 §3)

| # | Invariant | Scenario / action | Pass condition | Evidence |
|---|---|---|---|---|
| D1 | `node-failure-tolerant` placement is real | inspect a tolerant workload's pods | ≥2 Ready replicas on **distinct** nodes; PDB present; topology spread rendered | `kubectl get pods -o wide`, PDB, Deployment spec |
| D2 | Graceful drain does not remove all ready capacity (scenario 4) | `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` | at least one replica stays Ready throughout; PDB respected; no error-rate spike beyond configured tolerance | watch loop samples, PDB/eviction events, app error rate |
| D3 | Unplanned node loss + **measured** restoration within the 5-minute target (§3) | terminate a node's EC2 instance (no drain) | **measured** time from node `NotReady` → required ready capacity restored = `measured`; PASS iff ≤ 300 s, given declared headroom | timestamped watch samples, node events, measured value |
| D4 | Drain grace closes the 30s/30s race (§3) | during D2, observe the terminated pod | pod terminates cleanly within `terminationGracePeriodSeconds` (45 s), no SIGKILL mid-drain, in-flight request completes | pod events, app log showing drain completion, rendered grace value |
| D5 | Slow start is not liveness-killed (§3) | deploy a tolerant workload with a deliberately slow start (within the startup probe budget) | pod reaches Ready without a liveness restart; `restartCount` 0 | pod events, `restartCount` |
| D6 | Kafka-worker readiness = consumer-group join, including a zero-partition member (§3) | watch `/readyz` across start → join → forced rebalance | 503 until the consumer joins its group (the first assignment, which may own **zero** partitions), then 200; a rebalance that reassigns or removes partitions does **not** drop readiness — liveness is D7, not readiness | endpoint samples with timestamps, broker/consumer-group state; the contract is `Worker_health.is_ready` (`framework/ocaml/sol-worker/lib/worker_health.ml`) and its unit test `test_ready_without_owning_a_partition` |
| D7 | Readiness ≠ liveness; a hung consumer is replaced (§3) | stall the consumer beyond the poll-cadence bound (e.g. block the poll loop / pause the broker) | `/livez` fails while the process is up → pod is restarted; readiness never inferred from "was ready once" | `/livez` samples, `restartCount`, probe events |
| D8 | Broker unreachable at startup blocks readiness, does not crash-loop (§3) | start the worker while the broker is unreachable | `/readyz` 503 with bounded retry; process stays up (not CrashLoopBackOff) | pod state, `/readyz` samples, restartCount |

## E. Data durability and recovery (scenarios 5–6; DEC-026 §5)

| # | Invariant | Scenario / action | Pass condition | Evidence |
|---|---|---|---|---|
| E1 | Postgres is Multi-AZ (§5) | inspect the live RDS instance | `MultiAZ = true`; standby in a different AZ | `aws rds describe-db-instances` |
| E2 | Postgres infra-failure RPO ≈ 0, RTO < 120 s (**measure**) | write a known row, trigger failover (`aws rds reboot-db-instance --force-failover`) | row present after failover; **measured** failover time ≤ 120 s | row read-back, measured seconds, RDS events |
| E3 | Postgres logical-loss RPO ≤ 5 min via PITR within 7-day retention (**measure**) | note a write timestamp, `aws rds restore-db-instance-to-point-in-time`, repoint the app | **measured** RPO (last durable write before the restore point) ≤ 300 s; restore complete | restore point, row-set comparison, measured RPO |
| E4 | Restore into a clean target verified **at the application level**, RTO ≤ 60 min (**measure**) | deploy against the restored DB and drive a transaction (scenario 6) | app serves reads/writes against the restored data; **measured** RTO ≤ 3600 s; not merely "provider job completed" | deploy + transaction evidence, measured RTO |
| E5 | Broker loss: zero loss of acknowledged messages (§5) | produce N messages `acks=all` (RF≥3, write caching off), kill one broker, consume | all N acknowledged messages consumed; none lost | produced/consumed counts, broker pod events, topic describe (RF) |
| E6 | Consumers resume automatically within the 60 s target (**measure**) | during E5, sample consumer lag/assignment | **measured** time to resume consuming ≤ 60 s, no operator action | lag samples with timestamps, consumer-group describe, measured value |
| E7 | Kafka policy is the qualified one (§5) | inspect the topic + cluster config | RF ≥ 3, `acks=all` on the producer path, write caching disabled; **no** claim about Apache Kafka's `min.insync.replicas` | `sol`/admin API topic describe, rendered base config |
| E8 | Admitted volume is `single`-tier only (§3, §5) | deploy a workload with a declared volume | admitted; volume is durable per cloud default; **no** automated backup path is claimed; a tolerant+volume combination is refused (A9) | PVC/PV evidence, plan output |
| E9 | Control-state RPO ≈ 0 and a clean operator can execute recovery (§5, §6) | follow the documented recovery procedure for Terraform/control state from a clean runner | state recovered from versioned encrypted remote state; a clean operator/runner completes the documented procedure | procedure transcript, versioned-object evidence, `terraform state` listing |
| E10 | Telemetry is best-effort, non-durable (§5) and not confused with business data | lose the telemetry backend, then confirm app behaviour | app unaffected; telemetry gap recorded; no business-data claim attached | app transaction evidence, telemetry gap timestamps |
| E11 | Every recovery is proven by a real transaction (scenario 10) | after E2/E4/E5, run the representative transaction again | succeeds; ordering/idempotency preserved | transaction evidence per recovery |

## F. Security posture (scenario 7; DEC-026 §7)

| # | Invariant | Scenario / action | Pass condition | Evidence |
|---|---|---|---|---|
| F1 | No ambient ServiceAccount token by default | inspect every workload's SA + pod spec | `automountServiceAccountToken: false`; no projected SA token volume | SA/pod YAML |
| F2 | Runtime rotation completes without hand-edited manifests (scenario 7) | `sol secret set` on a DB/API credential; watch the workload | workloads restart via the DEC-027 authority, return to healthy; app transaction still succeeds | `sol secret set` output, pod UIDs/restart evidence, transaction |
| F3 | The old credential is revoked | use the pre-rotation credential after rotation | rejected by the dependency | dependency error proving rejection |
| F4 | No secret value in plan, release record, log, or bundle | scan the run's artifacts | zero matches for every secret value | redaction scan over plan/logs/records/bundle |
| F5 | Scoped identities are the ones actually used (§4, §6) | inspect the deploy/provisioner/operator identities used | deploy uses the scoped identity, not the cluster-creator admin; admin permission is not standing | IAM/CloudTrail evidence, `sts get-caller-identity` per phase |

## G. Alerting (scenario 8; DEC-026 §8)

| # | Invariant | Scenario / action | Pass condition | Evidence |
|---|---|---|---|---|
| G1 | A synthetic alert reaches the named on-call destination | Use Alertmanager and receiver-native test procedures against the **real configured production-profile receiver** | alert observed at the destination operator-side | receiver-side evidence (timestamped) |
| G2 | The alert is acknowledged by the owner | owner acknowledges in the incident destination | acknowledgement observed | acknowledgement evidence |
| G3 | Every required alert has owner + runbook (§8, OBS-043) | inspect the rendered alert set | each required alert (failed rollout, node loss, Postgres loss/restore, Kafka lag/broker loss, telemetry loss) has owner + runbook URL | rendered alert rules, runbook links |

## H. Evidence bundle integrity (HARDEN-002 acceptance criteria)

| # | Invariant | Scenario / action | Pass condition | Evidence |
|---|---|---|---|---|
| H1 | One command runs the whole matrix, no manual result editing | run the harness | single entry point; bundle produced programmatically | harness entry point, bundle |
| H2 | A failed required scenario returns non-zero and marks the bundle non-conformant | deliberately fail one scenario (e.g. C2's expected failure inverted) | harness exits non-zero; bundle says non-conformant | exit code, bundle status |
| H3 | Evidence distinguishes inspection from behavioural proof | inspect the bundle schema | each row is tagged `behavioural` or `inspection`; no inspection row passes a failure scenario | bundle schema + per-row tags |
| H4 | Repeatable on a clean target from the declared matrix + named credentials | teardown, re-provision, re-run | second run reproduces pass/fail with only documented inputs | two bundle headers |
| H5 | Secrets redacted | scan the bundle | zero secret values | redaction scan |
| H6 | Teardown independently verified | after the run, `live-row.sh verify` reads every required disposable class through the provider | EKS cluster, RDS instance, subnet group and snapshots, EC2 instances, VPC, NAT gateways, elastic IPs, EBS volumes, OIDC providers, security groups, load balancers, ECR repositories, IAM roles and policies, S3 buckets, CloudWatch dashboards and log groups are each ABSENT, and every class's read succeeded and had the expected shape; a failed, unreadable, unshaped or unattributable read is UNKNOWN and fails the run | the tri-state per-class verdict, the exact queries and raw provider output (`aws-inventory.txt`, `aws-inventory-verdict.txt`) |

## I. Lifecycle phases — authority, desired-state policy and transition (ADR 0003)

The phase is **operational context, not infrastructure truth**: it names the
operation Sol is performing and therefore the authority it may use and the
desired-state policy in force. Readiness is always *observed*, never inferred from
the phase, and no phase is persisted (no pointer file, no second state database).
Rows I1–I4 are captured during provisioning, I5–I6 during a deliberate re-apply,
I7–I9 during teardown, I10–I13 during and after failure/abort conditions.

Every row here needs **live behavioural** evidence: the phase the run reports is
not sufficient on its own, so each row pairs the reported phase with an
independent observation (an identity probe, an RBAC listing, a describe call, or
the terraform argv).

| # | Invariant (ADR 0003) | Scenario / action | Pass condition | Evidence |
|---|---|---|---|---|
| I1 | `CloudBootstrap` is the phase before the platform exists, holding temporary privileged authority and the Bootstrap policy | `sol deploy <target>` on a fresh target; capture the phase and the reconciliation identity at each step | the run reports `CloudBootstrap` **before** any platform mutation; the identity in use is the temporary bootstrap authority; no Ready/Production desired-state policy is applied in this phase | CLI `lifecycle phase:` output; terraform argv per step; `aws sts get-caller-identity` per phase |
| I2 | `PlatformInstalling` holds explicitly privileged installation authority, and that association stays open through the **whole** platform apply — chart RBAC included (invariant 1; **finding 14**) | during I1's apply, sample the reconciliation identity across the entire platform apply | chart RBAC (e.g. the prometheus `prometheus-server` ClusterRole) and the deploy identity's `sol-deploy` ClusterRole are created successfully — not rejected by Kubernetes' RBAC escalation check — and the privileged association is still in place afterwards | per-module terraform apply log; the created `ClusterRole` objects; `kubectl auth can-i --list` samples during the phase |
| I3 | Privilege is revoked only at the verified `PlatformInstalling -> Ready` transition, and the separate bounded cluster-access identity is then verified effective (invariants 1, 2; DEC-034) | after the install, capture the phase and probe the cluster-access identity's effective RBAC and AWS IAM boundary | run reports `lifecycle phase: Ready`; the temporary privileged association is **gone**; **positive** `can-i` for steady-state operations and **negative** `can-i` for `escalate` and `bind` on cluster roles; an `aws eks associate-access-policy` attempt as the cluster-access identity is denied; creating a ClusterRole or ClusterRoleBinding remains permitted because scoped platform management needs it, while the separate cloud provisioner alone owns access-entry/policy-association mutation | `lifecycle phase:` output; recorded cloud-provisioning and cluster-access principals; RBAC binding listing; paired `kubectl auth can-i` results; denied AWS association attempt |
| I4 | `Ready` applies the Production policy — `rds_deletion_protection = true` (BUG-039) is in force in exactly this phase | while Ready, inspect the live RDS instance and the terraform argv of a Ready-state apply | `DeletionProtection = true` live; no Destroy override (`rds_deletion_protection=false`) appears in a Ready apply's argv | `aws rds describe-db-instances`; terraform argv |
| I5 | A privileged platform change after `Ready` is an explicit `PlatformUpdating` re-entry, never a silent widening of `Ready` (invariant 3) | re-apply the platform on the already-`Ready` target (`sol deploy` carrying a platform change) | run reports `lifecycle phase: PlatformUpdating` at the start and **never** `PlatformInstalling`; elevated authority is present for the operation; the run returns to `Ready` | `lifecycle phase:` output at both ends; identity evidence during the update; post-update `can-i` (as I3) |
| I6 | The `PlatformUpdating -> Ready` return re-verifies readiness and re-establishes the bounded provisioner | after I5, capture the phase and probe RBAC exactly as I3 | run reports `lifecycle phase: Ready`; provisioner verified effective; no standing privileged association remains | `lifecycle phase:` output; RBAC listing; `can-i` results |
| I7 | `PreparingDestroy` applies the Destroy policy, and once preparation is verified the Ready policy must not run again (invariant 4; **finding 15**) | `sol destroy <target> --apply` on the Ready target; capture **every** terraform invocation after preparation | every reconciliation after verified preparation carries the Destroy overrides, appended **after** the profile's `rds_deletion_protection=true`, so the `-var` order visible in the argv makes the Destroy policy win; no post-prepare apply sets `rds_deletion_protection=true`; `DeletionProtection` is false live between preparation and destruction | terraform argv per post-prepare step (flag order visible); `aws rds describe-db-instances` sampled between the steps; run log |
| I8 | Destroy preparation is a real applied transition with a unique per-attempt final-snapshot identity (INFRA-023) | inspect the RDS snapshot list and the terraform argv during I7 | the disable is a **targeted apply**, not a `-var` on `terraform destroy`; the final-snapshot identifier matches this attempt's identity **and appears in the live snapshot list** | terraform argv; `aws rds describe-db-snapshots` |
| I9 | `Destroying` proceeds under the Destroy policy and ends at `Absent` | complete the destroy; capture the phase and the end state | run reports `lifecycle phase: Destroying`, then nothing remains; describe calls show EKS/RDS/VPC/ELB/EIP/EBS absent | `lifecycle phase:` output; teardown verification log (H6) |
| I10 | **Destruction is an abort edge** (invariant 6, INFRA-029): a failed or partially installed target stays destructible through the public lifecycle | deliberately produce a target whose platform install did **not** complete (fail or interrupt the platform step), then run `sol destroy <target> --apply` | the destroy **succeeds** and enters `PreparingDestroy`; it is not refused for being in `PlatformInstalling`; no out-of-band deletion of cloud resources is needed | `lifecycle phase:` output; destroy exit code; run log showing no refusal |
| I11 | Destroy is idempotent: an already-absent target is `Absent`, not an error | re-run `sol destroy <target> --apply` after I9 | exits 0; reports the target as absent (`lifecycle phase: Absent`); performs no RDS preparation | CLI output; terraform argv (no targeted apply) |
| I12 | Destroy resumed after an interrupted destroy completes (the abort edge is available from `PreparingDestroy`/`Destroying`) | interrupt the destroy between preparation and destruction, then re-run `sol destroy … --apply` | the second run completes destruction; the final-snapshot identity is **not** reused from the first attempt | terraform argv of both runs; live snapshot list; teardown verification |
| I13 | The phase record is operational context, never infrastructure truth (ADR 0003) | after a full apply→destroy cycle, inspect the tree and the run's artifacts | no phase-pointer file and no second state database exist; every readiness claim in I3/I4/I6 was established by an observation, not inferred from the reported phase | repository/artifact listing; the probe evidence cited in I3/I4/I6 |
| I14 | **What `Ready` asserts, and what it deliberately does not** (INFRA-035/036). `Ready` is gated on authoritative Kubernetes convergence: CRDs `Established`, Deployments `Available`, StatefulSets/DaemonSets reporting every declared replica ready, PVCs `Bound`, nodes `Ready`, the default `StorageClass` and EBS CSI driver registered, the ingress LoadBalancer endpoint assigned, and Redpanda's own broker-native cluster health. It does **not** probe the platform across the network and does **not** require an external ACME round trip | inspect the readiness checks and run them against the target; confirm no check reads a service/pod endpoint through the API server's `/proxy/` path and none requires a `ClusterIssuer` condition | the gate names only Kubernetes-native convergence (plus Redpanda's own health API); a target whose platform is converged reports `Ready` with an unreachable external ACME provider, and a revoked `/proxy/` route does not make it `Unmet` | the readiness check list (`readiness_invocations`); the run's `platform-readiness` phase output; the behavioural evidence for capability (J below and HARDEN-002's observability scenarios) |

Two consequences of I14 are worth stating, because both were learned from failed attempts
rather than reasoned about:

- **API-server → arbitrary pod/service reachability is not part of this platform's
  contract.** The EKS module admits the control plane to nodes only on the
  admission-webhook ports (4443/6443/8443/9443), and nothing promises more. Probing
  capabilities through that route made `Ready` depend on a path the platform never
  created — and the fix was to remove the probes, never to widen a security group so a
  test would pass.
- **Capability behaviour is HARDEN's question, not `Ready`'s.** "Loki's `/ready`
  answers through an API-server proxy" says almost nothing about whether observability
  works. A known log reaching Loki and being queryable does. That evidence belongs in
  HARDEN-002's observability scenarios, and it subsumes what the removed probes were
  reaching for.

## J. Explicitly not claimed (recorded as skipped, with reason — DEC-026 §9)

| Item | Reason |
|---|---|
| Zone-failure tolerance | DEC-026 does not select it |
| TypeScript production qualification | Staged by §2 with three named triggers (OCaml-only `v1`) |
| `-fn` availability tier | Not applicable: a `-fn` invocation is not a continuously-available process |
| Kafka/Redpanda AZ tolerance and multi-broker/cluster loss recovery | Named exclusion (§5) |
| Region-level failover, autoscaling, multi-team RBAC, admission policy, federation, signing/SBOM | Explicit exclusions (§2, §6, §7, §9) |
| Automated backup/restore for workload volumes | Outside `v1` (§5) |
| Business-data-grade telemetry durability | Telemetry is best-effort by design (§5) |

## Measurements to record (never assumed)

| Target (DEC-026) | Value | Measured |
|---|---|---|
| Node-loss restoration, required ready capacity | ≤ 300 s | `<from D3>` |
| Postgres failover RTO | ≤ 120 s | `<from E2>` |
| Postgres failover RPO | ≈ 0 | `<from E2>` |
| Postgres logical-loss RPO (PITR) | ≤ 300 s | `<from E3>` |
| Postgres restore RTO into a clean target | ≤ 3600 s | `<from E4>` |
| Kafka acknowledged-message loss on one broker | 0 | `<from E5>` |
| Kafka consumer auto-resume | ≤ 60 s | `<from E6>` |

## Blocking inputs (must be real, cannot be substituted)

- **The production-profile alert receiver**: a real destination plus an owner who
  can acknowledge (G1–G3). A local sink proves the mechanism only and explicitly
  does not qualify the target (DEC-026 §8).

## Assertions that ride along at no extra cost

Obligations the normal run collects, so they are exercised without a separate scenario:

1. **Make the absence verdict fire.** Section H's independent inventory queries every required
   disposable class (the run procedure lists them). Leave one residual of a class where
   `live-row.sh verify` will observe it — or record a real leftover — so the checks are shown
   able to fail against real resources, not only against the offline harness's mock. A green
   absence check that has never been seen to go red is not evidence of absence.
2. **Record the steady-state authority posture as the named identities.** Section F and `I3`:
   as the bounded cluster-access identity, an `aws eks associate-access-policy` attempt must be
   **denied**, and the steady-state `can-i` results must be recorded *with the identity that
   produced each* — positive for steady-state operations, negative for `escalate` and `bind`.
3. **Exercise the migration gate end to end.** Section C's gate, including a normal
   failing-then-fixed migration and `INFRA-044`'s redaction on the same path — not a unit test.

## What a run must not do

- Record B or D as passing from a partially deployed workload.
- Promote inspection or mechanism evidence to behavioural, or a phase line to
  infrastructure truth (section I).
- Record G as passed unless a real receiver with an owner is in place.
- Start from a checkout build rather than the released bundle.

## Host prerequisites the run's own commands need

These are not product defects; they are things the operator's session must have.

- **Docker group access, in the shell that runs the app phase.** The *publisher*
  builds and pushes the workload images, and the app phase runs Sol from the
  installed release bundle, whose `migration-runner-image` names its own runner by
  digest (SEC-011, RELEASE-006). Sol's own deploy path never shells out to `docker
  build` for anything: it resolves digests read-only, because the deploy identity
  has no registry-write authority (ADR 0002). A session that predates the operator's
  `docker` group membership fails with `permission denied ...
  unix:///var/run/docker.sock` — which reads like a target or credential problem
  and is neither. Check with `docker version` before starting, or run the app
  phase under `sg docker -c '…'`.
- **The deploy's kubeconfig context must be the deploy identity's.** Running
  `aws eks update-kubeconfig` twice with different `--role-arn` values and the
  same cluster makes both aliases share one user entry, so the "operator" context
  silently authenticates as the deploy role. Verify with
  `kubectl --context <ctx> auth can-i get clusterroles` before trusting a probe's
  identity.
- **`script` (util-linux) on `PATH`, for a fresh account.** The whole-target deploy
  offers to establish the durable installation through an interactive prompt, and the
  harness drives that prompt through a pty (`script -qec …`). Without `script` the
  harness falls back to a no-terminal run, where a fresh account's deploy refuses to
  set the installation up and the cloud phase stops before any infrastructure exists.

