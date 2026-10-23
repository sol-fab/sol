# Install Sol and reach a first deployed service

This page takes you from nothing to a service running in your own cloud account.
It assumes you have an AWS account and no prior Sol, Terraform or Kubernetes
knowledge, and it assumes **no source checkout**: everything below is the released
binary and your own configuration.

If you would rather see Sol work before touching a cloud account, do the local
walkthrough in [`TUTORIAL.md`](TUTORIAL.md) first — it needs no account and reaches
a running service in one sitting. The two paths use the same workspace, the same
manifests and the same commands; only the destination differs.

---

## 1. Install the CLI

```bash
# Linux x86_64 — replace vX.Y.Z with the latest release:
# https://github.com/sol-fab/sol/releases
curl -L https://github.com/sol-fab/sol/releases/download/vX.Y.Z/sol-vX.Y.Z-linux-x86_64.tar.gz | tar xz
export PATH="$PWD/sol-vX.Y.Z/bin:$PATH"

sol assets        # check the install: where this sol's assets come from, and that each is there
```

`sol assets` is the install check. The binary drives assets that ship beside it
(the Helm values and Terraform roots Sol applies), so a `sol` copied out of its
release directory without them is not a working install, and `sol assets` says so
before you point it at an account.

**What the machine needs.** Sol drives the tools you already use rather than
replacing them:

| Tool | Used for |
|---|---|
| `aws` | the AWS account: state backend, cluster, identities |
| `terraform` (1.5+) | the environment: network, cluster, database, platform |
| `kubectl` | the cluster: platform, workloads, health |
| `docker` | registry work: pushing images, and checking an `--image-ref` exists |
| `dig` | confirming your DNS delegation *from a public resolver* |

Installing the provider CLI and authenticating it is the one step Sol cannot do
for you: Sol runs as *your* identity, and the roles you create are the boundary
between what it may and may not touch (§2 below).

**Supported providers.** AWS is the provider with a qualified production profile
today; GCP support exists and is not yet production-qualified. That matters in one
concrete place, and §4 names it rather than leaving you to discover it.

---

## 2. The two units, and who owns what

Sol separates two things that look similar in most tools:

|  | **Installation** | **Environment** |
|---|---|---|
| Scope | your account | one deployable target |
| Members | Terraform state + locking; the provisioning, cluster-access, deploy and operator identities; the delegated DNS zone when Sol owns one | network, cluster, database, registry use, platform, workloads |
| Lifetime | outlives every environment | disposable |
| Removed by | `sol uninstall` | `sol destroy <target>` |

You set the installation up **once per account**, and every environment afterwards
is disposable. Both are created by the same command, in this order, and neither
needs a separate tool.

Two boundaries are worth knowing before you start, because they decide what you
are asked to do by hand:

- **Sol owns the policy contracts, not your IAM lifecycle.** Sol generates the
  least-privilege policy document for each identity; *you* create the role and
  declare its ARN. Sol never creates, attaches or deletes a role for you, so
  revoking Sol's access is a decision in your account rather than in Sol
  (`AUDIT-072`).
- **The infrastructure, images and data are yours.** Terraform state is durable and
  inspectable, a fresh machine or CI runner can operate the same environment with
  provider-native credentials, and if you stop using Sol the environment keeps
  running. §6 is that exit path.

The full statement is [`DEVELOPER_EXPERIENCE.md`](../DEVELOPER_EXPERIENCE.md) §2–3.

---

## 3. Local first (optional)

The local loop needs no cloud account and is the fastest way to see what Sol
generates:

```bash
sol new workspace demo
cd demo

# Local secret inputs are ignored and scoped to each workload.
mkdir -p sol/secrets.local/payments sol/secrets.local/comms
cat > sol/secrets.local/payments/charge_svc.env <<'SECRETS'
POSTGRES_URL=postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev
SOL_API_KEY=dev-internal-key
SECRETS
cat > sol/secrets.local/comms/notify_worker.env <<'SECRETS'
POSTGRES_URL=postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev
SOL_API_KEY=dev-internal-key
SECRETS

sol local deploy    # establishes infrastructure, then refuses pending migrations
sol local migrate
sol local deploy    # deploys workloads after migration
curl localhost:8080/health
```

