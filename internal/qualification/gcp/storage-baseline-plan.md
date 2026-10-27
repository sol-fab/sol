# GCP platform storage and capacity baseline

Status: **supporting plan for `INV-STORE-1`/`INV-STORE-2` in the existing
production-single-region GCP campaign — not a separate campaign and not a live
run authorization.**

The current production profile provisions 480 GiB against a 500 GiB
`SSD_TOTAL_GB` quota: four 100 GiB node boot disks, three 20 GiB Redpanda
volumes, and 20 GiB of monitoring PVCs. That initial footprint is verified, but
it does not establish a safe upgrade budget: a one-node surge at 100 GiB would
need 580 GiB. The preflight reports that separately and labels it a conservative
planning assumption; Sol does not currently pin `upgrade_settings`.

Changing `node_disk_gb` is a product decision, not a preflight fix. This plan
produces the missing measurements as part of the campaign that already qualifies
the GCP production profile.

## What the reference application can and cannot establish

The reference application is a **platform fixture**, not a model of a customer's
production workload. Its role is to exercise the platform: image pulls, normal
logging, deployment churn, Redpanda and observability operation, and the
lifecycle boundaries.

It can establish:

- the platform's baseline boot-disk and PVC footprint;
- whether the full platform remains healthy with a chosen boot-disk size under
  the activity the campaign actually exercises;
- creation, upgrade, repair and teardown behaviour and their quota peaks.

It cannot establish how much storage a large customer's images, Kafka retention,
application logs or node count will require. Those relationships must be stated
as workload-dependent constraints, not claimed as qualified. We will not invent
an artificial load solely to justify a smaller default.

## Precise quota model

All values are observed, not inferred:

```text
S = nodes × chosen_node_disk
  + redpanda_replicas × broker_pvc_size
  + monitoring_pvc_total

available = regional SSD_TOTAL_GB limit - current regional usage
T = max(0, observed_provisioned_capacity - S) over the lifecycle run
required = S + T
```

- `S` is **steady-state provisioned capacity**.
- `T` is **additional transient capacity** above `S` during creation, upgrade,
  repair or replacement. It is not the total observed lifecycle footprint. Do
  not add the total observed footprint to `S`; that double-counts the steady
  resources.
- `available` uses the provider's current usage, including any orphan or
  interrupted-attempt capacity.
- Actual filesystem consumption (`U`, free bytes/inodes) is a separate
  measurement and never substitutes for provisioned quota.
- Cloud SQL storage is separate from `SSD_TOTAL_GB`; do not add it here.
- Every observation must satisfy `S + T <= available`; a quota error aborts the
  lifecycle even if the arithmetic model passed beforehand.

The campaign records, separately:

1. steady-state provisioned capacity;
2. transient additional capacity during creation, upgrade and repair;
3. actual disk-space/inode consumption on every node;
4. regional quota usage and remaining headroom before and after each boundary.

## Predeclared success criteria

These thresholds are fixed **before** the run. They are not chosen after seeing
the result.

### Capacity and stability

On every node, at peak workload (deployment, steady state, and each lifecycle
boundary):

- at least **20% of the boot filesystem remains free**;
- at least **10% of inodes remain free**;
- no `DiskPressure=True` condition after initial node boot;
- no pod eviction and no image-GC failure/error;
- no pod left Pending for insufficient ephemeral storage.

The 20% byte margin is deliberately above the kubelet image-GC high threshold
(85% used) so normal GC does not have to run continuously at the measured peak.
A normal successful image-GC invocation is recorded, not treated as a failure.

#### Peak sampling, not a final snapshot

A final `df` after deployment is not evidence that the node never hit
disk pressure. The run must capture a predeclared time series, including the
intervals before and during image pulls, rollout churn, upgrade and repair.

- Sample every node at least every **5 seconds** during image pull, application
  deploy/rollout, upgrade and repair, and at least every **15 seconds** during
  steady state, for at least 30 minutes after the last mutation.
- Record per node: filesystem used/capacity and inode used/total from the
  kubelet stats/summary API (or an equivalent recorded host read), plus node
  conditions at the same timestamp.
- Start event capture before the first image pull/deploy and keep it running
  through teardown: `DiskPressure`, `Evicted`, `ImageGCFailed`,
  `FailedScheduling`/insufficient ephemeral storage, and kubelet GC messages.
- Exercise at least two image pulls/redeploys of the reference application so
  the image cache and writable-layer path are exercised. This is not an
  artificial load test; it is the campaign's normal deploy/rollback activity.
- Record the sampling commands, interval, start/end timestamps, missing samples,
  and the maximum value per node. A gap larger than two intervals marks the
  affected peak interval `UNKNOWN`; a final snapshot cannot fill it.
- A normal image-GC success is recorded as an event, not a failure. A GC error,
  unexpected disk-pressure condition, or eviction is a failure.

