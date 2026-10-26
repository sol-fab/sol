# Building an application

How a Sol workspace is organised, which of the three primitives to reach for, how units talk to
each other, and how to add the ordinary things an application grows: an event, a unit, a table,
a scheduled job, a service dependency.

This is the conceptual and task-level guide. The exact contract — env var names, health
endpoints, discovery rules, migration filenames — lives in
[the runtime contract](../reference/runtime.md) and the per-package specs under
`framework/ocaml/`, and this page links to those rather than repeating signatures. The runnable
proof of everything here is [`examples/pluto`](../../examples/pluto), whose paths are cited
beside each sample so you can read the real thing.

## The workspace

A workspace is one application: a `sol.yml` at the root, the units under `app/`, the event
contracts under `events/`, the database migrations under `db/`, and the environment
declarations under `sol/`.

```text
pluto/
  sol.yml                     the application declaration: resources, services
  sol/environments.yml        environments and their targets
  app/
    checkout/checkout_svc/    one unit: bin/, lib/, sol.toml, Dockerfile
    payments/charge_svc/
    comms/notify_worker/
    demo_ts/order_svc/        a TypeScript unit
  events/payments/charged.ml  a typed event contract, per domain
  db/migrations/0001_notifications.sql
  lib/                        code shared inside this workspace
  test/
```

A **domain** is a group of units that change together and own their data (`payments`,
`checkout`, `comms`). A **unit** is one deployable process: `app/<domain>/<name>_{svc,worker,fn}/`.
The unit's directory name and the `sol.yml` entry must agree: discovery finds units by their
directory, while the declaration is what deployment reads for a unit's `language`, `uses` and
`scale`. `sol check` fails when a declared service has no unit directory (or its declared `path`
names a different directory), and warns when a unit exists on disk but is not declared.
`sol plan` refuses the same unimplemented declaration rather than rendering a service that cannot
be built or deployed.

`sol.yml` declares resources and services, and the `path`, `type`, `uses` and `language` of
each service:

```yaml
project: pluto

resources:
  app_db:
    type: postgres

  events:
    type: kafka

services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
    uses: [app_db, events]
    language: ocaml
```

