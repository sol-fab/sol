# Durable tasks on release candidate v0.1.0-prealpha.4 — AWS

**Verdict: the AWS SQS + Lambda durable-task lifecycle passes against the
installed release candidate v0.1.0-prealpha.4.** Deploy and verify succeeded,
an Ack task completed once, a Retry task was redelivered and dead-lettered, a
mixed `SendMessageBatch` preserved its Ack while retrying only the fail, the
live alias rolled back from version 5 to version 4 and served a post-rollback
Ack, and destroy plus independent inventory removed the task resources.

**GCP is not qualified for this candidate.** A bounded GCP deploy failed before
creating the service because the qualification identity lacks
`iam.serviceAccounts.get`; the blocker is recorded below. No GCP task resource
was left running.

This record is the candidate-level AWS evidence. The earlier
[`2026-10-29-task-aws-live.md`](2026-10-29-task-aws-live.md) and
[`2026-10-29-task-aws-partial-batch.md`](2026-10-29-task-aws-partial-batch.md)
records are checkout-build mechanism evidence.

## Candidate

| Field | Value |
|---|---|
| Release | `v0.1.0-prealpha.4` (draft candidate) |
| Revision | `70b191f49951b2e8d550bab9ea1b8ce75ab362b7` |
| Bundle SHA-256 | `12a73da823bfef77f50f7e452bf6a4c48121887d32aa2c81ebaa80db9054ad87` |
| Runner image | `ghcr.io/sol-fab/sol-migration-runner@sha256:61be1fb844c7f216d5807a8f31dc4085b94be2b3b166e7b7d1cea2445d0f8c1c` |
| Installed prefix | extracted `sol-v0.1.0-prealpha.4` beside `candidate.json` |
| Verification | `sol-under-test.sh` checked version, revision, runner, bundle hash, and installed files |
| Identity | `sol-identity.txt` |

## Specimen

| Field | Value |
|---|---|
| AWS account / region | `<aws-account>` / `us-east-1` |
| Sol service | `checkout` |
| Lambda function / alias | `checkout-task` / `live` (version 4; version 5 rolled back to 4) |
| Source queue / DLQ | `checkout-task` / `checkout-task-dlq` |
| Settings | `max_attempts=2`, `visibility_timeout_s=30`, `dlq_retention_s=3600`, `concurrency=2` |
| Lambda timeout | 25 s |
| Image | `<ecr>/sol-task-live@sha256:d3a2a723e90c185e55ac98a1e9ce35dcca35aa43c91789cae3e9a8169e92e079` |
| Evidence | `2026-10-29-task-candidate-prealpha4-aws/` |

## Claims

| Claim | Result | Evidence |
|---|---|---|
| Candidate install is the recorded artifact | PASS | `sol-identity.txt`; `candidate.json`; `sol-under-test.sh` |
| `sol task aws deploy` and `verify` succeed with the candidate CLI | PASS | `deploy.log`, `verify.log`, `record.json` |
| Ack task is handled once and leaves no source/DLQ residue | PASS | `logs-ack-retry.json`; `source-queue.json`, `dlq-queue.json` |
| Retry task is redelivered and reaches the DLQ | PASS | `logs-ack-retry.json`; `candidate-fail-1` handler twice; `dlq-queue.json` |
| Mixed batch Ack is not repeated; fail is retried and dead-lettered | PASS | `logs-batch.json`: `candbatch-ack-1` once, `candbatch-fail-1` twice; `dlq-messages.json` |
| Mapping targets the live alias and reports batch item failures | PASS | `mapping.json`: `:live`, `ReportBatchItemFailures`, `MaximumConcurrency=2` |
| Rollback moves the alias from version 5 to 4 | PASS | `rollback.log`, `alias.json`; `version` 4 in `record.json` |
| Post-rollback Ack runs on version 4 | PASS | `logs-rollback.json`, log stream `[4]`, idempotency key `candidate-rollback-ack` |
| Destroy and independent inventory remove task resources | PASS | `destroy.log`; `final-absence.txt` |

## GCP blocker

The bounded GCP attempt used the same qualification identity and the project
`sol-qualification`. It failed at:

```text
gcloud iam service-accounts describe ...
PERMISSION_DENIED: Permission 'iam.serviceAccounts.get' denied on resource
(or it may not exist).
```

`gcp-blocker-raw.txt` preserves the diagnostic. The failure is an identity
permission on the service-account API, not a candidate or handler result. No
Cloud Run service or subscription was created; the two Pub/Sub topics that the
partial attempt created were deleted, and the review found no Cloud Run
services or subscriptions. The Artifact Registry repository used for the
attempt was deleted. Cloud Run was disabled after the attempt; Pub/Sub and
Artifact Registry remained enabled because disabling them hit the
`containerregistry.googleapis.com` dependency, not because task resources remain.

The GCP candidate cannot be called qualified until the identity can read
service accounts (or the adapter is deliberately changed to create without a
prior describe, with an explicit UNKNOWN/creation contract) and a bounded
candidate run succeeds.

## Not claimed

- GCP candidate qualification.
- Concurrency-limit measurement under load; the mapping records
  `MaximumConcurrency=2`.
- Handler timeout/cancellation live behavior; the function timeout is 25 s but
  the fixture returns immediately.
- Exactly-once business effects; at-least-once with application idempotency.
- Target-scoped `sol deploy` task deployment; the supported workflow is
  standalone `sol task aws`/`sol task gcp`.
- Sol-managed task metrics/traces; provider-native logs/metrics plus the
  `task_id`/kind/outcome log lines are the operational surface.

## Cleanup

The Lambda function, event source mapping, source queue, DLQ, ECR repository,
execution role, and log group were deleted. `final-absence.txt` shows no matching
Lambda functions or SQS queues, no ECR repository, no execution role, and no log
group. The evidence `manifest.txt` contains the SHA-256 of each file.
