# AWS live qualification

Live AWS qualification requires explicit operator authorization before billable resources are created. The owning claim contract is `production-single-region-v1-matrix.md`; this procedure is operational guidance, not a second verdict store.

## AWS live qualification procedure

This procedure maps the current AWS matrix to the reference application and live provider observations. A run is evidence only for rows it actually exercises.

### Production identities

Earlier procedure text precondition 3 names **four** IAM roles (provisioner, publisher, deploy, operator).
The bootstrap root emits **five** policy documents and the Run 8 target declares **five**
identities; `cluster_access_policy_json` / `aws.cluster_access_role_arn` — the DEC-034 split
between cloud-substrate mutation and steady-state platform management — is the one earlier runs
omitted. The run's precondition is:

| Identity | Bootstrap output | Target field | Owns |
|---|---|---|---|
| provisioner | `provisioner_policy_json` | `aws.provisioner_role_arn` | cloud substrate mutation; access-entry / policy association |
| cluster-access | `cluster_access_policy_json` | `aws.cluster_access_role_arn` | steady-state platform management |
| deploy | `deploy_policy_json` | `aws.deploy_role_arn` | application / release mutation, namespace-scoped |
| operator | `operator_policy_json` | `aws.operator_role_arn` | read-only diagnostics |
| publisher | `publisher_policy_json` | — (never a target field) | ECR push only, on its own assume-role session |

The qualification transport principal is a **sixth** identity, created by the harness for the
transport only (`internal/qualification/transport/`), never named by a target field
(DEC-039 §3). Earlier procedure text step 10 "four-identity check" is read as five for this run.

### Alpha row reconciliation (the run's scope)

The workload is the frozen reference scenario, implemented by `FEAT-131`/`FEAT-132` in the
OCaml namespace; the TypeScript namespace is not in the production profile (DEC-026 §2).
The harness binds the scenario through `SVC_UNIT`/`WORKER_UNIT` (with their directories
`SVC_DIR`/`WORKER_DIR`), `APP_NS`/`WORKER_NS`, `APP_SERVICE`, `APP_PORT` and `SCENARIO`. The
pre-campaign shape is the default (`charge_svc`/`notify_worker`, `charges`); the alpha binding
is `SVC_UNIT=orders_svc WORKER_UNIT=fulfilment_worker APP_SERVICE=orders-svc SCENARIO=orders`
(with `SVC_DIR=payments`, `WORKER_DIR=comms`, `APP_NS=pluto-payments`, `WORKER_NS=pluto-comms`
unless `FEAT-131`/`FEAT-132` land different names — then the binding values change, not the
mechanism). The alpha rows whose target includes `aws`, and the AWS matrix rows that carry them:

