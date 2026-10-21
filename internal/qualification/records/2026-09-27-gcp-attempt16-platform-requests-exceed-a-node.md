# GCP qualification Attempt 16 (2026-09-27) — the platform's pod requests exceed one node's allocatable capacity

> File names here are historical: `qual-aws-row.tfvars` and `qual-gcp.tfvars` are now `qual.tfvars`, `live-row.sh` is now `live-qual.sh`, and `test-live-row.sh`/`test-live-qual.sh` are now `stubbed-qual-test.sh`.

## Summary

| | |
|---|---|
| revision | `c6d8a460` (current `main`, the observer merge `#634`, confirmed before the run) |
| target | fresh `qual16/gcp/us-central1`, cluster `sol-qual-gcp-16`, fresh state prefix |
| result | **STOPPED at the full platform apply** — `helm_release.redpanda` and `helm_release.loki[0]` timed out |
| first blocker | **two pods request more than a single node's allocatable capacity**, so they are unschedulable by arithmetic, not by pressure |
| last boundary crossed | the platform prerequisites apply (`ok (52.4s)`) and every other platform pod scheduled: 58 of 62 pods `Running` |
| new finding | **`FND-0066`** — the platform's declared requests cannot fit the substrate its own GCP driver defaults to |
| decision ticket | **`DEC-054`** (BACKLOG, `Decision Required`) — the remedy is a sizing or a request-profile decision |
| billable residue | none; supported teardown verified `absent` |
| purpose of the run | first live exercise of the merged qualification observer, and a fresh specimen of the Redpanda/Loki scheduling question |

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `c6d8a460` | `git rev-parse --short HEAD` at run start; recorded in the bundle as `harness.log` line 1 |
| Working tree state | clean at start and at end; the one expected untracked target appeared during the run and was removed by the verified teardown | `git status --porcelain` |
| Qualification target | written by the harness at `examples/pluto/sol/environments.local.yml`, removed after the verified teardown. Contents (from `harness.log`): environment `qual16`, target `gcp/us-central1`, `cluster_name: sol-qual-gcp-16`, `base_domain: qual-gcp.sol-fab.dev`, `profile: production-single-region`, `terraform_var_file: internal/qualification/gcp/qual-gcp.tfvars`, `state_bucket: sol-qualification-tfstate`, `destroy_retention: none`, `app_db`/`events`/`charge_svc`/`notify_worker` omitted | target file; `harness.log` |
| Profile | `production-single-region` | target |
| Account / project | `lbendtlynielsen@gmail.com` / `sol-qualification` | `gcloud auth list`, `gcloud config get-value project` |
| Region | `us-central1` | harness environment |
| Cluster name | `sol-qual-gcp-16` | harness environment |
| Harness | `internal/qualification/gcp/live-qual.sh cloud`, `PHASE_TIMEOUT=2700` | `harness.log` |
| Operator identity running Sol | `user:lbendtlynielsen@gmail.com` (impersonated as `sol-qual-gcp-16-provisioner@sol-qualification.iam.gserviceaccount.com`) | target + apply argv |
| Started (UTC) | `2026-09-27T22:16:53Z` | `harness.log` line 1 |
| Finished (UTC) | `2026-09-27T22:54:33Z` (teardown verified) | `harness.log` |
| Evidence bundle | `/tmp/sol-gcp-qual-16` — outside the repository; the harness's own narrative is inside it as `harness.log` | bundle |

## 2. Entry point and environment

- **Procedure followed:** `internal/qualification/README.md` (operating rules) and
  `internal/qualification/gcp/gcp-production-single-region-v1-matrix.md`. The read-only preflight ran
  first (below); `DEC-040`'s whoami capture is Sol's own install-path gate and is reported in
  `cloud-apply.log`.
- **Commands executed, in order, as run:**

  ```sh
  # 1: preflight (read-only, before any mutation)
  gcloud container clusters list --project sol-qualification
  gcloud sql instances list --project sol-qualification
  gcloud compute regions describe us-central1 --project sol-qualification --format=json
  gcloud storage buckets describe gs://sol-qualification-tfstate --project sol-qualification
  gcloud dns managed-zones describe qual-gcp-sol-fab-dev --project sol-qualification

  # 2: the run (detached in its own session, output into the bundle)
  cd /home/logan/Code/sol-cloud/sol-obs3
  dune build cli/bin/main.exe
  setsid nohup env CLUSTER=sol-qual-gcp-16 TARGET=qual16/gcp/us-central1 \
    IMPERSONATOR=user:lbendtlynielsen@gmail.com \
    LE_EMAIL=qualification@sol-harden-qualification.dev \
    PROJECT=sol-qualification REGION=us-central1 PHASE_TIMEOUT=2700 \
    LOG_DIR=/tmp/sol-gcp-qual-16 XDG_DATA_HOME=/tmp/q16-xdg \
    internal/qualification/gcp/live-qual.sh cloud >>/tmp/sol-gcp-qual-16/harness.log 2>&1 &
  ```

