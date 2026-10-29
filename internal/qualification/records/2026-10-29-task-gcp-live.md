# GCP durable-task vertical slice (2026-10-29)

**Verdict: the GCP Pub/Sub push + Cloud Run durable-task vertical slice is
established at mechanism level.** A task handler image was deployed through
`sol task gcp`, a Pub/Sub push subscription delivered a task to a private Cloud
Run service, `Ack` was acknowledged, a `Retry` task was redelivered and reached
the dead-letter topic, Cloud Run traffic was rolled back to the first revision,
and `sol task gcp destroy --apply` removed the owned resources. The pre-disable
provider inventory was empty.

This is **experimental, mechanism-only** evidence from a checkout build. It is
not a released-candidate qualification, not a production-profile claim, and not
evidence for AWS, target-scoped `sol deploy`, exactly-once effects, or a
Sol-managed observability acceptance layer.

## Specimen

| Field | Value |
|---|---|
| Checkout | `/home/logan/Code/sol-cloud/sol-task-gcp` |
| Lifecycle code | GCP lifecycle + dead-letter publisher fix, equivalent to `c78d12aa`; the later `da6e17a2` deploy-time verification was not in the live binary and is covered by the fake-provider test |
| Handler source | `internal/fixtures/task-handler` (preserved after the run; the live image was built from equivalent scratch source) |
| GCP project / region | `sol-qualification` / `us-west1` |
| Sol service | `checkout` |
| Cloud Run service | `checkout-task` |
| Cloud Run URL | `https://checkout-task-yzef77wyjq-uw.a.run.app` |
| Revisions | `checkout-task-00001-h9t`, `checkout-task-00002-zjr` |
| Topic / subscription / DLQ | `checkout-task` / `checkout-task-sub` / `checkout-task-dlq` |
| Push service account | `checkout-push@sol-qualification.iam.gserviceaccount.com` |
| Image | `us-west1-docker.pkg.dev/sol-qualification/sol-task-live/task-handler@sha256:4863c9f15edef8569037cb3728217ece16da135e4f7702ac2c467208a0113163` (Artifact Registry repository deleted after the run) |
| Settings | `max_attempts=5`, `ack_deadline_s=30`, `dlq_retention_s=3600`, `concurrency=2` |
| Evidence | `internal/qualification/records/2026-10-29-task-gcp-live/` |

## Claims established

| Claim | Result | Evidence |
|---|---|---|
| Deploy creates a private Cloud Run service with `SOL_TASK_RUNTIME=pubsub` | PASS | `deploy.log`; `verify.log`; `subscription.json` |
| Push subscription uses OIDC and the dedicated push service account | PASS | `subscription.json` (`pushConfig.oidcToken.serviceAccountEmail`, `pushEndpoint`) |
| Dead-letter policy records `maxDeliveryAttempts=5` | PASS | `subscription.json` (`deadLetterPolicy.maxDeliveryAttempts=5`) |
| Ack task is delivered and acknowledged | PASS | task `abd76aa1bdc28b95c92271fc6d7ca540`, idempotency key `live-ack-1`; `logs-ack.txt` contains `task_handler` and `task acknowledged` on `checkout-task-00001-h9t` |
| Retry task is redelivered, not acknowledged | PASS | task `a3b11c23be602a98820790d2c0ef651d`; `logs-fail-wide.txt` contains 11 `task_handler`/`task requested retry` pairs |
| Exhausted task reaches the dead-letter topic | PASS | `dlq-pull.json` contains the task with `CloudPubSubDeadLetterSourceDeliveryCount=12` |
| Dead-letter publisher grant is required | PASS (failure observed, then fixed) | Before `roles/pubsub.publisher` on `checkout-task-dlq`, Pub/Sub kept redelivering; after the grant and a redeploy, the second fail task reached the DLQ |
| Rollback moves traffic to a prior revision | PASS | `rollback.log` records `checkout-task-00001-h9t`; post-rollback Ack `00de49a63832a325def70c301f503682` ran on revision `checkout-task-00001-h9t` in `logs-ack-rollback.txt` |
| Destroy removes owned resources and verifies absence | PASS | `destroy.log` exit 0; `final-absence.txt` (pre-disable inventory) |
| The push identity needs IAM propagation | OBSERVED | Initial push attempts returned 401 while grants propagated; Pub/Sub retried, and the Ack succeeded at 08:54:03Z |

## Provider-observation notes

- **Provider count is not a handler count.** With `maxDeliveryAttempts=5`, the
  dead-lettered message carried a source delivery count of 12, while the logs
  show 11 handler invocations. The contract deliberately does not expose a
  handler-attempt number and does not claim an exact number of invocations.
- **Dead-letter permission is part of the lifecycle.** The dead-letter topic
  needs `roles/pubsub.publisher` for
  `service-<project-number>@gcp-sa-pubsub.iam.gserviceaccount.com`. Missing it
  produced repeated redelivery instead of dead-lettering. The adapter now
  grants and verifies it.
- **IAM propagation is asynchronous.** The first push attempts after deploy
  returned 401; the subscription retried and the first Ack was delivered after
  the token-creator/invoker grants took effect. This is provider propagation,
  not an application retry policy.
- **Cloud Run API state.** The API was disabled before this work and enabled
  only for the exercise. It was disabled again after the pre-disable inventory.
  A post-run Cloud Run inventory is therefore unreadable
  (`SERVICE_DISABLED`), never "absent"; the absence claim rests on the
  pre-disable observation.
- **The image repository was deleted** after the run. The handler source is
  preserved in `internal/fixtures/task-handler`; the digest above is the
  observed image identity, not a currently pullable reference.

## Recorded as NOT RUN / not claimed

| Item | Status | Why |
|---|---|---|
| AWS SQS + Lambda live | NOT RUN | The qualification SSO session expired (`Token has expired and refresh failed`); no AWS resources were created. Fake-provider lifecycle tests are the only AWS evidence. |
| Target-scoped `sol deploy` for tasks | NOT RUN | `sol task` is a standalone experimental lifecycle; target integration is an open design decision. |
| Released-candidate qualification | NOT RUN | This was a checkout build, not a release candidate. |
| Exactly-once external effects | NOT CLAIMED | The contract is at-least-once; the fixture has no external side effect. |
| Duplicate external side-effect prevention | NOT CLAIMED | Redelivery was observed; application idempotency was not exercised against an external effect. |
| Concurrency-limit measurement | NOT RUN | The setting was deployed; actual concurrent handler count was not measured. |
| Handler timeout/cancellation | NOT RUN | The fixture returns quickly. |
| Observability acceptance | NOT CLAIMED | Cloud Run/Cloud Logging records exist; there is no Sol-managed metrics/trace acceptance layer. |
| Production profile, IAM least-privilege review, cost/SLO | NOT CLAIMED | Experimental project only. |

## Evidence manifest

`manifest.txt` contains the SHA-256 of each file. The files are the deploy and
verify records, the subscription description, enqueue outputs, Cloud Logging
excerpts, the dead-letter pull, rollback records, the destroy result, and the
pre-disable absence inventory. The evidence was copied from the live run; the
Cloud Run service, topics, subscription, service account, Artifact Registry
repository, and temporary IAM grant were deleted.

## What this establishes, and what it does not

It establishes the first GCP durable-task vertical slice: provider-native
queueing and push delivery, Ack/Retry mapping, dead-lettering after the
configured provider budget, revision rollback, and destroy/absence at mechanism
level.

It does not establish AWS live behavior, target-scoped lifecycle integration,
release qualification, exact handler-attempt accounting, production guarantees,
or parity with any other provider.
