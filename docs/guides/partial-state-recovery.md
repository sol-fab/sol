# Recovering partial Terraform ownership

A provider can create a resource and return an error before Terraform records it.
An empty state is therefore not proof of absence. Sol observes attributable
resources independently and refuses verified absence when required evidence is
present or unknown.

This guide defines the bounded recovery contract for [#1119](https://github.com/sol-fab/sol/issues/1119).
Import has historical live evidence; the exceptional Cloud SQL guard procedure
below still requires a disposable-target qualification before it can be called a
supported end-to-end recovery path. Do not infer qualification from offline tests.

## Restore ownership first

Use the original workspace, explicit target, provider identity and protected
remote state backend. Pause concurrent operations and retain the original provider
error and Sol diagnostics. State, execution plans and state backups can contain
credentials; keep them private and out of public logs or CI artifacts.

```sh
sol target reconcile <target> --dry-run --explain
sol target reconcile <target> --explain
```

The first command previews imports; the second performs imports and mutates state.
Lifecycle apply and destroy also reconcile ownership automatically.
Inspect the observed provider identity, target attribution, import identity and
Terraform address before applying. An unattributed or unobservable resource is not
permission to import or delete it. Resolve that uncertainty first.

Rerun the preview after import to establish that the resource is already owned.
Import restores Terraform ownership; it does not lower deletion protection or
prove the resource is absent. If provider configuration cannot be evaluated after
cluster loss, preserve that error and stop. Current GCP configuration still derives
the Kubernetes provider endpoint and CA from the GKE resource.

## Diagnose the guard before changing it

For Cloud SQL, distinguish two independent settings:

| Setting | Authority | Consequence |
|---|---|---|
| `deletion_protection` | Google Terraform provider's resource state/configuration | Blocks Terraform deletion even when the API guard is off |
| `settings.deletion_protection_enabled` | Cloud SQL API | Blocks deletion through GCP interfaces |

The [provider resource documentation](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_database_instance)
describes both. Inspect the exact imported address in the initialized target root
and observe the API setting separately. Counted resources require their instance
address, such as `google_sql_database_instance.postgres[0]`; use the address reported
by recovery, rather than assuming this example matches your state.

Sol normally lowers represented guards through a checked Terraform preparation
plan. That plan permits updates to the represented guarded resources; it does not
permit creating missing dependencies. A plan proposing to recreate a VPC or private
service networking is refused. Preserve the rejected plan diagnostic. Best-effort
guard preparation failure does not stop all teardown: other represented resources
may still be destroyed. A declared retention guarantee can block teardown when its
preparation fails. Passing a
false guard variable to `terraform destroy` does not apply a guard transition.

## Exceptional operator intervention

Explicitly authorize the exact resource and guard change, with the same retention
and backup requirements as ordinary destruction. Use the target's existing remote
backend, pinned provider and configuration for any Terraform operation. Review the
complete preparatory plan; it must not create dependencies or replace the database.
Do not bypass Sol's policy with an unreviewed apply.

If only the API guard requires a change, an explicitly authorized operator can
lower that setting through GCP and observe the completed operation. This does not
clear Terraform's separate `deletion_protection`. The historical #1119 specimen
already had the API guard off, so a GCP patch alone would not have resolved it.

If no guard-only Terraform transition is possible, stop and retain an unresolved
recovery result. There is no qualified automatic procedure for that case today.
Do not edit state blindly, recreate dependencies implicitly, or add a provider-side
resource-deletion fallback. Any exceptional recovery plan needs separate operator
review and disposable-target evidence before reuse.

Once all guards are demonstrably lowered, return to `sol destroy <target> --apply`
for Terraform-owned deletion. A provider accepting a deletion request is not the
final postcondition: require Sol's verdict and independent provider inventory,
including any previously captured identities. Present, pending deletion and
unobservable resources must not become verified absence. Record retained resources
under their explicit retention contract.

## Evidence still required

Keep #1119 open until a disposable target demonstrates orphan detection, exact
ownership restoration, accurate guard diagnosis, the operator-approved transition,
Terraform destruction and independent final absence. Populated-storage interruption
and retry evidence belongs to [#1454](https://github.com/sol-fab/sol/issues/1454).
No live mutation is authorized by this guide.

Reconsider automatic recovery if repeated ordinary failures require this procedure,
multiple native resource classes need it, or unattended exceptional recovery becomes
a product requirement. A dedicated recovery configuration or root/state migration
needs its own design decision; normal destruction must remain fail-closed meanwhile.