If the kubelet stats API does not expose inode counts in the deployed version,
use a recorded host read and say so; do not substitute an estimate. If no
deploy/redeploy actually exercised image pulls, the image-cache portion is
`UNQUALIFIED`, not passed.

### Lifecycle

Before the run, the campaign must either:

- pin and record `upgrade_settings.max_surge` and `max_unavailable`; or
- mark the lifecycle portion `BLOCKED` and do not claim it.

The candidate production setting is:

```hcl
upgrade_settings {
  strategy        = "SURGE"
  max_surge       = 1
  max_unavailable = 0
}
```

This preserves availability but requires one extra node boot disk (`T ≈
chosen_node_disk`). A capacity-constrained alternative (`max_surge = 0`,
`max_unavailable = 1`) avoids that disk but deliberately reduces availability;
it is a product decision, not a way to make the quota check pass.

The run must separately observe:

- cluster creation, including the transient default pool
  (`initial_node_count = 1` followed by its removal);
- one node-pool upgrade under the declared settings;
- one node repair/replacement;
- `S + T <= available` at every observation.

If the actual transient peak cannot be measured, the lifecycle result is
`UNKNOWN`, not pass.

### Cleanup

After teardown:

- independent provider inventory reports the target resources absent;
- `SSD_TOTAL_GB` usage returns to the recorded pre-run baseline (or a difference
  is explained by an independently identified retained resource);
- no orphan PVC, disk, snapshot or cluster-scoped resource remains;
- any unreadable inventory class is `UNKNOWN`, which fails the row.

### Evidence

The bundle must contain:

- per-node capacity/allocatable, free-byte/inode **time series** with timestamps,
  sampling intervals, gaps, and per-node maxima — not only final values;
- image/layer and kubelet/containerd/log footprint measurements;
- disk-pressure, eviction and image-GC observations;
- quota limit/usage snapshots before creation, at each lifecycle peak, and after
  teardown;
- provider resource inventory at the same boundaries;
- the exact commands and sampling interval used;
- a matrix result and evidence references.

## Abort criteria

Abort the storage decision test and preserve evidence if any of these occurs:

- any capacity threshold above is breached on any node;
- any `DiskPressure`, eviction, image-GC failure, or unexplained ephemeral-storage
  scheduling failure occurs;
- any lifecycle step would exceed `S + T <= available`, or the provider returns
  a quota/resource error;
- the actual `max_surge`/`max_unavailable` cannot be established;
- any required measurement or provider inventory is `UNKNOWN`;
- teardown cannot be completed or independent absence is not established.

On abort: do not proceed to the next lifecycle step, capture the evidence, run
supported teardown, verify absence, and stop. Diagnose the cause before deciding
whether a larger disk is necessary. A larger disk can mask image accumulation or
logging problems; do not treat it as the automatic remedy.

## Decision rule

Choose the smallest node disk whose measured peak leaves the predeclared
capacity margin and whose measured lifecycle peak satisfies:

```text
4 × chosen_disk + 80 GiB steady PVCs + measured_T <= available_SSD_TOTAL_GB
```

The 80 GiB is the verified 60 GiB Redpanda plus 20 GiB monitoring total. 50 GiB
is the first candidate to test, not a default to ship. If 50 GiB fails, record
the failure and diagnose before repeating; 20 GiB is not adopted merely because
it fits the arithmetic.

## Scaling model to document

The campaign must state, with configuration references:

- **node-driven:** `nodes × node_disk_gb` provisioned boot capacity; more nodes
  increase quota usage linearly;
- **Kafka-retention-driven:** broker replicas × retained-data requirements;
  topic count/partition metadata is modest, retained messages are the dominant
  term;
- **workers/publishers/HTTP servers:** primarily CPU, memory, image and
  ephemeral-storage pressure; they may add nodes, which then adds boot disks;
- **platform PVCs:** Redpanda, Prometheus, Loki and Alertmanager sizes are fixed
  for the profile unless explicitly changed;
- **observability data:** PVC/object-store growth independent of node count;
- **Cloud SQL:** separate storage quota, not `SSD_TOTAL_GB`.

Anything not exercised by the reference fixture is labelled **workload-dependent
and unqualified**, not extrapolated into a production claim.

## Campaign integration

The acceptance rows live in
`gcp-production-single-region-v1-matrix.tsv`:

- `INV-STORE-1` — behavioral baseline, headroom, lifecycle, cleanup.
- `INV-STORE-2` — mechanism: configuration-derived scaling model and explicit
  unqualified boundaries.

This document is supporting procedure; the matrix owns the verdict. A live run
still requires explicit operator authorization, expected costs and cleanup
responsibility, and the existing certificate, quota and identity preflights.
Stubbed tests or the quota calculation alone cannot establish live behaviour.
