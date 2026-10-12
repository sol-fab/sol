# Sol's TypeScript framework parity

`order_svc` and `fulfillment_worker` are a real TypeScript service and worker
running on Sol's deploy machinery (CLI, Docker builds, Kubernetes manifests
are all language-neutral) and consuming Sol's own conventions via seven published
npm packages:

- [`@sol-fab/kafka`](https://github.com/loganbnielsen/sol-kafka) — declared
  partitioning and keys, explicit topic provisioning, the read-only runtime
  contract, the Confluent wire format, the `Ack | Fail` outcome, the group-scoped
  decode DLQ, and the contract projection program Sol's deploy lifecycle runs.
- [`@sol-fab/obs`](https://github.com/loganbnielsen/sol-obs) — metric naming/label
  vocabulary, Loki push shape, and W3C traceparent propagation.
- [`@sol-fab/svc`](https://github.com/sol-fab/sol-typescript) — the service
  lifecycle contract `order_svc` runs on: bounded drain and idempotent
  `SIGTERM`/`SIGINT`, matching the OCaml `sol-svc`.
- [`@sol-fab/worker`](https://github.com/sol-fab/sol-typescript) — the
  worker lifecycle contract `fulfillment_worker` runs on, matching the OCaml
  `sol-worker`.
- [`@sol-fab/jobs`](https://github.com/sol-fab/sol-typescript) — the durable
  Postgres job queue, matching `sol-jobs`: a transactional, dedupe-keyed enqueue
  and a leased runner.
- [`@sol-fab/outbox`](https://github.com/sol-fab/sol-typescript) — the
  transactional outbox, matching `sol-outbox`: `publish` records the intent in
  the caller's transaction, and `runRelay` publishes each key's events in `ord`
  order, removing a row only after the broker acknowledged it.
- [`@sol-fab/retry`](https://github.com/sol-fab/sol-typescript) — the
  operation-level retry helper, matching `sol-retry`: one bounded, jittered
  policy vocabulary (`baseDelayS`, `maxDelayS`, `maxAttempts`, `jitterRatio`)
  that retries a dependency call in place, never a message or a handler.

Alongside them, the local `@demo-ts/contract` workspace package is the single
source of truth for both events — the interfaces, the topic contracts and the
validated runtime decoders (`decodeOrderPlaced`, `decodeOrderFulfilled`), so a
producer and a consumer cannot accept different payloads under the same event
name: `order_svc` imports `OrderPlaced`/`decodeOrderPlaced` to produce and relay
it, `fulfillment_worker` imports `OrderFulfilled`/`OrderPlaced` and their
decoders for its consumer and its outbox relay, and `main.ts` is the workspace's
projection program. `sol local deploy
--scope=demo_ts` runs it (`npm run contract`) before any workload, so both topics
and subjects are registered by the deployment lifecycle; both services only
resolve the topic and schema id at startup and fail if a contract is not
registered — the same BUG-105 split an OCaml `sol-svc`/`sol-worker` follows. Both
images install `/usr/local/bin/contract` so `sol deploy` can reconcile the
contract from inside the destination, where a private registry is reachable.

`order_svc` accepts an order in one Postgres transaction (FEAT-132's OCaml
`orders_svc` is its twin): `INSERT INTO orders_ts … ON CONFLICT (order_id) DO
NOTHING`, the `send_confirmation` job (`dedupe_key = order_id`) and the
`OrderPlaced` outbox intent (`kind = order_placed`, `key = order_id`, `ord = 1`)
commit together, and only then does the service answer `202 {order_id, status}`.
A duplicate `POST` is absorbed at all three effects and still answers `202`.
`GET /orders/{order_id}` reads the order back — `accepted`, `fulfilled` or
`confirmed`, derived from the acceptance row's `fulfilled_at`/`confirmed_at` — or
`404`. The service hosts its own outbox relay, which publishes `OrderPlaced` to
`sol-demo-ts-orders` and removes the row only after the broker acknowledged it.

`fulfillment_worker` demonstrates the Kafka → job → outbox handoff: handling
an order writes `fulfilled_orders_ts`, enqueues a `release_inventory` job **and**
records an `OrderFulfilled` outbox intent, marks the acceptance row `fulfilled`,
all in one Postgres transaction, so none of the effects can exist without the
state change that caused it. It hosts the queue's runner and the outbox relay
alongside its consumer; the relay publishes each key's events to
`sol-demo-ts-fulfilled` in `ord` order through the same registered contract
`order_svc` produces under, and removes a row only after the broker acknowledged
it. The runner executes both kinds: `send_confirmation` writes the confirmation
effect (`order_confirmations_ts` plus the acceptance row's `confirmed_at`) and
`release_inventory` records its release, so the read-back reaches `confirmed`.
The transaction is retried in place with `@sol-fab/retry`'s bounded, jittered
policy — the same `{ baseDelayS: 0.25, maxDelayS: 5, maxAttempts: 4,
jitterRatio: 0.25 }` the OCaml `notify_worker` uses — so a transient Postgres
failure does not cost the message; only an operation that keeps failing after
the attempt budget returns `Fail`.

The two relays share one `sol_outbox` table, so each owns a disjoint slice of it
and refuses the other's: `OrderPlaced` is `order_placed`/`ord = 1` and
`OrderFulfilled` is `order_fulfilled`/`ord = 2` for the same per-order key (a
per-key ordering token is the caller's to assign, and two producers must not
reuse one), and a relay whose `publish` callback sees a kind it does not own
fails loudly instead of publishing another contract's event to its own topic.

Every table the demo touches is the workspace's migration, not the app's DDL:
`db/migrations/0002_sol_jobs.sql`, `0003_sol_outbox.sql`,
`0006_orders_ts.sql` (`orders_ts`, `fulfilled_orders_ts`,
`order_confirmations_ts`) and `0007_orders_ts_traceparent.sql`. Nothing creates a
table at runtime, so `sol migrate apply` must run before the units do — the local
walkthrough below does that, and so does the TypeScript golden-path smoke.

The acceptance row also carries the request's W3C `traceparent`
(`orders_ts.traceparent`, migration 0007), because the relay — not the HTTP
handler — publishes the record: the relay reads that row back and replays the
caller's context as the record's `traceparent` header, so one trace still spans
`order_svc`'s `receive_order`, the Kafka boundary and `fulfillment_worker`'s
`fulfill_order` (G3). A row with no stored context is published without the
header and the consumer starts a new trace, which is the deliberate degradation.

Duplicate delivery is absorbed at every effect. Kafka is at-least-once, and a
duplicate is a legal outcome (DEC-022), so a redelivered `OrderPlaced` is handled
like this:

- the row insert is `ON CONFLICT (order_id) DO NOTHING` against the primary key,
  and the handler proceeds to the job and the intent only when that insert
  actually applied (the redelivery is a no-op, not a second attempt at the same
  `(key, ord)` intent, which `sol_outbox`'s unique index would refuse), and
- the follow-up job's dedupe key is the order id, so a second enqueue is a no-op.

One fact therefore leaves one row, one job, one intent and one effect. `npm test`
(see `test/delivery.test.ts`) delivers the same fact twice against a real Postgres
and asserts exactly that; the case self-skips without `POSTGRES_URL`, and CI
provides one. This is the guard `BUG-112` had to add on the OCaml side
(`notify_worker` enqueues with `~dedupe_key:msg.id`). `test/outbox.test.ts` adds
the relay's Postgres boundaries against the same database: the three writes commit
or roll back together, a key's events publish in `ord` order and are removed only
after the publish resolved, and a blocked head holds its key's later events.


These packages exist so a TypeScript service and an OCaml `sol-svc`/
`sol-worker` land in the same Grafana panels and the same Tempo traces
without an author having to reconstruct Sol's policy by hand — see each
package's own tests for the specific bugs a hand-rolled first attempt hit
(FEAT-033's spike) before these existed. `kafka` and `obs` each live in their own
repository with their own CI, including the broker-backed DLQ/partitioning tests;
`svc`, `worker`, `jobs`, `outbox` and `retry` share
[`sol-fab/sol-typescript`](https://github.com/sol-fab/sol-typescript).

This example is the *runnable* TypeScript path, not the scaffolded one: `sol new`
writes OCaml units only, so these two units were authored by hand (FEAT-084
tracks the scaffolding gap). It is also deployed for real in CI
(`golden-path-smoke-ts`).

This directory is deliberately its **own npm project root**: its own
`package.json` and `package-lock.json`, resolving `@sol-fab/*` from npm with no
dependence on an enclosing JavaScript workspace. It is the conformance fixture
for DEC-024 — the Sol workspace boundary is `sol.yml` (`examples/pluto`), and a
Sol workspace must not need an enclosing npm workspace to consume the packages.
Note this is a *property the example demonstrates*, not a rule Sol imposes: a
user is free to organise their workspace however they like, including a root
`package.json` shared by several services.

## Run it locally

Both units run through Sol, from the workspace root (`examples/pluto`), once
their npm dependencies are installed:

```bash
cd examples/pluto
(cd app/demo_ts && npm ci)      # the units' dependencies; the loop needs them
sol local deploy              # k3d cluster + broker, schema registry, Postgres, Loki, Tempo, Prometheus
sol local migrate         # the demo's tables are migrations; nothing creates them at runtime
sol local run --scope=demo_ts
```

`sol local run` builds each unit with `npm run build` in `app/demo_ts` — the npm
project that owns both packages — and runs the built entry with `node`, prefixed
`[demo_ts/<unit>]` so you can follow both in one terminal. Sol starts them
itself, so Ctrl-C stops both. It also injects the local substrate's addresses
(`KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL`, `POSTGRES_URL`, `LOKI_URL`, `TEMPO_URL`,
`KAFKA_SECURITY_PROTOCOL=plaintext`), which is what the units read.

Locally `POSTGRES_URL` is a plain connection string. Deployed to a Sol-provisioned
cluster it is a libpq URL that names the target's database CA and asks for chain
verification — `?sslmode=verify-ca&sslrootcert=/etc/sol/db-ca/ca.pem`, with the CA
mounted from the `<target>-db-ca` ConfigMap. `verify-ca` verifies the chain but not
the hostname, because the provider issues the server certificate for the instance,
not the address in the URL; node-postgres instead aliases `verify-ca` to
`verify-full` and fails with `ERR_TLS_CERT_ALTNAME_INVALID`. Each unit's `db.ts`
therefore reads the URL through `poolConfig`, which passes the CA to the driver and
keeps libpq's semantics. A TypeScript consumer that builds its own pool must do the
same.

Under a Sol manifest — `sol local run` or `sol deploy` — Sol also injects the six
semantic workload identity values (`SOL_WORKSPACE`, `SOL_ENV`, `SOL_DOMAIN`,
`SOL_SERVICE`, `SOL_PRIMITIVE`, `SOL_RELEASE`), the same values it renders as pod
labels (DEC-064). `@sol-fab/obs` reads them: the Loki stream and the OTLP trace
resource carry `SOL_SERVICE` — the workload's bare Kubernetes name, not the
`order-svc-ts`/`fulfillment-worker-ts` fallback — plus the other five, so an
app-pushed log or trace is scoped exactly as the collector-promoted logs and
metrics for the same pod, and Grafana/Loki's `{workspace,domain,service}` selector
selects it. Run outside a manifest the variables are absent and the fallback
service name is used.

In another terminal, send one order through the whole path:

```bash
curl -X POST localhost:8080/orders -H 'content-type: application/json' \
  -d '{"order_id":"demo-1","item":"widget","quantity":3}'
# {"order_id":"demo-1","status":"accepted"}

curl localhost:8080/orders/demo-1
# {"order_id":"demo-1","item":"widget","quantity":3,"status":"fulfilled"} then "confirmed"
```

The `POST` answers `202` once the transaction committed; the two `GET`s that
follow are the read-back moving through `accepted` → `fulfilled` → `confirmed` as
the worker and the job runner do their work. A second `POST` of the same order id
is absorbed and still answers `202`.

Then check Grafana (Loki logs + Prometheus metrics) and Tempo — the
`receive_order` span from `order_svc` and `fulfill_order` span from
`fulfillment_worker` link into a single trace across the Kafka boundary.

To see that continuity as a check rather than a claim, supply your own
`traceparent` and follow that exact trace id:

```bash
trace_id=$(openssl rand -hex 16)
span_id=$(openssl rand -hex 8)
curl -X POST localhost:8080/orders -H 'content-type: application/json' \
  -H "traceparent: 00-${trace_id}-${span_id}-01" \
  -d '{"order_id":"demo-1","item":"widget","quantity":3}'

curl -s "http://localhost:3200/api/traces/${trace_id}" | jq -r '
  [.batches[].resource.attributes[] | select(.key == "service.name").value.stringValue]
  | unique | .[]'
# order-svc-ts
# fulfillment-worker-ts
```

`order_svc` extracts the inbound carrier with the OpenTelemetry propagation API,
so the trace is the caller's: `receive_order` keeps `${trace_id}`, the Kafka
message carries the same trace id in its `traceparent` header, and
`fulfillment_worker` continues it as `fulfill_order`. With no `traceparent`
header the service starts a valid new trace, and an unparseable one is ignored
the same way.

A unit whose `sol.yml` entry declares no language is refused by the loop rather
than guessed at, and a unit with no installed dependencies is reported with the
`npm ci` to run — Sol never decides a workload's language from its files.

## Docker

Each service has its own `Dockerfile`, built with the **Sol workspace root**
(`examples/pluto`, the directory holding `sol.yml`) as build context — not the
Sol repository root, and not the service directory. Both images install
`@sol-fab/*` from npm:

```bash
cd examples/pluto
docker build -f app/demo_ts/order_svc/Dockerfile -t order-svc .
docker build -f app/demo_ts/fulfillment_worker/Dockerfile -t fulfillment-worker .
```

The build splits in two so the npm install stays cached against the manifests
rather than the source: both units' `package.json`/`package-lock.json` are copied
and `npm ci` runs before any source is copied.

The runtime stage ships the workspace's single shared install plus **only this
unit's** tree. The sibling's workspace symlink inside `node_modules` then points
at nothing, which is inert because nothing resolves it at runtime.

Running the images needs the same environment variables as the local walkthrough
above, pointed at reachable infrastructure.
