---
name: audit
description: Run a technical production-readiness audit of the Sol codebase. Checks security, runtime correctness, data integrity, and infrastructure synthesis against the principles in internal/pipeline/audits/AUDIT.md. Files actionable findings as ordinary GitHub Issues.
---

# /audit — Production Readiness Audit


The audit must evaluate both operational readiness and mission alignment: autonomous domain teams, typed event contracts, generated infrastructure, explicit security, framework-owned lifecycles, and AI-agent-friendly conventions.

## Finding tracking

Search open and closed GitHub Issues before filing. File an ordinary issue only for a distinct actionable finding that is not already tracked. Do not create labels, status conventions, dependency validators, branch conventions, or other workflow metadata to replace the retired repository issue system.

## Steps

### 1. Read the template
Read `internal/pipeline/audits/AUDIT.md` in full before starting. This is the checklist you will work through.

### 2. Determine today's date
Use the current date for the output filename in `YYYY-MM-DD` format.

### 3. Check previous findings



### 4. Work through each section

For each checklist item in `internal/pipeline/audits/AUDIT.md`, read the relevant source files and determine whether the invariant passes or fails. Do not rely on memory or assumptions — read the code.

**Section 1 — Local Developer Loop (`cli/bin/`, `cli/lib/base/sol_cli_scaffold.ml`):**
- Read `cmd_new.ml` to verify generated workspaces compile cleanly and library names are workspace-namespaced
- Check `cmd_local_deploy.ml` and `cmd_deploy.ml` for failure-path behaviour and rollback

**Section 2 — Infrastructure Synthesis (`cli/lib/workspace/sol_cli_manifest.ml`):**
- Read `sol_cli_manifest.ml` in full
- Check `deployment_doc` and `cronjob_doc` for `runAsNonRoot`, `runAsUser`, `seccompProfile`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation`
- Check `service_doc` for `type: ClusterIP` (not `NodePort`)
- Check `secret_doc` exists and `default_cluster_secrets` contains no plaintext passwords
- Check `network_policy_doc` is included in `render`
- Verify all `Sys.command` calls use `Filename.quote`

**Section 3 — Core Runtime (`~/Code/kafka-eio/kafka-eio-core/lib/kafka_stubs.c`, `~/Code/kafka-eio/kafka-eio-consumer/lib/kafka_consumer.ml` — extracted to the standalone `kafka-eio` opam package, no longer in this repo; `framework/ocaml/sol-worker/lib/worker.ml`, `cli/bin/cmd_new.ml`):**
- Read `kafka_stubs.c` — for every blocking librdkafka call, verify `caml_release_runtime_system()` before and `caml_acquire_runtime_system()` after
- Check `pause_partition` and `resume_partition` for `CAMLparam`/`CAMLreturn`
- Read `kafka_consumer.ml` — verify `acked` ref and warning in both `consume` and `consume_partitioned`
- Read `cmd_new.ml` — verify `ack ()` placement in worker templates
- Read `kafka_service.ml` — verify `produce_await` result is checked before `ack ()`

**Section 4 — Observability (`framework/ocaml/kafka-eio-service/lib/kafka_service.ml`, `framework/ocaml/sol-svc/lib/`):**
- Read `parse_base_url` — verify `https://` is handled
- Read `default_on_decode_error` — check for structured log line, Prometheus counter, dead-letter option

**Sections 8–9 — Mission alignment and framework boundary:**
- Read `README.md`, `docs/DEVELOPER_EXPERIENCE.md`, and `docs/guides/TUTORIAL.md` for the stated architecture and user promise
- Read `cmd_new.ml` scaffold templates and the reference workspaces under `internal/fixtures/venus/` / `examples/pluto/`
- Verify event contracts are owned under `events/<team>/` and consumers import contracts, not producer service internals
- Verify generated names and labels preserve workspace/domain/service ownership
- Verify `Sol.Service.Make`, `Sol.Worker.Make`, and `Sol.Fn.Make` own lifecycle concerns in generated apps
- Verify package specs and user-facing docs do not claim commands or guarantees that are unavailable

### 5. File the findings

read it before filing; the report-shaped content below becomes the issue body:

- the observation and the exact command or line that shows it
- the mechanism, and what the product actually does
- what it would take to fix, and what would make a fix fail (the acceptance criteria)

### File actionable findings

For each distinct actionable finding not already represented by a GitHub Issue, create an ordinary issue with the problem, evidence, affected files, desired end state, and acceptance criteria. Prefer one coherent issue per ownership/refactor boundary over line-level findings.
