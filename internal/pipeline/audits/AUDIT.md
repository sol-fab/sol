# Sol Framework: Production Readiness Audit

This is a reusable audit template. When performing an audit, copy this file (e.g., `AUDIT_FINDINGS_03.md`), work through the checklist and runbook sections, and record every finding in the Findings section of your copy using the format at the bottom. Do not record findings in this file — it is the blank exam, not the answer sheet.

**What this audits:** Whether Sol is staying true to its core promise — that a startup using this framework gets security, reliability, and observability as defaults, not afterthoughts. Every section maps to a principle Sol holds. A passing audit means the principle holds in the current codebase.

**Mission alignment lens:** Sol is a production platform for startups built around autonomous domain teams and typed event contracts. When a checklist item passes technically but weakens domain autonomy, typed event ownership, generated infrastructure, explicit security, or AI-agent-friendly conventions, record that as a finding. Operational correctness is necessary but not sufficient.

---

## 1. Local Developer Loop & CLI Contracts

Sol must eliminate "it works on my machine" syndrome. The local loop must mirror production architectures without introducing operational overhead.

**Source locations:** `cli/bin/` · `cli/lib/base/sol_cli_scaffold.ml` · `cli/lib/base/sol_cli_scaffold_tree.ml`

### Checklist

* [ ] **Zero-Knowledge Onboarding:** `sol new workspace <name>` generates a fully compiling, zero-warnings codebase on the first try. Library names are workspace-namespaced to prevent collisions in multi-workspace monorepos.
* [ ] **Whole-plan prevalidation, recorded failure:** `sol local deploy`/`sol deploy` build and render the whole plan before touching the cluster (`Sol_cli_change_set.build` collects every render error first, and `--dry-run` contacts no cluster), so a refusal before the billable boundary changes nothing. Once apply begins, a failure exits non-zero and the release record is written only when apply succeeded, so the prior release remains authoritative. Sol does not promise atomic rollback of a partially-applied set: recovery is re-running `sol deploy` (the plan is idempotent) or `sol rollback <release_id>` to restore a recorded boundary. A scoped deploy or a rollback refuses, before any mutation, when the boundary it must read cannot be read.
* [ ] **Hermetic Test Harnesses:** The E2E test sequence does not rely on ambient `sleep N` timing, manual port-forwards, or host-level broker state. Infrastructure setup is fully scripted and idempotent.

---

## 2. Infrastructure Synthesis & Deployment Engine

Sol generates Kubernetes and Kafka topologies from OCaml definitions. The synthesis engine must be deterministic and structurally secure by default — a startup should not need to understand Kubernetes security internals to ship a hardened deployment.

**Source locations:** `cli/lib/workspace/sol_cli_manifest.ml` · `cli/lib/workspace/sol_cli_manifest_yaml.ml` · `cli/lib/deploy/sol_cli_deployment_render.ml`

### Checklist

* [ ] **Containers never run as root:** Every generated `Deployment` and `CronJob` sets `runAsNonRoot: true`, `runAsUser`, and `runAsGroup`. Container-level contexts enforce `allowPrivilegeEscalation: false` and `readOnlyRootFilesystem: true`.
* [ ] **Seccomp profile is set:** Pod security contexts include `seccompProfile: type: RuntimeDefault`, passing standard Kubernetes security scanners.
* [ ] **Credentials are never rendered as plaintext:** ConfigMaps contain only non-sensitive config. Every required unit key has an explicit `sol` or `external` authority. Sol-owned values are written to `<unit>-secrets`; ESO-owned values are rendered as namespace-scoped ExternalSecrets targeting `<unit>-external-secrets`. Direct and GitOps artifacts contain references, never values or placeholder Secret objects. Direct deploy verifies Sol-owned keys, ESO sync, materialized key sets and workload rollout.
* [ ] **Services use ClusterIP + Ingress, never NodePort:** Generated `Service` resources use `type: ClusterIP`. HTTP services generate an `Ingress` with TLS redirect.
* [ ] **NetworkPolicy is generated for every workload:** Each workload gets a `NetworkPolicy` restricting ingress and egress to only what it needs (ingress-nginx, in-cluster pods, Redpanda, PostgreSQL, monitoring namespaces, DNS).
* [ ] **Subprocesses run from an argv list:** Shipped code (`cli/`, `framework/`, `platform/`) invokes subprocesses through `Sol_cli_process.cmd`, which carries a `string list` argv and never a shell string; `Sys.command` appears nowhere in those trees. The deliberate shell exceptions are `sol local run`'s generated command and maintainer tooling (`internal/tooling/sol_process.run_shell`), and both `Filename.quote` every interpolated value.
* [ ] **Escape hatches via `sol.yml`/target files:** A startup needing custom annotations, non-default resource limits, or a progressive rollout strategy can inject it via `sol.yml` or a `sol/<env>/<provider>/<region>.yml` target file without forking the framework.
* [ ] **Generated infrastructure is a build artifact:** Kubernetes, Kafka, and NetworkPolicy YAML are synthesized deterministically from workspace structure, `sol.yml`, and the resolved target file; service repos do not require hand-committed per-workload manifests to deploy.
* [ ] **Team boundaries are reflected in infrastructure:** Namespaces, service accounts, Kafka topics, ACLs, and NetworkPolicies are derived from `app/<team>/...` and `events/<team>/...`, so domain ownership is visible and enforceable at runtime.

