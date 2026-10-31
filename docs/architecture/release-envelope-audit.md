# Release-envelope audit

**Decision:** do not adopt the canonical envelope now, and remove the unused envelope
module.

## Question

Would a single versioned release envelope simplify provider release records, or would it
add a layer over records that still need provider-specific fields?

## Evidence

Current provider release records:

| Adapter | Common fields | Provider-specific lifecycle fields |
|---|---|---|
| AWS Lambda `-svc` | region, service, image, identity | function name, version, alias, URL |
| AWS Lambda `-fn` | region, service, image, identity | function name, version, alias, scheduler |
| AWS Lambda task | region, service, image, identity | function/queues/DLQ/mapping/retry |
| GCP Cloud Run service | project, region, service, image, identity | provider service, revision, URL |
| GCP Cloud Run job | project, region, service, image, identity | job, generation, execution, timeout, scheduler |
| GCP task | project, region, service, image, identity | Cloud Run service/revision, topics/subscriptions/DLQ/retry |

The common fields are already small and stable. The lifecycle code is dominated by the
provider-specific fields: verification, rollback, partial-create recovery, and destruction
all read those fields directly. A canonical envelope would either:

1. duplicate the common fields while retaining every provider field under
   `provider_detail`, adding a wrapper without removing a representation; or
2. force each adapter to reconstruct typed provider state from untyped
   `provider_detail`, moving rather than removing complexity.

There is no current cross-provider consumer that reads release records as one stream.
`sol releases` lists Kubernetes releases, not provider ownership records. Each provider
adapter remains the authority for verifying and destroying the resource it created.

## Decision

Do not migrate provider records. The unused `Sol_cli_release_envelope` module and its
tests are removed so the repository has one authoritative record shape per lifecycle
rather than a second, unused schema.

Revisit this only when a concrete consumer needs to inspect records across providers, for
example a release inventory or audit command. At that point the envelope should be
designed from that consumer's required fields, not ahead of it.

## Preserved guarantees

- Provider records remain the single authority for deploy, verify, rollback, and destroy.
- Each adapter still validates the recorded provider identity and ownership before
  mutation.
- No compatibility reader or migration path is introduced.
