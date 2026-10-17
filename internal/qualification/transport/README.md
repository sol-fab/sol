# Qualification-only transport

DEC-039 / FND-0020.

A live qualification run sometimes has to drive a real transaction against an
application's **private** `ClusterIP` service. No Sol-provisioned production identity
can reach one, and that is deliberate: provisioner mutates infrastructure, publisher
publishes artifacts, deploy mutates workloads, operator observes. None of them should
be able to tunnel into an arbitrary application pod.

This directory exists so the harness can get connectivity **without** touching that
model.

## What it grants

| Resource | Verbs | Scope | Why |
|---|---|---|---|
| `pods`, `services` | `get`, `list` | cluster | resolve a service's selector to a pod to attach to |
| `pods/portforward` | `create` | cluster | the transport |
| `namespaces` | `get` | cluster | read the server-returned `kube-system` UID for the observation identity |
| `deployments`, `jobs`, `configmaps` | `get`, `list` | per namespace | the application and migration CA observations |

The identity read is the only cluster-scoped addition. The observation reads are a
separate `sol-qualifier-observe` ClusterRole bound by **RoleBindings** in the
namespaces `establish.sh` is told to observe (the app and worker namespaces the row
passes); there is no cluster-wide binding for them. Nothing else: no mutating verb,
no `pods/exec`, no `pods/log`, no `events`, no `secrets`. Diagnosis stays the
operator's job.

The principal's **AWS** authority is the other half, and it is checked before the window
opens: the role must carry no attached policy beside the script's own inline one (an
`AdministratorAccess` attached by hand would make the transport an account administrator,
which no Kubernetes-side probe could see), its trust policy must name this account's root
and nothing else, and the inline policy is `eks:DescribeCluster` on the one cluster this
transport reaches — `eks:ListClusters` is a different, unused, unavoidably `Resource: "*"`
permission. A role that fails any of those is refused, not repaired.

## Establishing it

```
./establish.sh <cluster-name> <iam-role-name> [region] [namespace]
```

No standing identity can write cluster-scoped RBAC — the installation authority is
de-escalated (ADR 0003) — so the script opens a **temporary cluster-admin window on its
own principal**, applies `transport.yaml`, and closes it. `[namespace]` is the namespace
the post-establishment check reads (default `default`); pass the application namespace
under qualification where one exists.

The window is closed by **deleting the access entry and recreating it**, never by
disassociating the policy: measured live, a disassociation was reported complete while the
authorizer still granted cluster-admin for minutes, so the API's own report is not evidence
that a privileged grant is gone (`FND-0021` / `INFRA-061`). Deleting the entry propagated
in under 45 seconds.

Establishment then **verifies the effective surface** as the qualifier, with real
authorized calls rather than the API's description, and refuses to leave a credential
behind when it cannot show the declared one:

- `kubectl auth whoami` names the qualifier's own assumed-role session and the group
  `sol:qualifiers`, and does not name `system:masters` — the observation is of *this*
  principal, carrying *this* mapping, not merely of a name that contains it;
- `get pods -n <namespace>` succeeds, and `auth can-i list services` answers `yes` — the
  addressing grant is effective;
- `auth can-i create pods/portforward -n <namespace>` answers `yes`;
- `auth can-i get namespaces` answers `yes` — the cluster-scoped identity read;
- for each declared observation namespace, `auth can-i get deployments.apps`,
  `list deployments.apps`, `get jobs.batch`, `list configmaps` and `get configmaps`
  answer `yes` — the CA observations' reads are effective where they are needed;
- `get secrets -n <namespace>` is **denied** by a real call — the strongest single negative,
  because cluster-admin answers it;
- `auth can-i` answers `no` for `*/*`, `create pods/exec`, `get pods/log`, `delete pods` and
  `get secrets` — **in every observation namespace** — a sample of the contract's deliberate
  absences, and the verbs by which a broader grant would be usable rather than merely
  visible. `*/*` is the catch-all: a grant of any verb on any resource fails it;
- the observation reads answer `no` in a namespace that was never bound
  (`sol-qualifier-unbound` by default), so an accidental cluster-wide observation grant
  fails establishment.

The probe is a *sample* of the effective surface, not an exhaustive RBAC audit. It
positively checks every observation read the driver performs (including
`get configmaps`) in each bound namespace and denies those reads in an unbound one,
but a grant on a resource or verb outside the sampled set — `get events`, say — would
still pass. What it establishes is that the principal is this mapping, that the
addressing, transport and observation grants are effective where required and denied
outside them, and that the decisive broad grants are refused.

A failure at any of those leaves **no** access entry rather than a broad one, and the script
says so: it reports the removal only after `describe-access-entry` agrees the entry is gone,
and if the entry cannot be removed it names the principal and prints the command to remove it,
rather than reporting a removal it did not verify. That path matters because the measured
stickiness (`FND-0021`) is a property of the API's *reports*: a delete that failed used to be
indistinguishable from a window that closed. The retry bound is
`SOL_QUALIFIER_VERIFY_ATTEMPTS` (default 12) and `SOL_QUALIFIER_VERIFY_INTERVAL_S` (default
15); the defaults are the live values, and the offline test below lowers them.

`internal/ci/test_qualification_transport_establish.sh` runs the whole sequence against
stub `aws`/`kubectl` binaries and asserts: a narrow surface is accepted; a surface broader
than declared fails with the entry removed; a grant the contract excludes (`pods/exec`) fails;
a mapping outside the declared group fails; a manifest that did not take effect fails with the
window closed; a `delete-access-entry` that did not remove the entry fails *and says so*; an
attached policy and a trust beyond this account are refused before any window opens. It also
asserts that no run ever reaches `disassociate-access-policy`.

## What must never happen

- `sol deploy` (its environment reconcile) applying this, or any production Terraform root referencing
  `sol:qualifiers` or `sol-qualifier-transport` — a customer environment must not be
  able to acquire qualification scaffolding by running Sol's normal lifecycle.
- A target field naming the qualifier principal.
- Any verb added to provisioner, publisher, deploy or operator to make a test
  easier.
- Closing the establishment window by disassociating the admin policy, or trusting
  `describe-access-entry` for it (`FND-0021`).
- Reporting a closed window or a removed entry that was not observed to be closed or removed.

`internal/ci/check_qualification_transport.py` asserts the grant, the reachability
directions and the establishment script's own AWS authority (one `eks:DescribeCluster`
statement scoped to the cluster, no attached policy, no disassociation), and
`internal/ci/test_qualification_transport_check.sh` proves the guard can fail.

## Evidence rule

The qualification record must name the identity that established transport
**separately** from the identities whose contracts are under test. Transport is
harness mechanics; it is never evidence about a production identity. Before a run
uses it, the run reports the effective-surface verification above, from the principal
that performed it.
