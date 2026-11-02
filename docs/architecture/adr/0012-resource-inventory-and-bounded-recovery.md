# ADR 0012: Read-only resource inventory and bounded stale-state recovery

- **Status:** Accepted
- **Date:** 2026-11-02
- **Related:** PR [#1911](https://github.com/sol-fab/sol/pull/1911), issue
  [#1119](https://github.com/sol-fab/sol/issues/1119), issue
  [#1605](https://github.com/sol-fab/sol/issues/1605), ADR 0003, ADR 0005,
  [`docs/architecture/ownership.md`](../ownership.md),
  [`docs/architecture/proposals/resource-inventory.md`](../proposals/resource-inventory.md)

## Context

Terraform state is the record of what Sol owns, but it can be incomplete after a
provider creates a resource and the apply fails or is killed before Terraform persists
state. The provider inventory can see the object, but existence alone is not ownership.
`sol target reconcile` already restores Terraform ownership for exactly attributable
objects; it does not show the complete recorded/observed picture.

The operator needs one read-only answer: what is recorded, what the provider actually
holds, what can be adopted, and what is unknown. The inventory must not become a second
mutation path, a general account scanner, or a second source of ownership truth.

ADR 0005's wording says the only adoption is a declaratively-owned resource Sol must not
duplicate. The existing `sol target reconcile` recovery of a provider object attributable
to a Sol target through the identity registry is a narrower, already-implemented exception
for Sol's own stale state. This ADR records that exception explicitly rather than leaving
the product and the ADR in tension.

## Decision

1. **The inventory is a read-only projection.** `sol resources <target>` reads the
   installation, cloud, platform and authorization Terraform states, the existing
   provider inventories, and the supervised operation record. It never imports, deletes,
   unlocks, or adopts. Adoption remains `sol target reconcile`.

2. **Inventory completeness and verification completeness are separate axes.**
   - *Inventory complete* means every declared root's state/release record was read
     successfully (`empty` or `represented`, never `unreadable`).
   - *Verification complete* means every required class was independently observed or is
     `By_contract` (no provider identity by contract), and no recorded row remains
     unverified.
   - `verdict: reconciled` and exit `0` require both axes and no confirmed discrepancy.
     A recorded-but-unobserved class is `incomplete`; a failed read is `unknown`; a
     confirmed unrecorded/missing mismatch is `attention_required`; `--state-only` is
     `unverified`. Every non-reconciled verdict exits `1`.

3. **Status and recovery are separate.** A row's `status` says what the inventory knows
   (owned, recorded, missing, unrecorded, external, in-cluster, synthetic, unknown). Its
   `recovery` says what Sol can do about an observed object (`not_applicable`,
   `recoverable`, `unrecoverable`, `unmapped`). An accurately observed object can still be
   unrecoverable.

4. **Bounded stale-state recovery is the ADR 0005 exception.** `sol target reconcile` may
   restore Terraform ownership only when the provider object maps exactly to one declared
   Terraform address through the identity registry, and only for Sol-owned stale state.
   It never adopts ambient external infrastructure, never guesses ownership from a name,
   label, creation time, or proximity, and never deletes a provider object directly.
   `sol resources` may report such an object as `unrecorded`/`recoverable`, but its
   partial collection is display-only and is never the authorization for adoption.

5. **No persisted inventory and no second provider inventory.** Terraform state and
   release records remain the records; the provider remains reality. The inventory
   consumes the existing `Sol_cli_absence` observations, `Sol_cli_resource_identity`
   registry and `Sol_cli_ownership_reconciliation` dispositions. It introduces no
   inventory database, no phase file, and no account-wide scanner.

6. **`errored.tfstate` is evidence of an unresolved operation, not a second state
   authority.** The inventory reports its presence. v1 does not parse it or use its
   contents as ownership evidence; a future parser would be a separate decision with
   provenance, redaction and conflict rules.

### Provider parent-child absence

A child whose provider lifecycle is strictly owned by a parent may be declared absent
from a **positively absent** parent observation, even when the child enumeration itself
failed with 404. The two pairs currently encoded are:

| Parent | Child | Reason |
|---|---|---|
| Cloud Router | Cloud NAT | a NAT gateway cannot exist without its router |
| GKE cluster | GKE node pool | node pools are deleted with their cluster |

The derivation uses the parent's `Absent` observation and its attribution/evidence; it
does not read the child's error text. A `Present` or `Unobservable` parent leaves the
child's failure `unknown`. Each pair has a test for both the absent-parent proof and the
present-parent refusal, and the GCP live run after teardown exercises the absent case.
This is a narrow provider contract, not a general "children follow parents" rule.

## Consequences

- An operator can distinguish a clean inventory from one that merely lacks evidence,
  which is the property that prevents a false “all clear” after a partial apply.
- Reconciliation's fail-closed behavior and exact adoption set are preserved; the
  inventory cannot widen them.
- The inventory is intentionally not a complete account audit. It reports the Sol-owned
  boundary, and labels durable installation resources separately.
- Coverage is disclosed per class; an unobserved class is visible instead of being
  silently treated as owned or absent.
- The initial implementation may report `incomplete` while platform/authorization
  classes lack exact per-address observation. That is honest, not a false pass.
- The recovery exception is now documented where ownership decisions are made, so a
  future change to `sol target reconcile` must revisit this ADR and ADR 0005 together.

## Alternatives rejected

- A general account inventory or universal resource abstraction — contradicts ADR 0005
  and turns Sol into an infrastructure orchestrator.
- A persisted inventory database — stale exactly when it matters, and ADR 0003 forbids a
  second infrastructure state authority.
- Mutation or adoption inside `sol resources` — destroys the review boundary and makes a
  display command destructive.
- Treating a successful provider read as ownership proof — names and existence are not
  ownership; only the record and exact registry attribution are.
- Treating an unreadable or timed-out observation as absence — the failure mode that
  false-clean teardown exists to prevent.
