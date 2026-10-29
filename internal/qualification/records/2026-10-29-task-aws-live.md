# AWS SQS + Lambda durable-task slice (2026-10-29)

**Verdict: the AWS SQS + Lambda durable-task vertical slice is established at
mechanism level.** A handler image deployed through `sol task aws`, SQS
delivered an `Ack` task to the Lambda alias through an event source mapping with
`ReportBatchItemFailures`, a `Retry` task exhausted its two-receive budget into
the dead-letter queue, the `live` alias was rolled back to version 1 and served
a post-rollback Ack, and `sol task aws destroy --apply` removed the mapping,
function, and queues. The independent inventory was empty.

This is **experimental, mechanism-only** evidence from a checkout build. It is
not a released-candidate qualification, not a production-profile claim, and not
evidence for exactly-once effects, target-scoped `sol deploy`, or a Sol-managed
observability acceptance layer.

## Specimen

| Field | Value |
|---|---|
| Checkout | `/home/logan/Code/sol-cloud/sol-task-gcp` |
| Lifecycle code | `26f69fd4` (SQS attribute + mapping-wait fixes), cherry-picked to `feat/task-aws-lifecycle` as `a11f4194` |
| Handler source | `internal/fixtures/task-handler` (preserved after the run; built from the same source shape) |
| AWS account / region | `<aws-account>` / `us-east-1` |
| Sol service | `checkout` |
| Lambda function / alias | `checkout-task` / `live` (versions 1 and 2) |
| Source queue / DLQ | `checkout-task` / `checkout-task-dlq` (`maxReceiveCount=2`) |
| Execution role | `arn:aws:iam::<aws-account>:role/sol-task-live-exec` (deleted after the run) |
| Image | `<ecr>/sol-task-live@sha256:bd5f51bdac208567fa522529789504ad984dd3ed099613e3595f50d1696fc873` (Docker v2 manifest; ECR repository deleted after the run) |
| Settings | `max_attempts=2`, `visibility_timeout_s=30`, `dlq_retention_s=3600`, `concurrency=2` |
| Event source mapping | `18d2a439-0af0-4805-a57d-9b986197a748`, alias ARN, `ReportBatchItemFailures` |
| Evidence | `internal/qualification/records/2026-10-29-task-aws-live/` |

## Claims established

| Claim | Result | Evidence |
|---|---|---|
| Deploy creates function/version/alias and queues | PASS | `deploy.log`; `function.json`; `function-code.json`; `queue.json`; `versions.json`; `alias-before-rollback.json` |
| Event source mapping targets the alias and reports batch item failures | PASS | `mapping.json`: `FunctionArn` ends `:live`, `FunctionResponseTypes=["ReportBatchItemFailures"]`, `ScalingConfig.MaximumConcurrency=2` |
| Queue visibility and redrive policy match the request | PASS | `queue.json`: `VisibilityTimeout=30`, `RedrivePolicy.maxReceiveCount=2` |
| Ack task is delivered and acknowledged | PASS | task `3c75602d51eca4f292d90130690708b6`, key `aws-ack-1`; `logs-ack-all.json` contains `task_handler` and `task acknowledged`; source and DLQ counts 0 |
| Retry task is redelivered, not acknowledged | PASS | task `58c0bbb27a1f25093f42337c23826222`; `logs-retry.json` contains two `task requested retry` lines; two `task_handler` lines |
| Exhausted task reaches the DLQ | PASS | `dlq-message.json`: DLQ count reached 1, body is the same `task_id` with `idempotency_key=aws-fail-1`; message deleted after inspection |
| Rollback moves the alias to version 1 | PASS | `alias-before-rollback.json` = 2; `rollback.log` record version 1; `alias-after-rollback.txt` = 1; post-rollback Ack `666bdd03914999017695143efd8fe175` logged on stream `2026/10/29/[1]...` |
| Destroy removes mapping/function/queues | PASS | `destroy.log` exit 0; `final-absence.txt` |
| Partial create is destroyable | PASS | The first deploy failed on SQS attributes after creating only the DLQ; the ownership record had empty queue URLs; `sol task aws destroy --apply` (`destroy-partial.log`, exit 0) resolved the DLQ by name and removed it |

## Failures found and fixed during the live run