- **Preflight result — clean.** No clusters, no SQL instances, no addresses or disks matching
  `sol-qual-gcp-16`; `SSD_TOTAL_GB limit=1000 usage=0`, `CPUS 0/200`, `IN_USE_ADDRESSES 0/8`; both
  durable prerequisites present (`sol-qualification-tfstate`, `qual-gcp-sol-fab-dev`); the zone's
  `NS` record resolves to `ns-cloud-c{1..4}.googledomains.com`.

## 3. Step log

### Step 1 — bootstrap and observers

- **Command:** the harness's own `reconcile_durable_root`, then `start_cluster_kubeconfig_waiter` and
  `api_readiness_probe_start` (both before the apply, so they see the whole transition).
- **Times:** `22:16:54Z` → `22:17:03Z`
- **Observed output** (verbatim, `harness.log`):

  ```text
  [16:16:54] bootstrap: state bucket gs://sol-qualification-tfstate present
  [16:16:54] bootstrap: reconciling the durable root against its declared state
  [16:17:02] bootstrap: durable root already matches its declared state
  [16:17:02] run kubeconfig waiter: pid 2042822, polling every 10s
  [16:17:03] api readiness probe: every 15s -> /tmp/sol-gcp-qual-16/api-readiness.tsv (pid 2042887)
  [16:17:03] phase: cloud-apply
  ```

- **Result:** `PASS` (durable root reconciled in place; no replacement proposed).

### Step 2 — the run's credentials are established while the cluster becomes RUNNING

This is the transition Attempt 15g could never reach, and the step the observer wiring exists for.
Verbatim, `kubeconfig-waiter.tsv`:

```text
2026-09-27T22:17:15Z	2	unreadable	poll-failed	no status yet: cluster absent, or the read failed
2026-09-27T22:18:01Z	6	unreadable	poll-failed	no status yet: cluster absent, or the read failed
2026-09-27T22:22:29Z	30	PROVISIONING	waiting	cluster not RUNNING yet
2026-09-27T22:27:52Z	59	RECONCILING	waiting	cluster not RUNNING yet
2026-09-27T22:28:16Z	61	RUNNING	credentials-established	context pinned to sol-qual-gcp-16
```

and `harness.log`:

```text
[16:28:16]   kubeconfig: using context gke_sol-qualification_us-central1_sol-qual-gcp-16 (pinned to this run's cluster)
[16:28:16] run kubeconfig: established while the cluster became RUNNING (2026-09-27T22:28:16Z)
```

Attempt 15g's journal, on the same code path, ended at poll 123 with
`RUNNING / generation-incomplete` for 72 consecutive polls and then
`STOPPED-WITHOUT-CREDENTIALS`; its run-owned kubeconfig existed and named its cluster throughout.

### Step 3 — the provider and configured endpoints now agree, and `/readyz` answers

`api-readiness.tsv`, first sample before credentials, then the first after establishment:

```text
2026-09-27T22:17:03Z	-	-	UNREACHABLE	The connection to the server localhost:8080 was refused - did you specify the right host or port?
2026-09-27T22:28:27Z	23.236.57.130	23.236.57.130	REACHABLE	ok
2026-09-27T22:41:49Z	23.236.57.130	23.236.57.130	REACHABLE	ok
```

93 samples across the apply, 50 of them `REACHABLE`; **every** sample before establishment reports
`server_configured` as `-` (no credentials yet, so no configured endpoint exists to report), and
every sample after it reports `23.236.57.130`, equal to the provider-reported endpoint. In 15g the
configured column was `-` in **all 88** of its samples — including all 51 in which the API answered
`REACHABLE`, which is the state the fix removes.

- **Result:** `PASS` for the qualification claim "provider endpoint and configured endpoint align";
  the observer's configured-endpoint column is now measurable.

### Step 4 — cloud root: cluster RUNNING, Cloud SQL RUNNABLE