| Alpha row | Capability | AWS matrix row(s) | This run |
|---|---|---|---|
| B1 | Service accepts a request | B3 | in scope |
| B3 | Outbox relay | B3 | in scope |
| B4 | Worker consumes and mutates | B3 | in scope |
| C1 | Migrations apply | C1 | already `PASS (LIVE, Run 7)`; re-confirm |
| C2 | Deploy migration gate | C1–C5 | in scope (LIVE completion) |
| C3 | Per-migration checksum | C2, C5 | in scope (LIVE) |
| C4 | Postgres durability (AWS) | E1–E4 | in scope |
| C5 | Durable leased jobs | FEAT-077 rows | in scope (LIVE) |
| C6 | Transactional outbox | E11 | in scope (LIVE) |
| D1 | Topic provisioning | FEAT-117 rows | in scope (LIVE) |
| D4 | Retry/DLQ topology | FEAT-076/078/118 rows | in scope (LIVE) |
| D5 | Decode-error DLQ | OB-F2 | in scope (LIVE) |
| D7 | Broker durability (AWS) | E7 | in scope |
| D8 | Broker loss + resume | E5, E6 | in scope |
| E2 | Production SASL_SSL | FEAT-093 row | in scope (LIVE) |
| E4 | Managed secret projection | — | in scope (`VERIF-021`) |
| E5 | Projected SA tokens | — | **blocked**: `FEAT-134` (implementation) then `VERIF-022` |
| E6 | Workload cloud authority | I3, F5 | in scope (DEC-062 / `VERIF-021`) |
| E7 | Scoped identities | I2, I3, I6, F5 | in scope (LIVE completion) |
| E8 | No ambient token / no leaked secret | F1, F4 | in scope |
| F1 | Profile preflight | A1–A11 | already `PASS (LIVE, Run 7)`; re-confirm |
| F2 | Provision + normal deploy | B1 | in scope (the profile row is the one Run 8 did not claim) |
| F3 | Idempotent re-deploy | B2 | in scope |
| F4 | Failed deploy + rollback | B4–B6 | in scope |
| F5 | Drift detection | B7 | in scope |
| F6 | Immutable artifacts | DEC-026 §6, SEC-011 | in scope (registry digest verification) |
| F7 | Release provenance | FEAT-110, DEC-057 §9 | in scope (LIVE completion) |
| F8 | Observed → desired contract | FEAT-130 | in scope (LIVE) |
| H1 | Bad-message / DLQ | OB-F2 | in scope (LIVE) |
| H3 | Deploy → fail → diagnose → rollback → recover | B | in scope |
| H4 | Availability | D1–D8 | in scope |
| H5 | Broker loss | E5, E6 | in scope |
| H6 | Postgres failure / restore | E2–E4, E11 | in scope |
| H7 | Telemetry loss | E10 | in scope |
| I1 | Installation | AWS Run 7 | already `PASS (LIVE)`; prerequisite |
| I2 | Environment to `Ready` | I1–I6 | already `PASS (LIVE)`; re-confirm |
| I3 | Ready-state destroy | I9, H6 | in scope (AWS `NOT RUN`) |
| I4 | Destroy from partial / failed install | I10 | in scope (AWS) |
| I5 | Destroy idempotence | I11 | in scope |
| I6 | Retention | I8 | already `PASS (LIVE, Run 7)` |
| I7 | Uninstall | DEC-057 §7 | in scope |
| I8 | Independent absence verification | H6, DEC-045 | in scope (LIVE completion) |
| — | Delivered-and-acknowledged alert (AWS matrix G1–G3) | G1–G3 | **BLOCKED**: a real receiver and an owner who acknowledges |

Rows the run does not reach stay `NOT RUN` in the record; they are not inferred from a later
command's output.

### Prerequisites (all present before any billable resource is created)

**Environment**

1. A fresh, disposable, isolated AWS account and an unexpired SSO session for the operator's
   profile (`aws sts get-caller-identity` names the qualification account).
2. `aws`, `terraform` ≥ 1.5, `kubectl`, `dig`, `jq`, `python3`, and
   `script` (util-linux, used to confirm the inline installation offer on a fresh
   account); `docker` reachable from the
   shell that runs the app phase (`docker version` succeeds, or run under `sg docker -c`).
   `opam` + `dune` are needed only if the runner is built from source rather than taken from
   the release.
3. The **released bundle** (`RELEASE-006`): `sol-<version>-linux-x86_64.tar.gz` extracted,
   `SOL_HOME` unset, `sol --version` reports the tag, `sol assets` reports every asset
   present. `SOL=<bundle>/bin/sol` selects it for the harness.
4. Runtime inputs, never in the repository: `TF_VAR_db_password` (≥ 8 characters, no `/`,
   `@`, `"`). No `POSTGRES_URL` is held: the deploy reads the cluster
   root's own `postgres_url` output and delivers `<target>-ddl-creds` to the migration Job
   and `<target>-dml-creds` to a consuming unit (2b). The workspace declares no unit-level
   runtime secret (its only declared secrets are the two Kafka platform inputs), so the
   harness supplies exactly those.
5. The durable bootstrap root applied: the state bucket and lock table, and the delegated
   `qual-aws.sol-fab.dev` zone with `manage_dns_zone=true`. The zone is durable and outlives
   the target.
6. The five IAM roles created by the operator from that root's generated policy documents
   (`terraform output -raw <name>_policy_json`), each used on its own session — the publisher
   on a session used by nothing else. Sol owns the policy contracts, never the role
   lifecycle. The harness is given the publisher's ARN as `PUBLISHER_ROLE_ARN` and assumes
   that role itself: publication never runs on the operator's ambient credentials, and the
   phases that publish refuse rather than fall back when the ARN is absent or the session
   cannot be assumed (`internal/qualification/aws/live-row.sh`).
