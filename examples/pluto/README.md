# Pluto

A Sol workspace with OCaml service examples (`charge_svc`, `checkout_svc`,
`notify_worker`) and the existing TypeScript demo pair under `app/demo_ts`. It
also carries the alpha campaign's reference application, the "Pluto orders"
scenario, in both languages.

## The reference scenario: Pluto orders

`examples/pluto` is the alpha campaign's reference application: one realistic
backend workflow implemented independently in OCaml and TypeScript with the same
externally observable behaviour (`internal/qualification/README.md` §2).
`FEAT-131` lands the shared scenario contract and skeleton; `FEAT-132` implements
the OCaml half and `FEAT-133` the TypeScript half.

### Two namespaces, one scenario

The two implementations are independent deployments inside this one workspace —
separate domains, topics, tables and job kinds — so both can run side by side
against one Postgres and one broker. They share the scenario's event semantics
and its HTTP contract, and nothing else.

| | OCaml namespace | TypeScript namespace |
|---|---|---|
| units | `orders_svc` (`-svc`), `fulfilment_worker` (`-worker`) | `order_svc` (`-svc`), `fulfillment_worker` (`-worker`) |
| domains | `payments`, `comms` | `demo_ts` |
| event declaration | `events/orders/sol.toml` (canonical) | `events/demo_ts/sol.toml` (projection) |
| `OrderPlaced` topic | `orders.v1` | `sol-demo-ts-orders` |
| `OrderFulfilled` topic | `orders-fulfilled.v1` | `sol-demo-ts-fulfilled` |
| tables | `orders`, `fulfilled_orders`, `order_confirmations` | `orders_ts`, `fulfilled_orders_ts`, `order_confirmations_ts` |
| job kinds | `send_confirmation`, `release_inventory` | `send_confirmation`, `release_inventory` |
| job workspace | `pluto.orders` | `pluto.demo_ts` |

The two namespaces use the same job kind names; `sol_jobs.workspace` separates
their rows, and each unit's job contract pins its own workspace string. The
scenario's shared tables ship as migrations (`0005_orders.sql`,
`0006_orders_ts.sql`, and `0007_orders_ts_traceparent.sql` for the accepted
order's W3C trace context, which the service-side relay replays onto the record);
`sol_jobs` and `sol_outbox` are the workspace-shared DDL in `0002`/`0003`.

`orders_svc` and `fulfilment_worker` are declared in `sol.yml` with their
language and in `sol/environments.yml` with their environment settings.
`FEAT-132` adds their directories, under `app/payments/orders_svc` and
`app/comms/fulfilment_worker`; until then `sol plan` reads the declaration and
renders both units, while `sol check` cannot see a workload for them because
discovery is directory-based (the gap is `BUG-131`). The TypeScript half already
lives under `app/demo_ts`.

### The workflow

```
client
  │  POST /orders {order_id, item, quantity}
  ▼
orders_svc  (-svc)
  │  BEGIN
  │    INSERT orders        (order_id PK, item, quantity, status)   ON CONFLICT DO NOTHING
  │    INSERT sol_jobs      (kind = send_confirmation, dedupe_key = order_id)
  │    INSERT sol_outbox    (kind = OrderPlaced, key = order_id, ord = 1)
  │  COMMIT
  │  outbox relay  ──►  Kafka topic  orders.v1            (3 partitions, key = order_id)
  ▼
fulfilment_worker  (-worker)
  │  consume OrderPlaced
  │  BEGIN
  │    INSERT fulfilled_orders (order_id PK, item, quantity, correlation_id)   ON CONFLICT DO NOTHING
  │    INSERT sol_jobs       (kind = release_inventory, dedupe_key = order_id)
  │    INSERT sol_outbox     (kind = OrderFulfilled, key = order_id, ord = 1)
  │  COMMIT
  │  ack
  │  outbox relay  ──►  Kafka topic  orders-fulfilled.v1   (3 partitions, key = order_id)
  ▼
downstream behaviour
  • the job runner executes send_confirmation (writes the confirmation effect)
  • GET /orders/{order_id} reads fulfilment back:  accepted → fulfilled → confirmed
```

