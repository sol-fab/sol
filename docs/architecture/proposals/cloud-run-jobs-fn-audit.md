# Audit: Cloud Run Jobs as a GCP `-fn` execution backend

- **Status:** audit only — no implementation authorized
- **Date:** 2026-10-28
- **Related:** ADR 0009 (`-fn` contract), ADR 0010 (target-scoped execution),
  `docs/deployment/serverless-experimental.md`, PR #1779 (AWS Lambda `-fn` slice)
- **Question:** can Cloud Run Jobs implement the Sol `-fn` contract with the same
  lifecycle semantics as the verified AWS Lambda slice, or does it require a
  different, explicitly provider-specific contract?

## Short answer

No parity can be assumed. Cloud Run Jobs is a credible run-to-completion
execution backend, but it does not supply three things the AWS slice relies on:

1. a provider-native version/alias pointer that rollback can move atomically;
2. an event/stdin input contract comparable to `sol local invoke` or the Lambda
   runtime invocation;
3. a response body (`{"status":"ok"}`) as the success signal.

It also adds execution-level task counts and per-task retries that change what
"succeeded once" means. A GCP `-fn` adapter is therefore a separate design
decision, not a translation of the Lambda adapter. The current refusal in
`sol deploy` is the correct behavior until that decision exists.

## The Sol `-fn` contract being compared

From ADR 0009 and the current implementation:

- run-once, run-to-completion execution with an exit status;
- invoked manually or on a schedule, never an HTTP server or Kafka
  consumer-group lifecycle;
- local `sol local invoke` supplies event bytes on stdin and propagates
  stdout/stderr/exit status;
- a release identity, rollback, destroy, and positively established absence;
- a target-scoped execution choice (`execution: serverless`);
- scheduling/triggers are a separate contract.

The AWS Lambda slice maps those to an immutable image, a published Lambda
version, a movable `live` alias, an invocation through that alias, and a
`{"status":"ok"}` acknowledgement.

## What Cloud Run Jobs provides

The Cloud Run Admin API v2 `Job` resource has a desired `template`, a
monotonically increasing `generation`, `executionCount`, `latestCreatedExecution`,
and a `terminalCondition`. It has no revision, traffic split, or alias field.
`jobs.patch` updates a job; `jobs.run` "triggers creation of a new Execution of
this Job."

Each `Execution` is a separate resource with its own name, `completionTime`,
`startTime`, `logUri`, and task counters: `succeededCount`, `failedCount`,
`cancelledCount`, `retriedCount`, and `runningCount`. Executions can be listed
and deleted through their own API resource.

The `TaskTemplate` carries the task's service account, `maxRetries` (the API
description says it defaults to 3), a per-attempt `timeout`, and the container
`command`, `args`, and `env`. Container input is declarative command/args/env;
there is no Lambda-style event payload or response body.

Scheduling is a separate Cloud Scheduler trigger that calls `jobs.run`; it is not
part of the Job resource.

## Parity assessment

| Contract element | Kubernetes `-fn` | AWS Lambda slice | Cloud Run Jobs | Assessment |
|---|---|---|---|---|
| Invocation unit | Job created from a CronJob | `Invoke` through a version alias | New `Execution` from `jobs.run` | Different provider shape; needs a new observation path |
| Input/event | `sol local invoke` stdin bytes | Fixed `{}` payload for the slice | Command/args/env only | No portable event contract; cannot reuse `{}` meaningfully |
| Success signal | Process exit status | No `FunctionError` plus `{"status":"ok"}` body | Execution task counts and terminal condition | Must define success from counters, not a response body |
| Schedule/trigger | CronJob schedule | Deliberately none in the slice | Cloud Scheduler calls `jobs.run` | Trigger is a separate resource and contract |
| Immutable release identity | Release record and rendered spec | Lambda version + alias | Image digest + job `generation` + execution name | No alias pointer; record must carry the full desired template identity |
| Rollback | Restore a previous release | Move the `live` alias | Patch the job back, then start a new execution | Not a pointer move; requires post-patch execution proof |
| Concurrency | CronJob concurrency policy | Lambda concurrency | `taskCount` / `parallelism` | Different meaning: parallel tasks, not concurrent request handling |
| Retries | CronJob `backoffLimit` | None for synchronous invoke | `maxRetries` per task, default 3 | Retries can change the observed failure semantics |
| Timeout | `activeDeadlineSeconds` | Lambda timeout | Per-attempt task timeout | Retries get a fresh timeout; not equivalent to one run deadline |
| Identity | Kubernetes workload identity | Lambda execution role | Task service account | Provider-native and similar, but still separate configuration |
| Logs/metrics | Pushgateway, app telemetry | CloudWatch | Cloud Logging / Monitoring | No Sol acceptance on either serverless provider |
| Destroy/absence | Release cleanup and inventory | Delete function, list functions | Delete job and account for executions separately | Two resource classes; absence must query both |
| HTTP/Function URL | None | None | None | Consistent with `-fn` |

