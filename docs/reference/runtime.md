# Service Runtime Contract

[`substrate.md`](substrate.md)
documents what must exist *around* your containers (cluster, registry, Kafka,
secrets). This document covers the other direction: what the code *inside* a
`*_svc`/`*_worker`/`*_fn` directory must actually do — and, for every item,
whether Sol's tooling actually checks it or merely assumes it.

Read both together. They're the complete picture of what Sol requires.

## The core fact to hold onto

Sol is a **naming-convention-driven container orchestrator** with one narrow,
runtime-checked health contract bolted on for `-svc`. Everything else — does
the code inside actually work, does it read the right environment variable
names, does it use Kafka correctly — is entirely developer-trusted. A
violation of any of it surfaces only as an *operational* failure (crash loop,
a probe that never turns green, silently missing metrics), never as a build
or deploy rejection. There is no compiler, schema, or admission check that
verifies a `*_svc` directory actually behaves like a service before Sol
deploys it.

Concretely: replace a generated service's `bin/main.ml` with
`print_endline "hello world"`. `dune build` succeeds. `docker build` succeeds.
`sol deploy`/`kubectl apply` succeeds. The pod then exits immediately, never
binds a port, and every downstream check (readiness probe,
Sol's deployment readiness verification) reports it unhealthy — the *only* place this gets
caught, and only after it's already running.

## Discovery contract — purely structural, content never inspected

`Sol_cli_manifest.discover_services` requires exactly:

- A directory at `app/<domain>/<name>_svc/`, `_worker/`, or `_fn/` — the
  suffix determines the primitive, which determines what Kubernetes object
  wraps it (Deployment+Service for `-svc`, Deployment for `-worker`, CronJob
  for `-fn`, using the `schedule:` field from `sol.toml`).
- A `Dockerfile` present directly in that directory.

That's the entire predicate. Discovery never opens the Dockerfile or any
source file — a directory with the right name and an empty Dockerfile
satisfies it exactly as well as a real, working service does.

## Runtime health contract (`-svc` only)

The generated Deployment uses `/healthz` for startup and liveness probes. For
workloads with an explicitly declared language, readiness uses `/readyz`; a
workload with no language declaration falls back to `/healthz`:

```yaml
ports:
  - containerPort: 8080
startupProbe:
  httpGet:
    path: /healthz
    port: 8080
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
readinessProbe:
  httpGet:
    path: /readyz
    port: 8080
```

| Requirement | Sol's checks |
|---|---|
| Bind an HTTP server on port 8080 | Generated Kubernetes probes exercise it after deploy. The golden-path smoke also makes HTTP requests. |
| Serve `GET /healthz` | Startup and liveness probes use it. The OCaml framework tests cover the built-in endpoint. |
| Serve `GET /readyz` | Readiness probes use it when the workload declares a language. The OCaml framework tests cover its 503 response after shutdown begins. |
| Serve `GET /metrics` in Prometheus text format | The OCaml framework tests and golden-path smoke check the response; Prometheus also scrapes it. |
| Drain in-flight requests on `SIGTERM` | The OCaml framework tests exercise shutdown and bounded drain. Kubernetes gives generated Pods 45 seconds to terminate. |

These checks do not prove that an arbitrary application uses the Sol framework.
Discovery and planning inspect the workspace layout and declarations, not the
application's source or runtime behavior.

The OCaml `Service.run` endpoint and shutdown behavior is documented in the
[`sol-svc` package reference](../../framework/ocaml/sol-svc/sol-svc.md#built-in-endpoints).

Two details worth being precise about, since they're easy to get subtly
wrong:

- **The port is a hardcoded convention, not an injected one.** `Service.run`
  reads `Sys.getenv_opt "PORT"` and falls back to a default of `8080` if
  unset. The generated Deployment never actually sets a `PORT` environment
  variable — it just declares `containerPort: 8080` and trusts the
  application's own default to match. The `$PORT` override exists as an
  escape hatch (useful if you're not using `sol-svc`'s generated scaffold),
  but nothing in the generated manifest exercises it; the two sides agree by
  convention, not by wiring.
- **The termination budget includes both shutdown delay and drain.**
  `Service.run` defaults to a 5-second shutdown delay and a 30-second drain;
  generated Pods have a 45-second `terminationGracePeriodSeconds`. If an
  application supplies larger shutdown or drain values, keep their combined
  duration below the Pod's termination grace period or Kubernetes may force
  termination before draining completes.

## Config and secret injection

Application values are scoped to one `domain/unit`. A workload references its
own Kubernetes Secret, named `<k8s-unit-name>-secrets`, through `envFrom`; for
example, `payments/charge_svc` receives values from `charge-svc-secrets` in the
`<workspace>-payments` namespace. `sol secret set TARGET payments/charge_svc/KEY`
changes only that Secret and restarts the unit when it is a long-running
Deployment. It never writes the platform Secret or another unit's Secret.

Sol's internal Jobs use a separate fixed-name Secret, `sol-secrets`, for platform
inputs that no unit owns. A TLS contract Job reads `KAFKA_SASL_PASSWORD` and
mounts `KAFKA_SSL_CA_CERT` from it; `sol secret set TARGET @platform/KEY` writes
only these Kafka platform Job inputs to `sol-secrets` objects in the target's
active workload namespaces. It does not fan values out to application Secrets.
Database connections are not a platform input: a unit that declares
`uses: [app_db]` reads the deploy-delivered `<target>-dml-creds` class Secret,
and the migration Job reads `<target>-ddl-creds`.

The substrate checks the platform inputs a Job consumes before proceeding. An
application Secret contains exactly the unit's declared keys; a unit-scoped
`POSTGRES_URL` is one it declares itself, while a unit that consumes the target's
database reads the class Secret instead. `sol secret status TARGET` reports
owners and presence without printing values.

Each required application key must declare `sol` or `external` authority in the
target. Sol can write only `sol` keys. External values are delivered by ESO into
the unit's separate `-external-secrets` object; deployment verifies the ESO sync
condition and exact materialized key set before checking workload readiness.

Sol verifies that each required value exists and is non-empty; it cannot verify
that application code reads the environment variable by the expected name. A
misspelled key in application code remains an application-level runtime issue.

### `SOL_ENV` — the environment, for behaviour only

Every generated workload's `<name>-env` ConfigMap carries `SOL_ENV`, set to the
resolved target's environment. Two properties are deliberate:

- **It is absent when no target is resolved.** `sol local deploy` against the local
  cluster deploys without a resolved target, so nothing sets it. Application
  code should treat "no environment" as a real state rather than assuming a
  value is always present.
- **It is for behaviour, never topology.** Use it to label logs, gate feature
  flags, or refuse destructive operations outside production. Do **not** derive
  any address, hostname, namespace or URL from it: namespaces, service names
  and injected internal URLs are identical in every environment by design
  (DEC-016), and anything that has to be rewritten to move between environments
  is somewhere dev and production can silently diverge. The same rule covers the
  `env` label Sol sets on the workload — it identifies, it never addresses.

The resolved target is authoritative: a `SOL_ENV` declared in a service's own
`config` is replaced by the target's environment rather than shadowing it.

### Sol workload identity

`DEC-064` (2026-10-02) settles who owns a workload's semantic identity: **Sol's
framework/runtime instrumentation emits it, and a collector may only add
infrastructure identity beside it** (`namespace`, `pod`, `node`, cloud region) —
a collector never defines or replaces Sol's vocabulary. So the generated
`<name>-env` ConfigMap carries the same identity the manifest renders as pod
labels, and `Sol_obs.of_env` reads it back:

| Environment variable | Label it carries | Value |
|---|---|---|
| `SOL_WORKSPACE` | `workspace` | the workspace name |
| `SOL_ENV` | `env` | the resolved target environment; absent when no target is resolved |
| `SOL_DOMAIN` | `domain` | the unit's domain |
| `SOL_SERVICE` | `service` | the workload's Kubernetes name (`charge_svc` → `charge-svc`) |
| `SOL_PRIMITIVE` | `primitive` | `svc`, `worker`, or `fn` |
| `SOL_RELEASE` | `release` | the workload's own immutable content-addressed identity (`r-<16 hex>`), derived from its effective spec and independent of unrelated workloads, so a change to one workload does not re-label the others |

The values are byte-for-byte the rendered label values, so an app-emitted trace
carries the same `service` a Prometheus scrape and a Loki stream do. The
platform owns these names: a service `config` that declares one of them is
ignored rather than allowed to shadow it. `Sol_obs.of_env` therefore needs the
`~service` argument only for a process run outside a Sol manifest (a local demo
or a `dune exec`); when `SOL_SERVICE` is present it wins.

`env` has no `SOL_ENV` when no target is resolved — `sol local deploy` against the local
cluster omits it by design (`docs/architecture/observability-design.md`
§ Identity), and application code treats "no environment" as a real state.

## Migration file convention

Migration filenames use `<decimal version>_<name>.sql`, with an optional
companion `<decimal version>_<name>.down.sql` for rollback. `001_...` and
`0001_...` both work; rollback uses the original filename. Invalid `.sql`
names and duplicate versions are errors. `sol migrate apply --dry-run`
connects to the database and prints only pending files in numeric version
order. It does not execute or validate their SQL; the database validates SQL
when the migration runs.

## What genuinely *is* compiler-enforced — and the real scope of that

Some things really are type-checked, but only because a developer chose to
construct a specific library's types — Sol's tooling never verifies that
choice was made at all:

- `Kafka_security.t` is a required field on every `kafka-eio` producer,
  consumer, and service config type. If you build one of those configs, the
  compiler forces you to state a security posture. Nothing stops a container
  from talking to Kafka a completely different way (a raw client, a different
  library) that never constructs this type at all — Sol's orchestration layer
  has no visibility into that choice either way.
- A conforming Sol HTTP adapter applies Sol workload authentication to every
  application route by default. Application code marks only exceptions with
  `Route.external_`; customer authentication remains application-owned. This
  guarantee applies only to traffic served through that adapter.

## Synchronous service calls

Cross-domain events are the default integration path. A synchronous
service-to-service request is an explicit opt-in:

```toml
[service]
calls = ["checkout/checkout_svc"]
```

That declaration makes Sol inject `CHECKOUT_SVC_URL` into the caller and opens
the generated NetworkPolicy only for that caller/target pair. Application code
should use `Peer` for the URL/header plumbing and ordinary
`cohttp-eio` for the request:

```ocaml
Sol_obs.with_span obs ?parent:req.trace_ctx "call_checkout" (fun span ->
  let trace_ctx = Sol_obs.current_trace_context span in
  match Peer.url "checkout_svc", Peer.headers ~env ~peer:"checkout_svc" ~trace_ctx () with
  | Ok base_uri, Ok headers ->
    let uri = Uri.with_path base_uri "/quote" in
    let headers = Http.Header.of_list headers in
    Cohttp_eio.Client.call client ~sw ~headers `GET uri
  | Error err, _ | _, Error err -> ...)
```

**Dev-substrate caveat:** the generated policy is correct per the Kubernetes
spec, but the dev substrate's policy engine (kube-router on k3s) does not honour
cross-namespace `namespaceSelector` rules, so a declared call is refused locally
even though it is wired correctly. `ipBlock` rules *are* honoured;
`namespaceSelector` rules never are; and egress policy is not enforced at all.
That holds on every k3s version tested (v1.27.4 and v1.35.5), so upgrading does
not help (BUG-024). Customer-cloud CNIs that implement the feature are
unaffected. Because a live assertion cannot pass here, the golden-path smoke
asserts the wiring — the injected URL plus the applied policy pair — rather than
enforcement.

`Peer.headers ~peer:"checkout_svc"` prefers the projected identity: Sol declares
the caller a projected ServiceAccount token for `checkout_svc` (audience = the
callee unit) and names the file through `CHECKOUT_SVC_TOKEN_FILE`, and the
helper attaches it as `Authorization: Bearer`. A declared projection that is
missing or unreadable is a config error, never a fallback to the shared key.
Only local development opts in to that key explicitly with
`SOL_ALLOW_PLAINTEXT_PEER_AUTH=1`; the name is reserved in `sol.toml` and
`sol secret set`, so a deployed workload cannot carry it. Either path serializes
the supplied `trace_ctx` as a W3C `traceparent`, which the callee's `Sol_svc`
extracts into `Request.trace_ctx`.

After the token is attached, the callee's Sol HTTP adapter requires the token's
`iss` to equal `SOL_TRUSTED_WORKLOAD_ISSUER`, which Sol projects from the target's
established capability. The adapter fetches that issuer's OIDC discovery document
and JWKS, checks the signature, and checks `aud` equals the callee's own unit
(`SOL_UNIT`), then maps
`sub = system:serviceaccount:<namespace>:<serviceaccount>` to a Sol unit and
requires that unit in the projected `SOL_CALLED_BY` set. An unauthenticated
caller (bad token, untrusted issuer, wrong audience) is a `401`; an
authenticated caller that is not declared is a `403`. Routes require Sol
workload identity by default. `Route.external_ route` exempts a route from that
Sol authentication boundary only; application authentication remains the
handler/framework's responsibility.

If a target driver cannot establish an issuer, deployment containing any `svc`
fails. Sol does not currently distinguish services that need internal workload
authentication from those that do not, so every `svc` requires a target that
establishes workload identity.

The discovery document must report the exact target-projected issuer, and its
JWKS URL must use the same HTTPS origin. Discovery, key-fetch, or validation
failures reject the request; workload authentication never falls back to an
application-provided key source.

The built-in `/metrics` endpoint can require the shared key: a unit that passes
`` `Api_key`` as `metrics_auth` answers `GET /metrics` only to a caller presenting
`x-api-key`, and `sol-svc` reads the expected value from `SOL_API_KEY_FILE` first, then
`SOL_API_KEY` (once, at startup). A unit that does not protect `/metrics` does not require
`SOL_API_KEY`; a unit that does declares it in its `sol.toml` `[infra.env] secrets`. Its
target authority selects either the unit-scoped Sol-managed Secret or an ESO-managed
`ExternalSecret`; Sol does not emit a placeholder value.

Route-level `` `Api_key`` authentication is **not implemented**: routes are either internal
(`` `Workload_identity``, validated against the declared `calls` graph) or external (no
authentication). Endpoint-level API-key auth is future work.

## Summary

| Layer | Enforced by | When |
|---|---|---|
| Directory naming + Dockerfile presence | `discover_services` (string/filesystem check) | Before deploy — determines *what gets generated*, not whether it's correct |
| Port bound, `/healthz` responds | Kubernetes probes and Sol deploy readiness verification | During rollout and after deploy |
| `/metrics` format | Nothing | Never — silent failure only |
| SIGTERM drain | Nothing | Never — degrades gracefully into a harder kill, no error |
| Env var names read correctly | Nothing | Never — surfaces as a runtime connection failure |
| Migration SQL correctness | The database itself | At apply time, via whatever error the driver returns |
| Kafka security config shape | OCaml compiler | Only if code constructs `kafka-eio`'s types directly |
| Sol workload auth by default; explicit external exceptions | OCaml compiler | Only if code uses a conforming Sol HTTP adapter |
| Service call NetworkPolicy | `sol.toml` `calls` declaration | Only for explicitly declared caller/target pairs |

If you're building anything on top of Sol that generates code or containers
on a user's behalf (a UI, a codegen tool), this table is the actual safety
net you're relying on — and everywhere it says "nothing," that's a real gap,
not an oversight to route around.