### Observable contract

Identical in both languages.

| Aspect | Contract |
|---|---|
| HTTP | `POST /orders` → `202 {order_id, status}`; `GET /orders/{order_id}` → `200`/`404`; a duplicate `POST` is idempotent |
| Events | `OrderPlaced`, `OrderFulfilled`; declared in `events/<scope>/sol.toml`; 3 partitions; key `order_id` |
| Atomicity | the domain row, the job and the outbox intent commit or roll back together; the relay removes a row only after the broker acknowledged it |
| Duplicate delivery | absorbed at every effect (row `ON CONFLICT`, job dedupe key, outbox unique `(key, ord)`), so one fact yields one row, one job, one intent, one effect |
| Decode failure | an undecodable record yields the structured decode log, `sol_worker_decode_errors_total`, and a DLQ record on `<topic>.<group>.dlq` carrying the raw bytes; the source offset advances |
| Undeliverable record | a handler that returns the fail-closed `Dead_letter` outcome produces no DLQ record (`FEAT-118`) |
| Identity | every log, metric and trace carries the six Sol dimensions, and one request's three signals agree |

### The event contract has one source of truth

`events/orders/sol.toml` is the scenario's canonical event declaration: the
event names, schemas, partition counts and message keys are authored there and
nowhere else. `events/demo_ts/sol.toml` is a **projection** of it. The
projection exists because a Sol scope binds one language and the TypeScript
deployment needs namespace topics of its own; it may differ in its `topic`
only.

`internal/ci/check_scenario_contract.py` enforces that direction: every
projection event must reproduce the canonical name, schema, partitions and key,
a projection may add no event of its own, and the two scopes' topics are
disjoint. `internal/ci/test_scenario_contract.py` mutates each of those and
requires the guard to fail naming the file. The pair is therefore one contract
with two language bindings — not two declarations that happen to agree today.

Change the scenario's event semantics in `events/orders/sol.toml`, mirror the
change into `events/demo_ts/sol.toml`, then regenerate both bindings, which the
application code imports and never redeclares:

```bash
sol contract generate          # writes both bindings
sol check                      # validates declarations and generated bindings in CI
```

### The scenario's current state

`FEAT-131` lands the event contract and its bindings, the migrations, the unit
declarations and this document. `FEAT-132` lands the OCaml half: `orders_svc`
(`app/payments/orders_svc`) and `fulfilment_worker`
(`app/comms/fulfilment_worker`), with the job kinds `send_confirmation` and
`release_inventory` and the two outbox relays. `FEAT-133` is the TypeScript half,
under `app/demo_ts`.

The status a read-back observes moves `accepted` → `fulfilled` → `confirmed`. The
service commits the order, the confirmation job and the `OrderPlaced` intent in one
transaction; the worker's transaction writes the fulfilled row, the
`release_inventory` job and the `OrderFulfilled` intent. `release_inventory` marks
the order fulfilled; `send_confirmation` completes only once the order is
fulfilled, so it retries (bounded, with backoff) rather than confirming an order
that has not been fulfilled yet, and is a no-op when it is already confirmed.

## Build

```bash
eval $(opam env)
dune build
dune runtest test
```

`test_charges` exercises the typed charge decoder and database operation boundary
without HTTP or a database. `test_orders` exercises the order decoder, the
duplicate-`POST` response and the read-back rendering through the same injected
operation boundary, and round-trips both job kinds through their codec. The
handlers only connect decoding, the operation and response rendering; Pluto accepts
through Postgres, while the workspace scaffold accepts by publishing a Kafka event.

## Run the scenario locally

