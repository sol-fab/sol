# AWS SQS partial-batch durable-task exercise (2026-10-29)

**Verdict: the AWS SQS + Lambda durable-task mechanism preserves the successful
records of a mixed batch while retrying and dead-lettering the failed record.**
One `SendMessageBatch` placed an `Ack` task and a `Retry` task on the source
queue; Lambda delivered both records to one invocation; the handler acknowledged
the Ack and requested Retry for the fail; only the fail record was retried and
dead-lettered. The Ack appeared exactly once in the handler log and never in the
DLQ.

This is **mechanism-level evidence from a checkout build**, not a released
candidate and not a production-profile claim. It is separate from the earlier
AWS lifecycle record [`2026-10-29-task-aws-live.md`](2026-10-29-task-aws-live.md).

## Specimen

| Field | Value |
|---|---|
| Checkout | `/home/logan/Code/sol-cloud/sol-task-timeouts` |
| Revision | `2f622678` (checkout build; the AWS task code is the same as `main`; the commit also carries an unmerged GCP timeout change) |
| AWS account / region | `<aws-account>` / `us-east-1` |
| Sol service | `checkout` |
| Lambda function / alias | `checkout-task` / `live` (version 3) |
| Source queue / DLQ | `checkout-task` / `checkout-task-dlq` |
| Settings | `max_attempts=2`, `visibility_timeout_s=30`, `dlq_retention_s=3600`, `concurrency=2` |
| Lambda timeout | 25 s (five seconds below the queue visibility timeout) |
| Image | `<ecr>/sol-task-live@sha256:bd5f51bdac208567fa522529789504ad984dd3ed099613e3595f50d1696fc873` (Docker v2 manifest) |
| Event source mapping | `90a6d95f-ad3c-4017-ad01-7e67cd696e02`, batch size 10, batching window 0, `ReportBatchItemFailures`, `MaximumConcurrency=2` |
| Batch tasks | `batch-ack-1` (Ack), `batch-fail-1` (Retry) |
| Evidence | `2026-10-29-task-aws-partial-batch/` |

## Claims established

| Claim | Result | Evidence |
|---|---|---|
| A batch with an Ack and a Retry record reaches one Lambda invocation | PASS | `logs-batch.txt`: both task IDs share log stream `2026/10/29/[3]6db64f...` |
| The successful record is acknowledged exactly once and is not retried | PASS | `logs-batch.txt`: one `batch-ack-1` handler line; `dlq-message.json` contains only `batch-fail-1`; source/DLQ queue snapshots |
| The failed record is retried and reaches the DLQ after the two-receive budget | PASS | `logs-batch.txt`: two `batch-fail-1` handler lines; `dlq-message.json`; `source-queue.json` shows source empty |
| The mapping targets the alias and reports batch item failures | PASS | `mapping.json`: `FunctionArn` ends `:live`, `FunctionResponseTypes=["ReportBatchItemFailures"]`, `MaximumConcurrency=2` |
| The function timeout leaves a margin below queue visibility | PASS | `function.json`: `Timeout=25`; record visibility 30 |
| Destroy removes the function, mapping and queues | PASS | `destroy.log`; `final-absence.txt` (Lambda/SQS/ECR/log group empty; role absent) |
| The image is a Docker v2 manifest, not OCI | PASS | The first deploy failed with Lambda `InvalidParameterValueException` for an OCI manifest; rebuilding with `buildx --output ...oci-mediatypes=false` produced the recorded digest and deployed |

The DLQ snapshot also contained the earlier `partial-fail-1` task from the
two-message smoke run. That task is not part of the batch claim; its presence is
why the DLQ count is 2 while the batch contributes one message.

## Failures and operational notes

| Observation | Resolution / consequence |
|---|---|
| Docker's default BuildKit output is an OCI manifest, which Lambda rejected with `InvalidParameterValueException` for the image. | Build with `buildx --output type=image,...,oci-mediatypes=false`; the procedure now records this prerequisite. |
| The first deploy failed while creating the SQS queue after creating the DLQ. | `sol task aws destroy --apply` removed the partial DLQ, but SQS `QueueDeletedRecently` refused a same-name recreation for 60 seconds. Wait before redeploying a destroyed partial queue. |
| The first two-message smoke run delivered the messages in separate Lambda invocations. | The batch evidence uses one `SendMessageBatch` request; only that run supports the mixed-batch claim. |

## Recorded as NOT RUN / not claimed

| Item | Status | Why |
|---|---|---|
| Released-candidate qualification | NOT RUN | Checkout build; no candidate tag/draft was used. |
| Planned-concurrency measurement | NOT RUN | `MaximumConcurrency=2` is recorded on the mapping; concurrent invocation count was not measured. |
| Handler timeout/cancellation live behavior | NOT RUN | The fixture returns immediately; the function timeout is configured but not exercised. |
| GCP and local providers | NOT RUN | Out of scope for this AWS record. |
| Exactly-once business effects | NOT CLAIMED | At-least-once; application idempotency remains mandatory. |
| Exact handler-attempt accounting versus provider counters | NOT CLAIMED | The contract exposes stable task IDs, not provider attempt numbers. |

## Cleanup

The function, event source mapping, source queue, DLQ, ECR repository, execution
role, and log group were removed. `final-absence.txt` records the independent
inventory after cleanup: no matching Lambda functions or SQS queues, no ECR
repository, no execution role, and no log group. The queue/DLQ observations in
the evidence are pre-destroy snapshots.

The evidence directory's `manifest.txt` contains the SHA-256 of each file.
