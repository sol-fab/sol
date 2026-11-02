# Inspect a target's resource inventory

`sol resources <target>` is a read-only view of what Sol records as owned and what the
provider actually holds. It is for diagnosis, pre-destroy review, CI evidence, and the
partial-apply case where Terraform created a resource but did not record it.

It never imports, deletes, unlocks, or adopts anything. `sol target reconcile` remains the
only ownership-recovery path; `sol destroy` remains the absence authority.

## Run it

```sh
sol resources prod/aws/us-east-1
sol resources prod/aws/us-east-1 --json
```

The human view shows each resource's layer, status, class, name, action, and (with
`--explain` or `--verbose`) its state address, observed identity, import identity,
observation coverage, recovery disposition, and reason. `--class` and `--status` filter
rows; `--all` also shows in-cluster, Terraform-internal, and absent class rows.

## Read the verdict

`sol resources` reports two independent completeness axes:

- **Inventory:** every declared root's state/release record was read successfully.
- **Verification:** every required class was independently observed (or is `By_contract`,
  with no provider identity by contract), and every recorded row was verified.

| Verdict | Meaning | Exit |
|---|---|---|
| `reconciled` | Both axes complete; no confirmed discrepancy | `0` |
| `incomplete` | Records are complete, but a required class was unobserved | `1` |
| `attention_required` | A confirmed discrepancy: unrecorded, missing, or UID mismatch | `1` |
| `unknown` | A state/required observation could not be read; no completeness claim | `1` |
| `unverified` | `--state-only`; no independent provider observation | `1` |

A clean-looking inventory is not a clean verdict. Check
`coverage.verification.unobserved_classes` and `coverage.verification.recorded_unverified`
before treating a result as complete. `--state-only` is an inspection mode, not a
presence/absence gate.

## Status and recovery are different

A provider object can be observed accurately while Sol cannot restore Terraform ownership
of it:

| Status | Meaning |
|---|---|
| `owned` | Recorded and independently observed at the same identity |
| `recorded` | Recorded, but not independently verified (unobserved class or no exact identity) |
| `missing` | Recorded, and a successful provider read says it is gone |
| `unrecorded` | Observed, but not recorded in Terraform state |
| `external` | Durable/external by contract (state backend, delegated DNS, and similar) |
| `in_cluster` / `synthetic` | Terraform declares it, but it has no separate provider identity |
| `unknown` | The state or observation could not be read |

`recovery` is `not_applicable`, `recoverable`, `unrecoverable`, or `unmapped`. A
`recoverable` row names its Terraform address and import identity; `unrecoverable` and
`unmapped` rows explain why Sol will not guess. Only `sol target reconcile` can act on a
recoverable row.

## After a failed or timed-out apply

1. Run `sol resources <target> --json`.
2. If the verdict is `attention_required`, inspect each `unrecorded` row's `recovery`.
   A `recoverable` row is the partial-apply candidate; an `unrecoverable`/`unmapped` row
   is the enumeration the operator needs and is not adoptable by Sol.
3. Run `sol target reconcile <target> --dry-run --explain`, then the mutating
   `sol target reconcile <target> --explain`.
4. Re-run `sol resources <target> --json`; the adopted resource should be `owned`, and
   the verdict should move to `reconciled` or `incomplete` for a remaining coverage gap.
5. Use `sol destroy` for removal; the inventory is not an absence proof.

If the state or a required observation is unreadable, the verdict is `unknown`; do not
read that as absence. Preserve the original provider error and the JSON evidence.

## CI use

Use live mode for a presence/absence gate:

```sh
sol resources <target> --json > inventory.json
python3 internal/qualification/inventory_contract.py --expect reconciled inventory.json
```

The validator is also used by the read-only `inventory` phase of the AWS and GCP
qualification harnesses. `--state-only` is never a CI gate for presence or absence.