- **Command:** `sol cloud apply qual16/gcp/us-central1` (Terraform `<cluster>` root).
- **Observed (provider, at the time of the platform apply):** `gcloud container clusters list` →
  `sol-qual-gcp-16 RUNNING`; `gcloud sql instances list` → `sol-qual-gcp-16-postgres RUNNABLE`.
- **Result:** `PASS` (CloudBootstrap / CloudReady).

### Step 5 — platform prerequisites

- **Observed** (`cloud-apply.log`): `[platform-prerequisites-apply] ok (52.4s)` — namespaces,
  the provisioner RBAC and `helm_release.cert_manager`.
- **Result:** `PASS` — `FND-0060`, `FND-0010` and `FND-0061`'s boundary crossed again on a fresh
  target.

### Step 6 — full platform apply — **FAILED**

- **Observed** (`cloud-apply.log`, ANSI stripped):

  ```text
  [platform-apply] FAILED (695.0s)
    run: cloud-apply-20260927T221703Z-2042892
    log: /tmp/q16-xdg/sol/runs/cloud-apply-20260927T221703Z-2042892/platform-apply.log
    last lines:
      exited with code 1: ╷
      │ Error: context deadline exceeded
      │   with module.platform.helm_release.redpanda,
      │   on ../../modules/platform/main.tf line 214, in resource "helm_release" "redpanda":
      │
      ╵
      ╷
      │ Error: context deadline exceeded
      │   with module.platform.helm_release.loki[0],
      │   on ../../modules/platform/main.tf line 366, in resource "helm_release" "loki":
      │
      ╵
  ```

- **Result:** `FAIL` — two Helm releases, and only two, did not become ready. Nothing was remediated
  in the run.

### Step 7 — the failure capture

- **Command:** `capture_platform_failure_evidence` → `observer.py capture --dir
  …/platform-failure --kubeconfig …/run-kubeconfig.yaml --cluster sol-qual-gcp-16 --bound 30`.
- **Observed** (`platform-failure/capture-summary.txt`):

  ```text
  credentials for sol-qual-gcp-16: yes
  reads attempted: 10
  pods                   63 lines
  pod-states             62 lines
  pod-demand             62 lines
  events                 1287 lines
  pvc                    7 lines
  pv                     4 lines
  nodes                  4 lines
  node-capacity          3 lines
  node-taints            3 lines
  helm-release-secrets   10 lines
  ```

- **Result:** `PASS` — 10 of 10 reads produced output; the summary was written; the run continued
  into `capture_fnd0010` (23 discriminator files) and then into teardown. Attempt 15g produced **two**
  artifacts from the same step (`pods.log` empty-of-content, `pod-states.log` carrying kubectl's
  rejected-argv error) and then ended there under `set -e`, before `capture_fnd0010`.

### Step 8 — teardown, and the postcondition

- **Command:** `sol cloud destroy qual16/gcp/us-central1 --apply …` (harness-generated variables).
- **Times:** `22:41:56Z` → `22:54:33Z`. `platform-destroy ok (106.0s)`;
  `provisioner-bootstrap-access-remove ok (2.3s)`; cloud root destroyed.
- **Observed** (`harness.log`):

  ```text
  [16:54:33]   ✓ dns-zone present (durable prerequisite)
  [16:54:33]   ✓ quota absent
  [16:54:33] teardown verified: absent
  ```

- **Independent verification** (`inventory-post.tsv`, provider reads only): every disposable class
  `ABSENT` — cluster, SQL, network, subnetwork, router, NAT, addresses (regional and global), disks,
  forwarding rules, Artifact Registry, all three service accounts, custom role, role binding,
  impersonator binding, peering; `quota ABSENT` (`SSD_TOTAL_GB 0/1000`); both durable prerequisites
  `PRESENT`. The target file was removed.
- **Result:** `PASS` — supported teardown converged to absence with no manual or emergency action.

## 4. The new finding: what made the two releases time out

`FND-0066`. The two releases that timed out are the two whose required pods never scheduled. Of 62
pods, **58 were `Running` and 4 were `Pending`**, and those 4 are exactly the failure:

```text
monitoring/loki-chunks-cache-0	Pending	requests={"cpu":"500m","memory":"9830Mi"}	limits={"memory":"9830Mi"}	PodScheduled=False(Unschedulable)
redpanda/redpanda-0	Pending	requests={"cpu":"2","memory":"4Gi"}	limits={"cpu":"2","memory":"4Gi"}	PodScheduled=False(Unschedulable)
redpanda/redpanda-1	Pending	requests={"cpu":"2","memory":"4Gi"}	limits={"cpu":"2","memory":"4Gi"}	PodScheduled=False(Unschedulable)
redpanda/redpanda-2	Pending	requests={"cpu":"2","memory":"4Gi"}	limits={"cpu":"2","memory":"4Gi"}	PodScheduled=False(Unschedulable)
```

