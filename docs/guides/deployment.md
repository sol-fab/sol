# Deploying to your own cloud

From "it runs locally" to "it is running in my AWS account": choosing a target, provisioning the
substrate, deploying the application directly or through GitOps, and wiring CI.

This is the narrative path. The operator-level detail is
[production-bootstrap.md](../deployment/production-bootstrap.md) (the durable installation, identities and
recovery), [substrate.md](../reference/substrate.md) (what Sol generates and what you bring),
[escape-hatches.md](../deployment/escape-hatches.md) (the `sol.toml` overrides), and
[compatibility.md](../deployment/compatibility.md) (what a profile admits today). This page links them instead
of repeating them.

For ambiguous provisioning outcomes and exceptional deletion guards, see
[partial-state recovery](partial-state-recovery.md).

## 1. Choose a target

A target is `<env>/<provider>/<region>` — `prod/aws/us-east-1`. It is the only thing a
deploying command needs, and it is always the positional:

```bash
sol deploy prod/aws/us-east-1       # target-addressed: the target is the positional
```

Two layers, doing two different jobs (`DEC-016`):

- The **environment** is *policy*: the profile it selects, its base domain, resource sizes,
  service scaling, the alert-delivery contract. It is declared once in
  `sol/environments.yml` — pluto declares `prod`, `pilot`, `dev` and `customer_cloud`.
- The **target** is *where*: the provider and region, and the cluster name.

```yaml
prod:
  base_domain: pluto.example.com
  letsencrypt_email: ops@pluto.example.com
  shape: local
  services:
    charge_svc:
      scale:
        min: 1
        max: 2
  targets:
    aws/us-east-1:
      cluster_name: pluto-prod
```

`sol deploy prod/aws/us-east-1` resolves `sol.yml` → `prod` → `aws/us-east-1`, a lower layer
overriding a higher one. There is no `--env` and no ambient current target: the destination comes
from the target, not from the shell (`DEC-020`). Account-specific values you would rather not
commit go in `sol/environments.local.yml`, which is gitignored and may only add keys
`environments.yml` leaves unset.

An environment's **name never selects a profile**. `prod` above deliberately has none, and
`pilot` selects the production profile explicitly with `profile: production-single-region` — so a
"production" deployment is a decision you write down, not a name you type.

Every cloud target also **declares its platform shape** — `shape: local` for a deliberate
development posture (plaintext Kafka), `shape: durable` for authenticated Kafka and durable
infrastructure. `production-single-region` requires `durable`. A plan against a cloud target
that omits `shape` is refused before anything is provisioned, rather than silently defaulting
to a development shape.

Inspect what a target resolves to before changing anything:

```bash
sol target show prod/aws/us-east-1
sol plan prod/aws/us-east-1 \
  --image-ref charge_svc=registry.example/charge@sha256:<64-hex-digest>
```

`sol plan` resolves the target once, then previews its target-wide infrastructure and
authorization plans plus the desired workload images. On an existing deployment, omitted
image refs inherit immutable images from the current release record; supplied refs override
those images. A first deployment needs one immutable `--image-ref` for every non-omitted
workload. If the current cluster or release record cannot be read, supply the complete map
explicitly. If the durable installation is positively absent, Sol shows its bootstrap plan
using temporary local state. Partial or unknown installation state is deferred. Planning
never applies changes.

`sol plan` also reports the **live workload delta**, classified only by recorded UID
evidence: each declared workload is `create`, `owned, unchanged`, `live, not owned`, or
`recorded, gone`, and live workspace objects the plan does not declare are listed as
surplus (`removable` only while the live UID matches the UID captured at apply, otherwise
`retained`). When the cluster, credentials, or a kind cannot be observed, Sol says so
explicitly and infers nothing about those objects: absence of observation is not
observation of absence. Kubernetes live-object changes are never inferred from labels or
declarations; removal requires positive ownership evidence (see
[resource ownership](../architecture/ownership.md)).

## 2. The installation comes first, once per account

The durable layer — the Terraform state backend and locking, the provisioning/cluster-access/
deploy/operator identities, and the delegated DNS zone when Sol owns one — is per **account**, not
per environment. It outlives every environment, which is why `sol destroy` removes an
environment and never the installation.