[`TUTORIAL.md`](TUTORIAL.md) walks the whole thing: services, workers, migrations,
events, Grafana, rollback. Nothing about it is a toy — it is the same rendering
path and the same framework primitives you deploy in §4.

---

## 4. The first production deploy

### 4.1 Describe the target

A deploy is addressed by a target: `<env>/<provider>/<region>`. You declare what
it means in `sol/environments.yml`:

```yaml
prod:
  profile: production-single-region
  shape: durable
  base_domain: acme.example
  dns_zone_ownership: sol          # sol | user | external — see below
  targets:
    aws/us-east-1:
      cluster_name: acme-prod
      letsencrypt_email: ops@acme.example
      cluster_endpoint_cidr: 203.0.113.0/24
      state_bucket: acme-tfstate
      aws:
        state_lock_table: acme-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
```

- `state_bucket` / `state_lock_table` are the encrypted, versioned, locked
  Terraform state the installation keeps; they are what makes a destroyed
  environment unrecoverable *and* a rebuilt one identical.
- `cluster_endpoint_cidr` restricts the cluster's public API endpoint. `0.0.0.0/0`
  is refused: Sol will not deploy to a cluster it cannot bound. On GCP it
  populates the GKE master-authorized-networks list; without it the public
  control-plane endpoint is unrestricted and the production profile refuses.
- `dns_zone_ownership: sol` means Sol creates and owns the delegated zone for
  `base_domain`; `user` means you created it and Sol never removes it; `external`
  means it is published elsewhere and Sol only asks you to delegate to it.
- The four role ARNs are declared in the target's `aws:` block, because they are
  provider-native. You do not have to invent their permissions (§4.2).

**GCP publisher.** A GCP target may declare
`gcp.publisher_service_account`. Sol grants that account
`roles/artifactregistry.writer` on the cluster's repository only; it receives no
Kubernetes API authority, so it is safe to use as the CI image-push identity.
The operator creates the account and authenticates it (for example through
Workload Identity Federation); Sol does not create the identity.

Values you would rather not commit — an account id, a registry, the ARNs — belong
in `sol/environments.local.yml`, which the scaffolded `.gitignore` excludes.

### 4.2 Create the identities from the contracts Sol generates

The first interactive `sol deploy <target>` previews durable installation setup and offers to reconcile it inline. `sol plan <target>` remains read-only. Sol reports provider-observed prerequisites as `Established`, `Unmet` or `UNKNOWN`; an unobservable prerequisite is never promoted to healthy (`DEC-052`).

The report prints each contract's path beside the ARN field to declare:

```text
  the identities are yours to create: Sol owns each policy contract
  (AUDIT-072), you create the role and declare its ARN — Sol looks the role
  up by the name in that ARN:
    provisioning identity      declare aws.provisioner_role_arn
      contract: ~/.local/share/sol/terraform/aws-bootstrap-…/identity-contracts/provisioner_policy_json.json
    cluster-access identity    declare aws.cluster_access_role_arn
      contract: …/cluster_access_policy_json.json
    deploy identity            declare aws.deploy_role_arn
      contract: …/deploy_policy_json.json
    operator identity          declare aws.operator_role_arn
      contract: …/operator_policy_json.json
```