(`pod-demand.log`; a `Pending` pod has no assigned node and no container state, so `pod-states.log`
reports them with empty status for exactly the same reason.)

The scheduler's own verdict, verbatim from `events.log` (four messages, no others of this class):

```text
redpanda     Warning   FailedScheduling   pod/redpanda-0     0/3 nodes are available: 3 Insufficient cpu. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
redpanda     Warning   FailedScheduling   pod/redpanda-1     0/3 nodes are available: 3 Insufficient cpu. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
redpanda     Warning   FailedScheduling   pod/redpanda-2     0/3 nodes are available: 3 Insufficient cpu. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
monitoring   Warning   FailedScheduling   pod/loki-chunks-cache-0   0/3 nodes are available: 3 Insufficient memory. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

The nodes are healthy and unconstrained (`nodes.log`, `node-capacity.log`, `node-taints.log`): three
`Ready` nodes, no taints, `MemoryPressure=False`, `DiskPressure=False`, `PIDPressure=False`,
`Ready=True(KubeletReady)`, **allocatable `1930m` CPU and `6170268Ki` (≈ 6026 Mi) memory each**.

That makes the failure arithmetic rather than pressure:

| Pod | Requests | Per-node allocatable | Ratio |
|---|---|---|---|
| each `redpanda-*` | `2000m` CPU | `1930m` CPU | 1.04 × a node — **no node in this pool can ever fit it** |
| `loki-chunks-cache-0` | `9830Mi` memory | `6026Mi` memory | 1.63 × a node — **no node in this pool can ever fit it** |

So the queue is not "the nodes are full": an *empty* node of this shape cannot satisfy either request,
and adding nodes or replicas cannot change that. (Three redpanda brokers ask `6000m` together against
a pool total of `5790m` allocatable, which is the same statement from the other side.)

### The pool is not full — the fit is per node

Summing the requests of the captured pods by the node each is on (`pod-demand.log` carries both the
requests and `.spec.nodeName`):

| node | pods | CPU committed | memory committed |
|---|---|---|---|
| `…-afe4e39e-0fb0` | 21 | 0.40 / 1.93 | 0.69 / 5.88 GiB |
| `…-afe4e39e-5r8s` | 15 | 0.79 / 1.93 | 1.75 / 5.88 GiB |
| `…-afe4e39e-8zhw` | 22 | 1.05 / 1.93 | 1.30 / 5.88 GiB |
| **pool** | **62** | **2.23 / 5.79** | **3.74 / 17.65 GiB** |

The platform's 58 scheduled pods commit **2.23 CPU of the pool's 5.79** and 3.74 GiB of its 17.65.
With all four unschedulable pods placed, the demand would be **8.73 CPU / 25.34 GiB**, and the largest
single pod needs **2.00 CPU / 9.60 GiB on one node**. So the node shape is decided by the *largest pod*,
not by the pool total:

| machine type | advertised | observed allocatable | fits the largest pod? |
|---|---|---|---|
| `e2-standard-2` (this run) | 2 vCPU / 8 GiB | 1.93 CPU / 5.88 GiB | **no** — 2.00 CPU and 9.60 GiB both exceed it |
| `e2-standard-4` | 4 vCPU / 16 GiB | ≈ 3.9 CPU / ≈ 13 GiB (estimate) | yes; ≈ 3 GiB memory headroom on the cache's node |
| `e2-standard-8` | 8 vCPU / 32 GiB | ≈ 7.9 CPU / ≈ 28 GiB (estimate) | yes, comfortably |

The two estimates apply the observed reservation ratio (8 GiB → 5.88 GiB allocatable) to the larger
shapes; they are the next specimen's `node-capacity` read to confirm, not an input to the decision.

### Where each request comes from

- **Redpanda** — Sol's own declared platform defaults: `platform/cloud/modules/platform/variables.tf`
  (`redpanda_replicas = 3`, `redpanda_cpu_cores = 2`, `redpanda_memory = "4Gi"`), applied to the
  `helm_release.redpanda` values in `platform/cloud/modules/platform/main.tf`. The observed request
  matches those defaults exactly.
- **Loki's chunk cache** — the upstream `grafana/loki` chart's own default. Sol's values
  (`platform/shared/components.json`, `loki.common` / `loki.local`) set `deploymentMode: Monolithic`,
  `singleBinary.replicas: 1` and the replication factor, and never touch `chunksCache`; the substring
  `9830` does not appear anywhere under `platform/`. The chart deploys the cache as a separate
  component whose request the platform profile inherits.
- **The substrate** — the GCP driver's own defaults: `platform/cloud/gcp/cluster/variables.tf`
  (`node_count = 3`, `node_machine_type = "e2-standard-2"`, `node_disk_gb = 100`). The run set none of
  them, so the substrate is what the product declares. `node_count`'s description — "Three gives the
  platform's observability and Kafka components room" — is the intent the observation contradicts.

### Not the cause (recorded so it is not re-tested)

- **Storage.** The monitoring PVCs bound (`storage-loki-0`, `prometheus-server`,
  `storage-prometheus-alertmanager-0` all `Bound`); the redpanda `datadir-*` PVCs are `Pending` with
  `WaitForFirstConsumer`, which is their correct state until the pod schedules. No `ProvisioningFailed`
  or `ExternalProvisioning` failure appears for them. Storage is downstream of scheduling here.
- **Disk quota.** `SSD_TOTAL_GB limit=1000 usage=320 free=680` at the pre-teardown inventory — the
  `FND-0062` wall is not in play.
- **Taints and admission.** No node carries a taint; the prerequisites apply succeeded; the failures
  are resource-fit, not admission.
- **The `Ready` probe.** `loki-0` itself was `2/2 Running` (`Readiness probe failed: … 503` appears in
  its early log, then it became ready); the loki release failed because its cache pod could not
  schedule.

## 5. Deviations

| Time | Step | What was done differently | Why | Authorized by | Effect on evidence |
|---|---|---|---|---|---|
| before the run | — | the run was launched from worktree `sol-obs3` at `c6d8a460` (the merged observer revision) rather than from a dedicated run worktree | the observer work had just merged; one actor, one worktree | operator mandate (autonomous qualification loop) | none; the revision is recorded in `harness.log` and the manifest |
| — | Step 7 | no FND-0010 discriminator was selected (`classification: UNKNOWN`) | the run failed on resource fit, not on cert-manager; `capture_fnd0010` still captured all 23 probes | — | the cert-manager discriminator is captured but not needed; the classification is recorded as `UNKNOWN` rather than guessed |

No manual action, no state surgery, no emergency cleanup, no live remediation.

## 6. What this run does not establish

- **`Ready`** and Ready-state destruction: not reached — the platform never installed fully.
- **`INV-SUBSTRATE-*` rows** and every application-level row: not reached.
- The **AWS** consequence of the same arithmetic: the AWS driver's defaults
  (`platform/cloud/aws/cluster/variables.tf`, `node_instance_types = ["m6i.large"]` — the same
  2 vCPU / 8 GiB shape) imply the same unschedulability, but **no AWS run in the ledger has reached a
  platform install**, so this is inference from declarations, not observation. It is recorded as such
  in `FND-0066`.
- Whether the platform installs if the four pods schedule: untested here, and the direct question the
  next specimen would answer.
- The **Helm timeout** is not qualified as adequate or inadequate; the releases never had a chance to
  become ready. Nothing about it was changed.

## 7. Ledger and findings updates

| Finding / row | State before | Moves to | Because |
|---|---|---|---|
| `FND-0066` (new) | — | `OPEN`, decision required (`DEC-054`) | the four unschedulable pods and the arithmetic above |
| `FND-0027`, `FND-0010`, `FND-0060`, `FND-0061`, `FND-0062`, `FND-0063` | unchanged | unchanged | their boundaries were crossed on this fresh target; nothing here re-opens them |
| `Ready`, Ready-state destruction, `INV-SUBSTRATE-*`, application rows | `NOT REACHED` | still `NOT REACHED` | the platform apply stopped at the two releases |

## 8. The qualification machinery, as exercised

This run is also the first live exercise of `#634`, and it held:

- the run-owned kubeconfig was recognised by structure (Step 2) — the 15g defect;
- the probe's configured endpoint was populated and equal to the provider's (Step 3);
- the failure capture attempted all ten reads, recorded none as failed, wrote its summary, and the
  run continued (Step 7) — 15g lost six artifacts and the rest of the failure path;
- the observer's `pod-demand` and `node-taints` reads, added for this question, are what make the
  finding arithmetically exact rather than a reading of a timeout;
- teardown and its independent verification (Step 8) were unaffected.
