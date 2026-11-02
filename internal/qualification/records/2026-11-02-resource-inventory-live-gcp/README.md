# Read-only resource inventory — GCP (2026-11-02)

**Scope:** a read-only run of `sol resources` against an existing qualification target
after its resources were torn down. No provider mutation, no Terraform state change, no
adoption.

**Target:** `probe/gcp/us-central1` (project `sol-qualification`, region `us-central1`).
The target's state bucket was `sol-qualification-tfstate`.

**Command:**

```sh
sol resources probe/gcp/us-central1 --json
sol resources probe/gcp/us-central1 --state-only --json
```

**Results after the parent-child absence contract:**

- Live mode: `verdict: reconciled`, `coverage.inventory.complete: true`,
  `coverage.verification.complete: true`, 26 classes observed, no failures, no
  discrepancies, exit `0`.
- State-only mode: `verdict: unverified`, verification incomplete, exit `1`, and no
  provider probe ran.

The provider contract exercised here: a Cloud NAT is a child of a Cloud Router, and a GKE
node pool is a child of a GKE cluster. A **positively absent** parent proves the child
absent even when the child enumeration returns 404; a present/unknown parent keeps the
child unknown. This derives from the parent observation, never from the child's error
text. See ADR 0012.

**Evidence:**

- `resource-inventory.json` — live JSON.
- `resource-inventory.err` — progress/diagnostics (stdout was clean JSON).
- `resource-inventory-state-only.json` — state-only JSON.
- `resource-inventory-state-only.err` — state-only diagnostics.
- `validation.txt` — `inventory_contract.py` results for both.

**Limit:** this establishes the read-only contract and parent-child absence against real
provider state. It does not establish interrupted-apply recovery (separately authorized
destructive qualification). It was run from a checkout binary, not a released bundle; the
live qualification phase in `gcp/live-qual.sh` runs the installed candidate.