7. The qualification transport role (a name the harness is given, never a target field).
8. A target file `examples/pluto/sol/environments.local.yml` copied from
   `aws-target.example.yml` with real values. It is untracked by design, so the record
   carries its contents or a hash plus its path. It declares `profile: production-single-region`,
   the five role ARNs, `kube_context`, the registry, `terraform_var_file` (the
   qualification tfvars the cluster and platform roots read; `sol deploy` takes no
   `--var-file`, and the harness refuses a target that names none rather than deploy the
   roots with their default variables), `cluster_endpoint_cidr` (never
   `0.0.0.0/0`), `node_failure_headroom_nodes`, `destroy_retention: none`, and the two
   TypeScript units omitted. The alert fields are required by the profile preflight; they are
   set to a real receiver only when pursuing G1–G3, and the run records G as blocked otherwise.
9. Explicit operator authorization for the live run and the release
   version (§7.6).
10. Read access to this target's Kafka authority in AWS Secrets Manager, plus the
   cluster-access identity's existing broker/consumer Secret reads. Sol generates and
   persists the credential and projects it into Redpanda and declared consumers. The
   harness never generates, replaces, or writes these credentials. `kafka-delivery.json`
   records comparisons without values; the application transaction proves authentication
   and message processing. Terraform state remains sensitive and remote; captured state
   evidence contains only public references and input-presence metadata.

### Expected resources and cost-bearing steps

Billable from the whole-target deploy until the independent inventory is `ABSENT`; the cost rule is
absolute (tear down before asking). The target creates, at least:

| Resource class | Declared by | Teardown class |
|---|---|---|
| EKS cluster + control plane | cluster root (`kubernetes_version` 1.36) | cluster |
| Managed node group, 4 × `m6i.xlarge` desired | cluster root | cluster |
| RDS PostgreSQL Multi-AZ, `db.t4g.small`, engine 16.15 | cluster root | database (plus its snapshots) |
| VPC, subnets, route tables, one NAT gateway + EIPs | cluster root | network |
| EBS volumes (PVCs, node root disks) | storage class / PVCs | storage |
| Application/ingress load balancer | platform (ingress) | load balancer |
| ECR repositories | cluster root (`pluto/<unit>`, the release's own) | registry (empty after teardown) |
| CloudWatch log groups | platform | logs |
| Route 53 `qual-aws.sol-fab.dev` | durable bootstrap root | **retained** (durable, not a target resource) |

The nodes dominate the hourly cost; the run's own gate is the operator's authorization, and
the destroy is part of the run, not a follow-up. A run that stops early is still destroyed.

### The run, phase by phase

`internal/qualification/aws/live-row.sh <phase>` orchestrates Sol's public commands and reads
provider/Kubernetes state independently. It never invokes `terraform` or `helm`: the `cloud`
phase reconciles the *durable* installation inline (the operator's prerequisite) through the
installed release's `sol deploy <target>` — its first-run offer is confirmed through `script`
on a fresh account — and every disposable-target step
goes through Sol. `SOL` selects the released bundle.

**`prepare`** — build the application images bound to the candidate (`sol_candidate_bind_context`)
and touch no provider state, so the specimen stays fresh for `cloud`. Evidence: `app-build.log`,
`app-build-context/`, `candidate-binding.txt`, `app-built-tags.txt`.

**`cloud`** — `sol deploy <target> --registry <registry>` with **no** `--image-ref`: the release
names no digest yet, so Sol reconciles the durable installation, the cluster and the platform
(the row's `qual-aws-row.tfvars` reach the roots through the target's `terraform_var_file`, since
`sol deploy` takes no `--var-file`) — the cluster root creates the `pluto/<unit>` repositories the
target's release names — and then refuses at the immutable-artifact gate with `Deployment
incomplete.`, before any workload moves (issue #1473). The phase succeeds on the reconciled
environment (`The environment for <target> is reconciled.`) **and** that refusal, not on the
deploy's exit code. A Kafka authority or initialization failure blocks the run; the
harness never repairs it with operator-supplied credentials. Before publishing, establish the
cold-start boundary from the cluster as **namespace absence**, over the complete set of namespaces
the target's selected units declare (derived from the candidate-bound build context, never from a
fixed pair of names): a namespaced workload or release cannot exist without its namespace, so
every declared namespace must read positively absent. The read runs under the cluster-access
identity and its view is validated first — a namespace that must exist must be readable, and a
name that cannot exist must answer `NotFound` rather than `Forbidden`, because a filtered view
would answer `NotFound` for a namespace that exists. A namespace that exists, a read that fails or
times out, an unproven view, or a selection that does not cover every selected unit is UNKNOWN,
never a pass; a namespace set that omits a consumer refuses the phase rather than passing
vacuously. This establishes the absence of namespaced workloads and releases, not of
cluster-scoped objects, which the target's roots own. Then publish
the images `prepare` built into the repositories Sol created **as the publisher identity**: the
harness assumes `PUBLISHER_ROLE_ARN` on its own session, records the identity that session answers
with in `publisher-identity.txt`, and refuses to publish at all when the ARN is absent or the
session cannot be assumed. `docker inspect` each image for its digest,
and preview the whole target with `sol plan <target> --var-file <tfvars> --image-ref
<unit>=<repo>@sha256:<digest>`; build the deploy/access/operator kubeconfigs; capture nodes and the
cluster root credential-free metadata. Evidence: `cloud-apply.log`, `cold-start-namespaces.txt`, `cold-start-namespaces-*.err`, `cloud-plan.log`, `publisher-identity.txt`,
`ecr-sol-repositories-before.txt`, `ecr-sol-repositories-after.txt`, `prerequisites.txt`,
`k8s-nodes.txt`, `state/cloud.tfstate`, and the verbatim `lifecycle phase:` line per invocation.
Rows: I1, I2, I4, A, F1, F2.

**`transport`** — probe the production identities for `pods/portforward` (must answer `no`),
establish the qualification transport
(`internal/qualification/transport/establish.sh <cluster> <qualifier-role> <region> <namespace>`),
record the qualifier's own `auth whoami` session, probe the production identities again, and
confirm the qualifier can open the transport. Evidence:
`transport-separation-pre.txt`, `transport-establish.log`, `transport-whoami.json`,
`transport-separation-post.txt`. Rows: E7, INFRA-060 criterion 5, DEC-039 §4. The record names
the transport identity separately from the identities under qualification, and shows none of
the latter holds `pods/portforward` before or after.

The observation reads (`deployments`, `jobs`, `configmaps`) are namespace-scoped RoleBindings,
so they can be bound only after Sol has created the declared application namespaces. `app`
therefore establishes the transport after its first deploy — which moves no workload — and
before the migration observation. The standalone `transport` phase refuses on a fresh target
rather than binding those reads cluster-wide: the phase name is a diagnostic/re-run entry point
for a target whose declared namespaces already exist, not a pre-deploy step.

**`app`** — Sol's work with the digests the cloud phase published: `sol migrate apply <target>`,
`sol deploy <target> --registry <registry> --image-ref
<unit>=<repo>@sha256:<digest>` for every selected unit, then drive the representative
transaction through the transport (`transport-transaction.sh`, port-forward to the private
`ClusterIP`). Evidence: `app-transaction.log`, `transport-port-forward.log`,
`transport-transaction.txt`, `k8s-pods.txt`, `state/cloud.tfstate`. Rows: B1, B3, B4, C1–C6,
D1, D4, D5, F2, F6–F8. The read-back is the application's own effect — the worker's row
visible to the service — never broker progress (DEC-039 §5). Both paths decide it through
`transaction.py`: a typed nonempty operation identity and an exact matching read-back entry.
Textual substring matching cannot establish success, so an empty or malformed response cannot
be read as the worker's effect.

**`destroy`** — select the Kubernetes destination explicitly (`destroy_kube_destination`): the
attempt's own deploy kubeconfig when the declared cluster is readable and that kubeconfig
addresses its current endpoint, an empty config when the provider positively answers the
cluster is absent, and a recorded `blocked` when the cluster cannot be read or reached — so
a fresh session's shell never decides, and a stale same-named context can never aim the
release at another cluster. Then capture both roots' state with `terraform state pull` into
the bundle, run `sol destroy <target> --apply`, then the independent inventory. Evidence:
`destroy-kubeconfig.txt` (the classification), `cloud-destroy.log`, the inventory files.
**`verify`** runs the inventory alone. Rows: I3, I5, I7–I9, H6.

### VERIF-021 — managed secret projection and the fenced grant (alpha E4, E6)

This is a live cell of DEC-029's driver × runtime table, run inside the target so the
substrate is shared. The CSI driver and the AWS provider are **not** Sol platform components
(`docs/deployment/compatibility.md` records them as candidates); the run installs them out of
band, as `VERIF-020` did for Vault, and records the chart and provider versions.

1. Reconcile the declared secret grant with `sol grants plan <target>` / `apply <target>`
   (DEC-062, `FEAT-127`), so the unit has a real fenced identity.
2. Create a `SecretProviderClass` with `provider: aws` for a Secrets Manager secret under the
   environment's path, and confirm the provider authenticates as the **pod's** identity
   (IRSA / EKS Pod Identity), never the node's.
3. A granted unit reads the value; remove the unit's grant and confirm the read is
   `AccessDenied` while a granted read still succeeds.
4. `enableSecretRotation` updates the mounted file within the stated bound; measure the
   rotation-to-file-change delay. A new pod fails closed while the authority is unavailable;
   a running pod keeps its last-known value.
5. DEC-062 rule 6: run `aws iam simulate-principal-policy` against the unit's role for an
   allowed and a denied action, including a permissions boundary, and compare with a real
   call. Record on `DEC-062` whether the simulation reflects boundaries, resource policies
   and SCPs; if it does not, the deploy-time verification (`FEAT-128`) needs a mechanism that
   does.

Evidence: the exact commands and outputs, the provider/CSI versions, the measured delay, and
the DEC-029 cell verdicts.

### VERIF-022 — projected ServiceAccount tokens (alpha E5) — blocked on implementation

`VERIF-022` qualifies the DEC-063 mechanism: a projected ServiceAccount token volume with
`audience: <callee unit>` and `expirationSeconds: 3600`; no Kubernetes API access; issuer
discovery; caller/`calls`-graph authorization (`401`/`403`/wrong-`aud`); key rotation; and
refresh without restart.

**It cannot be collected in this run today, and the blocker is implementation, not
authorization.** The callee-side generic JWT verification exists
(`framework/ocaml/sol-svc/lib/auth.ml`, `Jwks_url` + JWKS fetching), but DEC-063's mechanism
is absent from the tree: no Kubernetes `serviceAccountToken` projected volume is rendered
(`rg -n 'serviceAccountToken|expirationSeconds' cli/ framework/` finds no projected volume;
the manifest builder only sets `automountServiceAccountToken: false`), and the caller API
`Service.call` and the `calls`-graph authorization do not exist (`rg -n 'Service\.call'
framework/ cli/` finds nothing). `FEAT-134` implements DEC-063's already-decided API; the
pluto `calls` edge it updates is `payments/charge_svc` → `checkout/checkout_svc`. Until that
lands, E5 is `BLOCKED` — recorded as blocked, never weakened.

### Failure injections (each is a scenario, not an accident)

| Row | Injection | Observable |
|---|---|---|
| B4 | deploy a workload that cannot become ready (bad probe/image) | deploy exits non-zero; the prior release stays authoritative; pods unchanged |
| B6 | roll back across a `contract` migration | refused, naming the migration boundary; pointer unchanged |
| C2 | add a migration file without applying it, then deploy | deploy fails closed naming the missing migration; no workload mutated |
| C3 | edit an applied migration, then `sol migrate status` / deploy | the checksum mismatch is reported |
| D5, H1 | produce an undecodable record to the worker's topic | structured decode log, `sol_worker_decode_errors_total`, a DLQ record on `<topic>.<group>.dlq` with the raw bytes, and the source offset advancing |
| H2 | make the broker unreachable, then restore it | the relay holds; recovery publishes; a relay restart preserves `ord` order |
| H4/D3 | terminate a node's EC2 instance with no drain | measured time from `NotReady` to required ready capacity restored; PASS iff ≤ 300 s |
| H5/E5/E6 | produce N `acks=all` messages, kill one broker | none lost; measured consumer auto-resume ≤ 60 s |
| H6/E2–E4 | `aws rds reboot-db-instance --force-failover`; PITR restore into a clean target | measured RTO/RPO within the matrix bounds; the app serves a transaction after each |
| H7/E10 | stop the telemetry backend | the app is unaffected; the telemetry gap is recorded, with no business-data claim |
| I10 | stop the platform install partway, then `sol destroy --apply` | the destroy succeeds and enters `PreparingDestroy`; no out-of-band deletion |
| I12 | interrupt a destroy between preparation and destruction, then re-run | the second run completes without reusing the first attempt's snapshot identity |

### Teardown and independent absence verification

1. `terraform state pull` for both the cluster and platform roots into the evidence bundle
   **before** any teardown (ledger rule 4).
2. `sol destroy <target> --apply`, run from a fresh session as well as a continued one: the
   phase selects the destination itself (this attempt's kubeconfig, or none) and records in
   `destroy-kubeconfig.txt` whether the workload release was `attempted`, `skipped` because the
   cluster is positively absent, or `blocked` because the cluster could not be read or reached —
   an unreadable cluster or an unreachable API is UNKNOWN there, never a skipped release.
   Capture every `lifecycle phase:` line and the
   terraform argv (I7's `-var` order, I8's targeted preparation, I9's `Destroying` → `Absent`).
3. Before teardown, the harness captures independently attributed EBS volume IDs, EIP allocation IDs, load-balancer ARNs, security-group IDs
   and the EKS issuer in `aws-pre-teardown-identities.json`, bound to the attempt, target, account,
   region and candidate. It also captures after cloud reconciliation while the cluster still exists.
   Retries preserve captured identities; failed capture refuses teardown. Final verification requires
   that capture, so tag loss and cluster removal cannot erase historical ownership. Missing or
   mismatched capture is UNKNOWN. These are provider reads, independent of Sol and Terraform state.

   Independent inventory (`absence.py`, read-only), tri-state `PRESENT` / `ABSENT` / `UNKNOWN`,
   over EKS clusters, RDS instances, subnet groups and snapshots, EC2 instances, VPCs, NAT gateways,
   EIPs, EBS volumes, OIDC providers, security groups, ELBv2 load balancers, ECR repositories, IAM roles and policies, S3 buckets,
   CloudWatch dashboards and log groups. Each class enumerates the provider and attributes what it
   returns to this target by the target's cluster tag, cluster-name prefix or declared registry
   path, so an unrelated account resource is not residue and an attributable one is found after the
   target disappears. A read that failed, timed out, was not JSON, did not have the class's expected
   shape, or could not be attributed is `UNKNOWN`, never absence. Only an all-`ABSENT` verdict
   passes; the matrix's H6 row is this set and this tri-state contract. The matrix's "assertions
   that ride along" requires the absence checks to have been seen to fail against a real residual.
4. The durable Route 53 delegation zone is recorded separately and is not part of the residue
   verdict: it is the contract that outlives the target, not a leak. Confirm it is present and its
   nameservers are unchanged, and that no snapshot, bucket, address or volume is retained
   (`retention: none`).
5. Re-run `sol destroy <target> --apply` against the now-`Absent` target: exit 0,
   `Absent`, no preparation (I11).

### Released-bundle interface (RELEASE-006, landed)

`RELEASE-006` part A moved the AWS and GCP harnesses onto the installed bundle and pinned it
with a harness test. The run uses that interface: `SOL_INSTALL` is the extracted prefix,
`SOL_HOME` is unset, `sol --version` equals the bundle version, the released platform bundle
lives under `share/sol/<version>/platform`, and the bundle's
`share/sol/<version>/migration-runner-image` pins the migration runner **by digest**. The
harness does not publish a runner and hands Sol no runner reference; an installed Sol refuses
`SOL_MIGRATION_RUNNER_IMAGE` because a release uses only its own assets (DEC-049). The harness
records the bundle version and that digest in `sol-identity.txt`. The run does not start against a
checkout build: the artifact a user installs is the thing under qualification (J3).

### What a run does not establish

- The delivered-and-acknowledged alert (AWS matrix G1–G3) without a real receiver and an owner.
- Alpha E5 (`VERIF-022`) until `FEAT-134` lands, and the DEC-063 mechanism on `gcp`/`byo`.
- The TypeScript production profile (DEC-026 §2), GCP, `byo`, `self_hosted_durable` /
  `external` observability, zone-failure tolerance, multi-team RBAC, admission policy,
  federation, and signing/SBOM (the matrix's section J).
- Any row it does not reach: those stay `NOT RUN` with the reason, never promoted.