```bash
# orders_svc — POST /orders, then GET /orders/{order_id}
KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 REDPANDA_ADMIN_URL=http://localhost:9644 POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  dune exec app/payments/orders_svc/bin/main.exe

# fulfilment_worker — consumes OrderPlaced, relays OrderFulfilled, runs both job kinds
KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 REDPANDA_ADMIN_URL=http://localhost:9644 POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  dune exec app/comms/fulfilment_worker/bin/main.exe

curl -X POST localhost:8080/orders -H 'content-type: application/json' \
  -d '{"order_id":"o1","item":"widget","quantity":3}'
# {"order_id":"o1","status":"accepted"}
curl localhost:8080/orders/o1
# {"order_id":"o1","item":"widget","quantity":3,"status":"confirmed"}
```

## Run locally

```bash
# Start Kafka (Redpanda) and Postgres
bash <path-to-sol>/platform/local/scripts/ensure-broker.sh
bash <path-to-sol>/platform/local/scripts/ensure-postgres.sh

# Run the worker (POSTGRES_URL is required — both services depend on Postgres)
KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 REDPANDA_ADMIN_URL=http://localhost:9644 POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
  dune exec app/comms/notify_worker/bin/main.exe

# `/quote` is an internal route. Sol projects the target's trusted issuer into
# deployed services; a bare process has no such target projection and fails
# closed. Run the Sol-to-Sol call in a deployed AWS/GKE target to exercise it.
```

`charge_svc` declares `calls = ["checkout/checkout_svc"]`. Sol injects
`CHECKOUT_SVC_URL` as a cluster DNS URL for the checkout ClusterIP, so the
east-west request stays inside the cluster network. The generated per-pair
NetworkPolicy permits that caller/target path, and the framework attaches the
projected ServiceAccount token for `checkout_svc` as `Authorization: Bearer`.

`/checkout-quote` is an external route on `charge_svc`, so application-owned
customer or anonymous policy applies there. Its call to `/quote` still requires
Sol workload identity. A bare process or local infrastructure does not establish
the target's trusted issuer, so `checkout_svc` fails closed; exercise this
Sol-to-Sol path in a deployed AWS or GKE target.

For customer-cloud, set `ingress_host` in `checkout_svc/sol.toml` to your DNS
name, run `sol deploy customer_cloud/aws/us-east-1`, then create an
`A`/`CNAME` record for that host pointing at the ingress load balancer.
Cert-manager uses the configured cluster issuer for TLS.

## Production profile

In `sol/environments.yml`, the `pilot` environment selects the
`production-single-region` profile; `prod` deliberately does not, because an
environment's name never makes a production claim.

The profile runs Kafka as SASL_SSL. The broker's SASL users Secret is a
pre-platform operator input: `sol deploy` creates the `redpanda` namespace
in its prerequisite stage, then stops before the privileged platform apply if
the Secret is absent, naming it and the command that creates it. On a fresh
target the order is `sol deploy pilot/aws/us-east-1`, create the Secret when
the run names it, then `sol deploy pilot/aws/us-east-1` again to resume.
Supply the platform Job inputs to the reserved target scope, then set the
application values separately for each unit that declares them. Database access
is not a platform input: the deploy delivers `<target>-dml-creds` to a unit that
declares `uses: [app_db]` and `<target>-ddl-creds` to the migration Job, so there
is no `POSTGRES_URL` to supply here:

```bash
kubectl create secret generic redpanda-users -n redpanda \
  --from-literal=users.txt="sol-workloads:$KAFKA_SASL_PASSWORD:SCRAM-SHA-256"
printf '%s' "$KAFKA_SASL_PASSWORD" \
  | sol secret set pilot/aws/us-east-1 @platform/KAFKA_SASL_PASSWORD --from-stdin
kubectl get secret redpanda-default-cert -n redpanda -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > ca.crt
sol secret set pilot/aws/us-east-1 @platform/KAFKA_SSL_CA_CERT --from-file ca.crt
printf '%s' "$KAFKA_SASL_PASSWORD" \
  | sol secret set pilot/aws/us-east-1 payments/charge_svc/KAFKA_SASL_PASSWORD --from-stdin
sol secret set pilot/aws/us-east-1 payments/charge_svc/KAFKA_SSL_CA_CERT --from-file ca.crt
```

Repeat the final two unit-scoped commands for each other declared TLS workload.
The `@platform` writes only populate `sol-secrets` for Sol's internal Jobs and
never copy values into application Secrets.

