# Proposal: cooperative jobs deadlines and shutdown

Status: for operator review. This document proposes semantics; it does not add an
execution policy or claim a hard execution limit. It follows the jobs correctness
stack (#1519, #1520, #1521) and the separate pre-handler fenced-release increment.
Keep those fixes independently reviewable. Do not merge a deadline implementation
until these semantics have been reviewed.

## Public contract

Add optional `?execution_timeout_s:float` to OCaml `Sol_jobs.Make(J).run`, absent
by default. An explicit value must be finite and strictly positive; reject invalid
values before database access or signal registration. The `JOB` signature stays
unchanged. TypeScript should eventually expose equivalent opt-in semantics using
its cooperative handler signal, in a corresponding focused PR.

This is a **cooperative execution deadline**, measured on a monotonic clock from
before decoding. It is not a limit on process lifetime, external requests, claim
queries, pool checkout, renewal queries or finalization. A deadline can request
cancellation only when the runtime can schedule it. Blocking or cancellation-
resistant code can occupy the worker indefinitely. All attempt work must join
before the handler returns; detached work cannot be managed by this contract.

Retain the existing 300-second lease default and optional long-running handlers.
Do not infer execution duration from lease duration or introduce a mandatory
arbitrary timeout. Compatible consumers of one kind must use consistent policies.

## Outcomes and race rules

| Event | Handler and cleanup | Renewal | Queue transition |
| --- | --- | --- | --- |
| Normal handler return before deadline | Already quiescent | Stop and join renewal | Existing fenced complete/retry/fail |
| Deadline observed | Request cancellation; wait for cleanup | Continue independently while the attempt remains owned | After quiescence, fenced retry/fail with `cooperative execution deadline exceeded` |
| Handler returns after elapsed deadline before timer was scheduled | Already quiescent; capture completion time before telemetry | Stop and join renewal | Same timeout retry/fail; late success does not erase timeout |
| Renewal confirms no matching attempt | Cancel and join handler, including timeout cleanup | Stop for that generation | None, even if cleanup catches cancellation and returns success |
| Renewal SQL error | Ownership is unknown; continue existing behavior | Log and retry | No inferred loss; execution deadline still applies if configured |
| First SIGTERM/SIGINT or stop promise during execution | Drain current attempt; configured deadline still applies | Continue while owned | Normal outcome or timeout, subject to fence |
| Parent cancellation | Propagate cancellation and join cooperative children | Cancel renewal too | None; last lease provides recovery |
| Process crash/kill | Local work stops when process terminates; accepted external effects may continue | Stops | No eager acknowledgement; reclaim or exhaustion after lease expiry |

The implementation must preserve distinct handler-result, timeout and loss
outcomes. A timeout initiates cancellation but does not itself prove quiescence.
A timeout must not release a lease, enqueue a retry or start another local job
while the old handler is still cleaning up. The renewal fiber must sit outside
the handler's timeout cancellation scope. One suitable implementation is a
handler-versus-deadline structured race nested inside an execution-versus-renewal
race; both races must join their cancelled branches.

Race resolution uses observed execution/renewal outcomes, not a wall-clock claim
of exclusive external execution. Loss observed while timeout cleanup is running
wins and suppresses finalization. If execution returns first, the finalization
statement still needs `(id, attempts, workspace, pending)` and may be fenced out
by a concurrent reclaim. A completion-time check catches an elapsed deadline even
if timer scheduling was delayed. Capture that time before logging/metric emission.
The deadline is one total execution budget, not reset for cleanup or inline retries.

Parent cancellation is intentionally different from a timeout: it cancels the
whole execution scope, including renewal. Protected cleanup may outlast that last
lease and overlap another attempt. Neither path retracts an external effect.
Likewise a non-cancellable renewal query can delay joining its branch even after
the handler stops; this setting does not solve database operation timeouts.

Keep the distinction in observation: handler-return metrics describe what
application code returned; durable counters describe confirmed SQL transitions.
A handler catching cancellation and returning success can have a successful return
and a durable timeout failure. If cancellation propagates, there is no normal
handler return. Deadline diagnostics identify kind, job and attempt without exposing
payloads. Do not build a separate monitoring subsystem for this setting.

## Pre-handler shutdown boundary

The immediate-release increment checks stop after a successful claim but before
any decode or handle call. Only that branch may use the existing fenced retry
statement with zero delay and an explicit shutdown diagnostic. The original loop
never starts that released generation. A newer generation makes release a no-op;
a query failure leaves ordinary lease recovery in charge.

Do not refund attempts. Attempts are fencing generations; decrementing can make
an older still-running token valid again. A pre-start release consumes its budget
slot, and repeated pre-start shutdown can lead to terminal failure without any
handler invocation. That is the documented existing claim-budget model. Separating
claim generations from handler-invocation budgets would be a new queue design and
is not part of this increment.

For a started attempt, SIGTERM continues to drain rather than releasing it. The
current Kubernetes manifest gives 45 seconds of termination grace. Neither a
cooperative deadline nor cleanup is guaranteed to finish within that period; the
Pod termination boundary remains authoritative. A second signal retains default
process termination behavior. Do not invent another shutdown timer or deployment
setting in the jobs library.

## Validation and implementation boundaries

Before implementation merge, require:

- Invalid deadline values fail before database/signal effects; absence preserves
  long-running behavior.
- A cooperative infinite wait is cancelled; protected cleanup can exceed the
  deadline, keeps renewal while owned, and prevents new local execution until exit.
- Handler completion, timeout and confirmed-loss races preserve the first observed
  controlling outcome and all SQL fences; include loss during timeout cleanup.
- An ordinary parent cancellation remains distinct from timeout, with no eager
  failure/retry. A stop promise drains an already active attempt.
- Advisory-lock-controlled pre-start tests establish immediate reclaim, increasing
  generations, inability to clear a newer lease, no handler entry after release,
  stale finalization rejection, and repeated-release exhaustion.
- Preserve original diagnostics and explain failed runs. Very short test leases
  are not evidence of practical production lease sizing.
- TypeScript parity uses its handler abort signal and joins the handler promise;
  a promise race must never be presented as proof that ignored cancellation stopped.

The implementation belongs entirely to jobs attempt orchestration and its focused
unit/PostgreSQL tests. No new scheduler, backend interface, deployment primitive,
Lambda support, process supervisor, or hard-isolation claim.

## Deferred decisions

Prolonged renewal uncertainty remains tracked in #1518. Do not turn SQL errors or
an arbitrary error count into confirmed lease loss. A conservative uncertainty
policy needs its own reviewed timing, query-bound and availability tradeoffs.

If a workload requires hard termination of blocking or cancellation-resistant
code, choose a separate process/executor boundary first. Eio cancellation alone
cannot meet that requirement.
