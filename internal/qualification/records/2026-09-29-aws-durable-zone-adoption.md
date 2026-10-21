# AWS durable hosted zone: the delegated zone adopted into durable ownership (2026-09-29)

> File names here are historical: `qual-aws-row.tfvars` and `qual-gcp.tfvars` are now `qual.tfvars`, `live-row.sh` is now `live-qual.sh`, and `test-live-row.sh`/`test-live-qual.sh` are now `stubbed-qual-test.sh`.

Operator instruction: choose mechanism (a) — the smallest AWS mirror of the existing GCP
durable-zone ownership mechanism, consistent with DEC-042/DEC-043 and HARDEN-004.

**Status: implemented, adopted without recreation, verified.**

## Why this exists

DEC-042 decided the two qualification labels and reserved `qual-aws.sol-fab.dev` for the AWS
row. DEC-043 (2026-09-22, decided 2026-09-23) then decided the zone's lifetime:

> The delegated Cloud DNS zone is a durable prerequisite and must have durable Terraform
> ownership separate from the disposable target cloud state. A target destroy must neither
> destroy it nor remove its ownership. The Attempt-5 zone is imported into that durable owner
> rather than recreated, so the delegated NS set is preserved.

Its stated reason is the external delegation, not run-to-run convenience: a recreated zone gets
different nameservers, silently breaking the delegation pasted at the registrar — which Sol
cannot repair programmatically. Only GCP had the mechanism; AWS's zone was created by the
disposable cluster root, so any teardown deleted it.

That is not hypothetical here. The Attempt-31 teardown deleted `qual-aws.sol-fab.dev`: the
state came back empty, `list-hosted-zones` returned nothing, and public resolution returned no
NS at all while the registrar still pointed at the dead delegation. Recreating the zone gave
**different** nameservers (`ns-1173.awsdns-18.org`, `ns-1997.awsdns-03.co.uk`,
`ns-411.awsdns-51.com`, `ns-966.awsdns-56.net` → `ns-1335.awsdns-38.org`,
`ns-803.awsdns-36.net`, `ns-1560.awsdns-03.co.uk`, `ns-485.awsdns-60.com`) and required a new
external delegation. DEC-042's premise — the nameservers are baked into the registrar — was
demonstrated live, on AWS, in this session.

## Scope of this change

This is the AWS implementation of the already-decided DEC-042/DEC-043 zone-lifecycle contract,
using the same qualification-shaped interim mechanism GCP has. **It does not decide or
implement DEC-043's larger Option A stage model** (named `bootstrap → preflight → apply`
stages owning durable prerequisites product-wide), which remains an open decision. The durable
root here is the existing provider bootstrap root, driven by the qualification harness.

Specifically:

- `platform/cloud/aws/bootstrap` owns `aws_route53_zone.qualification` behind
  `manage_dns_zone`, beside the state bucket it already owned, and now keeps that ownership in
  its own `backend "s3" {}` — the durable root's state must outlive the machine that ran it,
  exactly as GCP's does in its `backend "gcs" {}`.
- `platform/cloud/aws/cluster` no longer owns a zone that a target must not destroy: with
  `create_route53_zone = false` it reads the existing zone through
  `data.aws_route53_zone.existing`, and its cert-manager policy is scoped to that zone's ARN
  instead of the former `arn:aws:route53:::hostedzone/*` fallback.
- `internal/qualification/aws/qual-aws-row.tfvars` sets `create_route53_zone = false`, so the
  row uses the durable zone; `smoke-test.tfvars` sets `true`, so that path remains
  self-contained (its zone is disposable and never delegated).
- `internal/qualification/aws/live-row.sh` reconciles the durable root before the cloud phase
  — plan with `-detailed-exitcode`, refuse if the plan contains `must be replaced` or
  `will be destroyed`, apply only in-place changes — mirroring `live-qual.sh`.