| Observation | Resolution |
|---|---|
| `aws sqs create-queue --attributes` shorthand failed with `ParamValidation` because the `RedrivePolicy` value contains JSON quotes. The partial record and DLQ remained. | Send the attributes as one JSON object; parse the nested `RedrivePolicy` in the fake test. The partial record was cleaned by destroy. |
| Lambda `CreateFunction` rejected the image: `The image manifest, config or layer media type ... is not supported`. The image was an OCI index. | Rebuild/push a Docker v2 manifest with `docker buildx build --output type=image,...,oci-mediatypes=false`. This is a packaging requirement, not an adapter behavior. |
| The event source mapping was `Creating`, and deploy failed immediately with `event source mapping is Creating`. | Poll the mapping for a bounded time until `Enabled` (or `Failed`/timeout), then verify `ReportBatchItemFailures`. |
| Recreating a deleted queue immediately returned `QueueDeletedRecently`. | Operator/test sequencing: wait 60 seconds after deleting a queue with the same name. No code change. |

The SQS attribute and mapping-wait failures are exactly the provider operations
the fake test could not observe; the live run is what established them. Both
now have fake-provider regression coverage. The Docker v2 manifest is a
packaging requirement, not an adapter behavior.

## Provider-observation notes

- The mapping's `FunctionArn` is the alias ARN
  `...:function:checkout-task:live`; the post-rollback Ack ran on Lambda version 1
  and its CloudWatch stream is prefixed `[1]`. This is direct evidence that the
  alias, not a fixed version, is the delivery identity.
- `aws lambda get-function --query Configuration.ImageUri` returned `null`; the
  image reference is under `Code.ImageUri`/`ResolvedImageUri` (`function-code.json`).
- The fail task produced two handler attempts and two `task requested retry`
  logs, matching `maxReceiveCount=2` in this run. The contract still does not
  equate provider receive counts with handler attempts; this run happened to
  have a one-to-one count.
- The DLQ message retained the original envelope and `task_id`; it was read and
  deleted to leave the DLQ empty.

## Recorded as NOT RUN / not claimed

| Item | Status | Why |
|---|---|---|
| Released-candidate qualification | NOT RUN | Checkout build, not a release candidate. |
| Target-scoped `sol deploy` for tasks | NOT RUN | `sol task` is standalone; target integration remains an open design decision. |
| Partial-batch live failure | NOT RUN | Messages were sent one at a time; Lambda partial-batch behavior is unit tested, not live. |
| Handler timeout/cancellation | NOT RUN | The fixture returns quickly. |
| Concurrency-limit measurement | NOT RUN | `MaximumConcurrency=2` was configured; actual concurrent handler count was not measured. |
| Duplicate external side effect | NOT RUN | Redelivery was observed; the fixture has no external effect, so idempotency was not exercised. |
| Exactly-once effects | NOT CLAIMED | At-least-once contract only. |
| Retry/DLQ permission failure on AWS | NOT RUN | The GCP run observed the equivalent dead-letter publisher failure; the AWS execution role was correctly permissioned. |
| Observability acceptance | NOT CLAIMED | CloudWatch logs were inspected; there is no Sol-managed metrics/traces acceptance layer. |
| Production profile, IAM least-privilege review, cost/SLO | NOT CLAIMED | Experimental account only. |

## Evidence manifest

`manifest.txt` contains the SHA-256 of each file. The committed provider evidence
replaces the account ID with `<aws-account>`; the ARNs and resource names are
otherwise the observed values. The files include the deploy
records (including the failed attempts that drove the fixes), function and
mapping descriptions, queue attributes, enqueue outputs, CloudWatch log
excerpts, the DLQ message, rollback records, destroy results, and the final
absence inventory. The Lambda function, SQS queues, ECR repository, execution
role, and log group were deleted after the run.

## What this establishes, and what it does not

It establishes the AWS durable-task vertical slice at mechanism level:
SQS-to-Lambda delivery through an alias, per-item failure reporting, ack and
retry behavior, dead-lettering after the two-receive budget, alias rollback,
partial-create recovery, destroy, and independently verified absence.

It does not establish release qualification, production guarantees, target
integration, exact handler-attempt accounting, partial-batch live behavior,
concurrency measurement, or parity with GCP.