`uses` is the wiring: it is how a unit receives what it depends on. The names it may use, and
what each one puts into the environment, are the contract's business — see
[Config and secret injection](../reference/runtime.md#config-and-secret-injection--the-wiring-is-real-the-naming-is-trusted).

## The three primitives

One decision rule, three answers:

- **Something calls it and waits for an answer → `-svc`.** An HTTP service: it serves routes,
  reports runtime health, and is reached at `<workspace>-<domain>` inside the cluster.
- **Something happens and it must react → `-worker`.** A Kafka consumer: it owns its
  consumer group, processes events at its own pace, and can host background jobs.
- **Time passes and it must run → `-fn`.** A scheduled function: `run : unit -> result`, with
  the trigger in configuration rather than in code.

### `-svc` — an HTTP service

A service's entry point builds its observability context and serves its routes; everything else
(health, metrics, the runtime contract) follows from `Service.run`
([`app/checkout/checkout_svc/bin/main.ml`](../../examples/pluto/app/checkout/checkout_svc/bin/main.ml)):

```ocaml
let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let obs = Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~service:"checkout-svc" () in
  Service.run Checkout.routes ~env ~ot:obs () |> ...
```

The route table is ordinary data in `lib/`, which is what makes a service unit testable without
a cluster ([`lib/checkout.ml`](../../examples/pluto/app/checkout/checkout_svc/lib/checkout.ml)).
Health and metrics are checked after deploy rather than trusted from the declaration: the
[runtime health contract](../reference/runtime.md#runtime-health-contract--svc-only--checked-but-only-after-deploy)
is the authority.

### `-worker` — a Kafka consumer

A worker's entry point reads what it needs, then runs its consumer loop
([`app/comms/notify_worker/bin/main.ml`](../../examples/pluto/app/comms/notify_worker/bin/main.ml)):

```ocaml
let module W = Notify_worker.Consumer in
let module WR = Worker.Make (W) in
WR.run ~env ~config:kafka_config ~ot:obs () |> ...
```

The same binary can host background jobs beside the consumer — pluto's worker forks
`Notify_worker.Jobs.run` as an Eio daemon, which is how a leased job queue and an event consumer
share one process without sharing a failure domain. The job library's contract is
[`sol-jobs`](../../framework/ocaml/sol-jobs/sol-jobs.md).

A worker is where retry behaviour belongs, but it retries the *operation*, never the message: the
outcome vocabulary is exactly `Ack | Fail` and a `Fail` stops the consumer, so a transient
dependency failure is retried in place with
[`sol-retry`](../../framework/ocaml/sol-retry/sol-retry.md) — the dependency call, not the
handler. Work that must outlive the process or run independently is handed to a durable job
([`sol-jobs`](../../framework/ocaml/sol-jobs/sol-jobs.md)) in the transaction that caused it.
There is no fire-and-forget producer entry point in the framework, so a unit that produces
events always has the delivery outcome in hand.

### `-fn` — a scheduled function

```bash
sol new fn billing/invoice      # creates app/billing/invoice_fn/
```

The generated unit has a `run` function and a `sol.toml` whose `[service] schedule` (scaffolded
as `"0 * * * *"`) is **required**: Sol reads the schedule from the unit's configuration and
generates a Kubernetes `CronJob`, and a `-fn` without one is a plan error rather than an hourly
job. That is the whole shape — *a function is `run : unit -> result`, the trigger is
configuration* — and the walkthrough is in
[TUTORIAL.md § *New scheduled function*](TUTORIAL.md#new-scheduled-function).

A function is ephemeral, so its metrics are pushed rather than scraped; the push contract is in
[`sol-fn`](../../framework/ocaml/sol-fn/sol-fn.md).

### Choosing

| When | Primitive |
|---|---|
| A caller needs an answer now | `-svc` |
| An event must be reacted to, at whatever pace, with retries | `-worker` |
| A clock or a calendar triggers it | `-fn` |

Most systems need all three: pluto serves `checkout_svc` and `charge_svc`, consumes with
`notify_worker`, and a billing function would be the third shape rather than a variation of the
first two.

## Events are the only cross-domain contract

Within a domain, units share code freely (`lib/`). Across domains they share **events and
nothing else** — no cross-domain imports, no shared mutable table. A domain that needs another
domain's data subscribes to its events or calls its service.

An event is a file with a type, a topic, a JSON schema, a partition count and a key
([`events/payments/charged.ml`](../../examples/pluto/events/payments/charged.ml)):

```ocaml
type t =
  { id : string
  ; amount_cents : int
  ; customer_id : string
  ; currency : string
  ; correlation_id : string
  }

let topic_name = Kafka_service.topic_name_exn "pluto-payments-charges"
let schema = {|{ "type": "object", "properties": { ... }, "required": [ ... ] }|}
let partitions = 3
let key t = Some t.id
let encode t = `Assoc [ ... ]
let decode = ...
```

Three things follow from that shape, and they are the reason the contract is a file rather than
a convention:

- **The schema is registered, not assumed.** The declared JSON schema is what a producer and a
  consumer agree on through the schema registry, so a change that would break a consumer is
  caught where it is made rather than in production.
- **The key decides ordering.** `key t` is what routes an event to a partition; two events with
  the same key are processed in order, which is why pluto keys charges by charge id.
- **Decoding is explicit.** `decode` returns a result, so a malformed event is a handled case
  in the consumer, not a crash.

Add one with `sol new event payments/refunded` — the generated file has the same shape as the
sample above — and see [`examples/pluto/test/test_schemas.ml`](../../examples/pluto/test/test_schemas.ml)
for how the round-trip is tested without a broker.

## Choosing a language

OCaml and TypeScript are both first-class application languages (`DEC-022`): a unit's language
is declared in `sol.yml` (`language: ocaml`, `language: typescript`) and everything
language-neutral — the workspace declaration, the runtime contract, the deployment path, the
observability vocabulary — is identical either way. Parity means **capability and behavioural
parity, not implementation parity**: the contract holds in both languages, while TypeScript
keeps the Node ecosystem underneath and the OCaml path keeps `kafka-eio`/`pg-eio`.

Pick for the team you have. Scaffolding supports both languages and all three primitives:

- **Scaffolding.** `sol new svc`, `sol new worker` and `sol new fn` support
  `--language typescript`; OCaml remains the default. Both language shapes use
  the same workspace declaration and `sol check`.
- **The production profile.** ADR 0009 makes the profile cloud- and
  language-neutral, so TypeScript is accepted by the preflight; live
  qualification evidence remains a separate, tracked gap. The local path and
  the TypeScript golden path (`FEAT-082`) work.

Read the TypeScript demos as the worked examples: `order_svc` is the `-svc` shape and
`fulfillment_worker` is the `-worker` shape, in the same workspace as the OCaml ones.

## The ordinary operations

**Add a domain and a unit.**

```bash
sol new svc payments/refund      # → app/payments/refund_svc/
sol new worker comms/audit       # → app/comms/audit_worker/
```

Then declare it in `sol.yml` with its `path`, `type` and `uses`, and run `sol check`. The unit
directory and the declaration must agree.

**Add an event.** `sol new event payments/refunded`, then publish it from the producing unit and
subscribe from the consuming one. Changing an event's schema is a contract change: extend it
additively, or add a new event.

**Add a table.**

```bash
db/migrations/0003_refunds.sql
```

Migrations are ordered by filename and applied as part of deployment; the filename is the
contract and the SQL content is not inspected. The convention, and what happens when a
migration is contracting, is in
[Migration file convention](../reference/runtime.md#migration-file-convention--filenames-only-sql-content-unchecked).

**Add a scheduled function.** `sol new fn billing/invoice`, then implement `run` and set
`[service] schedule` — the generated value is a placeholder that is valid but probably not what
you want.

**Wire a dependency.** Add the resource to the unit's `uses` in `sol.yml`. The unit then reads
what it needs from the environment; never hard-code a broker address or a database URL. In dev
the same names point at the local stack, because local runs the same charts at single-replica
scale.

**Add a service dependency.** A synchronous call to another domain's service goes through
discovery by name, and the calling unit must survive the callee being unavailable — the
[Synchronous service calls](../reference/runtime.md#synchronous-service-calls) section states
what the runtime guarantees and what it does not.

## Where the contract lives

- [The runtime contract](../reference/runtime.md) — health, config, discovery, migrations,
  and what is actually compiler-enforced.
- [The application contract index](../reference/README.md).
- The per-package specs: [`sol-svc`](../../framework/ocaml/sol-svc/sol-svc.md),
  [`sol-worker`](../../framework/ocaml/sol-worker/sol-worker.md),
  [`sol-fn`](../../framework/ocaml/sol-fn/sol-fn.md),
  [`sol-jobs`](../../framework/ocaml/sol-jobs/sol-jobs.md),
  [`sol-obs`](../../framework/ocaml/sol-obs/sol-obs.md).
- [`docs/guides/TUTORIAL.md`](TUTORIAL.md) — the same material as a walkthrough, from an empty
  directory to a running service.
- [`docs/reference/cli.md`](../reference/cli.md) — every command and flag.