See [production bootstrap](../../docs/deployment/production-bootstrap.md) for the
full procedure.

A production target deploys immutable artifacts, not mutable tags. Pin each
workload to the digest the build pushed:

```bash
REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
sol deploy pilot/aws/us-east-1 \
  --image-ref charge_svc="$REGISTRY/pluto/charge-svc@sha256:$CHARGE_DIGEST"
```

A bare `--image-ref <ref>` is accepted when the scope selects exactly one
service; a whole-workspace deploy needs one `<service>=<ref>` per workload (the
`app/demo_ts` services deploy the same way). `sol deploy` verifies each
reference exists in its registry before it applies anything.

`sol deploy` reconciles the whole target; there is no `--scope`, because the
desired workload set must be singular for a later removal to be authorized
against it. A profile that requires an immutable reference needs one
`<service>=<ref>` for every workload the target deploys, and the deploy verifies
each reference exists in its registry before it applies anything. For a narrow
update, roll back the release a unit was last deployed in
(`sol rollback --scope DOMAIN/UNIT`) rather than deploying a subset.

The deploy runs the profile preflight before anything touches a cluster. It
refuses until the target establishes every guarantee the profile requires — a
tag reference is itself one unmet guarantee — and lists each unmet guarantee
with who must act.

Every workload declares its framework language in `sol.yml`. This workspace's
OCaml services declare `language: ocaml`; the `app/demo_ts` pair declares
`language: typescript`, so the preflight reports TypeScript as not yet
qualified for the first profile (DEC-026 §2) rather than silently admitting it.
The exact supported set — CLI, OCaml version, Kubernetes, provider module and
chart versions — is published in
`docs/deployment/compatibility.md` in the Sol repository.

The pilot target declares the alert-delivery contract
(`alert_receiver_type`/`alert_receiver_url`/`alert_owner`/`alert_runbook_url`).
Exercise that route without a real incident:

```bash
kubectl -n monitoring port-forward svc/prometheus-alertmanager 9093:9093 &
# Use Alertmanager's own test/receiver workflow to verify end-to-end delivery.
```

The command's exit status proves the route is configured and reachable; the
delivered-and-acknowledged result is HARDEN-002's live evidence. Runbooks for
each required alert are in `docs/deployment/alert-runbooks.md`.

