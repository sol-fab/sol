# Obs_prometheus.push (used by sol-fn)

The `push` function (from the external `obs-prometheus-eio` package) is called by
`Sol.Fn.Make` at the end of every invocation to push
metrics to a Prometheus Pushgateway. It is the correct solution for ephemeral processes
that cannot be scraped.

## Signature

```ocaml
val push
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string        (* Pushgateway base URL, e.g. "http://localhost:9091" *)
  -> job:string        (* job label, e.g. "payments-fn" *)
  -> (unit -> string)  (* renderer from Obs_prometheus.create () *)
  -> (unit, string) result
```

## Behaviour

- Builds the Pushgateway PUT URL: `<url>/metrics/job/<job>`
- Calls the renderer to snapshot current metrics
- If the snapshot is empty (no metrics emitted), returns `Ok ()` immediately
- Otherwise PUTs the Prometheus text body to the Pushgateway
- Uses a 5-second wall-clock timeout via `Eio.Time.with_timeout_exn`
- Returns `Ok ()` on HTTP 2xx, `Error msg` otherwise
- Never raises — all errors surface as `Error _`

---

# sol-fn — Function Primitive

`sol-fn` implements the `-fn` primitive: a unit of business logic that executes once
and exits: on a schedule as a Kubernetes CronJob (`Cron`), or hosted on AWS Lambda
(`Lambda`).

## Module type

```ocaml
type trigger =
  | Cron
  | Lambda

module type FN = sig
  val trigger : trigger
  val run : unit -> (unit, string) result
end
```

**The schedule lives in `sol.toml`, and only there** (BUG-048): `[service] schedule` in
the workload's `sol.toml` is required for a `-fn`. A missing one is a plan error; it
used to default to hourly. The code carries no cron string, so the two cannot disagree.

## Functor

```ocaml
module Make (F : FN) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> ?pushgateway_url:string   (* default: PUSHGATEWAY_URL from the environment *)
    -> ?job:string               (* default: SOL_PUSHGATEWAY_JOB, else "sol-fn"/"lambda" *)
    -> ?ot:Sol_obs.t
    -> ?stop:unit Eio.Promise.t
    -> unit
    -> (unit, run_error) result
end
```

Sol's manifests render `PUSHGATEWAY_URL` and `SOL_PUSHGATEWAY_JOB=<namespace>.<name>`
into every `-fn`, so a generated `main` that passes neither still pushes, and each
function's metrics land in its own Pushgateway group. The job used to default to the
cron string, so two functions on one schedule overwrote each other (BUG-048).

## Lifecycle

1. Create Prometheus backend+renderer (or use `~backend` override)
2. Register `sol_fn_invocations_total{status}` counter and `sol_fn_duration_seconds` histogram
3. Record `t0`
4. `Switch.run`:  install signal handler (self-pipe); `Fiber.first` returning typed outcome
5. Record duration + increment counter — **outside** Fiber.first, so never cancelled
6. Push to Pushgateway if a URL is configured (`~pushgateway_url` or `PUSHGATEWAY_URL`); push errors are logged and never fail the run
7. `Ok ()` → return; function failure → `Error (`Run msg)`; signal → `Error `Signalled`

## Signal handling

Uses the self-pipe pattern from `http/sol-svc/lib/service.ml`. `Eio_unix.Signal` does not
exist in the installed eio version; the self-pipe approach is async-signal-safe and proven.

## Generated main

```ocaml
(* app/payments/deposit-fn/bin/main.ml *)
let () =
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let obs =
      Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
        ~service:"deposit-fn" ()
    in
    let module M = Fn.Make (Deposit_fn) in
    match M.run ~env ~ot:obs () with          (* URL and job come from the manifest env *)
    | Ok () -> ()
    | Error `Signalled -> exit 130
    | Error e -> failwith (Fn.run_error_to_string e)