Scope is deliberately the delegated zone only. Durable ownership is **not** generalised to the
state bucket or other qualification infrastructure; DEC-043 itself records why the bucket
cannot be given the same treatment (it must preexist the root whose state it stores).

## Adoption, without recreation

The zone existed in the disposable target's state (`Z0555133LN4ZIDB3U52A`, created by a
targeted apply while diagnosing the teardown defect). It was adopted by import, not recreated.

Nameservers before adoption, verbatim:

```
ns-1335.awsdns-38.org	ns-803.awsdns-36.net	ns-1560.awsdns-03.co.uk	ns-485.awsdns-60.com
```

Imports into the durable root's S3-backed state (`bootstrap/aws/default.tfstate`):

```
aws_s3_bucket.state                                 -> sol-qual5-123456789012-tfstate
aws_s3_bucket_versioning.state                      -> sol-qual5-123456789012-tfstate
aws_s3_bucket_server_side_encryption_configuration.state -> sol-qual5-123456789012-tfstate
aws_s3_bucket_public_access_block.state             -> sol-qual5-123456789012-tfstate
aws_dynamodb_table.lock                             -> sol-qual5-tflock
aws_route53_zone.qualification[0]                   -> Z0555133LN4ZIDB3U52A
```

The bucket and lock table were imported too because the durable root previously had local
state; leaving them behind would have had the first plan propose creating a bucket that already
exists.

Nameservers after adoption — identical, so nothing was recreated:

```
ns-1335.awsdns-38.org	ns-803.awsdns-36.net	ns-1560.awsdns-03.co.uk	ns-485.awsdns-60.com
```

Reconciliation of the durable root:

```
terraform plan -detailed-exitcode ... -> rc=0, "No changes. Your infrastructure matches the configuration."
```

Detaching the zone from the disposable target:

```
terraform state rm aws_route53_zone.main   (in the target's cluster root)
Removed aws_route53_zone.main[0]
Successfully removed 1 resource instance(s).
```

The target no longer owns the zone. A full target plan afterwards reads the durable zone and
plans no action on it:

```
Plan: 69 to add, 0 to change, 0 to destroy.
matches for 'aws_route53_zone.main': 0
```

## Executable coverage

- `internal/ci/check_durable_dns_zone.py` holds the contract for **both** providers: each
  bootstrap root declares `<zone>.<qualification>` gated on `manage_dns_zone` and has a remote
  backend; each cluster root owns a zone only when told to create one, reads an existing one
  otherwise, and carries no wildcard authority; each qualification target sets the create flag
  false; each harness refuses a destructive durable-root plan; each absence verifier declares
  the retained zone class.
- `internal/ci/test_durable_dns_zone_check.py` mutates each of those eleven ways — including
  "the durable zone was dropped", "the target owns the zone unconditionally", "the row creates
  its own zone", "record authority widened to every zone", "the harness stops refusing a
  destructive plan", and two GCP cases so the guard cannot pass by being AWS-only — and
  requires each to be rejected for its own reason. Its first run rejected nothing, which is how
  the guard's CWD-relative path bug was found.
- `internal/ci/test_cloud_lifecycle_offline.sh` asserts the destroy report carries the zone as
  `external: Route 53 hosted zone …` (the declared prerequisite) and never as
  `present after destroy: Route 53 hosted zone` (this target's residue), while every existing
  ephemeral-absence and fail-closed assertion still holds.

## What is not yet established

- Public delegation to the current four nameservers is **not observable**: an NS query for
  `qual-aws.sol-fab.dev` returns `Status 2` (SERVFAIL) with no answer, because the registrar
  still delegates the earlier, now-dead set. The qualification row is gated on that being
  fixed by the operator; the zone itself is ready.
- The zone's survival across a real teardown has not been re-observed, since no target exists
  yet to tear down. It follows from the ownership move (the target no longer owns the zone) and
  is guarded structurally; the row will demonstrate it end to end.
