# Sol Tutorial

This tutorial walks through building and running a real multi-service application on Sol. By the end you will have two services deployed to a local Kubernetes cluster, talking to each other through Kafka, persisting data in PostgreSQL, and emitting structured logs and metrics visible in Grafana — without writing a single Kubernetes manifest or Helm chart.

---

## What Sol is

Sol is a production platform for backend services, written in **OCaml or
TypeScript** — both are first-class application languages on one
language-neutral platform. It gives you three service primitives:

- **`-svc`** — a long-running HTTP service with routes, auth, and a `/healthz` endpoint
- **`-worker`** — a Kafka consumer that processes a typed event stream
- **`-fn`** — a scheduled function that runs on a cron expression

These primitives share a common observability layer (Loki for logs, Prometheus for metrics) and a storage layer (PostgreSQL). Sol wires all of it together at startup. You write the handler; Sol runs it.

The `sol` CLI scaffolds new services, manages the local development cluster, builds and deploys container images, and runs database migrations.

This walkthrough uses OCaml, the deeper-supported path. `sol new svc` and
`sol new worker` also scaffold TypeScript units with `--language typescript`, and
the generated unit consumes the published `@sol-fab/*` packages. `sol new fn` is
OCaml-only for now: the TypeScript `-fn` runtime contract is not implemented (the
`-fn` row in [`framework-conventions.md`](../../internal/specs/framework-conventions.md)).
The hand-built reference for the TypeScript path is
[`examples/pluto/app/demo_ts`](../../examples/pluto/app/demo_ts/README.md).

---

## Prerequisites

- k3d v5+ and Helm v3+
- Docker, kubectl
- `librdkafka-dev`, `libpq-dev`, `libpq5` (`sudo apt-get install -y librdkafka-dev libpq-dev libpq5`)

Install `sol` (Linux x86_64) — download the self-contained release bundle:

```bash
# Replace vX.Y.Z with the latest version from https://github.com/sol-fab/sol/releases
curl -L https://github.com/sol-fab/sol/releases/download/vX.Y.Z/sol-vX.Y.Z-linux-x86_64.tar.gz \
  | tar xz
export PATH="$PWD/sol-vX.Y.Z/bin:$PATH"   # add to ~/.bashrc or ~/.zshrc
sol assets                                # where this sol's assets come from, and that each is there
```

The archive's top directory is an installation prefix: `bin/sol`, and `share/sol/vX.Y.Z/` with the platform assets that version uses (Terraform roots, Helm values, Grafana dashboards) and the digest of its migration-runner image. The binary uses those and nothing else, so no `SOL_HOME` or clone is needed to run it. It needs glibc 2.35+ (Ubuntu 22.04 or newer) and `libpq5`/`libgmp10`. The install can be read-only: Sol copies the Terraform roots into a working directory per target under `~/.local/share/sol/terraform/` and runs there. The one remaining checkout dependency: generated OCaml workspaces still require source framework packages until RELEASE-005 publishes them (see the note under Part 2).

> **Build from source:** See the repository README for the pinned support-package setup and current build commands.

---

## Part 1 — Local infrastructure

Sol's local cluster mirrors production exactly: same Helm charts, same service DNS names, same security model. The only difference is scale (single replica, no persistent volumes).

```bash
sol local infra up
```

This creates a k3d cluster named `sol-local` and installs:

| Component | What it does |
|-----------|-------------|
| Redpanda | Kafka-compatible broker + schema registry |
| PostgreSQL | Primary database |
| Loki + Grafana | Log aggregation and dashboards |
| Prometheus + Pushgateway | Metrics collection |

When it finishes, every component is reachable on localhost:

```
Kafka           localhost:9092
Schema registry localhost:8081
PostgreSQL      localhost:5432
Loki            localhost:3100
Grafana         localhost:3000   (admin / dev)
Pushgateway     localhost:9091
```

These port-forwards are managed by Sol in the background (PIDs recorded in `~/.local/share/sol/`). `sol local infra down` tears everything down. Running `sol local infra up` again clears any stale port-forwards first, so repeat runs are safe.

Each forward is observed until the addressed local port is actually owned by it; the command does not print a ready summary just because a supervisor started. If a required endpoint — one of the resources the workspace declares, plus the ingress — does not become ready within Sol's bound, the command names it, prints the forward's log, and exits nonzero, leaving the cluster and its Helm releases in place so you can fix the cause and re-run. Forwards Sol provisions opportunistically, without a corresponding declared requirement, are reported as optional instead of failing the run.

### Workloads declare their language

`sol.yml`'s `services:` block is where a workload says what it is implemented in. `sol new` records `language: ocaml` for the unit it just generated — it knows what it wrote — and nothing infers a language from a `package.json`, a `dune` file or a directory name (DEC-022 §7). A unit you authored by hand declares it once; `sol check` warns when one has not:

```text
warning: sol.yml: ledger_worker declares no language; add `language: ocaml` (or typescript) under services.ledger_worker in sol.yml
```

### Local iteration with `sol local run`

Once the cluster is up and you have a workspace (see Part 2), use `sol local run` for rapid code-change iteration:

```bash
sol local run
```

`sol local run` discovers every service in `app/<domain>/<name>/` that has a `Dockerfile` and runs each one as a **native process** — no Docker image rebuild required. The workload's declared language (above) picks how it is built and launched: an OCaml unit is built with a single `dune build` across all of them and its compiled binary is spawned; a TypeScript unit is built with `npm run build` in its npm project and its built entry is run with `node`. Sol launches each service with its literal argv and working directory — paths with spaces or shell metacharacters need no quoting — and owns each process, so Ctrl-C or SIGTERM stops every service Sol started and leaves no descendants. If one service exits nonzero or is signalled, Sol stops the rest and exits nonzero rather than reporting a successful run. Each service's stdout and stderr is prefixed with `[domain/name]`, so you can follow several in one terminal.

For local-only credentials, put values in `sol/secrets.local/<domain>/<unit>.env`. For example, `sol/secrets.local/payments/charge_svc.env` can contain `PAYMENT_API_KEY=value`. Each unit has a separate file, so two units can use the same key name with different values. Sol passes a value only to the matching unit when that key is declared under `[infra.env].secrets`; values are not shell-expanded, passed to build commands, or printed when they appear in service output. Local processes do not inherit the shell environment; Sol supplies its local development variables and the unit's declared secret values. Missing values stop local run before it builds or starts services. The scaffolded `.gitignore` and `.dockerignore` both exclude `sol/secrets.local/`; add the same entries to older workspaces before creating secret files.