---

## 3. Core Runtime: OCaml Domain Lock & Kafka FFI

High performance must not compromise correctness. Every blocking librdkafka call must release the OCaml domain lock so the Eio scheduler can continue running. Generated worker code must enforce at-least-once semantics.

**Source locations:** `~/Code/kafka-eio/lib/kafka_stubs.c` · `~/Code/kafka-eio/lib/kafka_consumer.ml` (standalone `kafka-eio` opam package, opam-pinned into this switch — not in this repo) · `framework/ocaml/sol-worker/lib/worker.ml` · `cli/lib/workspace/sol_cli_cmd_new.ml`

### Checklist

* [ ] **All blocking C stubs release the OCaml domain lock:** `consumer_poll`, `poll`, `flush`, `destroy`, `consumer_close`, `create_topic`, `commit_message`, `init_transactions`, `begin_transaction`, `commit_transaction`, `abort_transaction`, and `send_offsets_to_transaction` all call `caml_release_runtime_system()` before blocking and `caml_acquire_runtime_system()` after.
* [ ] **Missing `ack()` call is detected at runtime:** `consume` and `consume_partitioned` detect handlers that return `Continue` or `Stop` without calling `ack()` and emit a structured warning.
* [ ] **Scaffolded workers call `ack()` after business logic:** Generated worker templates only call `ack()` after all side effects succeed. The "ack-before-processing" pattern — calling `ack()` as the first line of the handler — must not appear in any generated file.
* [ ] **`Retry_topics` path handles producer failure before acking:** `publish_raw` checks the result of `produce_await` before calling `ack()`. On producer failure, the message is not acked, allowing it to be redelivered from the broker.
* [ ] **All `CAMLparam`/`CAMLreturn` macros are present:** Every C stub that accepts OCaml values uses the correct macros, even if it currently makes no OCaml allocations.
* [ ] **Hermetic container portability:** The build pipeline does not rely on the host machine's glibc version matching the container base image. Binaries are either statically linked or compiled inside the container via a multi-stage build.

---

## 4. Observability & Data Integrity

Startups rarely have dedicated SRE teams. The framework must surface failures with enough signal that a small team can debug production incidents without deep Kafka or OCaml expertise.

**Source locations:** `framework/ocaml/kafka-eio-service/lib/kafka_service.ml` · `framework/ocaml/sol-svc/lib/` · `framework/ocaml/sol-fn/lib/`

### Checklist

* [ ] **Decode errors are observable:** `default_on_decode_error` emits a structured log line. There is a Prometheus counter for decode errors. Users can supply a custom callback that receives the raw message bytes to forward to a dead-letter topic.
* [ ] **Zero-configuration distributed tracing:** `traceparent` (W3C) is extracted from Kafka headers by the consumer and injected by HTTP producers. The developer never manually threads trace context through business logic.
* [ ] **Prometheus label cardinality protection:** `sol_svc_requests_total` uses the declared route pattern (e.g., `/users/:id`) as the `route` label, not the raw runtime path (`/users/10283`).
* [ ] **Schema registry HTTP client supports TLS:** The schema registry and admin API client handles `https://` URLs. Production schema registry endpoints (Confluent Cloud, MSK, Redpanda Cloud) all require HTTPS.
* [ ] **Migration tracking is workspace-isolated:** Schema migrations tracked by `sol migrate` use a workspace-prefixed table (`sol_<workspace>_schema_migrations`) so multiple workspaces sharing a local database never collide.
* [ ] **No naked exceptions from storage or Kafka layers:** All DB and Kafka calls return `(_, error) result`. Uncaught exceptions must not reach Eio supervisor fibers.
* [ ] **Generated telemetry names preserve ownership:** Metrics, logs, traces, and labels include stable workspace, domain, service, and primitive identifiers without high-cardinality labels.
* [ ] **Incident paths stay inside Sol:** The documented path from alert/log/metric to service status, logs, rollback, and migration state uses Sol commands first; requiring raw `kubectl`, `rpk`, `terraform`, or cloud-provider CLIs is a finding unless explicitly scoped as an advanced escape hatch.

