# Read-only resource inventory — GCP (2026-11-02)

**Scope:** a read-only run of the new `sol resources` command against an existing
qualification target after its resources were torn down. No provider mutation, no
Terraform state change, no adoption.

**Target:** `probe/gcp/us-central1` (project `sol-qualification`, region `us-central1`).
The target's state bucket was `sol-qualification-tfstate`.

**Command:**

```sh
sol resources probe/gcp/us-central1 --json
sol resources probe/gcp/us-central1 --state-only --json
```

**Results:**

- Live mode: `verdict: unknown`, `coverage.inventory.complete: true`,
  `coverage.verification.complete: false`, exit `1`. The inventory read every root and
  observed 22 classes; two required probes returned provider 404s:
  - `Cloud NAT`: the router was not found.
  - `GKE node pool`: the cluster was not found.
  These are reported as `unknown`, not absence. The existing GCP absence contract
  deliberately keeps a failed enumeration unknown even when its text says "not found";
  a parent-child absence rule would be a separate provider-contract decision.
- State-only mode: `verdict: unverified`, verification incomplete, exit `1`, and no
  provider probe ran.

**Evidence:**

- `resource-inventory.json` — live JSON.
- `resource-inventory.err` — progress/diagnostics (stdout was clean JSON).
- `resource-inventory-state-only.json` — state-only JSON.
- `resource-inventory-state-only.err` — state-only diagnostics.
- `validation.txt` — `inventory_contract.py` results for both.

**Limit:** this run establishes the read-only contract against real provider state and
correctly refuses to call the two 404s absence. It does not establish a reconciled
post-destroy verdict for GCP, and it does not establish interrupted-apply recovery
(separately authorized destructive qualification). It was run from a source checkout, not
a released bundle; the live qualification phase in `gcp/live-qual.sh` runs the installed
candidate.