Resource inputs follow declared dependencies. A unit receives PostgreSQL configuration only
when its `uses` names a PostgreSQL resource. Kafka endpoints are supplied only when the unit
uses a Kafka resource or declares topics; being a worker alone does not imply Kafka usage.
Resource credentials are not application keys under `[infra.env].secrets`. A database consumer
can override its local `POSTGRES_URL` in its own ignored file; an unrelated unit receives
neither that file's database URL nor Kafka credentials. Undeclared application keys, including
`SOL_API_KEY`, are not forwarded.

Sol supplies these local values rather than inheriting resource credentials from the shell:

| Variable | Local value | Consumers |
|---|---|---|
| `KAFKA_SECURITY_PROTOCOL` | `plaintext` | Kafka dependencies |
| `KAFKA_BROKERS` | `localhost:9092` | Kafka dependencies |
| `SCHEMA_REGISTRY_URL` | `http://localhost:8081` | Kafka dependencies |
| `REDPANDA_ADMIN_URL` | `http://localhost:9644` | Kafka dependencies |
| `POSTGRES_URL` | `postgresql://postgres:dev@localhost:5432/dev` | PostgreSQL dependencies |
| `LOKI_URL` | `http://localhost:3100` | All local units |

**When to use `sol local run` vs `sol local deploy`:**

| | `sol local run` | `sol local deploy` |
|---|---|---|
| How services run | Native processes — the compiled binary (OCaml) or `node` on the built entry (TypeScript) | Docker containers in k3d |
| On code change | Rebuild + re-run (~seconds) | `docker build` + redeploy (~minutes) |
| Uses k3d infra | Yes (via port-forwards from `sol local infra up`) | Yes |
| Good for | Fast edit-compile-run loop | Final smoke test before CI |

Both commands talk to the same Kafka broker, PostgreSQL, and Loki instance that `sol local infra up` started. The difference is only in how the service processes themselves are launched.

---

## Part 2 — Scaffold a workspace

A **workspace** is a directory that contains one or more domain teams, each with their own services. Teams communicate through typed Kafka events — never through shared code.

```bash
sol new workspace pluto
cd pluto
```

> **Framework packages:** the generated workspace declares its framework dependency (`sol-svc`, `sol-worker`, …) in its own `.opam` file, and your opam switch provides it (DEC-025). Until those packages are published to opam (RELEASE-005), install them from a Sol checkout with `bash platform/local/scripts/prepare-framework-deps.sh`; otherwise `dune build` fails with "Library not found: sol_svc".

This generates 35 files. Here is what was created and why:

```
pluto/
  sol.yml                         ← workspace manifest (identifies this directory as a Sol workspace,
                                     and declares each workload's language)
  dune-project                    ← root dune project (required)
  .ocamlformat                    ← OCaml formatter config
  .dockerignore                   ← excludes _build/ and .git/ from Docker build context
  README.md                       ← workspace-level docs

  sol/environments.yml            ← deploy environments and their targets (a placeholder prod/aws/us-east-1)
  .gitignore                      ← ignores _build/ and sol/environments.local.yml

  .github/workflows/
    sol-ci.yml                    ← the Sol CI pipeline (build, test, authorize, deploy)

  events/payments/
    charged.ml                    ← the Charged event contract
    dune
    sol.toml                      ← declares the Kafka topic name for auto-provisioning

  app/payments/charge_svc/
    lib/handler.ml                ← HTTP route handlers
    lib/dune
    bin/main.ml                   ← service entrypoint
    bin/dune
    Dockerfile
    sol.toml

  app/comms/notify_worker/
    lib/notify_worker.ml          ← Kafka message handler
    lib/dune
    bin/main.ml                   ← worker entrypoint
    bin/dune
    Dockerfile
    sol.toml

  lib/
    notification.ml               ← shared DB module (used by svc and worker)
    dune                          ← pluto_storage library

  db/migrations/
    0001_notifications.sql        ← initial schema
    0001_notifications.down.sql   ← companion rollback migration (used by `sol local migrate rollback`)
    0002_sol_outbox.sql           ← transactional outbox table (durable publication intent)

  test/
    test_schemas.ml               ← schema backward-compatibility CI gate
    dune
```

Two domain teams are wired together out of the box:

- **payments team** — owns the `Charged` event and runs `charge_svc`
- **comms team** — runs `notify_worker`, which consumes `Charged` events published by the payments team

### The event contract

An event's contract is declared once, in `events/<team>/sol.toml`, and that
declaration is canonical:

```toml
[contract]
language = "ocaml"

[[events]]
name = "Charged"
topic = "pluto-payments-charges"
partitions = 3
key = "id"
schema = '''{"type":"object",...}'''
```

The declaration carries no language-specific paths: `[contract] language` selects the
binding, and its destination follows the language. An OCaml team's binding is
`events/payments/payments_contract.ml`, checked in beside the declaration, and
application code consumes it:

```ocaml
type t = {
  id          : string;
  customer_id : string;
  amount_cents: int;
  currency    : string;
}

include Payments_contract.Charged   (* topic_name, schema, partitions, key_field *)

let encode t = ...
let decode = ...
let key t = Kafka_service.Contract.key_of_field key_field (encode t)
```

The module still satisfies `Kafka_service.MESSAGE`, but the contract facts come
from the declaration rather than from hand-written code, so there is nothing to keep
in sync. `sol check` (including scoped checks) fails when a checked-in binding
drifts from its declaration; `sol contract generate` is the explicit command for
updating those projections. `sol plan` reads the declaration directly — it never parses or runs
application code. Sol registers the schema with the schema
registry during `sol local deploy`/`sol deploy` before any workload moves, and a producer or
consumer resolves it read-only at startup, so a producer cannot publish a message
that breaks it and a runtime never rewrites the contract. `partitions` is the count
Sol creates the topic with, and the declared `key` field is what keeps every record
for one entity on a single partition — and therefore in order.

A TypeScript team (`language = "typescript"`) generates into its scope's contract
package instead — `app/<team>/contract/src/<team>_contract.ts` — and the app supplies
only its value types:

```ts
import type { NamedContract, TopicContract } from "@sol-fab/kafka";
import { OrderPlacedSpec, generatedContract } from "./demo_ts_contract.js";

export interface OrderPlaced {
  order_id: string;
  item: string;
  quantity: number;
  correlation_id: string;
}

export const ORDER_PLACED: TopicContract<OrderPlaced> =
  generatedContract<OrderPlaced>(OrderPlacedSpec);
```

In both languages the contract facts come from the declaration rather than from
hand-written code — the declared `key` becomes a generated field extractor — so there
is nothing to keep in sync.

Runtime acceptance belongs to the contract as well: the interface and its validated
decoder live in the same module (`decodeOrderPlaced`/`decodeOrderFulfilled` beside
`OrderPlaced`/`OrderFulfilled` in `app/demo_ts/contract`), exactly as an OCaml event
module pairs `type t` with `decode`. Every producer and consumer imports that one
decoder instead of re-implementing the field checks, so a producer and a consumer
cannot disagree about which payloads the same event accepts.