---

## 5. Executable Local Audit Runbook

Each item below is a concrete command sequence. A checklist item in sections 1–4 is not verified until the corresponding commands pass — reading the code is not sufficient.

### 5.1 Zero-to-Running Local Loop

```bash
# 1. Fresh workspace scaffold — must compile with zero warnings
sol new workspace audit_test
cd audit_test
eval $(opam env) && dune build 2>&1 | grep -i warning  # must be empty

# 2. Bring up local infrastructure
sol local deploy
# All port-forwards must appear before the command exits

# 3. Verify each service address is reachable
curl -sf http://localhost:8080/healthz        # charge_svc health probe
rpk topic list --brokers localhost:9092       # Kafka broker reachable

# 4. Produce a message and verify round-trip through the worker
KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 REDPANDA_ADMIN_URL=http://localhost:9644 dune exec internal/fixtures/local-demo/bin/demo.exe 2>&1 | grep -v "^$"
```

**Invariants:**
* [ ] `dune build` produces zero warnings on a freshly scaffolded workspace
* [ ] `sol local deploy` is idempotent — running it twice must not error or duplicate resources
* [ ] All health endpoints return `200` within 10 seconds of `sol local deploy` completing
* [ ] A message produced in the demo reaches the worker and is logged without decode errors

---

### 5.2 Failure Behaviour Verification

Each step below must leave the cluster and the workspace exactly as it was before it.

```bash
# 1. Refusal before the cluster is touched: a build failure
echo "RUN this_command_does_not_exist" >> app/payments/charge_svc/Dockerfile
sol local deploy
# Expected: non-zero exit, reported before any manifest is applied
kubectl get pods -l workspace=audit_test --all-namespaces  # must be empty
git checkout app/payments/charge_svc/Dockerfile

# 2. External secret delivery is a reference, not a value
# Declare an external key in the target, emit GitOps manifests, and inspect the result:
sol deploy dev/aws/us-east-1 --image-tag audit-01 --registry <registry> \
  --emit-to /tmp/audit-gitops
# Expected: an ExternalSecret and matching workload secretKeyRef; no Secret value or
# placeholder Secret is written. Direct deploy additionally verifies ESO and rollout state.

# 3. Recovery facts are recorded, not assumed (live-only: needs an apply that fails)
sol releases --target dev/aws/us-east-1
# A deploy that failed after apply began writes no release record and leaves the
# current-release pointer unchanged, so sol releases still shows the prior release.
# Recovery is another sol deploy or sol rollback <release_id>; Sol does not roll the
# partial apply back for you.
```

**Invariants:**
* [ ] A build failure exits non-zero and leaves zero orphaned containers or services
* [ ] An incompatible secret backend is refused before any file or cluster state changes
* [ ] CLI exit codes are non-zero on every failure path (`echo $?`)
* [ ] A failed apply writes no release record and leaves the prior release authoritative (live-only)

---

### 5.3 Observability Smoke Test

```bash
# After sol local deploy:

# Prometheus: verify worker metrics are registered
curl -s http://localhost:9090/api/v1/label/__name__/values \
  | python3 -m json.tool | grep sol_worker

# Loki: verify structured log lines are indexed ("service" is a reserved
# Obs_loki stream label, always set to the running service's name)
curl -s 'http://localhost:3100/loki/api/v1/query?query={service="charge_svc"}' \
  | python3 -m json.tool | head -40

# Trace propagation: verify traceparent is forwarded through Kafka
KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 REDPANDA_ADMIN_URL=http://localhost:9644 dune exec internal/fixtures/local-demo/bin/demo.exe 2>&1 \
  | grep -i traceparent
```

**Invariants:**
* [ ] `sol_worker_messages_total` and `sol_worker_message_duration_seconds` appear in Prometheus after at least one message is processed
* [ ] Loki receives structured log lines from both the svc and worker
* [ ] `traceparent` header is present in Kafka message headers and re-extracted by the consumer

---

### 5.4 Generated Manifest Security Scan

