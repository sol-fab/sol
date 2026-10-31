# Scheduling contract for `_fn`

**Status:** current boundary plus proposed provider mappings. This page separates compute,
scheduling, and durable task delivery.

## Current evidence

- `_fn` is a run-once compute primitive; `Sol.Fn.Make` has no cron awareness.
- Kubernetes scheduling is a `CronJob` rendered from `[service] schedule`; it is the only
  implemented schedule backend.
- AWS and GCP serverless `_fn` deploy run-once Lambda/Cloud Run Jobs but have no scheduler.
  A scheduled `_fn` is now refused on those targets instead of being silently unscheduled.
- `sol-jobs` is a PostgreSQL durable queue with delayed `run_at`, leases, retries, and
  terminal failure. It is not a cron scheduler and does not replace `_fn` scheduling.
- Cloud task lifecycles are durable delivery backends; they are not cron or `_fn`.

## Proposed contract

Keep the declaration where it is:

```toml
[service]
schedule = "0 3 * * *"
scheduled_concurrency = "forbid"
```

The schedule is intent on the run-once function; it is not part of the function's
execution contract. A provider backend may map it to:

| Substrate | Mapping | Identity |
|---|---|---|
| Kubernetes | `CronJob` | Kubernetes scheduler, existing behavior |
| AWS | EventBridge Scheduler → Lambda alias | Scheduler execution role allowed to invoke the alias |
| GCP | Cloud Scheduler HTTP target → Cloud Run Jobs `:run` API | Scheduler OAuth service account with job-run permission |

GCP Cloud Scheduler cannot invoke a Cloud Run Job directly as a native target; the
HTTP `:run` API is the minimal bridge. A Workflows bridge would add another resource
and is not proposed first.

Each backend records the scheduler resource identity in the release record and owns
create/update/verify/rollback/destroy. Unsupported scheduler combinations fail closed.

## Open decisions

1. Scheduler identity ownership: one scheduler identity per unit, per target, or reuse
   the runtime identity.
2. Timezone and overlap semantics: the current cron string has no timezone; CronJob,
   EventBridge, and Cloud Scheduler each have their own timezone and retry semantics.
3. Whether schedule errors are visible in the same release/status path as workload
   rollout failures.

No provider scheduler is implemented yet. The fail-closed refusal is the current
guarantee: a scheduled `_fn` is never silently deployed without a scheduler.