## Findings

### 1. Rollback is not a pointer move

A Cloud Run Job has no alias. Moving back to a previous image/config means
patching the job's desired template and then starting a new execution. The
release record would need enough identity to restore the full template (image
digest, command/args/env, service account, retry/timeout settings), and the
rollback postcondition would have to be a *new execution* that satisfies the
chosen success definition. Patching the job alone is not evidence that the
previous behavior runs again.

### 2. There is no event/stdin input equivalent

`sol local invoke` passes event bytes on stdin, and the Lambda runtime receives
an invocation payload. Cloud Run Jobs supplies command/args/env. A GCP `-fn`
contract must either declare that `-fn` takes no input on this backend or define
an explicit input projection (for example, arguments derived from a declared
task input). Silently ignoring the event would change the primitive's contract.

### 3. Success is execution-level and retry-shaped

The AWS slice requires a successful invocation with `{"status":"ok"}`. Cloud Run
Jobs reports task counters and a terminal condition. With `maxRetries` defaulting
to 3 and a per-attempt timeout, a task can fail and then succeed, and a
multi-task execution can partially fail. The adapter must define which counts
constitute success; that definition is part of the product contract, not an
implementation detail.

### 4. Scheduling is a separate Cloud Scheduler contract

A Cloud Scheduler job that calls `jobs.run` is a separate resource with its own
identity, retry policy, and delivery semantics. It must not be inferred from
`execution: serverless`, and `-fn` must not silently acquire a schedule. This is
the same position the AWS slice takes: the function is deployed and verified, but
no trigger is created.

### 5. Cleanup spans two resource classes

Deleting a Job is not by itself evidence that its executions are absent: the API
exposes executions as a separate listable/deletable resource. A GCP adapter's
destroy/absence check must query both the Job and its executions (and any
Cloud Scheduler trigger if that contract is ever added). Inferring execution
absence from job deletion would violate the "positively establish absence" rule.

### 6. Configuration defaults must be explicit

`maxRetries` and per-attempt timeouts have provider defaults that differ from
Kubernetes `-fn` and from a Lambda synchronous invocation. A GCP adapter must
write these explicitly from the declared contract rather than inherit a
provider default that changes failure behavior.

## Recommendation

Keep GCP serverless `-fn` explicitly refused (the current target dispatch does
this). Do not copy the Lambda adapter.

If a Cloud Run Jobs `-fn` backend is wanted, open a separate design decision that
accepts, at minimum:

- whether `-fn` on this backend has an input contract or none;
- the success definition over task counters/terminal condition and retries;
- a full desired-template release record and a rollback postcondition that
  observes a new execution;
- job-and-execution absence for destroy;
- triggers/schedules as a separate contract;
- live evidence for deploy, invoke, rollback, destroy, and independent cleanup.

Until those are accepted, "GCP `-fn` is unsupported" is the accurate support
matrix cell.

## References

- Cloud Run Admin API v2, `projects.locations.jobs`:
  <https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs>
- `jobs.run` (triggers creation of a new Execution):
  <https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs/run>
- `jobs.patch` (updates a Job):
  <https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs/patch>
- `projects.locations.jobs.executions`:
  <https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs.executions>
- `jobs.executions.delete`:
  <https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs.executions/delete>
- Cloud Run jobs overview:
  <https://docs.cloud.google.com/run/docs/create-jobs>
- Scheduled jobs:
  <https://docs.cloud.google.com/run/docs/execute/jobs-on-schedule>
- `gcloud run jobs deploy`:
  <https://docs.cloud.google.com/sdk/gcloud/reference/run/jobs/deploy>
- Cloud Run Admin API v2 discovery document (field descriptions used above):
  <https://run.googleapis.com/$discovery/rest?version=v2>