Availability is declared, not inferred from replica count (AUDIT-080).
`notify_worker` declares `availability = "node-failure-tolerant"` (with two
replicas and a consumer readiness/liveness pair on `/readyz`//`livez`), so Sol
renders a topology spread, a PodDisruptionBudget and an explicit drain grace for
it; `charge_svc` stays `single` and is reported honestly as such. The pilot and
prod targets declare the fixed `node_failure_headroom_nodes` the claim needs.
See `docs/deployment/workload-availability.md`.

A production deploy refuses to roll code out against an unapplied migration
(AUDIT-069). `0005_orders` and `0006_orders_ts` carry the reference scenario's
two namespaces, each with a matching `.down.sql` for `sol migrate rollback`, as
`0001_notifications` does for the charge demo. `0002_sol_jobs` and
`0003_sol_outbox` are the shared job and outbox DDL the scenario's transactions
use. New scenario tables are added as migrations here, never as an
application-time `CREATE TABLE`.
`sol migrate apply <target> --dry-run` reads the applied set from the target with a
read-only in-cluster status Job and prints only the local unapplied migration SQL,
so it needs no credential in your environment. The two deploy cases are:

- **Compatible** — after `sol migrate apply prod/aws/us-east-1`, `sol deploy
  prod/aws/us-east-1` verifies `0001_notifications` against the authoritative
  `schema_migrations` table and proceeds.
- **Deliberately blocked** — drop a new file in (say `0007_add_index.sql`)
  without running `sol migrate apply`: the deploy fails before any workload
  moves, naming the missing migration and the command to fix it. `--dry-run`
  stays side-effect free and reports the prerequisite as not verified.

See `docs/deployment/migration-ordering.md`.

See the "Production Profile" section of
`docs/reference/substrate.md` in the Sol repository.

## Once per account: the installation

The installation is the durable, account-level layer — the Terraform state backend
and its locking, the provisioning/cluster-access/deploy/operator identities, and the
delegated DNS zone when Sol owns one. It outlives every environment: `sol
destroy <target>` removes an environment, never the installation.

It is declared where the environment's durable state already lives, in the target:

```yaml
prod:
  targets:
    aws/us-east-1:
      cluster_name: pluto-prod
      base_domain: pluto.example.com
      state_bucket: pluto-tfstate
      aws:
        state_lock_table: pluto-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
```

Sol creates the durable state, but the four identities are yours to create: it
generates each least-privilege policy document and you attach it to a role of your
own (`AUDIT-072`). Reconciling the durable root writes those documents beneath the
root's working directory and prints their paths, so no Terraform output has to be
read by hand:

```text
    provisioning identity        declare aws.provisioner_role_arn
      contract: ~/.local/share/sol/terraform/aws-bootstrap-…/identity-contracts/provisioner_policy_json.json
```

Then reconcile it with the whole-target deploy:

### `sol deploy` detects it

`sol deploy` observes the same installation, and when it is not
established — which is what a target with no cluster to reach looks like on a
fresh account — it reports what it found and offers to set it up:

```text
$ sol deploy prod/aws/us-east-1 --image-ref charge_svc="$REGISTRY/pluto/charge-svc@sha256:$DIGEST"

Sol is not installed for prod/aws/us-east-1 yet:

  what Sol observed at the provider, never inferred from configuration:
  terraform state backend      Unmet: An error occurred (404) ... Not Found
  terraform state lock         Unmet: An error occurred (ResourceNotFoundException) ...
  provisioning identity        Unmet: An error occurred (NoSuchEntity) ...
  ...
  delegated DNS zone           Unmet: no Route53 hosted zone named pluto.example.com, ...

  the installation the target declares:
  state bucket             pluto-tfstate
  state prefix             bootstrap/aws
  region                   us-east-1
  lock table               pluto-tflock
  ...

  Sol does this for you:
  reconcile the durable installation root, which keeps a Terraform state of its own:
    its state backend and its locking, and the durable resources it declares
  create the DNS zone for pluto.example.com, or adopt the zone that is already
  there rather than create a second one with different nameservers, ...

  One action may be required from you:
    when the zone that publishes pluto.example.com is not in this account, add the
    exact NS records Sol prints at that zone; Sol then waits for the delegation and
    confirms it from a public resolver, never from written configuration
Set up Sol for prod/aws/us-east-1 now? [Y/n]
```

Accepting reconciles the durable root, prints the exact NS records to add when
the parent zone is outside the account, waits for the delegation to become
visible and confirms it from a public resolver, then re-observes and continues
into the deploy. An observation Sol could not make — a refused read, or a CI
identity that is not allowed to read the durable layer — is `UNKNOWN`, never
treated as an absent prerequisite (`DEC-052`).

The same vocabulary covers the substrate this workspace runs on. `sol target show
--target prod/aws/us-east-1 --check` reports each self-hosted input
(`docs/reference/substrate.md`) as `Established`, `Unmet` or `UNKNOWN`, so you can see
which parts of the contract Sol actually observed for this target and which ones only
the cluster's own network can answer:

```text
kubernetes    reachable
substrate: kubernetes cluster Established
substrate: container registry UNKNOWN: the prefix is registry.example.test/pluto; Sol
cannot make a node pull an image, so whether the cluster can pull from it is unverified
substrate: postgres connection Established
substrate: kafka and schema registry UNKNOWN: the broker addresses and schema-registry
URL are workspace configuration; whether the workloads can reach them, and the broker's
security posture, are properties of the cluster's network, and are observed there rather
than here
```

Declining, or running where no one can answer (CI, `--dry-run`, `--emit-to`),
never prompts and never sets anything up: it prints the same observation and the
command that does it explicitly, so a pipeline fails with an explanation instead
of hanging or skipping installation:

```text
Sol is not installed for prod/aws/us-east-1, and this run is not interactive, so
Sol will not set it up and will not continue as if it were there.
...
Run an interactive deploy to establish the installation and reconcile the target:
  sol deploy prod/aws/us-east-1
```

An account that already has an installation is deployed to with no one-time setup
and no prompt; and because the run only ever *observes* it in that case, no
durable resource is touched again.

The environment is created in place as well, as part of the same whole-target
deploy rather than a separate command. Once the installation is
established, the run reconciles the environment (network, cluster, database and
platform) and then reaches the cluster it created as the *deploy* identity, so it
continues straight into migration and deployment:

```text
$ sol deploy prod/aws/us-east-1 --image-ref charge_svc="$REGISTRY/pluto/charge-svc@sha256:$DIGEST"

Profile: production-single-region/v1 (preflight passed)

Sol does this for you: reconcile the environment for prod/aws/us-east-1 — network,
cluster, database and platform — from the durable installation, and establish this
run's own cluster access.
...
The environment for prod/aws/us-east-1 is provisioned.
  cluster access identity: arn:aws:iam::<account>:role/sol-deploy (this run, ephemeral)
...
```

The plan and the profile preflight are built *before* anything is provisioned, so
a blocker that can be named now is named now rather than after the billable
boundary. The deploy identity's cluster access is a temporary kubeconfig for that
run: Sol never writes your `~/.kube/config` or the target file, and never reaches
the cluster as the provisioning identity (`DEC-058`, `DEC-034`). The deploy reconciles
that stage in place, and it is what `sol migrate` needs:
those read the target's declared `kube_context`, so run the printed
`deploy_kubeconfig_command` once and add the context name it writes. Where a provider
declares no deploy identity — GCP today —
the deploy stops after provisioning and prints exactly that command and context.

A second environment needs **no** installation work: it deploys against the
installation that already exists, which is why redeploying never means redoing
registrar or DNS work.

```bash
sol deploy prod/aws/us-east-1     # first environment
sol deploy pilot/aws/us-east-1    # a second one, same installation
```

## Granting a workload cloud authority: `sol grants`, then `sol deploy`

A unit that declares `secrets = ["stripe"]` needs a cloud identity and an IAM grant
of its own. That is a lifecycle separate from infrastructure and from deployment
(DEC-062): a fenced reconciler reconciles the whole target's workload identities and
grants. `sol grants apply` establishes that reconciler's identity and its fence for a
reviewed, deploy-independent change; the whole-target deploy drives the same reconcile
before the workloads run, and fails closed if the access is not effective.

```bash
sol grants plan prod/aws/us-east-1   # review: + payments-api → secret/stripe
sol grants apply prod/aws/us-east-1  # the reconciler establishes it
sol deploy prod/aws/us-east-1        # reconciles it too, then consumes it
```

The plan names the unit, the capability and the resource, so a production credential
being granted is visible before it is granted. The reconciler is target-wide with no
`--scope`: a partial reconcile would revoke every unselected unit's grants, so the
operation does not accept one. A removal is revoked only when the declarations no
longer require it *and* no deployed workload still records using it; when the deployed
state cannot be observed, nothing is revoked.

The target must declare the reconciler's trust principal (`aws.reconciler_trust_principal_arn`
for AWS, `gcp.reconciler_trust_principal` for GCP) and the reconciler's own identity
(`aws.reconciler_role_arn` / `gcp.reconciler_service_account`). A target without them
skips the authorization lifecycle, and `sol grants` refuses to run as the deploy
identity.

