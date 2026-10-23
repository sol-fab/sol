# TypeScript capability inventory

This is the current per-capability parity record for the TypeScript framework
against the OCaml framework. It supersedes the 2026-10-02 audit; that older
report remains in Git history. Parity is behavioural, not implementation
(DEC-022): the user-visible contract must hold across languages, while the code
underneath may differ.

## Current inputs

| Input | Current | Note |
|---|---|---|
| Sol contract | `production-single-region/v1` | `docs/deployment/compatibility.md`, ADR 0009 |
| OCaml framework | this checkout's `framework/ocaml/*` | source of the reference behaviour |
| `@sol-fab/svc` | `0.3.0` | `runService`, `isReady`, shutdown delay, workload-identity guard, peer helpers |
| `@sol-fab/worker` | `0.2.0` source | `runWorker` plus `createWorkerHealth`; publication pending (sol-typescript#19) |
| `@sol-fab/fn` | `0.1.0` source | run-once CronJob contract; publication pending (sol-typescript#20) |
| `@sol-fab/kafka` | `0.5.2` | Confluent wire format, schema/topic registration, DLQ, outcomes |
| `@sol-fab/obs` | `0.4.0` | workload identity, Loki labels/flush, traceparent helpers |
| `@sol-fab/jobs` | `0.1.2` | leased Postgres queue |
| `@sol-fab/outbox` | `0.1.0` | transactional outbox/relay |
| `@sol-fab/retry` | `0.1.0` | shared retry vocabulary |

The two source-only packages are contract work, not optional parity: the Sol
templates pin `@sol-fab/worker@^0.2.0` and `@sol-fab/fn@^0.1.0`, so a generated
workspace cannot install until those versions are published. The demo's
`@sol-fab/svc` is aligned to `0.3.0`.

## Capability verdicts

| Capability | OCaml reference | TypeScript | Verdict |
|---|---|---|---|
| Discovery and build | CLI-owned | CLI-owned | equivalent |
| `-svc` lifecycle | `Sol_svc.Service.Make`: signal, `/readyz` 503 on stop, shutdown delay, bounded drain | `runService`: signal, `isReady`, shutdown delay, bounded drain | implemented |
| `-svc` inbound identity | `Sol_svc.Auth`/`Route`, workload-identity verification | `createWorkloadIdentityGuard`, `verifyWorkloadIdentity`; scaffold uses it for non-public paths | implemented in package/scaffold; demo does not yet exercise a protected route |
| `-svc` peer calls | `Peer.url`/`Peer.headers` for declared `calls` | `declaredPeer`/`peerUrl`/`peerHeaders`; token rotation read per call | implemented in package; no generated peer call in the current demo |
| `-worker` lifecycle | `Worker.Make`: join/readiness, unbounded drain, `on_ready` | `runWorker` + `createWorkerHealth`: `/readyz` on group join, `/livez` on heartbeat, abort/drain | implemented in source/template; publish pending |
| `-worker` outcome vocabulary | `Ack \| Fail`; `Fail` stops the consumer and leaves the offset uncommitted | `ACK`/fail; `wireCrashListener` stops the consumer | implemented |
| `-fn` lifecycle | `Fn.Make`: one run, exit 0/1/130, Pushgateway metrics, SIGTERM cancel | `runFn`: one run, exit 0/1/130, AbortSignal, `sol_fn_*` metrics and Pushgateway | implemented in source/template; publish pending |
| Confluent wire format | magic `0x00` + BE u32 id + JSON | `encodeWire`/`decodeWire` | implemented, byte-compatible |
| Schema registry | `register_contract` sets `FULL` then registers, both fatal; runtime read-only | `registerContract`/`connectTopic`; projection CLI | implemented |
| Partitioning and key | declared partitions/key; no reduction | `TopicContract`/`registerTopic`; no reduction | implemented |
| DLQ naming | `<source>.<canonical-group>.dlq` with a 12-hex MD5 suffix | same rule in `dlqTopicName` | implemented (BUG-117 fixed) |
| Worker metrics | `sol_worker_messages_total{status}`, `sol_worker_decode_errors_total` | same names and `ok \| fail \| ack_failed` vocabulary | implemented |
| Service metrics | `sol_svc_requests_total`, `sol_svc_request_duration_seconds` | `@sol-fab/obs` helpers match names/labels | implemented |
| Trace propagation | W3C `traceparent` on HTTP/Kafka | `traceparentOf`/`extractTraceparent` | implemented |
| Logs/metrics identity | `Sol_obs.of_env` labels, `flush` | `workloadIdentity`, Loki `labels`, `flush` | implemented |
| Config | `config_of_env` requires brokers, security, schema registry and Redpanda admin | `kafkaConfigFromEnv` requires brokers and security; schema/admin URLs are read at their use sites | partial: transport posture and broker config are equivalent; the schema/admin requirement is not one helper |
| Secrets | `Secret.get` with declared authority | apps read env; no TypeScript `Secret.get` | gap owned by DEC-029 |
| Jobs | `Sol_jobs` | `@sol-fab/jobs` | implemented |
| Transactional outbox | `Sol_outbox` | `@sol-fab/outbox` | implemented |
| Operation retry | `Sol_retry` | `@sol-fab/retry` | implemented |
| Auth levels | `Public`/`Api_key`/`Jwt` per route | workload-identity guard only; app-owned Fastify/Express auth for the rest | partial: inbound workload identity is implemented; general auth plugins remain app-owned |
| Env access | `Sol_env`/`Sol_runtime` | `process.env`; names are the contract | equivalent |

## Remaining work to close the TypeScript target

1. **Publish `@sol-fab/worker@0.2.0` and `@sol-fab/fn@0.1.0`.** The source and
   tests are in sol-typescript#19/#20. Worker `0.2.0` can go through the OIDC
   tag workflow (`worker-v0.2.0`); `fn` needs its first authenticated publish
   and npm trust bootstrap (`fn-v0.1.0`).
2. **Verify the generated TypeScript workspace.** After publish, `sol new
   workspace`/`sol new fn --language typescript` must build from npm and the
   worker's `/readyz`/`/livez` must be probed when the consumed topic is
   declared. Add the TS fn/worker paths to the golden-path smoke rather than
   only asserting template contents.
3. **Exercise peer/identity in the demo.** The svc package and scaffold have the
   surface; the deployed demo does not yet call a peer through a declared
   `calls` edge or serve a protected route. Add that before claiming production
   parity.
4. **Admit TypeScript at the production preflight.** `supported_by_profile`
   remains `[Ocaml]` until the type/language evidence above exists. This is an
   evidence gate, not a permanent exclusion; the support table in the README is
   the current measurement.
5. **Keep the config/secrets gaps explicit.** The transport posture is
   equivalent; the schema/admin URL helper and TypeScript `Secret.get` are not.