```

## Exit codes

| Condition | Exit code |
|---|---|
| `F.run ()` = `Ok ()` | 0 |
| `F.run ()` = `Error _` | caller policy, generated main exits non-zero |
| Ordinary exception from `F.run ()` | caller policy, generated main exits non-zero |
| SIGTERM / SIGINT | 130 |

## HTTP trigger

A `-fn` may declare an HTTP trigger instead of a schedule. The application
module then implements `Fn.HTTP` and is run by `Fn.Make_http`:

```ocaml
module Handler = struct
  let handle request =
    Response.json ~status:200
      (Printf.sprintf {|{"path":"%s"}|} request.path)
end

let () =
  Eio_main.run @@ fun env ->
  let module M = Fn.Make_http (Handler) in
  match M.run ~env () with
  | Ok () -> ()
  | Error e -> failwith (Fn.run_error_to_string e)
```

`Fn.Make_http` reads `SOL_HTTP_PATH` and `SOL_HTTP_EXPOSURE` (both injected by
Sol). Exposure is deliberately not defaulted: a missing or unknown value is a
configuration error before the server starts.

- **public**: the route is external; the provider endpoint is the security
  boundary.
- **internal**: the route keeps `sol-svc`'s workload-identity check, so a caller
  must present a projected token from the declared caller set. The platform also
  keeps the endpoint off the public network (Kubernetes Service without an
  Ingress; Cloud Run `--ingress internal`).

The same image adapts to the backend at runtime. If `AWS_LAMBDA_RUNTIME_API` is
set, it serves the Lambda runtime and translates API Gateway v2 / Lambda
Function URL events (`rawPath`, `rawQueryString`, headers, base64 body) into
`Request.t` and back. Otherwise it serves the declared route plus `/healthz` and
`/readyz` over HTTP on `PORT` (default 8080).

## Deployment: a run-once execution primitive (FEAT-079)

`-fn` is formally a **run-once Kubernetes execution primitive**, not "a cron
abstraction" — `Fn.Make(F).run` above has no cron awareness at all; it runs
`F.run` exactly once and exits. Sol schedules it with Kubernetes `CronJob`; Kubernetes creates a `Job` from
the declared template for each scheduled invocation.

Two pieces of that `jobTemplate` are explicit `sol.toml` decisions rather
than Kubernetes defaults Sol silently inherited:

```toml
[service]
scheduled_concurrency = "forbid"   # allow (default) | forbid | replace
backoff_limit = 3                  # default: 3
```

- **`scheduled_concurrency`** renders as `CronJob.spec.concurrencyPolicy`
  (Kubernetes' own three-value enum, unchanged). It governs overlap between
  the **CronJob controller's own scheduled runs** only — a function whose
  execution can outlast its schedule interval either lets the next tick
  overlap it (`allow`, the default, preserving pre-FEAT-079 behavior),
  skips the next tick (`forbid`), or cancels the running execution and
  starts the next one (`replace`).
- **`backoff_limit`** renders as `jobTemplate.spec.backoffLimit` (default:
  `3`, matching pre-FEAT-079 behavior). This is the end-to-end operational
  meaning of a handler's `Error _` above: `F.run ()` returning `Error _` (or
  raising) exits the process non-zero, Kubernetes' `restartPolicy:
  OnFailure` restarts the container, and after `backoff_limit` total
  failures the `Job` is marked failed and not retried again. `backoff_limit`
  is deliberately *not* named or documented as equivalent to `sol-worker`'s
  `retry_policy.max_attempts` (FEAT-078) — the two have not been checked for
  exact semantic equivalence (pod/container restart interactions in
  particular), so `backoff_limit` is exposed substrate-shaped rather than
  implying a stronger, shared contract it may not actually have.

Deliberately not made explicit (Kubernetes defaults apply, unchanged):
`activeDeadlineSeconds`, `startingDeadlineSeconds`,
`successfulJobsHistoryLimit`/`failedJobsHistoryLimit`, `suspend`.

Both settings are part of a release's identity and of its recorded boundary
(BUG-072): changing either produces a new release id, and `sol rollback`
reconstructs the `CronJob` with the policies the release recorded — so a
function deployed as `scheduled_concurrency = "forbid"` with
`backoff_limit = 0` comes back that way, not as the `allow`/`3` defaults.
