# `_fn` versus queue-delivered tasks

**Status:** audit and recommendation. This page determines whether the existing `_fn`
primitive can carry task execution or whether a new task primitive is justified.

## What `_fn` is

`_fn` is a run-once execution primitive, not a cron abstraction:

- `Sol.Fn.Make(F).run` has no schedule awareness; it calls `F.run : unit -> result`
  exactly once and exits.
- Kubernetes schedules it with a `CronJob`; `scheduled_concurrency` and `backoff_limit`
  are substrate-shaped execution policy, not queue retry semantics.
- AWS deploys a Lambda function/version/alias and invokes the alias once.
- GCP deploys a Cloud Run Job and executes it.
- `sol local invoke` runs the function once with an event.

The same application contract therefore already supports **explicitly launched
run-to-completion work** on all three substrates. What it does not provide is a
provider queue, event-source mapping, delivery retry, or a dead-letter destination.

Serverless targets now provision the schedule with the same `[service] schedule` and
`schedule_timezone` declaration: EventBridge Scheduler for AWS Lambda and Cloud Scheduler
for Cloud Run Jobs. Kubernetes CronJob remains the self-hosted backend. A missing or
mismatched scheduler identity fails closed rather than deploying an unscheduled function.

## What standalone tasks are

The standalone task lifecycles are queue infrastructure plus a different application
runtime contract:

| | `_fn` | AWS task | GCP task |
|---|---|---|---|
| Runtime | `Sol.Fn.Make`, exits | `Sol_task_lambda`, SQS batches | `Sol_task_pubsub`, HTTP push |
| Invocation | schedule/manual/alias invoke | SQS event source | Pub/Sub push |
| App outcome | `Ok`/`Error`/signal | `Ack`/`Retry`, batch item failures | HTTP 200/500/400 |
| Retry/DLQ | Kubernetes Job backoff / provider invoke policy | SQS redrive + DLQ | Pub/Sub redelivery + DLQ |
| Stable task identity | none | task envelope | task envelope |
| Kubernetes equivalent | CronJob/Job | none | none |
| GCP execution shape | Cloud Run **Job** | Cloud Run **service** (push endpoint) | same |

The GCP task runtime is not a run-to-completion Job. Pub/Sub push needs an HTTP
service that acks or retries the request; mapping that to a Cloud Run Job would
change the delivery semantics. AWS task is a Lambda function but with an SQS event
source and a role that receives/deletes messages, not the `_fn` direct-invoke shape.

## Conclusion

`_fn` **does** naturally support explicitly launched run-to-completion jobs; that is
already its contract. It does **not** naturally subsume queue-delivered tasks because
the application runtime, retry/ack contract, queue ownership, and GCP execution shape
are different.

A new `_task` primitive is therefore **not justified merely to unify deployment
plumbing**. The existing standalone task lifecycle should remain until a target-scoped
queue/trigger contract is deliberately designed. If target-scoped tasks are required,
a new component contract is semantically justified because the application and
delivery contracts differ; it should be introduced for that reason, not for common
YAML/lifecycle plumbing.

## Recommended next steps

1. Keep `_fn` for scheduled and explicitly launched run-to-completion work.
2. If a gap remains, add a provider-neutral **explicit launch** operation for `_fn`
   (Kubernetes Job, AWS invoke, GCP execution) rather than a task primitive.
3. Keep standalone task commands as the supported queue-task lifecycle until a
   target-scoped task contract is approved.
4. Do not add `_task` solely so task and function deployment share a command path.
