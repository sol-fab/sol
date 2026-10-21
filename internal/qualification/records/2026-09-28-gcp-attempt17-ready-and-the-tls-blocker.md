# GCP qualification Attempt 17 (2026-09-28) — `Ready` on GKE Standard, Ready-state destruction, and the TLS blocker

> File names here are historical: `qual-aws-row.tfvars` and `qual-gcp.tfvars` are now `qual.tfvars`, `live-row.sh` is now `live-qual.sh`, and `test-live-row.sh`/`test-live-qual.sh` are now `stubbed-qual-test.sh`.

## Summary

| | |
|---|---|
| revision | `30ad9835` (the driver defaults adopting `Sol_cli_profile`'s recommended shape, `DEC-054` / `FND-0066`) |
| target | fresh `qual17/gcp/us-central1`, cluster `sol-qual-gcp-17`, fresh state prefix |
| substrate | **4 × e2-standard-4**, 100 GiB pd-balanced each (was 3 × e2-standard-2) |
| result | **the platform installed and the lifecycle reported `Ready`** — the first time on GKE Standard |
| platform apply | **`ok (166.6s)`** — where Attempt 16 failed after `695.0s` on two Helm releases |
| new boundary | **`Ready-state destruction`** exercised: a supported `sol cloud destroy` from a `Ready` platform, converged to verified absence |
| new finding | **`FND-0067`** — the platform's only ACME DNS-01 solver is Route 53, so a GCP cluster issues no certificates |
| billable residue | none; `teardown verified: absent` |
| evidence bundle | `/tmp/sol-gcp-qual-17` (the harness's manifest) plus `ready-state/`, a read-only capture made while the platform was `Ready` |

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `30ad9835` | `harness.log` line 1, `evidence-manifest.txt` |
| Working tree | clean; the one expected untracked target appeared during the run and was removed by the verified teardown | `git status --porcelain` |
| Target | `qual17/gcp/us-central1`, `cluster_name: sol-qual-gcp-17`, `base_domain: qual-gcp.sol-fab.dev`, `profile: production-single-region`, `terraform_var_file: internal/qualification/gcp/qual-gcp.tfvars`, `destroy_retention: none` | target file; `harness.log` |
| Account / project / region | `lbendtlynielsen@gmail.com` / `sol-qualification` / `us-central1` | preflight |
| Harness | `internal/qualification/gcp/live-qual.sh`, `PHASE_TIMEOUT=2700`, phases `cloud` then `destroy` | `harness.log` |
| Started / finished (UTC) | `2026-09-28T00:39:23Z` → `2026-09-28T01:21:24Z` (teardown verified) | `harness.log` |
| Preflight | clean: no clusters, no SQL instances, `SSD_TOTAL_GB 0/1000`, `CPUS 0/200`, both durable prerequisites present | preflight reads |

## 2. Step log

| Step | Command | Observed | Result |
|---|---|---|---|
| bootstrap | reconcile the durable root | `durable root already matches its declared state` (00:39:29Z) | `PASS` |
| observers | waiter + API probe started before the apply | waiter pid 2575205, probe pid 2575272 | — |
| run credentials | `cluster_kubeconfig_waiter` | poll **38**: `RUNNING / credentials-established`, context pinned to `sol-qual-gcp-17` (00:46:27Z) | `PASS` — the observer's fix, live again |
| API readiness | 57 samples across the apply | 30 `REACHABLE`, and **all 30** carry the configured endpoint equal to the reported one | `PASS` |
| cloud root | `sol cloud apply qual17/gcp/us-central1` | `terraform-apply ok (615.7s)` (4 nodes), Cloud SQL `RUNNABLE` | `PASS` |
| prerequisites | included in the lifecycle | `platform-prerequisites-apply ok (47.5s)` | `PASS` |
| **platform apply** | included in the lifecycle | **`platform-apply ok (166.6s)`** | **`PASS` — first time** |
| authority bracket | after the install | `provisioner-bootstrap-access-remove ok (6.1s)` | `PASS` |
| **lifecycle** | — | **`lifecycle phase: Ready`** | **`PASS`** |
| delegation | harness wait | `delegation observed: ns-cloud-c1…ns-cloud-c4.googledomains.com.` (00:54:45Z) | `PASS` |
| TLS row | read-only capture while `Ready` | both certificates `READY=False`, challenges `pending`, `PresentError … Route 53 … NoCredentialProviders` | **`FND-0067`** |
| freeze | `capture_pre_teardown_inventory`, `freeze_evidence`, `finalise_bundle` | inventory (pre) + both Terraform states + Sol's run artifacts + manifest | `PASS` |
| **Ready-state destruction** | `sol cloud destroy qual17/gcp/us-central1` from the `Ready` platform | `platform-destroy ok (131.7s)`, `provisioner-bootstrap-access-remove ok (2.4s)`, `terraform-destroy ok (583.6s)` | **`PASS` — first time** |
| postcondition | independent provider reads | `teardown verified: absent` (01:21:24Z) | `PASS` |

## 3. The fix, observed live

Attempt 16 stopped here; Attempt 17 does not. The four pods that could not be scheduled are scheduled,
and the pool they landed on is the one the change declared:

```text
node                                    CPU      MEMORY
...-418d1ed9-3kcm                       3920m    13591676Ki
...-418d1ed9-73hb                       3920m    13591684Ki
...-418d1ed9-bqrq                       3920m    13591684Ki
...-418d1ed9-z8j8                       3920m    13591680Ki
```

**3920m CPU / 13,591,676Ki (≈ 12.96 GiB)** allocatable per node — the estimate in `FND-0066` was
*≈ 3.9 CPU / ≈ 13 GiB*, so the prediction and the observation agree to within 1%.

```text
pods: 72 Running, 1 Completed, 0 Pending   (attempt 16: 58 Running, 4 Pending)
pvc:  prometheus-server 8Gi, storage-loki-0 10Gi, storage-prometheus-alertmanager-0 2Gi,
      datadir-redpanda-0/1/2 20Gi — all Bound
quota at Ready: CPUS 16.0, INSTANCES 4.0, SSD_TOTAL_GB 480.0 (4 × 100 GiB boot + 80 GiB of volumes)
```

`platform-apply` went from `FAILED (695.0s)` on two Helm releases to **`ok (166.6s)`**, and the lifecycle
then reported `Ready`. `FND-0066`'s GCP half is therefore **observed**, not merely fixed: the change is
what made the difference, on a fresh target, with no other platform change in between.

## 4. The new blocker: `FND-0067`

The harness's `write_target` deliberately omits `cluster_issuer` (a GCP target that declares one is
refused at install time), so the platform's own default issuers are in play. Both deployed with exactly
one solver — `dns01.route53.region: us-east-1` — and on GCP the role ARN is empty, so cert-manager falls
back to an AWS credential chain that does not exist:

```text
Warning PresentError challenge/grafana-tls-… Error presenting challenge: failed to determine Route 53
        hosted zone ID: NoCredentialProviders: no valid providers in chain. Deprecated....
Warning PresentError challenge/argocd-tls-…  (same)
```

The ACME account registers (`ACMEAccountRegistered`, `lastRegisteredEmail` present), so the failure is
purely the solver: `platform/cloud/modules/platform/cert_manager_issuer.tf` is the *shared* module and
declares Route 53 unconditionally for both issuers, with no Cloud DNS alternative anywhere in the GCP
roots. `argocd/argocd-tls` and `monitoring/grafana-tls` were still `READY=False` after 14 minutes.

The platform is `Ready` — Sol's readiness does not depend on ACME — while no ingress on the cluster can
obtain a certificate. Full statement, decision space and acceptance criteria: `FND-0067`.

## 5. Deviations

| Time | Step | What was done differently | Why | Effect on evidence |
|---|---|---|---|---|
| after the delegation | TLS row | the `cloud` phase ended by design with `not tearing down: the delegation boundary is deliberate, not a leak`; rather than stopping there, the platform's state was captured read-only into `ready-state/`, the two certificates were given a bounded window (~14 min from their creation), and then the supported `destroy` phase was run | teardown is required when a run ends, and the destruction from a `Ready` platform is itself a matrix row that had never been exercised | none adverse: the frozen bundle, the pre-teardown inventory and the state snapshots are the harness's own; `ready-state/` and this record are additive |

No manual provider action, no state surgery, no emergency cleanup, and nothing remediated in the run.

## 6. What this run establishes, and what it does not

- **Establishes:** the platform installs and reaches `Ready` on `4 × e2-standard-4`; the four pods that
  blocked Attempt 16 schedule; the driver-default change in `DEC-054` is the reason; a supported
  destruction from a `Ready` platform converges to verified absence with the authority bracket used once
  each way.
- **Does not establish:** certificate issuance on GCP (`FND-0067`); any application-deploy row (no `sol
  deploy` was run); the TLS rows' own claims.
- The bundle's discriminator manifest reads `MISSING / 0 probes`, which is correct for a successful run:
  that capture is the cert-manager *failure* discriminator.

## 7. Ledger updates

| Finding / row | Before | After |
|---|---|---|
| `FND-0066` | `FIXED_UNQUALIFIED` | **`QUALIFIED`** (GCP half): the fix's effect was observed live; the AWS half remains inference |
| `FND-0067` | — | **`OPEN`**, decision required |
| `Ready` | `NOT REACHED` | **reached** |
| Ready-state destruction | `NOT REACHED` | **exercised**, converged to verified absence |
| TLS rows | unreachable | reachable but **blocked by `FND-0067`** |
| application rows | `NOT REACHED` | `NOT REACHED` |