**Guided first-run.** `sol deploy` observes the durable installation and offers to establish it
when needed. After that, every cloud-backed deploy reconciles the target's cluster and platform
roots before continuing to authorization and workloads. `--dry-run` and `--emit-to` remain
read-only. The durable installation stays separate: `sol uninstall` removes it under its own
confirmation contract. Where a provider declares no deploy identity — today, GCP — the run stops
after provisioning and names the kubeconfig command and `kube_context` the operator must add. The
identity contracts and external setup steps are in
[production-bootstrap.md](../deployment/production-bootstrap.md).

## 3. Provision the substrate

The substrate is the cluster and platform components Sol runs on it. `sol plan` is the read-only
review step, and `sol deploy` reconciles the whole cloud-backed target:

```bash
sol plan prod/aws/us-east-1                     # full target preview; nothing is applied
sol deploy prod/aws/us-east-1                   # reconcile infrastructure and workloads
```

- `sol plan` previews the existing target Terraform roots, authorization, and workload changes.
  Cluster and CRD prerequisites are reported as explicit deferrals when they are not yet present.
- `sol deploy` applies fresh Terraform plans for the existing roots, verifies the platform, then
  reconciles configured authorization, workloads, and removals. A service removed from the
  declarations is removed from the cluster only while its live object's UID still matches the UID
  Sol recorded at apply. If an owned removal cannot be completed — unreadable evidence, an
  unobservable live set, or a failed delete — the deploy fails before advancing the release record,
  so the next deploy retries with the same evidence. Uncertain state, unsafe grant revocation, and
  unknown Kubernetes ownership fail closed.
- `sol deploy` re-applies every declared workload, but each workload carries its own immutable
  identity; changing one workload's image or configuration does not change the Pod template of an
  unchanged one, so it does not roll out.
- Target teardown is `sol destroy <target>`. It does
  not remove the durable installation; use `sol uninstall` for that separate scope.