Create each role in your account with that contract attached, set its trust policy
to your own principal (or your CI's), and put its ARN in the target. The boundary
the contracts encode is worth one sentence each:

- **provisioner** creates and updates cloud and platform infrastructure, including
  the workspace's ECR repositories — their lifecycle, never the ability to push an
  image into one;
- **cluster-access** is the steady-state identity the platform paths use; it can
  discover the cluster and read credentials but cannot mutate access entries or IAM;
- **deploy** mutates application objects through a namespace-scoped EKS access
  entry, and explicitly denies infrastructure and IAM mutation, so it cannot
  escalate or grant itself administration;
- **operator** is read-only over the cluster and the state bucket — enough for deployment operations. For ongoing diagnosis, use Kubernetes and the
  configured observability/provider tools.

### 4.3 Run the deploy

```bash
sol deploy prod/aws/us-east-1 \
  --image-ref charge_svc="123456789012.dkr.ecr.us-east-1.amazonaws.com/acme/charge-svc@sha256:…"
```

(A production-profile target requires an immutable digest rather than a tag, and a
CI job normally passes `--image-tag "$GIT_SHA"` for a non-profile target.)

This is one command, and it does the whole first run in order:

1. **Preflight** — the workspace contract, the target, and the profile's guarantees.
   This is cheap and knowable, so it happens *first*: a missing alert receiver, an
   unusable domain or a mutable image reference is reported before anything billable.
2. **Installation** — observe the durable prerequisites. If they are not
   established, Sol reports what it found, separates the work it will do from the
   one action you may have to take, and offers to set the installation up in place.
   Accepting reconciles the durable root, prints the exact NS records to add when
   the parent zone is outside the account, waits for the delegation to become
   visible and confirms it **from a public resolver** rather than from written
   configuration, then re-observes.
3. **Environment** — reconcile this target: network, cluster, database and platform.
   This is part of `sol deploy`; `sol plan` previews the target without applying it.
4. **Access** — reach the cluster Sol just created as the *deploy* identity, with a
   temporary kubeconfig for this run only. Sol does not write your `~/.kube/config`
   or your target file, and never reaches a cluster as the provisioning identity
   (`DEC-058`, `DEC-034`).
5. **Migrate, deploy, verify** — the workspace substrate and its namespace-scoped
   RBAC, pending database migrations, the rendered workloads, and the deployment's
   own verification — then it prints the endpoint.

The first run looks like this:

```text
$ sol deploy prod/aws/us-east-1 --image-ref charge_svc="…@sha256:…"

Run: deploy-20261001T101500Z-4711

Workspace: acme  tag: deadbeef

Profile: production-single-region/v1 (preflight passed)

This target names no Kubernetes destination Sol can reach from here, so this is the first run for prod/aws/us-east-1:
Sol observed the installation for prod/aws/us-east-1 at the provider: every durable prerequisite is established, so the installation is not what stopped this run.

Sol does this for you: reconcile the environment for prod/aws/us-east-1 — network, cluster, database and platform — from the durable installation, and establish this run's own cluster access.
…
The environment for prod/aws/us-east-1 is provisioned.
  cluster access identity: arn:aws:iam::111122223333:role/sol-deploy (this run, ephemeral)
…
  ✓  namespace acme-payments  image 123456789012.dkr.ecr.us-east-1.amazonaws.com/acme/charge-svc@sha256:…

Done. 1 service(s) deployed.
  →  http://localhost:8080  (acme-payments/charge-svc)
Use Kubernetes tooling to inspect workload health after deployment.
```

**One action may be required, and Sol names it exactly.** When the zone that
publishes your domain is not in this account, the run prints the NS records to add
at that zone and waits for them (five-second checks, bounded by
`--await-delegation=SECONDS`; 300 seconds by default, `0` disables the wait). The
wait is a real check against a public resolver, so a delegation that has not
propagated is reported rather than assumed — and a resolver Sol cannot query is
`UNKNOWN`, never a silent success.

**What later operations need from your machine.** Sol establishes its own cluster
access for *a deploy run*. For ongoing diagnosis, use Kubernetes and provider
tools with your own operator context; Sol does not expose a separate operational
status, logs, or dashboard interface.

```text
deploy_kubeconfig_command   aws eks update-kubeconfig --region us-east-1 --name acme-prod --alias acme-prod-deploy --role-arn arn:aws:iam::111122223333:role/sol-deploy
deploy_kube_context         acme-prod-deploy
```

```yaml
target:
  kube_context: acme-prod-deploy
```

**GCP deploy identity.** Sol creates a `sol-deploy` Kubernetes ServiceAccount in
the `monitoring` namespace and binds it, per application namespace, to the
`sol-deploy` ClusterRole. The cluster root's bootstrap role lets that identity
create the namespace RoleBindings and bind only `sol-deploy`/`sol-operator`
(the bind permission is restricted to those two ClusterRoles). For a deploy run,
Sol mints a one-hour token for the ServiceAccount using the caller's cluster
access and writes a token-scoped kubeconfig; the application apply therefore
runs with namespace-scoped authority, not the caller's or the provisioner's
identity.

The caller must be able to run `container clusters get-credentials` and create
`serviceaccounts/token` for `monitoring/sol-deploy`. The provisioner has both;
a CI deploy identity needs the same two capabilities. Sol never grants GKE's
project-wide `roles/container.developer`.

### 4.4 Unattended runs

In CI, `sol deploy prod/aws/us-east-1 …` performs the same preflight, environment
and application stages with no prompt. A run that *cannot* be asked — no terminal,
`--dry-run`, `--emit-to` — never prompts and never sets an installation up: it
prints the same observation and the command that establishes it
(`sol deploy prod/aws/us-east-1`), so a pipeline fails with an
explanation instead of hanging or silently skipping. `--dry-run` and `--emit-to`
change nothing at all, including the environment.

---

## 5. The second deploy

Once the installation exists, the one-time setup is gone:

```bash
sol deploy prod/aws/us-east-1 --image-tag "$GIT_SHA" --registry 123456789012.dkr.ecr.us-east-1.amazonaws.com
```

No prompt, no installation work, no DNS. The run observes the installation at the
provider (it does not touch it), reconciles the environment to its declared state,
and deploys.

A **second environment** needs no installation work either — the same installation
carries it:

```yaml
prod:
  base_domain: acme.example
  targets:
    aws/us-east-1: { … }
    aws/us-west-2: { … }
```

```bash
sol deploy prod/aws/us-west-2 …
```

which is why redeploying never means redoing registrar or DNS work.
[`deployment.md`](deployment.md) covers the everyday and operator detail:
scopes, GitOps mode, releases, rollback, and the substrate commands.

---

## 6. What is yours, and how to get out

Everything this page created is in your account, and it does not depend on Sol:

- the infrastructure and its Terraform state (durable, versioned, inspectable —
  where it is and how to recover it is documented in
  [`../deployment/production-bootstrap.md`](../deployment/production-bootstrap.md));
- the images, in your registry;
- the roles, which you created and can revoke;
- the data, in your database.

A fresh machine or CI runner can operate the same environment with provider-native
credentials, and the acceptance test for this section is: an operator who stops
using Sol can still describe, inspect and continue operating what was built,
without a Sol binary in the loop. The one thing that is not portable in the same
way is the delegated zone Sol manages for you when `dns_zone_ownership: sol` —
§7 names what happens to it.

---

## 7. Teardown: two different operations

|  | `sol destroy prod/aws/us-east-1` | `sol uninstall prod/aws/us-east-1` |
|---|---|---|
| Removes | that environment: network, cluster, database, workloads | the installation: state backend, locking, the delegated zone Sol created |
| Leaves | the installation, untouched | the roles you created, a zone you supplied, anything Sol does not own |
| Verified | absence is confirmed independently of Terraform state | absence is confirmed, and what was intentionally retained is reported |

Destroying an environment does not force registrar or DNS work before you deploy
again, and it never removes a durable prerequisite: those outlive every
environment.

Uninstalling is explicitly separate, and carries extra confirmation when it would
remove a zone Sol created — naming the exact domain whose NS records at your
registrar become stale. A zone you supplied (`dns_zone_ownership: user`) is never
deleted by ordinary teardown or by uninstall.

---

## 8. Where to go next

- [`TUTORIAL.md`](TUTORIAL.md) — the local loop, end to end.
- [`../../examples/pluto/README.md`](../../examples/pluto/README.md) — a runnable
  reference application whose README carries the same first-run walkthrough
  against a real workspace, and which the CI smoke tests build.
- [`deployment.md`](deployment.md) — the operator view: targets, direct and GitOps
  deploys, substrate commands.
- [`operations.md`](operations.md) — day two: health, logs, rollback, diagnostics,
  destroy and uninstall.
- [`../reference/cli.md`](../reference/cli.md) — every command and flag.
- [`../reference/substrate.md`](../reference/substrate.md) — the inputs this page's
  target fields feed, and what the platform assumes about them.
- [`../deployment/production-bootstrap.md`](../deployment/production-bootstrap.md)
  — the identities, the state backend, and recovery, in operator detail.
- [`../DEVELOPER_EXPERIENCE.md`](../DEVELOPER_EXPERIENCE.md) — what Sol owns, what
  you own, and what is still planned.