```bash
sol deploy dev/aws/us-east-1 --image-tag audit-01 --registry <registry> --dry-run 2>&1 \
  | tee /tmp/sol-manifest.yaml

grep "type: NodePort"         /tmp/sol-manifest.yaml  # must be empty
grep "POSTGRES_URL.*password" /tmp/sol-manifest.yaml  # must be empty
grep "runAsNonRoot: true"     /tmp/sol-manifest.yaml  # must appear per container
grep "readOnlyRootFilesystem" /tmp/sol-manifest.yaml  # must appear per container
grep "seccompProfile"         /tmp/sol-manifest.yaml  # must appear per pod
grep "kind: NetworkPolicy"    /tmp/sol-manifest.yaml  # must appear per workload

# Deployment artifacts contain secret references only:
grep -E "^kind: Secret$" /tmp/sol-manifest.yaml       # must be empty
grep -E "^kind: ExternalSecret$" /tmp/sol-manifest.yaml # expected for external keys
grep -E "POSTGRES_URL|SOL_API_KEY" /tmp/sol-manifest.yaml # references, never values
```

**Invariants:**
* [ ] All `grep` checks above produce the expected matches/non-matches before any cluster state is touched
* [ ] Sol-owned and ESO-owned values are never rendered into deployment artifacts; a declared external key produces only its namespaced ExternalSecret and workload reference

---

## 6. Cloud Deployment & Lifecycle Operations Audit

### 6.1 Rolling Deploy: Zero Consumer Downtime

```bash
# Baseline: record consumer lag before deploy
rpk group describe <group_id> --brokers localhost:9092 | grep LAG

# Trigger a rolling deploy
sol deploy dev/aws/us-east-1 --image-tag audit-02 --registry <registry>

# Poll consumer lag while rollout is in progress
watch -n2 "rpk group describe <group_id> --brokers localhost:9092 | grep LAG"

kubectl rollout status deployment/charge_worker -n payments --timeout=120s
```

**Invariants:**
* [ ] Consumer lag does not grow unbounded during rollout
* [ ] No duplicate processing is logged during rebalance (watch for double-ack warnings)
* [ ] Consumer group resumes from the correct offset after the new pod becomes ready

---

### 6.2 Database Migration on a Live Cluster

```bash
# Add a new additive migration
cat > db/migrations/002_add_idempotency_key.sql <<'EOF'
ALTER TABLE charges ADD COLUMN idempotency_key TEXT;
CREATE UNIQUE INDEX idx_charges_idempotency ON charges(idempotency_key)
  WHERE idempotency_key IS NOT NULL;
EOF

sol migrate apply dev/aws/us-east-1 2>&1

# Verify migration tracking is workspace-prefixed
# Replace <workspace> with the workspace directory name (e.g. sol_pluto_schema_migrations)
psql $POSTGRES_URL -c \
  "SELECT * FROM sol_<workspace>_schema_migrations ORDER BY applied_at DESC LIMIT 3;"

kubectl logs -n payments -l app=charge_worker --since=5m | grep -i error
```

**Invariants:**
* [ ] `sol migrate apply` is idempotent — running it twice produces no error
* [ ] Migration tracking table is workspace-prefixed, never shared across workspaces
* [ ] `sol migrate apply <target> --dry-run` prints the SQL before touching the database
* [ ] Zero application errors in worker logs immediately after migration

---

### 6.3 Credential Rotation

```bash
kubectl create secret generic charge-svc-secrets \
  --from-literal=POSTGRES_URL="postgresql://postgres:new_password@..." \
  -n payments --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/charge_svc -n payments
kubectl rollout status deployment/charge_svc -n payments --timeout=60s

kubectl logs -n payments -l app=charge_svc --since=2m | grep -i "error\|connect"
```

**Invariants:**
* [ ] New pods start with the rotated credential without code changes
* [ ] Zero "authentication failed" errors in logs after rollout completes

---

## 7. Breaking Change Detection & Guard Audit

### 7.1 Schema Incompatibility Is Blocked at Registration Time

```bash
# Attempt to register a schema that breaks existing consumers
KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092 REDPANDA_ADMIN_URL=http://localhost:9644 SCHEMA_REGISTRY_URL=http://localhost:8081 \
  dune exec app/payments/charge_worker/bin/main.exe -- --register-only 2>&1
```

**Invariants:**
* [ ] Removing a required field → blocked at schema registration, not at message decode
* [ ] Changing a field type (e.g., `int` → `string`) → blocked at schema registration
* [ ] Adding a required field with no default → blocked at schema registration
* [ ] Adding an optional field with a default → allowed

---

### 7.2 Partition Count Reduction Is Blocked