`sol deploy` proves the grants are effective before it applies anything, read-only: on
AWS it simulates `secretsmanager:GetSecretValue` against the unit's role for the
declared secret (`iam:SimulatePrincipalPolicy`; its fidelity is `VERIF-021`), on GCP it
reads the secret's IAM policy for the unit's Workload Identity principal. A grant that
is declared but not yet established fails the deploy at plan time, naming the unit, the
grant and the reconciliation to run — so no pod is left waiting in `ContainerCreating`
for a credential that does not exist:

```text
$ sol deploy prod/aws/us-east-1
unit charge-svc does not have effective access to secret/stripe in prod/aws/us-east-1:
the reconciler has not established the grant. Run `sol grants apply prod/aws/us-east-1`,
then re-run this deploy (DEC-062 rule 3).
```

The deploy identity holds no IAM-mutating permission at all — only read-only IAM
visibility — so it can observe effective access but can never create, widen or repair a
grant (`check_deploy_identity_iam.py` holds that structurally).

## Tearing down: destroy an environment, or uninstall Sol

The two operations remove different things, and neither removes the other's.

```bash
sol destroy prod/aws/us-east-1 --apply   # environment only
```

That removes the environment's network, cluster, database and workloads, verifies
their absence independently, and leaves the installation standing: the state
backend, the identities, and the delegated DNS zone survive, so redeploying the
same environment needs no registrar or DNS work again. Sol reports what it
retained and why.