`sol new event <team>/<name>` appends a declaration to the team's `sol.toml` and
regenerates its binding, so a new event follows the same path.

### The HTTP service

`app/payments/charge_svc/lib/handler.ml` defines routes:

```ocaml
let routes pool ~publish_charged ~ot = [
  Route.external_ (Route.get  "/health" (fun _req -> Response.ok "ok"));
  Route.external_ (Route.post "/charges" (fun req -> ...));
  Route.external_ (Route.get  "/notifications" (fun _req -> ...));
]
```

`POST /charges` generates a charge ID, publishes a `Charged` event to Kafka, and returns `{"id":"ch_XXXXXX","accepted":true}`. `GET /notifications` reads the last 20 rows notify-worker wrote back from PostgreSQL.

`~ot` is the observability handle (Part 6 shows how it's constructed) — `/charges` wraps its work in `Obs_eio.with_span ot ?parent:req.trace_ctx "charges" (fun sp -> ...)` so the request gets both a Tempo trace and a correlated Loki log line, matching the upstream trace if the caller sent a `traceparent` header.

Auth is always declared explicitly on each route. There is no implicit auth based on path conventions.

### Two services talking

Pluto also includes `app/checkout/checkout_svc`, an API-key-protected HTTP
service. `charge_svc` declares the east-west dependency in `sol.toml`:

```toml
[service]
calls = ["checkout/checkout_svc"]
```

That makes Sol inject `CHECKOUT_SVC_URL` into `charge_svc` and generate the
per-pair NetworkPolicy. In-cluster, the URL resolves through Kubernetes DNS to
the checkout ClusterIP; the request never goes out to the public internet.
The caller endpoint uses `Peer.url "checkout_svc"` and
`Peer.headers ~peer:"checkout_svc"`, so the projected identity token becomes
`Authorization: Bearer` and the current W3C `traceparent` is set in one place.

### The worker

`app/comms/notify_worker/lib/notify_worker.ml` is a Kafka consumer:

```ocaml
module Make (Config : sig
  val pool  : Pg_db.pool
  val ot    : Obs_eio.t
  val clock : float Eio.Time.clock_ty Eio.Resource.t
end) = struct
  module Message = Charged
  let group_id = "pluto-comms-notify-worker"

  let handle (msg : Message.t) ~trace_ctx:_ : Worker.outcome =
    Sol_retry.run ~clock:Config.clock retry_policy (fun () ->
      Pg_db.transaction Config.pool (fun tx ->
        let open Result.Syntax in
        let* inserted = Notification.insert tx ~charge_id:msg.id ... in
        match inserted with
        | None -> Ok ()
        | Some _ ->
          let* () = Jobs.enqueue tx ~dedupe_key:msg.id
                      Email_job.{ charge_id = msg.id; customer_id = msg.customer_id } in
          Notification_sent_outbox.publish tx ~key:msg.id ~ord:1L
            Notification_sent.{ charge_id = msg.id; customer_id = msg.customer_id; ... }))
    |> function
    | Ok () -> Worker.Ack
    | Error _ -> Worker.Fail
end
```

`module Message = Charged` tells Sol which Kafka topic and schema this worker consumes. `group_id` is the Kafka consumer group name. `handle` is called once per message with the decoded payload — there's no `ack` to call; Sol commits the offset for you, only after `handle` returns `Worker.Ack`.

`handle` returns `Worker.outcome`, which is exactly `Ack` or `Fail`. `Ack` applies the fact and advances the offset. `Fail` declines it: the offset is not committed and the consumer stops, so a contract failure surfaces to an operator instead of being a fact the runtime silently skipped. There is no retry outcome and no application-level dead-letter outcome — a transient dependency failure is handled at the operation level (retry the dependency call, not the whole handler), never by re-running `handle`.

`Sol_retry.run` is that retry. The operation is the dependency call — here the whole transaction — and the handler still returns exactly one outcome:

```ocaml
let retry_policy =
  match
    Sol_retry.of_policy
      { base_delay_s = 0.25; max_delay_s = 5.0; max_attempts = 4; jitter_ratio = 0.25 }
  with
  | Ok policy -> policy
  | Error message -> failwith ("retry policy: " ^ message)
;;

let handle (msg : Message.t) ~trace_ctx:_ : Worker.outcome =
  match
    Sol_retry.run ~clock:Config.clock retry_policy (fun () ->
      Pg_db.transaction Config.pool (fun tx -> apply_fact tx msg))
  with
  | Ok () -> Worker.Ack
  | Error e ->
    Obs_eio.log_standalone Config.ot Obs_eio.Error
      ~fields:[ "error", Pg_error.to_string e ] "db transaction failed after retries";
    Worker.Fail
;;
```

A transient Postgres failure repeats the transaction, which rolls back on every failed attempt, and only after the budget is spent does the handler return `Fail`; `Ack` and `Fail` remain the only outcomes, and `handle` is never re-run, because retrying the message would repeat whatever side effects already succeeded. The policy vocabulary — `base_delay_s`, `max_delay_s`, `max_attempts`, `jitter_ratio` — is the same one `sol-jobs` and the worker's retry machinery use, and the helper yields to Eio between attempts, so the retry never blocks the domain. `handle` runs in the consumer's fiber, so the worker's `Make(Config)` carries the clock (`env#clock` in `bin/main.ml`) rather than reaching for an ambient one. Contract: [`sol-retry.md`](../../framework/ocaml/sol-retry/sol-retry.md).

Independent work that must be retried later goes to `sol-jobs` instead. `notify_worker` above hands its confirmation email to a job: `Jobs.enqueue` runs in the same Postgres transaction as the notification insert, so either both rows exist or neither does, and `~dedupe_key:msg.id` makes a redelivery after a failed offset commit a no-op (FEAT-112). The notification insert is idempotent for the same reason: the migration puts a unique index on `charge_id`, so `Notification.insert` runs `ON CONFLICT (charge_id) DO NOTHING` and reports through `RETURNING charge_id` whether it applied, and a redelivered fact therefore leaves exactly one notification row. The `None`/`Some` gate around the job and the intent matters: without it a redelivery whose intent is still pending would try to insert the same `(aggregate_key, ord)` again, and `sol_outbox`'s unique index refuses that, turning a legal duplicate into a `Fail`. The worker's `bin/main.ml` hosts the job runner alongside the consumer. That is the endorsed composition — the stream carries the fact, and the durable job queue performs the retry ([`sol-jobs.md`](../../framework/ocaml/sol-jobs/sol-jobs.md)).

Publishing the fact is the other half of that transaction. The same `Pg_db.transaction` writes a `Notification_sent` record through `Notification_sent_outbox.publish`, so the notification row, the retried email job and the publication intent commit together or roll back together. The handler does not publish to Kafka itself: the relay in `bin/main.ml` reads the unpublished record, publishes it keyed by the aggregate (`msg.id`), and removes it only after the broker acknowledges. That is the transactional outbox — `events/` declares the fact, the domain transaction records the intent atomically, the relay distributes it at-least-once, and the worker stays idempotent because **a duplicate is a legal outcome**: the relay may publish a record twice if it dies between the acknowledgement and the removal, but it never publishes a later record for a key before an earlier one, and never leaves a gap. Order is per key, not global; a record that cannot publish holds only its own key and surfaces as publication lag ([`sol-outbox.md`](../../framework/ocaml/sol-outbox/sol-outbox.md)).

The `Make(Config)` functor pattern lets you inject the database pool and observability handle without module-level mutable state. Sol's worker runtime manages the Kafka connection lifecycle, acknowledgement, graceful shutdown, and per-message metrics.

### The shared storage module

`lib/notification.ml` is used by both the svc and the worker. It wraps two caqti queries:

```ocaml
let insert pool ~charge_id ~customer_id ~amount_cents ~currency = ...
let list_recent pool = ...
```

Both return `(_, Storage_error.t) result`. No exceptions cross module boundaries.

The `lib/dune` file publishes this as `pluto_storage`, a library both services depend on.

---

## Part 3 — Deploy to the local cluster

Local secret values are kept in ignored, unit-scoped files. For each workload,
create `sol/secrets.local/<domain>/<unit>.env` with the values it needs:

```bash
mkdir -p sol/secrets.local/payments sol/secrets.local/comms
cat > sol/secrets.local/payments/charge_svc.env <<'SECRETS'
POSTGRES_URL=postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev
SOL_API_KEY=dev-internal-key
SECRETS
cat > sol/secrets.local/comms/notify_worker.env <<'SECRETS'
POSTGRES_URL=postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev
SOL_API_KEY=dev-internal-key
SECRETS
```

Then establish infrastructure and apply the workspace migrations before releasing workloads:

```bash
sol local deploy    # establishes infrastructure, then refuses pending migrations
sol local migrate
sol local deploy    # reuses the cluster and deploys against the migrated schema
```

The first refusal applies no workloads. Migration uses the local PostgreSQL service;
it does not need an earlier successful workload deployment. Applied migration files
must also retain their recorded checksums before deploy can continue.

For each service that has a `Dockerfile`, Sol:

1. Builds the Docker image and tags it with the short git SHA
2. Pushes it to the local registry (`sol-registry:5000`)
3. Reads that unit's ignored secret file and applies its required values to the unit Secret
4. Generates Kubernetes manifests (Namespace, Deployment, Service, ServiceAccount, ConfigMap)
5. Validates them against the live API server (`kubectl apply --dry-run=server`)
6. Applies them live

If a required key is absent or blank, Sol stops before building images and names
the keys and file that need values.

> The generated `Dockerfile` is a two-stage build, and its rationale -- the glibc
> pin, where its dependencies come from, and the uid it runs as -- is documented
> in your workspace's `README.md`.

The generated ConfigMap injects cluster-internal service addresses so pods communicate via k8s DNS, not localhost port-forwards:

```
KAFKA_SECURITY_PROTOCOL plaintext
KAFKA_BROKERS       redpanda.redpanda.svc.cluster.local:9093
SCHEMA_REGISTRY_URL http://redpanda.redpanda.svc.cluster.local:8081
REDPANDA_ADMIN_URL  http://redpanda.redpanda.svc.cluster.local:9644
LOKI_URL            http://loki.monitoring.svc.cluster.local:3100
TEMPO_URL           http://tempo.monitoring.svc.cluster.local:4318
```

Application secrets such as `SOL_API_KEY` are delivered through each workload's
Kubernetes Secret instead of the ConfigMap. A unit that declares `uses: [app_db]`
gets its database connection from the deploy-delivered `<target>-dml-creds` class
Secret, not from a declared key. `sol local deploy` reads the matching ignored
file under `sol/secrets.local/`, applies only that unit's declared values, and
verifies the rollout. A changed local value causes the affected workload to
restart.

A secret that only the **build** needs is declared separately, in
`[infra.env] build_secrets`, so it is never delivered to the running workload:

```toml
[infra.env]
# runtime keys — delivered to the pod through <service>-secrets
secrets       = ["SOL_API_KEY"]
# build-time keys — named for the builder, exported in the plan, never shipped
build_secrets = ["BUILD_REGISTRY_TOKEN"]
```

`sol deploy --emit-plan-to` lists each service's `build_secret_keys` by name; Sol
never emits a value, and a key declared in both lists fails validation.

When a service needs a synchronous call to another service, declare it in the
caller:

```toml
[service]
calls = ["checkout/checkout_svc"]
```

Sol injects `CHECKOUT_SVC_URL` and opens only that pair's NetworkPolicy path.
Prefer events for cross-domain flows unless the synchronous dependency is part
of the service contract.

These names are deterministic from the Helm release names and workspace/domain
names chosen by `sol local infra up`.

After `sol local deploy` finishes, Sol verifies workload readiness. For inspection of the
local cluster, use `kubectl` and the local Grafana interface.

```
Namespace: pluto-comms
NAME                              READY   STATUS    RESTARTS   AGE
notify-worker-77859bbfff-77vm6    1/1     Running   0          2m

Namespace: pluto-payments
NAME                           READY   STATUS    RESTARTS   AGE
charge-svc-5464d77bd4-2lnb9    1/1     Running   0          2m
  →  http://localhost:8080  (charge-svc)
```

---

## Part 4 — Manage database migrations

The initial migrations were applied before deployment in Part 3. After adding a new
migration file, run the same command before deploying the changed application:

```bash
sol local migrate
```

If `POSTGRES_URL` is not set, Sol detects the cluster postgres automatically and starts a background port-forward:

```
Forwarding postgresql (cluster) → localhost:15432 ...
Applying migrations from db/migrations...
Done.
```

The migration runner applies SQL files in numeric order and records each applied version in a `sol_<workspace>_schema_migrations` table (for example, `sol_pluto_schema_migrations` when your workspace directory is `pluto`). Re-running `sol local migrate` is safe — already-applied versions are skipped.

The table name is derived from your workspace directory name. Use `--table <name>` to override the default if you need a custom tracking table. An explicit `--table` that would exceed PostgreSQL's 63-byte identifier limit is refused rather than silently truncated.

Long directory names are shortened rather than truncated. PostgreSQL truncates identifiers
past 63 bytes, which would have let two long-named workspaces share one tracking table and
skip each other's migrations; the derived name therefore keeps a readable prefix plus a
stable hash of the full directory name. Two workspaces sharing one database each read only
their own table:

```console
$ cd checkout-svc && sol migrate status
$ cd ../billing-svc && sol migrate status
```

Check migration status at any time:

```bash
sol local migrate status
```

```
VER     NAME                            DRIFT     APPLIED AT
------------------------------------------------------------------------
1       0001_notifications              -         2026-06-05T12:34:56Z
```

Each applied version also records the checksum of the file that was applied. If you edit a migration after applying it, `sol migrate status` marks its row `yes` in the DRIFT column and exits non-zero, `sol migrate apply` refuses to run, and a local or production deploy fails before any workload moves — the applied record and the files you are deploying must agree. Restore the file, or put the change in a new migration and apply that. A migration applied before Sol recorded checksums has no baseline, so it shows as `-` rather than as drift.

---

## Part 5 — Try the API

`sol local deploy` started the port-forward automatically — the service is already reachable at http://localhost:8080. If the port-forward was stopped, run `sol local deploy` again to restart it (or run `kubectl port-forward svc/charge-svc -n pluto-payments 8080:80` directly).

```bash
# Health check
curl localhost:8080/health
# ok

# Create a charge
curl -X POST localhost:8080/charges \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"cus_123","amount_cents":4999,"currency":"usd"}'
# {"id":"ch_042381","accepted":true}

# List stored notifications
curl localhost:8080/notifications
# [{"charge_id":"ch_042381","customer_id":"cus_123","amount_cents":4999,"currency":"usd"}]

# Call checkout through charge_svc's declared service dependency
curl localhost:8080/checkout-quote
# {"shipping_cents":799,"currency":"USD","trace_id":"..."}
```

---

## Part 6 — Observe logs, metrics, traces, and alerts

Open Grafana at `http://localhost:3000` (admin / dev).

### Logs

Go to **Explore → Loki** and query:

```
{workspace="pluto"} | logfmt
```

You will see structured log lines from both services — the `workspace` label Sol writes on every workload pod, so the query cannot pick up a same-named unit from another workspace. Each line includes `level`, `msg`, `span`, `trace_id`, and any fields the handler added. W3C `traceparent` headers propagate across the Kafka boundary, so a charge request's `trace_id` appears in both the `charge-svc` logs and the `notify-worker` logs when the event is consumed. The `/checkout-quote` path also forwards `traceparent` over HTTP via `Peer`, so the checkout response includes the propagated `trace_id`.

### Ingress

In local dev, Sol serves `checkout_svc` on its per-service host:

```bash
curl -H 'Host: checkout-svc.pluto-checkout.localhost' \
  -H 'x-api-key: dev-internal-key' \
  http://localhost:8088/quote
```

For customer-cloud, set `ingress_host` in `checkout_svc/sol.toml` to your DNS
name, run `sol deploy customer_cloud/aws/us-east-1`, then create an `A` or
`CNAME` record pointing at the ingress load balancer. Cert-manager provisions
TLS through the configured cluster issuer.

### Metrics

Go to **Explore → Prometheus** and query:

```
sol_svc_requests_total
sol_worker_messages_total
sol_svc_request_duration_seconds_bucket
```

Sol registers these metrics automatically when `?ot` is wired in the service entrypoint. No instrumentation code is needed in the handler.

### Traces

Unlike metrics, tracing isn't automatic — a handler opts in by wrapping its work in `Obs_eio.with_span`, as `POST /charges` does (Part 2). `sol local infra up` provisions Tempo and wires `TEMPO_URL` in automatically, so any handler that calls `with_span` gets a real trace with no extra setup. Click a `charge-svc` log line in the Loki view above: next to `trace_id=...` Grafana shows a **Tempo** button (a derived-field link, no copy-pasting IDs) that jumps straight to that request's span waterfall in **Explore → Tempo**.

Tracing is `-svc`-only for now. `notify-worker` receives the same trace context and logs the matching `trace_id` for correlation, but doesn't wrap its work in a span, so it doesn't emit its own spans to Tempo yet.

### Alerting

Sol ships two starter Prometheus alert rules by default, scoped to the same `workspace`/`domain`/`service` labels as everything above — no extra instrumentation needed:

| Alert | Fires when |
|---|---|
| `SolHighErrorRate` | A service's 5xx rate exceeds 5% of requests, sustained 5 minutes |
| `SolPodRestartLoop` | A pod's container restarts more than 3 times in 15 minutes |

View rule state at `http://localhost:9090/alerts` (`kubectl port-forward -n monitoring svc/prometheus-server 9090:80` if not already forwarded) — each rule shows `inactive`, `pending`, or `firing`. Once a rule fires it also shows up in Alertmanager's own UI (`kubectl port-forward -n monitoring svc/prometheus-alertmanager 9093:9093`, then `http://localhost:9093`).

Alertmanager ships with a `null` receiver by default — alerts fire and are visible in its UI/API, but nothing pages or texts anyone until you point it at a real receiver (Slack, PagerDuty, email). See [`docs/deployment/observability-backends.md`](../deployment/observability-backends.md) for how to wire one up, and to add your own alert rules.

---

## Part 7 — Extend the workspace

Adding a new domain or service follows the same pattern.

### New event type

```bash
sol new event billing/payment_confirmed
```

Generates `events/billing/payment_confirmed.ml` with a stub `type t` and `schema`. Edit the type to match your payload; the compiler will find every place that needs updating.

**Schema backward compatibility:** Changing the `schema` field (the JSON Schema string) may break consumers that are still running against the old schema. The OCaml compiler catches structural type mismatches, but JSON schema changes are only caught when the contract is reconciled — at `sol plan`/`sol deploy` time, and by this test. To catch breaking schema changes in CI before deploy, run the generated schema compatibility test:

```bash
SCHEMA_REGISTRY_URL=http://localhost:8081 dune test test/
```

`test/test_schemas.ml` (generated by `sol new workspace`) calls `Kafka_service.Schema.check_all` against the registry containing published schema history. If the new schema is incompatible with the already-registered version, the test fails before staging. Configure the generated CI workflow's `SCHEMA_REGISTRY_URL` GitHub Actions secret: CI fails when it is absent or the check cannot run. On a developer machine, the test visibly skips when the URL is unset.

### New worker

```bash
sol new worker logistics/fulfillment
```

Generates a minimal worker in `app/logistics/fulfillment_worker/`. Wire the event library into its `dune` file, set `module Message = Payment_confirmed`, implement `handle`, then redeploy:

```bash
sol local deploy
```

### New service

```bash
sol new svc ops/admin
```

Generates `app/ops/admin_svc/` with a stub handler. Add routes and redeploy.

### New scheduled function

```bash
sol new fn billing/invoice
```

Generates `app/billing/invoice_fn/` with a `run` function and a `sol.toml` whose `[service] schedule` (scaffolded as `"0 * * * *"`) is required. Sol reads the schedule from `sol.toml` and generates a Kubernetes `CronJob`; a `-fn` without one is a plan error rather than an hourly job.

---

## How observability wiring works

Every service entrypoint follows the same pattern, through `Sol_obs` — the
app-facing observability facade (`framework/ocaml/sol-obs`). Here is the
charge-svc `bin/main.ml`:

```ocaml
Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let obs =
  Sol_obs.of_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
    ~service:"charge-svc" ()
in
```

`Sol_obs.of_env` reads `LOKI_URL`/`TEMPO_URL` from the environment, composes
whichever backends are configured (Prometheus is always included), and applies
Sol's workload identity as ambient labels — so every signal the handle emits
carries the same `workspace`/`env`/`domain`/`service`/`primitive`/`release`
values that `sol deploy` renders as pod labels
([`runtime.md` § Sol workload identity](../reference/runtime.md#sol-workload-identity)).
The injected values win over a `~context` field of the same name; `~context`
still adds app-owned fields (for example `team`). Handlers use
`Sol_obs.log_info`/`log_warn`/`with_span` instead of calling `Obs_eio` directly;
`Sol_obs.obs_eio obs` and `Sol_obs.metrics_renderer obs` hand the lower-level
pieces to `Service.run`'s `?ot`/`?metrics_renderer`.

When `LOKI_URL`/`TEMPO_URL` are absent (local `dune exec` dev), logs go to
stdout in logfmt format and no traces are emitted. In the cluster,
`sol local infra up` sets Loki/Tempo automatically. The code is identical either way.
Workers follow the same pattern, but only service handlers currently opt into
application spans.

---

## CLI reference

```
sol new workspace <name>                          scaffold a new workspace
sol new svc <domain>/<name> [--language typescript]    add an HTTP service
sol new worker <domain>/<name> [--language typescript] add a Kafka consumer
sol new fn <domain>/<name>                         add a scheduled function
sol new event <team>/<name>                       add a typed Kafka event

sol local infra up                                        provision local k3d cluster
sol local infra down                                      tear down the cluster
sol local run [--scope DOMAIN[/UNIT]]                 run services as native processes (fast iteration)

sol plan TARGET                                   print merged app/resource/service plan
sol local deploy [--scope DOMAIN[/UNIT]] [--dry-run] [--tag]  build images and deploy to local cluster
sol deploy TARGET [--image-tag TAG] [--registry URL]  deploy pre-built images (CI mode)
sol deploy TARGET --emit-to DIR [--image-tag TAG] ...  write YAML for Argo CD (GitOps mode)
sol releases                                     list this workspace's recorded releases (id, environment, workloads)

sol migrate [apply]                               apply pending migrations
sol migrate status                                show per-file applied/pending table
sol migrate rollback                              roll back the last applied migration

sol assets                                        where this sol's own assets come from (a checkout or an installed release), and check each one

sol rollback RELEASE_ID                           restore a recorded release boundary (see `sol releases` for ids)

sol secret set TARGET DOMAIN/UNIT/KEY [--from-stdin|--from-file PATH]
sol secret status TARGET                                                         show owners and readiness without values
sol secret delete TARGET ADDRESS                                                 delete an unused Sol-owned key
sol local run                                                                    load ignored sol/secrets.local/<domain>/<unit>.env files

# --scope selects one domain (`payments`) or one unit (`payments/charge_svc`).
# A name that matches nothing fails closed and says what exists, before any
# mutation runs. Mutating commands (up/deploy/rollback) refuse an empty
# selection. A scoped local `sol local deploy` records a complete workspace boundary: the
# workloads it did not select keep their recorded spec and their provenance,
# and `sol rollback` restores each workload under the release that applied it,
# so rolling back a scoped change never prunes or re-labels the services it
# never touched. The inherited boundary is read while the workspace lease is
# held, so the release a scoped `sol local deploy` records describes the workspace as it
# was at apply time: a deploy or rollback that won the lease first is what the
# new release builds on, never a snapshot taken before the lease was acquired.
# A scoped local `sol local deploy` keeps the callers it did not select: deploying a callee alone
# renders its NetworkPolicy from the whole workspace declaration, so a
# cross-domain caller that is already running keeps the ingress rule that
# admits it.
# A scoped local `sol local deploy` refuses before mutating anything when the current boundary
# cannot be read; deploy the whole workspace to establish it. A scoped deploy
# also compares and records the workspace's complete consumer-group set, not only
# the units it selected: a worker it did not select is not read as a removed
# group, while a group whose worker really is gone from the workspace still
# refuses until `--confirm-group-change` acknowledges it. That check reads the
# recorded set while the workspace lease is held, so an update that won the lease
# before the check is what the deploy measures against. `sol secret` addresses the exact
# workload as `<domain>/<unit>/<KEY>`; it never broadcasts a value across a namespace.

sol plan TARGET                                  preview target changes
sol deploy TARGET                                reconcile infrastructure and workloads
sol destroy TARGET [--plan|--apply]              destroy cloud infrastructure via Terraform
```

---

## Part 8 — Production deployment

The `sol deploy` command is `sol local deploy` without the build step. It is designed to run in CI after images have already been built and pushed to a production registry.

`sol deploy` takes a required `<env>/<provider>/<region>` target — same convention as `sol plan` — and that target must be declared in `sol/environments.yml` first, even with an empty body. `sol new workspace` scaffolds a placeholder `prod` environment with an `aws/us-east-1` target; rename them to match your real environment and target.

### Environments and targets

`sol/environments.yml` holds each environment's policy once, and the targets it runs on:

```yaml
prod:
  base_domain: example.com            # environment policy, shared by its targets
  letsencrypt_email: ops@example.com
  services:
    charge_svc:
      scale: { min: 2 }
  targets:
    aws/us-east-1:
      cluster_name: acme-prod         # where it runs: identity is per target
      services:
        charge_svc:
          scale: { max: 6 }
```

`sol deploy prod/aws/us-east-1` resolves `sol.yml` → `prod` → `aws/us-east-1`, a lower layer overriding a higher one. `scale` and provider blocks (`aws:`, `gcp:`) merge key by key, so the example deploys `charge_svc` with `min: 2` and `max: 6`. `omit: true` at any layer sticks. A few rules keep environments from drifting:

- `cluster_name`, `kube_context`, `kubeconfig`, `cluster_endpoint_cidr` and `registry` identify one cluster, so they are set on a target, never on an environment.
- What your application *is* (a service's `type`, `path`, `language`, `uses`; a resource's `type` and keys) belongs in `sol.yml`. An environment or target only adjusts `size`, `scale` and `omit`, and only for services and resources `sol.yml` declares.
- `profile` is chosen per environment or target, never in `sol.yml`.
- `shape` (`local` or `durable`) is declared per environment or target, never in `sol.yml`. Every cloud target must declare it; `production-single-region` requires `durable`. A plan against a target that omits it is refused before anything is provisioned.

Values you would rather not commit — an account's registry, role ARNs — go in `sol/environments.local.yml`, which the scaffolded `.gitignore` excludes. It has the same shape and may add keys the tracked file leaves unset, or whole environments and targets; setting a key the tracked file already sets is an error, so a value you see in `sol/environments.yml` is always the one in use.

Set `cluster_issuer` on the environment or target to override the cert-manager ClusterIssuer used for service Ingress TLS; it defaults to `letsencrypt-prod`, matching `platform/cloud/modules/platform`.

### Inspecting a target

Before deploying, look at what the target actually is — rather than at the kubectl plumbing underneath it:

```bash
sol target show --target prod/aws/us-east-1
```

```
provider       aws
region         us-east-1
cluster        acme-prod
registry       123456789012.dkr.ecr.us-east-1.amazonaws.com
base domain    acme.com
kubernetes     configured — not checked; pass --check to probe it
last operation unavailable — Sol keeps no target-scoped operation record (ADR 0003)
```

The summary is offline by default, so it still prints while you are diagnosing a cluster you cannot reach. `--check` probes it, `--json` prints the same fields for scripts, and `--verbose` adds where the target sits plus the raw kube-context Sol will use. `--check` adds three more rows, each answering from an authority rather than from a Sol-side record:

- **`platform`** carries ADR 0002's live readiness verdict — `Ready`, or `Unmet — <component>: <reason>` when a required component's named predicate ran and failed (AWS targets). A check Sol could not observe — refused, timed out, or unable to launch kubectl — is `Unobservable — <component>: <reason>` with the probe's own evidence, never reported as a confirmed `Unmet`.
- **`cloud`** is the provider's own answer for the installation Sol manages: `Healthy` when every durable prerequisite is observed established, or `Unmet — <prerequisite>: <reason>`/`Unknown — <prerequisite>: <reason>`. A prerequisite Sol could not look at is `Unknown`, never promoted to healthy.
- **`drift`** is a read-only, refresh-only Terraform plan: `None` when Terraform's recorded state matches observed reality, `Detected` when it has drifted, or `Unknown — <reason>` when the refresh could not be read — never reported as no drift.

`last operation` is reported either way, because it needs no read: Sol keeps no target-scoped operation record, and ADR 0003 forbids adding one, so it says so instead of pretending the target was never operated on.

Two things that line is telling you:

- **`not configured`** means the target names no `kube_context`, so `sol deploy` has no cluster to reach. After `sol deploy` provisions the target, run the printed `deploy_kubeconfig_command` output and add the resulting context name to the target; for a cluster you own, name its context directly.
- **The context is hidden unless you ask.** It is how Sol reaches the cluster, not what the target is, so it does not lead the summary — but it is what you need when you want to run `kubectl` by hand, which is what `--verbose` is for.

### Destinations: the cluster comes from the target, never from your shell

Every cluster-touching command resolves its destination from the target you
name, and Sol passes it to `kubectl` explicitly as `--context` (plus a scoped
`KUBECONFIG` when the target has one). It never consults, and never changes,
your machine's active `kubectl` context. So there is no "switch context, then
run `sol`" step, and no risk of a stale context sending a command to the wrong
cluster:

```bash
sol deploy prod/aws/us-east-1        # explicitly against that target's cluster
```

For Sol's own local cluster, the destination is the literal `k3d-sol-local`, so
the local forms need no target at all:

```bash
sol local rollback r-1a2b3c4d5e6f7890
sol local migrate
```

The two forms are one grammar: `sol <command> --target <t>` and
`sol local <command>`. A top-level cluster-touching command with no `--target`
fails closed and points at its `sol local` spelling rather than guessing.

Naming a target that does not exist fails closed and lists the ones that do:

```bash
sol target show --target prod/aws/nope
```

```
available targets:
  prod/aws/us-east-1
```

### Direct deploy (CI pushes to the cluster)

```bash
# In CI, after docker build && docker push:
sol deploy prod/aws/us-east-1 \
  --image-tag "$GIT_SHA" \
  --registry  "123456789.dkr.ecr.us-east-1.amazonaws.com"
```

Sol generates the same Kubernetes manifests as `sol local deploy` but uses the provided registry and tag for the image reference. A run whose target names a `kube_context` uses it; a run that has no destination it can reach treats itself as the first run for that target, reconciles the environment and establishes its own deploy-identity access (DEC-058) — see the [installation and first-deploy guide](installation.md) §4.

### GitOps deploy (Argo CD watches a manifest repo)

```bash
# In CI:
sol deploy prod/aws/us-east-1 \
  --emit-to   manifests/ \
  --image-tag "$GIT_SHA" \
  --registry  "123456789.dkr.ecr.us-east-1.amazonaws.com"
# → writes manifests/pluto-payments-charge-svc.yaml, manifests/pluto-comms-notify-worker.yaml
# → CI commits and pushes these to the GitOps repo
# → Argo CD detects the change and applies it
```

Application secret authority is declared per unit and key in the selected target. Sol-owned
values use that unit's `-secrets` object; external values use a namespaced ESO `ExternalSecret`
that writes only the declared external keys to `-external-secrets`. Direct and GitOps deployments
render the same references and never emit values or placeholder Secret objects. Direct deploy
verifies ESO sync, materialized keys and workload readiness. GitOps relies on Argo CD and ESO to
reconcile the emitted resources.

Kafka credentials are resource-owned. For a managed Kafka target the deploy reads
the password from the provider store and the broker CA from Kubernetes, then
writes `KAFKA_SASL_PASSWORD` and `KAFKA_SSL_CA_CERT` to `<target>-kafka-creds` in
each namespace that declares a consumer; a TLS contract Job reads only those two
keys. External Kafka keeps its ESO-delivered Secret. Database access is likewise
deploy-delivered: `<target>-dml-creds` to a unit that declares `uses: [app_db]`
and `<target>-ddl-creds` to the migration Job. `sol secret set` refuses the Kafka
keys because the binding, not an operator mapping, is their single producer.

The generated files contain the full manifest (Namespace, ServiceAccount, ConfigMap, Deployment/Service). If a service enables progressive delivery in `sol.toml`, Sol emits an Argo Rollouts `Rollout` instead of a Kubernetes `Deployment`. Argo CD applies these manifests with `ServerSideApply=true` and prunes resources that are removed.

### Day-2 operations

If a deploy introduces a regression, `sol rollback <release-id>` restores that recorded release boundary — find the id with `sol releases`. Rollback does not use `kubectl rollout undo`, which cannot restore config, volumes, or ingress; instead it reconstructs the target release's own resolved workloads from its immutable record, re-applies them, verifies the live workload set, and only then moves the current-release pointer and verifies it.

Rollback restores every workload in the boundary under the release that applied it, so a release that touched one unit leaves the other units exactly as they were. It refuses closed rather than mutating the cluster when: the release id doesn't resolve to a valid record; the record was applied as controller/GitOps-owned (Sol does not own those resources, so a direct apply would not establish a stable transition); a migration applied since that release is a *contracting* change (or fails to declare an expand/contract disposition at all — see `-- sol:disposition` in each migration file), or the target has a migration applied that this checkout cannot supply a readable disposition for, or its applied state cannot be read — rollback reads the applied set from the target, so an absent local file is not evidence that the schema did not change; or verification finds the live workloads don't match the restored release — including a workload left over from the superseded release — or the pointer doesn't name it. Verification runs before the pointer moves, so a failure leaves the pointer unchanged. There is no `--force`.

A verified rollback also corrects the workspace's consumer-group safety record to the restored release's own set: the workers that release deployed are what the next `sol deploy` compares against, so a rollback between releases with different consumers neither warns about a group the rollback brought back nor lets a real removal pass without `--confirm-group-change`. A rollback that fails verification leaves that record alone, and if the corrected record cannot be written the rollback says so rather than reporting a clean transition.

For logs and traces, use Grafana/Loki with the workspace, domain, and service
labels Sol injects into workloads.

Every `sol local deploy` and `sol deploy` also records a release in the target's cluster: `sol releases` lists the recorded releases (content-addressed id, environment, workload count). A record is an immutable Kubernetes ConfigMap, so history cannot be edited in place. Each workload's `release` label is that workload's own immutable identity, derived from its effective spec, so a deploy that changes one workload leaves the labels — and Pod templates — of the others untouched; a scoped local `sol local deploy` release record also retains untouched workloads and their earlier provenance. Use that workload label to filter telemetry in the configured observability tools.

There is no separate deployment-attempt history: a failed apply is not recorded as an attempt. The release record is written only on success, and a failed apply leaves the current-release pointer unchanged, so the prior release is still authoritative.

The release record lives in your own cluster, so `sol releases` is not required to read it — you can leave Sol behind without leaving your release history behind:

```bash
kubectl get configmap -A -l sol.dev/workspace=pluto   # every release Sol recorded here
NS=pluto-payments
kubectl -n "$NS" get configmap sol-release-current-pluto -o jsonpath='{.data.release_id}'
kubectl -n "$NS" get configmap sol-release-<id> -o jsonpath='{.data.record}' | jq .
```

That last command prints the release's own identity, each workload with the image
digest it was applied at, and the migrations that were applied with it — enough to
describe what is running and to pick a rollback target with `kubectl` alone.

### Progressive delivery with Argo Rollouts

Services can opt into a typed high-level rollout strategy:

```toml
[infra.rollout]
strategy = "canary"
steps = [{weight = 10}, {pause = {duration = 300}}, {weight = 50}, {pause = {}}, {weight = 100}]
```

Canary steps are weight percentages from 0 to 100. For blue-green deployments, use:

```toml
[infra.rollout]
strategy = "blue-green"
```

Blue-green emits active and preview `Service` resources and disables automatic promotion. This is not a raw Argo YAML escape hatch: Sol supports only the fields above, and arbitrary Argo Rollouts features such as analysis templates and traffic-manager integrations are deferred.

See [`deployment/ci.md`](../deployment/ci.md) for the generated workflow and the identity it expects; GitOps mode uses the same workflow with `sol deploy --emit-to`.

### Provisioning a production cluster

Use `sol plan` to preview a target and `sol deploy` to reconcile its infrastructure, authorization and workloads. `sol deploy` consumes pre-built images; pass immutable image refs for workloads that do not already have a recorded image. Sol keeps separate durable cloud and platform Terraform states and observes readiness before reporting success.

**AWS (EKS, ECR, RDS, Route53):**

```bash
sol plan prod/aws/us-east-1
sol deploy prod/aws/us-east-1 --image-ref=payments=123456789.dkr.ecr.us-east-1.amazonaws.com/payments@sha256:…
```

Set Terraform variables through the target's `terraform_var_file` and provider configuration in `sol/environments.yml`; deploy no longer has a separate cloud apply command or cloud-only variable flags. The first interactive deploy previews and confirms durable installation setup inline.

**Point DNS at the ingress** before any service with an `ingress_host` in its `sol.toml` is reachable:

```bash
# The controller's externally provisioned address (AWS ELB / GCP LB):
kubectl get svc -n ingress-nginx ingress-nginx-controller   # EXTERNAL-IP
```

Create an `A`/alias or `CNAME` record for each `ingress_host` — or one wildcard record such as `*.acme.com` — in the zone created by your provider module (`platform/cloud/aws/cluster` exposes `route53_zone_id` and `route53_nameservers`; point your registrar's NS at the latter on first setup). Sol deliberately does not run external-dns, so this is a required manual step, and cert-manager only finishes TLS once the name resolves. Locally there is nothing to do: `sol local infra up` forwards the same controller to `http://localhost:8088`, and a service with no `ingress_host` gets the dev host `<svc>.<namespace>.localhost` — send it as the `Host` header, e.g. `curl -H 'Host: charge-svc.acme-payments.localhost' http://localhost:8088/health`.

> **Advanced / manual recovery:** direct Terraform is an escape hatch, not the supported lifecycle. An operator using it must initialize each root against its correct durable backend (distinct `sol/<target>/cloud.tfstate` and `sol/<target>/platform.tfstate` keys), preserve cloud-before-platform ordering and explicit output wiring, stage cert-manager before CRD-dependent resources, and perform the same live readiness checks. Do not use a bare `terraform init`, local state, or ambient kubeconfig as a substitute for `sol deploy`. See `docs/deployment/production-bootstrap.md` for the recovery procedure.

**Set up Argo CD GitOps** (one-time per cluster):

```bash
# Edit platform/cloud/delivery/argocd/application.yaml — set GITOPS_REPO_URL and WORKSPACE_NAME
kubectl apply -f platform/cloud/delivery/argocd/application.yaml
```

From this point, every `git push` to `main` in CI runs `sol deploy --emit-to`, commits the YAML to the GitOps repo, and Argo CD reconciles the cluster automatically.