**Expected:** `sol` detects a partition count reduction and exits with an error naming the topic and both counts. A `--force` flag is required to override.

**Invariants:**
* [ ] Partition count reduction is blocked without explicit override flag
* [ ] Partition count increase is allowed
* [ ] Error message names the topic and both counts

---

### 7.3 Consumer Group ID Change Surfaces a Warning

**Expected:** `sol deploy` detects a `W.group_id` change and emits a prominent warning identifying the old and new IDs and the data-skip risk. A `--confirm-group-change` flag is required to proceed.

**Invariants:**
* [ ] Group ID change is surfaced before apply
* [ ] Warning identifies old and new group IDs and states the consequence

---

## 8. Domain Architecture & Event Contract Audit

Sol's central architecture is autonomous domain teams coordinating through typed events. The framework should make that model easy to follow and deviations easy to spot.

**Source locations:** `README.md` · `docs/guides/tutorial.md` · `cli/lib/workspace/sol_cli_cmd_new.ml` · `cli/lib/workspace/sol_cli_workspace.ml` · workspace examples under `internal/fixtures/venus/` and `examples/pluto/`

### Checklist

* [ ] **Events are owned by publishing domains:** Event contracts live under `events/<team>/` and scaffolded producers publish events owned by their own team. Consumers import event modules from `events/<team>/`, never from another team's service implementation.
* [ ] **Cross-domain shared code is narrow and intentional:** Shared libraries do not become a backdoor for business logic coupling between teams. Storage helpers or pure data helpers are acceptable only when the ownership and blast radius are obvious.
* [ ] **Scaffolded examples teach the intended architecture:** The default workspace demonstrates one producer domain and one consumer domain connected by a typed event contract, with no hidden shared service internals.
* [ ] **Naming conventions enforce ownership:** Topics, consumer groups, namespaces, deployments, metrics labels, and generated library names include workspace/domain/service identity consistently.
* [ ] **Schema compatibility checks are available before deploy:** Breaking schema changes can be detected in CI or by a Sol command before a pod restart in staging or production.
* [ ] **Service primitives stay distinct:** `-svc`, `-worker`, and `-fn` lifecycles remain separate and explicit. A primitive should not need to know the internal lifecycle details of another primitive to interoperate.

---

## 9. Framework Boundary & AI-Agent-First Audit

Sol is intentionally a framework at infrastructure and network boundaries, and a library inside business logic boundaries. It is also designed for AI-assisted development. The codebase should preserve predictable structure, explicit contracts, and one clear path for common tasks.

**Source locations:** `README.md` · `docs/developer-experience.md` · `docs/guides/tutorial.md` · `cli/lib/workspace/sol_cli_cmd_new.ml` · `framework/*/lib/` · package-level `*.md` specs

### Checklist

* [ ] **Sol owns application lifecycle at the boundary:** `Sol.Service.Make`, `Sol.Worker.Make`, and `Sol.Fn.Make` own startup, shutdown, telemetry wiring, and resource lifecycle. Scaffolded apps do not hand-roll these concerns.
* [ ] **Business logic remains readable and local:** Handler modules contain business behavior and explicit dependencies, not hidden global state, implicit service discovery, or infrastructure manipulation.
* [ ] **There is one recommended way to do common tasks:** Scaffolding, deployment, logs, migrations, rollback, schema checks, and local dev have a single documented Sol command path. Alternative low-level paths are clearly marked as advanced.
* [ ] **Templates are agent-friendly:** Generated files compile immediately, have predictable names, use stable module shapes, avoid surprising metaprogramming, and include enough local context for an AI agent to modify them without guessing.
* [ ] **Spec files match implementation reality:** Package-level `*.md` specs, `README.md`, `docs/developer-experience.md`, and generated docs do not claim unavailable commands, incomplete guarantees, or obsolete workflows.
* [ ] **Escape hatches are explicit deviations:** Any override that weakens a Sol default, such as security posture, rollout behavior, resource policy, or network access, is visible in `sol.yml`/target files or command flags and can be audited.

---

## Findings Log

Record every gap found during this audit run below. Use one entry per finding.

```
### [AUDIT-NNN] — Component / Feature Name
* **Category:** DX | Security | Runtime Performance | Data Integrity | Lifecycle | Domain Architecture | Framework Boundary | AI-Agent-First
* **Severity:** Critical | High | Medium | Low
* **Location:** `path/to/file.ml` (Lines X–Y)
* **Description:** What is wrong and what invariant it violates.
* **Impact:** Why a startup shipping with this gap will have a bad time.
* **Remediation:** The concrete code change that closes the gap.
```