- Add workspace Terraform under `sol/terraform/<provider>/{cluster,platform}`. It joins the
  matching existing root and state; see the
  [substrate reference](../reference/substrate.md#workspace-owned-terraform) for the stable
  `local.sol_target` interface.

What the substrate contains, and which parts Sol generates versus which you bring, is
[substrate.md](../reference/substrate.md). The `sol.toml` overrides that change what Sol renders
are [escape-hatches.md](../deployment/escape-hatches.md).

**Profiles admit less than Sol can run.** A target that declares a profile runs that profile's
preflight, and the preflight refuses until the target establishes every guarantee the profile
requires, naming each unmet guarantee and who must act. Today the profile admits OCaml
applications on AWS: TypeScript is staged (`DEC-026` §2, the standing goal **FEAT-102**), and GCP
is not a qualified provider for it. The current verdicts, with their evidence, are in
[compatibility.md](../deployment/compatibility.md).

## 4. Deploy the application

Images must already exist in a registry: Sol deploys images, it does not build them in the
deploying command (a `sol build` is planned, not shipped). Choose how the manifests reach the
cluster.

**Direct mode** — the CLI renders and applies:

```bash
sol deploy prod/aws/us-east-1 --registry 123456789.dkr.ecr.us-east-1.amazonaws.com --image-tag "$SHA"
```

**GitOps mode** — the CLI renders and you commit the result, and a controller applies it:

```bash
sol deploy prod/aws/us-east-1 --emit-to manifests/ --image-tag "$SHA"
```

**Which to choose.** Direct mode is the shorter path: one command, and the cluster credentials
live wherever the command runs. GitOps buys you a reviewable diff of what is about to change and a
controller that reconciles drift, at the cost of a pipeline that commits. Both render the same
manifests from the same inputs — the difference is who applies them, not what they say — so
switching later is a change of mechanism, not of contract.

Both modes take the same inputs, and both are honest about what they would do:

- `--dry-run` runs everything except the change.
- `--emit-plan-to plan.json` captures the typed deployment intent without rendering, which is what
  a review gate should consume.
- `sol deploy` reconciles the whole target; there is no `--scope`. The desired workload set
  must be singular so a later removal can be authorized against it, so a narrow update is a
  separate, explicitly non-deleting operation (`sol rollback`) rather than a partial deploy.
- `--keep-releases N`, `--loki-push-url` and `--confirm-group-change` cover release retention,
  telemetry destinations and explicit authorization for removing a consumer group. The check
  reads the recorded set while the deploy holds the workspace lease.

Never rebuild the plan/render/execute logic in your own CI: all deployment decisions (image tags,
namespaces, discovery, secrets) belong to `sol deploy`, and CI's job is to supply the inputs
(`--registry`, `--image-tag`).

Deployed releases are records, not folklore:

```bash
sol releases --target prod/aws/us-east-1     # what is deployed, by content-addressed id
sol rollback <release-id> --target prod/aws/us-east-1  # restore a recorded boundary
```

`sol rollback` refuses when a migration since that release is contracting, because restoring
workloads cannot un-apply that.

## 5. CI

Generate the supported workflow into an existing workspace:

```bash
sol ci init github
```

It writes `.github/workflows/sol-ci.yml` (also scaffolded by `sol new workspace`) and prints the
repository variables and provider-side trust it expects. It never overwrites a workflow you have
edited; pass `--force` when you mean to replace one. The generated workflow is checked in at
[`examples/pluto/.github/workflows/sol-ci.yml`](../../examples/pluto/.github/workflows/sol-ci.yml).

The workflow authenticates with **GitHub OIDC** — no long-lived cloud credentials are stored in the
repository. It uses two identities, deliberately separate (`DEC-062` rule 1): the **deploy** identity
runs the deploy, and the **reconciler** identity runs workload authorization, so the identity that
deploys cannot grant cloud authority. The exact subjects, jobs and variables are in
[`deployment/ci.md`](../deployment/ci.md). Configure the provider side once:

- **AWS**: an IAM OIDC provider for `token.actions.githubusercontent.com`, then a deploy role scoped
  to the `production` environment (`SOL_DEPLOY_ROLE_ARN`, the target's `deploy_role_arn`) and a
  reconciler role scoped to the `sol-authorization` environment (`SOL_AUTHORIZATION_ROLE_ARN`, the
  target's `reconciler_role_arn`).
- **GCP**: a Workload Identity Federation provider bound to this repository, plus the deploy service
  account (`SOL_WORKLOAD_IDENTITY_PROVIDER`, `SOL_DEPLOY_SERVICE_ACCOUNT`) and the reconciler
  service account (`SOL_AUTHORIZATION_SERVICE_ACCOUNT`).

Protect the `sol-authorization` environment with required reviewers: the `authorize` job runs under
it (`sol grants plan`, then `sol grants apply`), so adopting, dropping or widening a workload cloud
grant is a reviewed action separate from the deploy. The `deploy` job depends on `authorize`, so a
declared grant is established before the deploy that consumes it — and `sol deploy` still fails
closed if it is not effective.

`SOL_TARGET` is a repository variable and is passed to `sol deploy` verbatim; the workflow never
infers a destination from the branch or the event (DEC-016). Workload secret values are never held
by CI (FEAT-053). Seed Sol-owned values from a secret source through stdin, for example:
`your-secret-tool get payment-api-key | sol secret set "$SOL_TARGET" payments/charge_svc/PAYMENT_API_KEY --from-stdin`.
Database access needs no CI step: a unit that declares `uses: [app_db]` reads the target's
`<target>-dml-creds` class Secret, and the migration Job reads `<target>-ddl-creds`, both delivered
by the deploy from the target's binding — never from an operator-held `POSTGRES_URL`.
Every required key has an explicit `sol` or `external` authority mapping in the target declaration.
Sol-owned values live in that unit's Kubernetes Secret. For an external key, declare a namespaced
`SecretStore` and remote key under the same unit, for example:

```yaml
production:
  targets:
    aws/us-east-1:
      secrets:
        payments/charge_svc:
          PAYMENT_API_KEY:
            authority: external
            store: payments-vault
            key: production/payments/api-key
```

The SecretStore and ExternalSecret are namespaced to the unit's domain. Sol does not install ESO or
create the SecretStore; install the controller and configure its controller identity, provider
permissions and namespaced SecretStore before deploying. Sol renders `external-secrets.io/v1`, so it
requires an ESO release that serves that API: v0.16 or later (v0.17 stopped serving `v1beta1`).
That is an API-compatibility floor, not a qualified upgrade range; see the
[compatibility contract](../deployment/compatibility.md#operator-supplied-external-secrets-operator).
Direct deploy waits for ESO to report `Ready=True` with reason `SecretSynced`, verifies that the sync
names the current spec (below),
checks the materialized Secret's key set, and then verifies rollout readiness. GitOps emits the same
ExternalSecret and workload references; Argo CD and ESO reconcile after CI writes the manifests.
`sol plan` reports declarations, not proof that provider credentials can read a value.
`sol secret status` evaluates the same readiness state as the deploy, once and without waiting,
and reports why a Secret is not ready; it cannot prove an already-running process has loaded a
rotated value.

ESO's ExternalSecret `Ready` condition carries only `type`, `status`, `reason`, `message` and
`lastTransitionTime`; it publishes no observed generation. To verify that ESO has processed the
spec Sol just applied, Sol reads `status.syncedResourceVersion`, whose generation prefix changes
only when the object changes, so a periodic `refreshInterval` refresh cannot produce it. This
format is an ESO implementation detail rather than a documented API guarantee, but missing
freshness evidence is not treated as fresh: a `Ready=True`/`SecretSynced` condition with no
generation-bound synced version is refused immediately, because waiting cannot manufacture the
missing signal and an earlier sync would otherwise be accepted as evidence for this one. When the
prefix is present but has not reached the applied generation, deploy waits within its bound and
then fails closed. `sol secret status` applies the same predicate without waiting, so it cannot
report `ready` for an observation the deploy would reject.

ESO rotation is manual: rotate at the external authority, wait for ESO sync, then restart the
affected workload with Kubernetes rollout tooling. An unchanged `sol deploy` is not a restart.

The deploy step is the same lifecycle as local execution — `sol deploy <target>` then
`sol migrate <target>` — so nothing about the plan, the render or the apply exists in the workflow.
GitOps mode uses the same workflow with `--emit-to` in place of the direct deploy, and the
`platform/cloud/delivery/argocd/application.yaml` `Application` reconciles what it writes; Sol
ships one CI workflow, not a separate copy per mode.

## 6. What you bring, and what Sol brings

Sol generates the cluster substrate, the platform components and the manifests; you bring the
cloud account, the images, the domain and the decisions above. That split, with the exact list, is
[substrate.md](../reference/substrate.md) — read it before deciding how much of the stack you want
to manage yourself, and [escape-hatches.md](../deployment/escape-hatches.md) for the levels at which you can take
part of it over.

## 7. Where to go next

- Day two — logs, metrics, rollback, destroy — is the operations guide (DOCS-029), and the index
  in [`docs/README.md`](../README.md) says what is published today.
- [The runtime contract](../reference/runtime.md) is what a deployed unit may rely on.
- [Building an application](application-authoring.md) is the other half: what runs once it is
  deployed.
- [`docs/reference/cli.md`](../reference/cli.md) is every command and flag.

### Sensitive Terraform execution artifacts

Terraform state and saved binary execution plans can contain plaintext credential values even
when ordinary output is redacted. Keep the remote backend private, encrypted, and restricted to
its authorized provisioning/deployment principals. State versions and backups remain sensitive;
provider Secret Manager storage is not the only copy of a generated credential.

Sol's saved apply/destruction plans use fresh 0700 directories under `/tmp`, with 0600 plan files.
They ignore caller-supplied `TMPDIR`, stay outside workspace caches and diagnostic/run-log
archives, and are removed on success, failure and handled Terraform interruption. Cleanup errors
are warnings naming the failed cleanup, never the file contents. Do not add these directories to
CI uploads, caches, support bundles or broad host diagnostic collection.

A hard kill or host crash can leave an abandoned private plan directory. Host administrators
must include these private temporary directories in their retention/cleanup policy; an operator
can remove an abandoned `sol-terraform-plan-*.private.d` directory after establishing that its
Sol/Terraform operation is no longer active. Sol's Terraform supervisor can outlive the CLI, so
the CLI PID disappearing alone does not prove that. Never remove the remote state or lock as a
substitute for cleaning up a temporary plan. There is no unconditional crash-cleanup guarantee.