Removing the installation is its own command and is never implied by an
environment destroy:

```bash
sol uninstall prod/aws/us-east-1
```

Without `--confirm` it prints the plan and changes nothing. The plan names what
it would remove (the state facility, and the delegated zone when Sol owns it) and
what it keeps, with the reason: a user-supplied or externally delegated zone,
the registrar NS records (which live outside every provider API Sol can call),
and the four identities, which the durable root does not create — the operator
creates them from its policy output.

When the zone going away is a Sol-created one, it needs its own confirmation
naming the exact domain, because the delegation at the registrar becomes stale
and a recreated zone gets different nameservers:

```bash
sol uninstall prod/aws/us-east-1 --confirm --confirm-dns-zone pluto.example.com
```

After the removal Sol re-observes each resource with the installation's own
probes and reports which are absent; an unqueryable answer is UNKNOWN and fails
closed rather than being reported as removed.

## CLI commands

```bash
mkdir -p sol/secrets.local/demo_ts
for unit in order_svc fulfillment_worker; do
  cat >"sol/secrets.local/demo_ts/${unit}.env" <<'SECRETS'
POSTGRES_URL=postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev
SOL_API_KEY=dev-internal-key
SECRETS
done
sol local deploy          # build, apply each unit's secret values, and deploy workloads
kubectl get pods --all-namespaces  # inspect local workloads
sol local migrate # apply database migrations
```

## Container images

The OCaml units use the same two-stage Dockerfile a scaffolded workspace gets: a
glibc-pinned builder that installs this workspace's dependencies from
`pluto.opam`, then a minimal `ubuntu:24.04` runtime. The build context is the
workspace root -- this directory -- and the images run as uid 65534 to match the
`securityContext` Sol renders into the manifests. To build one by hand:

```bash
docker build -f app/payments/charge_svc/Dockerfile -t pluto-charge-svc .
```

The TypeScript pair has its own story -- npm workspaces, and a runtime stage that
ships only the unit it serves: see `app/demo_ts/README.md`.

## Project layout

```
events/orders/                   ← the scenario's canonical event contract + generated OCaml binding
events/demo_ts/                  ← the scenario's TypeScript projection (same events, TS topics)
events/payments/            ← Charged event contract (payments team owns)
events/comms/               ← Notification_sent event contract (comms team owns)
app/payments/charge_svc/         ← OCaml HTTP service (POST /charges, calls checkout)
app/checkout/checkout_svc/       ← OCaml HTTP service (GET /quote, ingress exposure)
app/comms/notify_worker/         ← OCaml Kafka consumer (subscribes to Charged)
app/demo_ts/order_svc/           ← TypeScript HTTP service demo
app/demo_ts/fulfillment_worker/  ← TypeScript worker demo
contract/                        ← the OCaml contract projection program (`contract/run`)
db/migrations/                   ← SQL migration files (0005/0006 are the scenario's namespaces)
```

`orders_svc` and `fulfilment_worker` are declared in `sol.yml` but have no
directory yet; `FEAT-132` adds them under `app/payments/` and `app/comms/`.
