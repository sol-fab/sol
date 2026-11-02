# ADR 0005: Sol owns only its declared contract boundary

- **Status:** Accepted
- **Date:** 2026-10-03
- **Source:** operator decision (pre-alpha architecture review)
- **Related:** ADR 0002 (Sol owns the complete cloud-target lifecycle), ADR 0004
  (destruction removes what the lifecycle created), DEC-045 (Terraform destroy is
  the authority for what it manages), DEC-044 (recovery ownership; A1 withdrawn),
  DEC-057 (installation/environment ownership and `sol uninstall`), DEC-065 (the
  declarative contract is canonical), `docs/deployment/escape-hatches.md`

## Context

Sol provisions a target, plans a deployment, renders manifests, and reconciles
what it owns. Around that boundary sits a large amount of infrastructure the
user already runs or will run: a shared VPC, an S3 bucket with company data, an
existing DNS zone, a cache, a bastion, a data warehouse. A workload Sol deploys
legitimately needs to *use* some of it.

Two directions are available, and only one of them is Sol:

- Sol grows into a general infrastructure orchestrator: it discovers what exists
  in the account, imports it into state, plans it, reconciles it, and reports it.
  That path makes `sol plan` a universal plan, makes Sol responsible for
  resources it did not create, and turns every provider's resource model into
  Sol's problem.
- Sol owns only what its contracts declare, and exposes stable interfaces so a
  user can integrate externally-managed infrastructure themselves.

The repository already leans the second way in several places — the escape
hatches' Level 4 ("write your own Deployments, Services, and Terraform modules;
Sol does not generate or manage these resources"), the identity hand-over
(AUDIT-072: Sol owns the policy contract, the operator creates the role),
`sol uninstall` retaining externally supplied zones and operator-created
identities, and DEC-045's rule that Terraform's destroy is the authority for what
it manages — but never stated as one principle. This ADR states it.

## Decision

**Sol guarantees stable interfaces at its boundary; users are free to provision
and integrate arbitrary infrastructure outside Sol. Sol neither plans nor manages
infrastructure outside the Sol-owned contract.**

Concretely:

1. **Sol owns and reconciles only resources represented by Sol's supported
   contracts and primitives.** A resource is in scope because a Sol contract
   declares it, not because it exists in the account or because a workload
   happens to use it.
2. **`sol plan` describes changes within the Sol-owned boundary.** It is not a
   universal plan for all infrastructure associated with an application or
   environment.
3. **Users may provision additional infrastructure directly** through Terraform,
   Pulumi, provider tooling, or anything else, outside Sol.
4. **Integration with externally managed infrastructure is the user's
   responsibility.** Sol exposes stable interfaces that make it possible —
   workload identities and roles, service accounts, namespaces, endpoints, and
   the other platform boundaries Sol owns — and documents them.
5. **Sol does not need to discover, import, understand, or reconcile an external
   resource merely because a Sol-managed workload uses it.**
6. **No generic "external resource" abstraction** is introduced unless Sol has a
   concrete need to know something in order to fulfil one of its own contracts.
   The prohibition is against gradually turning Sol into an infrastructure-as-code
   orchestrator, not against every future concrete field.
7. **Provider-specific integration is expected.** On AWS a user may grant a
   workload's stable IAM identity access to an externally managed S3 resource;
   the equivalent must be possible through the appropriate GCP/Azure identity
   mechanism without Sol owning the resource.

## The one declared-ownership exception: adopting a resource the user assigns to Sol

The rule is about *ambient* external resources — ones of unknown or user-owned
provenance that a workload merely uses. It is not violated when the target's own
declaration places a resource inside Sol's contract and Sol adopts the existing
instance instead of creating a second one:

- `dns_zone_ownership: sol` means the installation creates and owns the zone. If
  that zone already exists, reconciling the durable root **adopts** it
  (`terraform import`) rather than creating a duplicate with different
  nameservers and silently breaking the delegation (DEC-057 §4). Under
  `dns_zone_ownership: user | external`, Sol owns nothing and asks for the
  delegation instead.
- The identity hand-over is the same shape from the other side: Sol owns the
  policy contract, the operator creates the role and declares its ARN, and Sol
  never creates, attaches, or rotates it (AUDIT-072).

Adoption here is bounded by declaration: Sol imports only what its contract says
it owns, never a resource discovered in the provider, and never by guessing
ownership from the fact that an object exists.

**Recovery of Sol's own stale state is not a second exception.** ADR 0012 records the
narrower case where an apply failed after a provider created a resource Sol's own
declaration caused: `sol target reconcile` may restore Terraform ownership only when the
object maps exactly to one declared address through the identity registry. It is bounded
recovery of a resource Sol already created, not adoption of ambient infrastructure, and
it does not change this boundary.


## What this resolves

- **`sol plan` scope.** The plan is the plan of the Sol-owned boundary. Resources
  a user provisions outside Sol do not appear in it, and a GitOps overlay's delta
  remains a seam rather than a primary workflow
  (`docs/deployment/escape-hatches.md`, Level 3/4).
- **Import/adoption.** It confirms DEC-044's withdrawal of A1 and DEC-045: Sol
  does not adopt resources it did not record in order to destroy or reconcile
  them; the only adoption is a declaratively-owned resource Sol must not
  duplicate.
- **The `plan`-reads-code question (DEC-065).** Contracts Sol reasons about are
  canonical in the declarative contract precisely because that is the boundary
  Sol plans; the mechanism does not extend Sol's ownership to infrastructure the
  user manages elsewhere.
- **Reconciliation of Sol's own stale state (INFRA-082 / INFRA-094).** Reconciling
  state Sol owns is in-boundary; it never becomes a licence to discover or
  mutate external resources.
- **No external-resource modelling.** Nothing in the product needs to enumerate
  a user's infrastructure to satisfy a Sol contract.

## Consequences

- Sol's plan and destroy output stays scoped and honest: it reports what Sol
  owns, and the user is never misled into thinking the account is fully
  managed.
- Integration is documented through interfaces, not ownership: a user grants a
  Sol workload's stable identity access to their resource using their own
  tooling.
- A concrete future need to know something about an external resource (for
  example, to fulfil a Sol promise about connectivity or identity) is met with a
  specific, named contract, not a generic external-resource layer.

## Non-goals

- Not a prohibition on provider-specific integration code Sol genuinely needs to
  fulfil a contract (for example, a stable IAM role it creates for a workload).
- Not a rejection of `terraform import` in the declared-ownership case above.
- Not a statement about the future hosted factory floor (DEC-008/DEC-010), where
  Sol owns its own account and substrate; that is a different ownership boundary
  and this ADR does not extend or restrict it.
