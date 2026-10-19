# AWS attempt `a39-aws-2` on `v0.1.0-alpha.39` — cloud qualified; transport and app blocked by two defects; provider state independently clean (2026-10-19)

**Verdict: this candidate is not qualified.** The whole-target cloud phase passed on a fresh
specimen, including the Kafka authority and digest-published application images. The app phase
then stopped at a real product gap (the deploy identity could not read the broker CA), before
the migration gate or any workload. Two further defects blocked the teardown verdict documents
from reading clean. Every finding has a fix PR; none is repaired inside this candidate.

## Candidate and harness identity

| Field | Value |
|---|---|
| Candidate | `v0.1.0-alpha.39` |
| Sol revision | `9188f03d8167ea1ef3f8038927c77b52242abb2f` |
| Bundle | `sol-v0.1.0-alpha.39-linux-x86_64.tar.gz`, sha256 `91b83e069b28a21ac64a8810ade6459b151bd238fdb176172e408ff72d5a1dc0` (verified == archive) |
| Migration runner | `ghcr.io/sol-fab/sol-migration-runner@sha256:233fc27500a348b9bc1ec3a9218d3f17879578ddf82c62403f306c6f57862e5d` |
| Harness, prepare/cloud | `9188f03d` (the candidate revision) |
| Harness, app/destroy/verify | `64ddb242` (PR #1587, a descendant; the candidate's application is still materialized from `9188f03d`) |
| Account / region | `123456789012` (documented placeholder) / `us-east-1`, `sol-qual` SSO session |
| Evidence bundle | `/home/logan/qual-alpha39/` (outside the repository) |

The harness revision is not the candidate revision for the later phases, so this run is **not**
"one tag, two providers" evidence. It is a failed-candidate record.

## Attempts and specimen identity

`a39-aws-1` (target `qual-a39-aws`, cluster `sol-qual-aws-a39`) stopped before any provider
mutation: the durable-installation observation reported `public delegation UNKNOWN`, because the
host's `/home/logan/.local/bin/dig` wrapper pointed at a `/tmp/dnsutils` extraction that had been
cleaned. The deploy refused with "target reconciliation stopped before changing the environment".
A read-only inventory confirmed the account was still empty.

The harness treats a started cloud phase as claiming its specimen even when it failed before
mutation, so the retry used a new attempt and target rather than editing attempt evidence:

| Field | Value |
|---|---|
| Attempt | `a39-aws-2` |
| Target | `qual-a39-aws-2/aws/us-east-1` |
| Cluster | `sol-qual-aws-a39-2` |
| State key | `sol/qual-a39-aws-2/aws/us-east-1/cloud.tfstate` |
| Target file | `examples/pluto/sol/environments.local.yml` in the run worktree (untracked by design; it declares the profile, `shape: durable`, the five roles and the durable state bucket) |

The `dig` prerequisite was restored without a system package change by extracting `dnsutils` and
its libraries under `/tmp` and pointing the existing wrapper at them. This is a host repair, not
product evidence.

## Phases

| phase | verdict | evidence |
|---|---|---|
| `prepare` | pass | five candidate-bound images built; `candidate-binding.txt` names candidate and harness `9188f03d` with all 11 framework pins on it |
| `cloud` | **pass** | see below |
| `transport` (standalone, `9188f03d`) | **fail** | `could not bind the observation reads in pluto-payments`; the observation RoleBindings are namespace-scoped and the application namespaces do not exist yet (#1587) |
| `app` (on `64ddb242`) | **fail** | the first deploy created the namespaces and reached database setup, then the deploy identity was refused `get` on `redpanda/redpanda-default-cert` (#1588) |
| `destroy` | **non-zero** | Terraform destroyed every managed resource, but the product postcondition read the EKS node group's `ResourceNotFoundException` as UNKNOWN (#1590) |
| `verify` | **NOT ABSENT (one class)** | every disposable class read ABSENT except `kafka-secret: UNKNOWN`, where the harness did not recognise the CLI's `aws: [ERROR]:` prefix on the same not-found (#1590) |

## `cloud` — qualified on this specimen

- ECR repositories read ABSENT before the deploy and PRESENT after it; the five images were
  published **as the publisher identity**, by digest:
  `checkout-svc`, `charge-svc`, `notify-worker`, `orders-svc`, `fulfilment-worker`.
- The whole-target deploy reconciled the substrate, the platform and the resource-owned Kafka
  authority (`sol-kafka-sol-qual-aws-a39-2`), then refused at the immutable-artifact gate with
  `Deployment incomplete.` before moving a workload or recording a release — the documented
  cold-start behaviour.
- The cold-start boundary was established from the cluster as namespace absence over the
  declared set (`pluto-checkout`, `pluto-comms`, `pluto-payments`), with the observation
  identity's view validated against a must-exist namespace and an absent name.
- `sol plan` named the published digests; node, state and ECR-before/after evidence were
  captured. Rows I1, I2, I4, A, F1 and F2 have their cloud-phase observations; this record does
  not promote them to a provider verdict.

## `app` — stopped on the broker CA read

With the transport-ordering fix (PR #1587) the app phase reached and passed the first deploy's
namespace creation, the Kafka credential delivery plan and the database setup. It then stopped:

```
error: could not read Secret redpanda/redpanda-default-cert: Forbidden:
User "arn:aws:sts::…:assumed-role/sol-qual5-deploy/EKSGetTokenAuth" cannot get resource
"secrets" in API group "" in the namespace "redpanda"
```

The deploy runs as the namespace-scoped `sol:deployers` group; the platform module bound no read
for the broker CA in the platform-owned `redpanda` namespace. The deploy therefore failed closed,
as it should for an unreadable CA, but a fresh profiled target could never deliver a Kafka
consumer. PR #1588 adds a dedicated `sol-kafka-ca-reader` Role (exactly `get` on
`redpanda-default-cert`) bound to that group.

Not reached, and not claimed: the post-setup migration gate, `sol migrate apply`, the workload
rollout, the database/Kafka delivery comparisons, the CA family, and the representative
transaction. Rows B1, B3, B4, C1–C6, D1, D4, D5 and the application half of F remain `NOT RUN`.

## Teardown and independent absence

Terraform's disposable state is empty and the provider inventory read every required disposable
class ABSENT (EKS cluster, RDS instance/subnet group/snapshot, EC2 instances, VPC, NAT gateway,
elastic IPs, EBS volumes, OIDC provider, security groups, load balancers, ECR repositories, IAM
roles/policies, S3 buckets, CloudWatch dashboards and log groups). The durable delegated zone is
retained and excluded.

The verdict documents are nevertheless not clean under the harness that produced them:

- `sol destroy` exited non-zero because its EKS node-group postcondition asked
  `list-nodegroups --cluster-name sol-qual-aws-a39-2` after the cluster was gone and read the
  provider's `ResourceNotFoundException: No cluster found` as UNKNOWN. A direct read of the same
  account now shows no cluster, no node group and no RDS instance.
- The independent `kafka-secret` class read UNKNOWN for the same reason: `DescribeSecret`
  answered `aws: [ERROR]: An error occurred (ResourceNotFoundException) …`, and the harness
  matched only the unprefixed text. A direct `DescribeSecret` now returns the same not-found,
  i.e. the secret is absent; it is not pending deletion.

PR #1590 makes the distinction explicit: a targeted read's not-found is absence, while an
enumeration's failed list stays UNKNOWN. Until that fix is in the candidate and its harness, no
teardown claim for this attempt is promotion-eligible, even though the provider state is clean.

## Findings

| Finding | Owner |
|---|---|
| The transport's namespace-scoped observation bindings were established before the application namespaces existed | PR #1587 |
| The deploy identity had no read on the Redpanda chart's CA Secret | PR #1588 |
| A targeted provider not-found was classified as UNKNOWN by the destroy postcondition and the Kafka-secret inventory | PR #1590 |
| The host's `dig` wrapper pointed at a cleaned `/tmp` extraction, stopping the first attempt before mutation | host prerequisite; repaired, no product change |

The attempt guard's refusal to retry a cloud phase that failed before mutation is conservative
and was honoured by starting a new attempt; it is not recorded as a defect.

## What this run does not establish

- No application-contract row, no transaction, no Kafka delivery or CA-family observation.
- No populated-storage teardown: the teardown removed platform and registry resources, not
  application data written through a release.
- No alert delivery, no failure injection, no recovery measurement, and no GCP evidence.
- No release verdict for `v0.1.0-alpha.39`; the candidate is failed and must not be promoted.
