# Scheduling contract for `_fn`

**Status:** implemented boundary plus provider mappings. This page separates compute,
scheduling, and durable task delivery.

## Current evidence

- `_fn` is a run-once compute primitive; `Sol.Fn.Make` has no cron awareness.
- Kubernetes scheduling is a `CronJob` rendered from `[service] schedule`.
- AWS and GCP serverless `_fn` deploy run-once Lambda/Cloud Run Jobs.
- `sol-jobs` is a PostgreSQL durable queue with delayed `run_at`, leases, retries, and
  terminal failure. It is not a cron scheduler and does not replace `_fn` scheduling.
- Cloud task lifecycles are durable delivery backends; they are not cron or `_fn`.

## Declaration

```toml
[service]
schedule = "0 3 * * *"
schedule_timezone = "America/Denver"   # optional; Kubernetes defaults to UTC
scheduled_concurrency = "forbid"
```

The schedule is intent on the run-once function; it is not part of the function's
execution contract. Provider mappings:

| Substrate | Mapping | Identity |
|---|---|---|
| Kubernetes | `CronJob` | Kubernetes scheduler, existing behavior |
| AWS | EventBridge Scheduler → Lambda alias | Dedicated scheduler execution role |
| GCP | Cloud Scheduler HTTP target → Cloud Run Jobs `:run` API | Dedicated scheduler service account |

GCP Cloud Scheduler cannot invoke a Cloud Run Job directly as a native target; the
HTTP `:run` API is the bridge. No Workflows bridge is used.

`schedule_timezone` is part of the released schedule identity when present; changing it
creates a new release id and rollback restores the recorded timezone.

## Authorization relationship

The scheduler is a local resource edge:

| Principal | Capability | Resource |
|---|---|---|
| per-unit scheduler identity | `function.invoke` | the scheduled `_fn` |

The scheduler identity is **not** the function runtime identity. The declaration uses
the same capability vocabulary as secrets, service calls, queues, and object storage, but
provider adapters create separate principals and grants. AWS uses an IAM role trusted by
`scheduler.amazonaws.com` with `lambda:InvokeFunction` scoped to the function alias. GCP
uses a dedicated service account with `roles/run.jobsExecutor` scoped to the Cloud Run
Job and Cloud Scheduler OAuth.

Unsupported invocation grants fail closed; provisioning the scheduler must not broaden
the runtime role. `scheduled_concurrency` and `backoff_limit` are Kubernetes-only policy
today: a serverless target refuses them rather than silently ignoring Kubernetes semantics.

Removing `[service] schedule` from a previously scheduled serverless function deletes the
provider schedule on the next deploy. The authorization root removes the corresponding
scheduler principal when it is no longer declared.

## Lifecycle

Each scheduled `_fn` release records the scheduler resource and identity. Deploy creates
or updates the schedule; verification checks identity, trust, target, and schedule;
rollback restores schedule identity; destroy removes the schedule. A schedule belongs to
one unit and can only invoke that unit.
