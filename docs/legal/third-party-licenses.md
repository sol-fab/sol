# Third-party components Sol installs and depends on

Sol's own licence (Apache-2.0) says nothing about the software Sol deploys *for*
users. This is the inventory of what the platform modules install, which licences
apply, and where those terms interact with Sol's own product decisions.

**Status:** first pass, covering what `platform/cloud/modules/platform` and `sol local deploy`
install. The opam and npm dependency graphs are not yet inventoried — see
[Not yet inventoried](#not-yet-inventoried).

## Deployed components

| Component | Chart | Software licence | Notes |
| --- | --- | --- | --- |
| cert-manager | `cert-manager` | Apache-2.0 | |
| ingress-nginx | `ingress-nginx` | Apache-2.0 | |
| Argo CD | `argo-cd` | Apache-2.0 | GitOps mode |
| **Redpanda** | `redpanda` *(chart: Apache-2.0)* | **BUSL-1.1** | The chart's licence is not the broker's. See below. |
| PostgreSQL | `postgresql` (Bitnami, Apache-2.0) | PostgreSQL Licence | Chart is open source; the image channel changed in 2025. See below. |
| **Grafana** | `grafana` | **AGPL-3.0** | |
| **Loki** | `loki` | **AGPL-3.0** | |
| **Tempo** | `tempo` | **AGPL-3.0** | |
| Alloy | `alloy` | Apache-2.0 | Grafana's collector, but not AGPL. |
| Prometheus | `prometheus` | Apache-2.0 | |
| Pushgateway | `prometheus-pushgateway` | Apache-2.0 | dev only |
| Thanos | `thanos` (Bitnami) | Apache-2.0 | durable-observability path |

## Three that need a decision, not a footnote

### 1. Redpanda is BUSL-1.1, and the hosted tier may need a commercial licence

Redpanda's Helm chart is Apache-2.0, but the broker it deploys is under the
**Business Source License 1.1** — source-available, not OSI open source. BUSL
permits most internal and production use, but generally **prohibits offering the
software as a hosted or managed service to third parties** without a commercial
agreement.

Sol's event layer is built on it, and DEC-008 has Sol running customer
infrastructure inside Sol's own account — which is exactly the shape BUSL is
written to restrict. **This needs a legal read before the hosted tier is sold.**
The fallback is knowable rather than hypothetical: Apache Kafka (Apache-2.0)
behind the same interface, since Sol's applications talk to Kafka through the
schema registry contract rather than to Redpanda specifically.

### 2. The Bitnami image channel changed in 2025

The Bitnami PostgreSQL *chart* is still Apache-2.0, and PostgreSQL is under the
PostgreSQL Licence — but the free, maintained `bitnami/*` images were retired:
existing tags moved to `bitnamilegacy/*` (unmaintained, no CVE fixes, liable to
disappear) and updated images became subscription-based (Bitnami Secure Images).

That is a **supply-chain and currency risk, not a licence one**: whichever tags
Sol pins today are likely frozen on an unsupported image. Worth deciding
deliberately — the official `postgres` image, CloudNativePG, or Crunchy — rather
than inheriting whatever the chart defaults to.

### 3. AGPL in the observability stack

Grafana, Loki and Tempo are **AGPL-3.0**. Deploying them into a cluster the
customer owns and operates is normally straightforward: Sol does not modify them,
and the customer is the user. **Hosting them on a customer's behalf** is the case
AGPL §13 addresses, so it belongs in the same review as Redpanda — and it is
independent of the licence Sol's own code carries.

## TypeScript packages published to npm (`@sol-fab/*`)

The four TypeScript framework packages are extracted to their own repositories
and published under the `@sol-fab` npm scope — `obs` and `kafka` each in their
own, `svc` and `worker` together in
[`sol-typescript`](https://github.com/sol-fab/sol-typescript):

- [`@sol-fab/obs`](https://github.com/loganbnielsen/sol-obs) — observability
  naming/shape conventions.
- [`@sol-fab/kafka`](https://github.com/loganbnielsen/sol-kafka) — Kafka policy
  layer on top of `kafkajs`.
- [`@sol-fab/svc`](https://github.com/sol-fab/sol-typescript) — the service
  lifecycle contract (bounded drain, idempotent signals).
- [`@sol-fab/worker`](https://github.com/sol-fab/sol-typescript) — the
  worker lifecycle contract.
- [`@sol-fab/fn`](https://github.com/sol-fab/sol-typescript) — the run-once
  function contract.

All five are **Apache-2.0**, as is everything they *ship* (their compiled
`dist/`) and everything consumers install at runtime. `svc` and `worker` are dependency-free (Node ≥ 20 only); `fn` depends on
`prom-client` for the invocation metrics:

| Package | Kind | Licence |
| --- | --- | --- |
| `@sol-fab/obs` | shipped source | Apache-2.0 |
| `@sol-fab/kafka` | shipped source | Apache-2.0 |
| `@sol-fab/svc` | shipped source | Apache-2.0 |
| `@sol-fab/worker` | shipped source | Apache-2.0 |
| `@sol-fab/fn` | shipped source | Apache-2.0 |
| `prom-client` (dependency of `@sol-fab/fn`) | runtime | Apache-2.0 |
| `@opentelemetry/api` (peer of both) | runtime | Apache-2.0 |
| `kafkajs` (peer of `@sol-fab/kafka`) | runtime | MIT |
| `@sol-fab/obs` (dependency of `@sol-fab/kafka`) | runtime | Apache-2.0 |

Build/test-only dependencies (not distributed, listed for completeness):
`typescript` (Apache-2.0), `tsx` + `esbuild` + `undici-types` + `@types/node`
(MIT). No copyleft component is shipped or required at runtime.

This closes the npm half of INFRA-007's "dependency licence audit" for the
packages being externally distributed. A licence scan in CI for these
repositories is still worth adding on top of the manual inventory.

## Verifying a component

Chart licence — which is *not* necessarily the software's:

```bash
helm show chart <repo>/<chart> | grep -i license
```

For the software, check the project's own `LICENSE` and how its container image
is distributed and supported. Redpanda is the live example of the two differing.

## Not yet inventoried

- **OCaml (opam) dependencies.** No licence scan runs in CI; this needs doing
  before the OCaml packages are published externally. (The npm runtime trees of
  the `@sol-fab/*` packages being distributed are inventoried above.)
- **Base images in generated Dockerfiles.**
- **Vendored or adapted code** inside `examples/` or `integration/` that may
  originate elsewhere.
- **Automated licence scanning in CI** for the two `@sol-fab/*` repositories —
  the manual inventory above is a point-in-time check, not a standing gate.

