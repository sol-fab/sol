# AWS attempt `a38-aws-1` on `v0.1.0-alpha.38` — cloud boundary and transport qualified; app phase stopped at the database-CA assertion (2026-10-16)

**Candidate:** `v0.1.0-alpha.38`, revision `86fe9d4256162013cf0c268bb840d955af0e98fc`,
bundle `sol-v0.1.0-alpha.38-linux-x86_64.tar.gz` sha256
`c97b10e07e6b0ade8404b322a969037285ec244de83bd2b90cd14ef38f20fb8d`,
migration runner `ghcr.io/sol-fab/sol-migration-runner@sha256:7ad3e89e6f5b15538460134c769f9bd83b4d04707bd602c21dc7ba95fc700c74`.
Cut deliberately (tag `v0.1.0-alpha.38`) so the attempt carried the cold-start fixes — the
namespace-existence observation before the workload release (#1493) and the platform teardown's
PRESENT/ABSENT/UNKNOWN classification (#1500) — together with the harness's declared-namespace
boundary (#1495).

**Harness:** `86fe9d4256162013cf0c268bb840d955af0e98fc` for `prepare`/`cloud`/`transport`; the app
phase's stop is diagnosed below and its fix is PR #1506 (not merged). Attempt `a37-aws-1` failed at
this same boundary for the opposite reason, so both sides are now on the record.

**Target:** row `qual-a38-aws`, target `qual-a38-aws/aws/us-east-1`, cluster `sol-qual-aws-a38`,
state key `sol/qual-a38-aws/aws/us-east-1/cloud.tfstate`, account `123456789012` (placeholder),
region `us-east-1`. A new target identity, so attempt `a37-aws-1`'s resources, state and evidence
could not be inherited. Same account, region and infrastructure configuration as attempt 1.

## Phases

| phase | verdict | evidence |
|---|---|---|
| `prepare` | pass | five candidate-bound images built; `candidate-binding.txt` names candidate and harness revision `86fe9d42` with all 11 framework pins on it |
| `cloud` | **pass** | see below |
| `transport` | pass | qualification transport established; production identities' surfaces recorded before and after, none holding `pods/portforward`; qualifier identity read back through `SelfSubjectReview` |
| `app` | **fail** | stopped at the database-CA assertion (below) |
| `destroy` | pass | `sol destroy` returned success after releasing the workloads through this attempt's kubeconfig |
| `verify` | **pass, ABSENT** | independent inventory: every required disposable class ABSENT, classified from the provider's own reads |

## `cloud` — the cold-start boundary, demonstrated live

This is the row the attempt exists for, and it passed against a fresh target:

- ECR repositories: Sol's five repositories read **ABSENT** before the deploy and **PRESENT**
  after (`ecr-sol-repositories-before.txt` / `-after.txt`); no repository existed beforehand.
- The first profiled deploy reconciled the environment, created those repositories, and **refused**
  at the artifact gate (`Deployment incomplete.`) without moving a workload and without recording a
  release.
- The boundary was then established **from the cluster** as namespace absence over the complete
  declared set: `boundary_namespaces: pluto-checkout pluto-comms pluto-payments`, each read
  `ABSENT`, with the observation identity's view validated against a must-exist namespace and an
  absent name. The previous assertion could not see `pluto-checkout` at all.
- The five images were published into Sol's repositories **through the publisher identity**
  (`arn:aws:sts::…:assumed-role/sol-qual5-publisher/sol-qualification-publisher`; session values
  never recorded) and the deploy resumed with digest-pinned references.
- The plan preview named the published digests and the row's var file; node and state evidence were
  captured.

## `app` — stopped: the deploy was right, the assertion was wrong

The deploy's own sequence was correct and is recorded in `app.run.log`:

1. first app deploy reconciled the substrate and the class credentials, then refused against
   unapplied migrations (expected);
2. `migrate apply` ran the migration runner pinned by digest;
3. the workspace's declared Kafka secrets were supplied through `sol secret set`;
4. the second deploy moved all five workloads — `checkout-svc` 1/1, `charge-svc` 1/1,
   `orders-svc` 1/1, `notify-worker` 2/2, `fulfilment-worker` 1/1 — and delivered the database as
   `<target>-ddl-creds` (setup Job) and `<target>-dml-creds` (consumer unit), with the consumer's
   unit Secret carrying no `POSTGRES_URL`.

Then the phase stopped:

```
the deploy declared CA ConfigMap qual-a38-aws-aws-us-east-1-db-ca and it is absent from
pluto-checkout, where the workloads read it
```

The cluster says the assertion, not the deploy, was wrong:

| namespace / workload | mounts `db-ca` | CA ConfigMap | `POSTGRES_URL` | health |
|---|---|---|---|---|
| `pluto-checkout`/`checkout-svc` | no (`kafka-ca` only) | absent | absent | 1/1 Ready |
| `pluto-payments`/`charge-svc` | yes | present | present | Running |
| `pluto-payments`/`orders-svc` | yes | present | present | Running |
| `pluto-comms`/`notify-worker` | yes | present | present | Running |
| `pluto-comms`/`fulfilment-worker` | yes | present | present | Running |
| `sol-db-pluto-qual-a38-aws-aws-us-east-1` (setup Job) | declared location | present | — | — |

`checkout-svc` is Kafka-only: its contract declares no database dependency, its pod template mounts
only `kafka-ca`, and it carries no `POSTGRES_URL`. The CA is delivered exactly where a workload
consumes the database, and in the location the setup Job uses. The harness required it in **every**
selected unit's namespace and required **every** selected workload to mount it, so a target whose
units have mixed database dependencies could never qualify.

**Corroboration from outside this attempt:** the migration comparison landed on `main`
(`internal/tooling/sol_qualification/test/test_legacy_ca.ml`, #1502/#1504) already records this
divergence — `nonconsumer-without-ca` and `valid-ca-through-renamed-volume` are recorded as cases
where the observer passes and the legacy AWS assertion refused. The live cluster matches the
observer.

**Not a defect**, checked and dismissed: `charge-svc`'s projected workload-identity volume is named
`sol-identity-checkout-svc` with audience `checkout/checkout-svc`. That is its *caller* identity —
`charge_svc`'s contract declares `[service] calls = ["checkout/checkout_svc"]` — not a mis-bound
identity.

### Disposition

A harness fix is written in PR #1506 but **held as a draft**: it removes the wrong requirement,
yet it leaves the harness unable to say which units are *required* to mount the CA (comparison
scenario 6, `one-of-several-no-ca-volume`), and the recorded expectations of a freshly landed
conformance matrix are not mine to rewrite around that gap. The decision — derive the required set
from the class Secret the delivery check already reads, adopt the shared observer, or read it from
the unit's database declaration — is raised in the linked issue.

## Teardown and independent absence

`destroy` released the workloads through **this attempt's** kubeconfig (selected by the harness, not
inherited from a shell), and `sol destroy` returned success. The verdict is not Sol's exit code:
`absence.py` re-read the provider independently and classified all sixteen required disposable
classes from the provider's own answers.

```
verdict: ABSENT (every required disposable class is independently ABSENT)
```

Every class reads `ABSENT` with the read's shape checked (`eks-cluster`, `rds-instance`,
`rds-subnet-group`, `rds-snapshot`, `ec2-instance`, `vpc`, `nat-gateway`, `elastic-ip`,
`ebs-volume`, `load-balancer`, `ecr-repository`, `iam-role`, `iam-policy`, `s3-bucket`,
`cloudwatch-dashboard`, `cloudwatch-log-group`); the durable delegated zone is retained and
excluded from the residue verdict. Nothing is left running for this attempt, and no further
environment was provisioned while this one was live.

## Scope and non-claims

- The reference transaction was **not** run: the app phase stopped before it.
- Not run, and not claimed: the B3 Kafka relay inspection; the deferred authorization/grants rows;
  the production-profile matrix rows outside this row; any GCP row.
- `cloud` and `transport` passed on harness `86fe9d42`; a later harness revision will produce the
  app phase's evidence, and the attempt's bundle must name which revision produced which phase.
