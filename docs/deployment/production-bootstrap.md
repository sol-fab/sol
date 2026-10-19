# Production state bootstrap, identities and recovery (AUDIT-072)

`production-single-region` requires infrastructure state that is encrypted,
versioned and locked, and named provisioning/deploy/operator identities distinct
from the cluster-creator admin. This is the AWS bootstrap for the one qualified
provider; provider parity is not part of maturity A.

Implementation and offline validation live here; the destructive recovery and
authorization checks are HARDEN-002's.

## 1. Provision the state backend (Sol provisions it by default)

A Terraform configuration cannot create its own backend, so the backend is a
small separate root:

```bash
cd platform/cloud/aws/bootstrap
terraform init \
  -backend-config="bucket=<globally-unique-name>" \
  -backend-config="key=bootstrap/aws/default.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=<name>" \
  -backend-config="encrypt=true"
terraform apply \
  -var="region=us-east-1" \
  -var="state_bucket=<globally-unique-name>" \
  -var="state_lock_table=<name>"
```

This root carries a partial `backend "s3" {}` so the resources it owns — the bucket, the lock
table, and, where a delegated zone is declared, the hosted zone itself — are recorded in state
that outlives the machine that created them, rather than in a local file. Where a delegated
qualification zone exists, pass `-var="manage_dns_zone=true" -var="base_domain=<delegated
name>"` and read the authoritative nameservers from this root's outputs rather than from a
target's plan: a zone whose nameservers are baked into an external delegation must not be
recreated, so it is owned here and merely read by a target (DEC-042/DEC-043).

It creates:

- an S3 bucket with **versioning**, **AES256 encryption** and a full
  **public-access block** — object versioning is the recovery mechanism;
- a **DynamoDB lock table** (`LockID`) so two concurrent applies serialize or
  one is rejected without corrupting state.

Bring-your-own is a documented alternative: any backend with the same
properties (encrypted, versioned, locked) is conformant. Record it in the target
so preflight can verify it:

```yaml
target:
  profile: production-single-region
  state_bucket: acme-tfstate
  letsencrypt_email: ops@acme.example
  aws:
    state_lock_table: acme-tflock
```

Provider-native settings — the lock table here, the role ARNs below — live in the
target's `aws:` block, so a target on another provider cannot carry them. A flat
`state_lock_table:` is refused with the key's new location.

Each field inside the block is a single value. A nested block (say `aws.vpc.id`) is
refused, naming the key, rather than silently ignored (REFAC-129): a typo that nests
one used to be indistinguishable from not writing the field at all.

The cloud lifecycle fails closed before Terraform initialization when either is missing.
It supplies this configuration at runtime and uses deterministic, distinct
`sol/<target>/cloud.tfstate` and `sol/<target>/platform.tfstate` objects. Do not
create a repository or operator-managed `backend.tf` for the normal lifecycle.

## 2. Identities: Sol generates the contracts, you supply the ARNs

The bootstrap root outputs four least-privilege policy documents
(`provisioner_policy_json`, `publisher_policy_json`, `deploy_policy_json`,
`operator_policy_json`). Sol owns the *contract*; it does not create roles,
attach policies, or manage their lifecycle. `sol deploy <target>`
writes them to the durable root's working directory (`identity-contracts/`) and the
installation report prints each path beside the ARN field to declare, so the roles can
be created without reading Terraform outputs by hand. Create the roles in your account
and declare the three ARNs `sol deploy` actually reads:

```yaml
target:
  cluster_endpoint_cidr: 203.0.113.0/24
  aws:
    provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
    cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
    deploy_role_arn:      arn:aws:iam::111122223333:role/sol-deploy
    operator_role_arn:    arn:aws:iam::111122223333:role/sol-operator
```

The boundary the contracts encode:

- **provisioner** — a constrained high-privilege identity that creates/updates
  cloud and platform infrastructure, including the workspace's ECR
  repositories (their *lifecycle* — create/describe/tag — never the data-plane
  actions that would let it push an image into one; that deny is explicit in
  the generated policy, not just an omission). Its direct Kubernetes grants
  cover the supported platform lifecycle in platform namespaces and exclude
  ordinary application mutation elsewhere; CRD/controller authority still
  makes it a powerful infrastructure trust domain;
- **publisher** — may push/replace images in the workspace's ECR repositories
  (`ecr:PutImage` and its supporting layer-upload actions) and nothing else;
  explicitly denied infrastructure, IAM, and repository-lifecycle mutation, so
  publishing an image cannot also grant provisioning or deploy authority. No
  target field names this ARN — Sol's own execution never resolves it.
  `sol local deploy` never touches AWS at all (local-only, no target concept); a CI
  pipeline authenticates as this identity for its own `docker push` step,
  entirely outside Sol, before calling `sol deploy` with the resulting digest;
- **deploy** — may `DescribeCluster` and mutate application objects through a
  namespace-scoped EKS access entry. It explicitly **denies** infrastructure and
  IAM mutation and any attempt to grant itself cluster administration, so it
  cannot escalate;
- **operator** — owns **production observation and diagnosis** (DEC-038). Its
  generated AWS policy is read-only (`eks:DescribeCluster`, `eks:ListClusters`,
  plus the state bucket), which is enough to obtain a kubeconfig; `sol deploy`
  then creates the EKS access entry (Kubernetes group `sol:operators`) and
  a `sol-operator-diagnostics` `ClusterRole`, bound per application namespace at
  runtime exactly like deploy's. The grant is `get`/`list` on **only** the
  resources Sol's read-only commands read — pods, pods/log, services, events,
  deployments, cronjobs, and namespaces for Sol's read-only target and recovery
  checks. It deliberately has **no** mutating verb, no `secrets`, and no
  `pods/exec` or `pods/portforward`: interactive debugging remains an operator
  action rather than a deployment identity capability.

`sol deploy` fails closed unless the three ARNs it reads (provisioner, deploy,
operator) are present and the public API endpoint is restricted to an
explicit CIDR (`0.0.0.0/0` is rejected). A public endpoint with an explicit
CIDR allowlist is acceptable for maturity A;
private-only networking is a stronger future posture.

### Configuring kubectl for the deploy identity

`sol deploy` wires `deploy_role_arn` into an EKS access entry (Kubernetes
group `sol:deployers`) and a cluster-wide `sol-deploy` `ClusterRole`; the
namespace-scoped `RoleBinding` that actually grants it is applied per
application namespace at deploy time (`Sol_cli_substrate.ensure`), not by
Terraform, since application namespaces are created dynamically. The one
Terraform-owned binding for this identity is the broker CA read: the deploy
projects the chart's `redpanda-default-cert` into consumer namespaces, so the
platform module binds a dedicated `sol-kafka-ca-reader` Role — exactly `get` on
that one Secret in `redpanda` — to the same group. The broad `sol-deploy` role
is never bound in the platform's namespaces. Once the role
exists and `deploy_role_arn` is set, `sol deploy`'s output prints the
command to run — Sol does not write your kubeconfig or the target file for
you (AUDIT-072: Sol owns the IAM policy contract, not your local kubeconfig
or role lifecycle):

```
deploy_kubeconfig_command   aws eks update-kubeconfig --region us-east-1 --name <cluster> --alias <cluster>-deploy --role-arn arn:aws:iam::111122223333:role/sol-deploy
deploy_kube_context         <cluster>-deploy
```

Run the printed command, then add the printed context name to the target:

```yaml
target:
  kube_context: <cluster>-deploy
```

`sol deploy` does not need that persistent entry for its own first run: when it
has no destination it can reach, it reconciles the environment and assembles the
deploy identity's access for that run only — a temporary kubeconfig under
`KUBECONFIG`, cleaned up at exit, never written into your home (DEC-058). The
printed command and the `kube_context` line above remain what the *other*
commands need: `sol migrate` uses the target's
declared destination, and a provider that declares no deploy identity (GCP today)
gets no ephemeral access at all — the deploy stops after provisioning and prints
exactly this command and context for you to add.

### The first deploy against a cold target

`sol deploy` owns reconciliation of the declared target, including its first
run. A target that has never been provisioned has no container repository for
its workloads, and a profiled target requires an immutable reference for every
workload — so the first run is completed across two `sol deploy` invocations
with a publish between them:

1. `sol deploy <target>` validates every guarantee whose evidence is
   configuration — configuration, shape, resource ownership, provider
   capabilities, artifact-reference syntax — before it changes anything. It then
   reconciles the environment, which creates the workspace's ECR repositories.
   It publishes nothing, so it reports the deployment incomplete, names the
   repositories to publish into, and stops before any workload moves:

   ```
   Profile: production-single-region/v1
   ...
   Deployment incomplete: infrastructure is reconciled and no workload has moved.
   ...
     - 123456789012.dkr.ecr.us-east-1.amazonaws.com/pluto/charge-svc
   ```

2. The publisher pushes each workload's image to its repository as the
   `publisher` identity above, and reads back the digest.

3. `sol deploy <target> --image-ref <service>=<repo>@sha256:<digest> ...`
   re-validates, reconciles the environment (already at its declared state, so a
   no-op), and applies the workloads. The run is resumable and idempotent:
   re-running any step changes nothing already reconciled.

The repositories belong to the target root, not to a longer-lived installation,
and are destroyed with it (ADR-0004) — teardown removes them and their contents.

## 3. No standing cluster-creator admin

The AWS module sets `enable_cluster_creator_admin_permissions = false`. During
`sol deploy`, the separate cluster-access identity holds temporary EKS bootstrap admin
access for the whole privileged `PlatformInstalling` phase — the full platform
apply and verified readiness — because installing cluster-wide software that
mints RBAC is itself privileged platform establishment (ADR 0003). Sol then
removes the managed admin association and verifies the effective positive and
negative RBAC boundary. Its IAM policy permits cluster discovery and credential
retrieval but explicitly denies access-entry/policy-association and all `iam:*`
mutation, so the steady-state identity cannot recreate that grant. The cloud
provisioner remains responsible for substrate and bootstrap-access mutation. An interrupted
run is safely re-runnable and reconciles that temporary association away; it is
not the steady-state access model.

## 4. Recovery procedure

Control-state RTO is procedure-based, not a numeric bound (DEC-026 §5).

**Recover a clean runner** (original runner and local files gone):

```bash
sol plan prod/aws/us-east-1
sol deploy prod/aws/us-east-1
```

**Recover a prior state object version** (bad apply, or corrupted state):

```bash
aws s3api list-object-versions --bucket <bucket> --prefix sol/prod/aws/us-east-1/
aws s3api get-object --bucket <bucket> --key sol/prod/aws/us-east-1/cloud.tfstate \
  --version-id <version-id> /tmp/tfstate.recovered
# Inspect, then restore the chosen version explicitly — never in place blindly.
```

**Two concurrent mutations** serialize through the lock table. A held lock is
not stale merely because the `sol` that started it has exited (see below): only
force-unlock after establishing that no Terraform process anywhere still holds
it. Unlocking a live lock is how GCP qualification Attempt 6 ended up with a
cluster the provider had and the state did not.

**Interrupting a cloud lifecycle run (INFRA-076).** Sol runs Terraform under a supervisor
in a session of its own, with its output in a durable operation record under
`$XDG_DATA_HOME/sol/operations/` (default `~/.local/share/sol/operations/`), so:

- **Ctrl-C** (or SIGTERM/SIGHUP to `sol`) sends one SIGINT to Terraform only,
  never to its provider plugins, and Sol waits while Terraform stops itself:
  persisting state and releasing the lock. A second Ctrl-C asks Terraform to
  cancel immediately, which Terraform warns may lose data.
- **If `sol` itself dies** (killed, out of memory, terminal closed), Terraform
  keeps running to completion and records its outcome. `sol` exiting does not
  mean Terraform exited.
- **The next command that uses that state reads the last operation:**
  - *still running* → refused. Wait for it; do not unlock.
  - *resolved*, including a graceful Ctrl-C → proceeds normally.
  - *unresolved* (Terraform was killed by a signal, its supervisor vanished, or it
    left `errored.tfstate`) → `sol deploy` refuses to change the target. There is no
    acknowledgement flag on deploy: inspect the provider and state, import or remove
    what diverged, and push any `errored.tfstate` yourself before retrying. Read-only
    plans can still report the unresolved operation; `sol destroy` has its own
    destructive lifecycle and release checks.
- **Where Terraform works (DEC-050).** Each state has its own working directory,
  `~/.local/share/sol/terraform/<provider>-<cluster|platform>-<id>/platform/cloud/<provider>/<role>/`
  (`$XDG_DATA_HOME/sol/…` when set). `sol` names it in the refusal above, and
  `errored.tfstate` is written there. Sol rewrites the Terraform source files in it
  from its assets on every run, but never deletes or overwrites anything it did not
  write, so `errored.tfstate`, `crash.log` and `.terraform/` stay until you remove
  them. The directory keeps `.terraform/` from Sol's own `init`, so it is already
  initialized with the target's backend: push a recovered state with
  `terraform -chdir=<that directory> state push errored.tfstate`.

## Evidence HARDEN-002 records

- two concurrent applies serialize or one is rejected without corrupting state;
- a clean runner recovers the backend and plans with no unintended recreation;
- recovery from a prior backend object version is exercised;
- the deploy identity is denied an infrastructure mutation and a self-granted
  admin policy;
- the ordinary operator path does not use the cluster-creator credential;
- one infrastructure and one application mutation are attributed to their named
  principal in retained audit evidence.

## Credentials and Terraform variable ownership

Two things learned by qualifying a real target (HARDEN-002 run 1), both now
enforced in code rather than in an operator's memory.

**The database master password is supplied out of band.** The provider root
creates the RDS instance, so it needs a master password before any workload
exists. Supply it through the environment, never as a Terraform variable on the
command line:

```bash
TF_VAR_db_password="$(your-secret-tool get sol-db-password)" \
  sol deploy prod/aws/us-east-1
```

Sol refuses an apply that would create Postgres with no credential source, and
refuses a password passed with `--var` — the run log records the terraform
command line verbatim, so the value would be written to a file. The module
carries the same precondition on `aws_db_instance.postgres`, so the constraint
holds even when terraform is driven directly. Nothing writes the password to a
plan, an output, a log or a release record; the module's `postgres_url` output
(which does contain it) is `sensitive`, and it exists so the deploy's database
setup step can derive the class credentials (`<target>-ddl-creds`,
`<target>-dml-creds`) from it. No operator copies the master into a secret store.

**`cluster_issuer` belongs to the base platform layer.** `sol plan`, `sol deploy` and `sol destroy` pass each Terraform root only the variables it declares.
`cluster_issuer` names a cert-manager `ClusterIssuer`, so Sol routes it to
`platform/cloud/modules/platform` after the cloud output contract has been validated.

It remains a target field (`sol deploy` uses it for ingress annotations). Passing
it to the provider root, as it used to be, made terraform abort with "a variable
named cluster_issuer was assigned on the command line, but the root module does
not declare a variable of that name" — so a documented target using it could not
provision at all.

## Production Kafka transport (SASL_SSL)

The `durable` platform shape runs Redpanda with TLS and SASL
(FEAT-093); `production-single-region` requires that shape. The shared platform
module enables both in the `durable` layer of
`platform/shared/components.json`: cert-manager issues an in-cluster CA and the
broker certificate, and the Kafka, schema-registry and admin listeners each get
TLS. Sol sets the module's `platform_profile` from the target's declared
`shape`, independently of `observability_backend`, so a durable target whose
telemetry goes to an external backend still gets the authenticated transport.

Terraform generates the workload credential once and stores it in the provider's
secret manager; the same value is projected into the broker's `redpanda-users`
Secret. The Kubernetes objects are delivery projections, not the authority.
Neither cluster replacement nor an ordinary deploy rotates the password.

On an ordinary deploy, after the platform prerequisites have created the broker
and its CA, the deploy reads the authoritative password from the provider store
and the chart-owned CA from Kubernetes, then writes only
`KAFKA_SASL_PASSWORD` and `KAFKA_SSL_CA_CERT` to `<target>-kafka-creds` in each
namespace that declares a Kafka consumer. A TLS contract Job reads only those
two keys from the same Secret. Non-consumers receive nothing, and there is no
operator step that copies Kafka credentials into unit Secrets or `sol-secrets`.

`sol secret set` cannot write the resource-owned `KAFKA_SASL_PASSWORD` and
`KAFKA_SSL_CA_CERT` inputs: the resolved Kafka binding is their single producer. An application `secrets:` mapping for either key is a conflicting
producer and fails planning. External Kafka keeps its explicitly declared ESO
Secret instead.

The deploy fails closed when the provider authority is missing or unreadable, or
when the broker CA Secret is absent, rather than rolling out a consumer that
cannot authenticate or verify the broker.

## Platform storage (finding 7 of HARDEN-002 run 2)

The qualified substrate must be able to host the platform's own durable
components. Two layers provide that, and neither is an application workload volume:

- **Cloud substrate**: on AWS (`platform/cloud/aws/cluster`) this installs the **EBS
  CSI driver** as an EKS addon, with an IRSA role scoped to
  `kube-system:ebs-csi-controller-sa`. Without it an EKS cluster has no CSI
  driver and therefore no StorageClass, so every PVC stays `Pending`. On GCP the
  `pd.csi.storage.gke.io` driver is part of GKE itself and needs no addon.
- **Platform substrate** (`platform/cloud/modules/platform`) creates the default **gp3
  StorageClass** on AWS (`WaitForFirstConsumer`, so the volume is created in the
  zone the pod lands in). Set `create_storage_class = false` if the platform is
  expected to adopt a class that already exists, or `storage_class_name` to rename
  it.
- **On GCP the module creates no class and adopts GKE's own default**
  (`standard-rwo`, provisioner `pd.csi.storage.gke.io`, `WaitForFirstConsumer`,
  `pd-balanced`). GKE already annotates it as the default, and the platform's PVCs
  name no `storageClassName`, so they bind to whatever the cluster calls default.
  Creating a second default class would leave the cluster with two, which
  Kubernetes accepts with a warning and then resolves arbitrarily. Persistent
  Disks are encrypted at rest with Google-managed keys by default, so the posture
  the AWS class states explicitly (`encrypted = "true"`) holds here without a
  parameter.

`Ready` asserts the outcome for either provider rather than trusting the
configuration that produced it: the provider's class is the *sole* default
StorageClass on the cluster and is backed by the provider's block-storage CSI
driver, which is registered (`Sol_cli_cloud_lifecycle.platform_storage`). A
cluster whose default is some other class, or whose default is ambiguous, is
`Unmet` — the platform's durable volumes are then not on the class Sol intends.

Disk allocation is established by the cloud provider and the CSI controller. Sol
checks PVC binding and workload readiness instead of estimating additional disk
space from chart defaults. An existing platform update therefore does not require
spare quota for volumes it already owns. A provisioning failure still fails the
operation and retains Terraform's diagnostic. For a pending claim, inspect
`kubectl describe pvc -n monitoring` or `kubectl describe pvc -n redpanda`; the
claim's events identify provisioning failures, including provider quota limits.

This is what makes Redpanda's RF≥3 persistent brokers schedulable. It changes
nothing about how a workload declares persistence: the `single`-tier restriction
DEC-026 §3 puts on workload-declared volumes is unaffected, because the driver and
the class are platform capabilities, not a workload's storage claim.

Before run 2 the substrate had neither, and the only reason the repository's own
live smoke harness ever installed the platform was that it disabled persistence
(`-var=redpanda_persistent_storage=false`).

## Platform roots are selected per provider

The platform *definition* is the shared module `platform/cloud/modules/platform`,
which declares no backend. A Terraform root's state backend *type* is part of its
own configuration — `-backend-config` sets attributes, never the type — so each
provider reaches the module through a thin root of its own, named by role under the
provider (`platform/cloud/<provider>/platform`, DEC-046 rule 4). The cloud lifecycle selects
it with `Sol_cli_cloud_lifecycle.platform_root`:

| Provider | Root | Backend | Platform state object |
|---|---|---|---|
| AWS | `platform/cloud/aws/platform` | S3 + DynamoDB locking | `sol/<target>/platform.tfstate` (`key=`) |
| GCP | `platform/cloud/gcp/platform` | GCS, native locking | `sol/<target>/platform.tfstate` (`prefix=`) |

Each root declares only its backend, the variables, and one `module "platform"` call,
so the definition itself is not duplicated. Things worth knowing before editing
either:

- Every root mirrors, and passes to the module, every variable the definition
  declares. The GCP root's only exceptions are the AWS-shaped ones — `aws_region`,
  the S3 buckets and their IRSA roles, and `cert_manager_irsa_role_arn` — which a
  GCP install cannot use. Adding a variable to the definition without adding it to
  a root fails `internal/ci/check_production_infra.py` rather than silently defaulting.
- Until REFAC-100 the AWS root *was* the definition, so an AWS platform state from
  before it holds every resource at the top level. The AWS root's `moved` blocks
  relocate each one under `module.platform`, so such a state plans with no destroy
  and no create.

Everything a target addresses inside the platform root goes through
`Sol_cli_cloud_lifecycle.platform_address`, because a root that reaches the
definition through a module addresses its resources through it
(`module.platform.<resource>`) while AWS's does not.

## Destroying a target (finding 9 of HARDEN-002 run 2)

Production RDS deletion protection stays **on** by default; that is correct and is
not relaxed for convenience. Destruction is an explicit lifecycle:

1. the operator confirms the target is disposable;
2. deletion protection is disabled **by an applied state transition** — either
   `terraform apply -var=rds_deletion_protection=false` or `aws rds
   modify-db-instance --no-deletion-protection`, followed by waiting for the
   instance to leave `modifying`;
3. Terraform takes a final snapshot. The module sets `final_snapshot_identifier`
   whenever it will take one, defaulting to `<cluster>-postgres-final`. RDS requires
   snapshot names to be unique, so destroying the same cluster name a second time
   needs a fresh `rds_final_snapshot_identifier` **applied in the same step as 2** —
   otherwise the delete fails with `DBSnapshotAlreadyExists`;
4. `terraform destroy` completes;
5. absence is verified. For what Terraform manages (EKS, RDS, ECR, the VPC with its
   NAT gateways and elastic IPs), a successful `terraform destroy` plus an empty
   state is the authority (DEC-045). `sol destroy` additionally checks what
   Terraform does not own: load balancers created by the in-cluster cloud
   controller, and target-tagged EBS volumes created for PersistentVolumeClaims. It
   fails closed when any of those queries errors or returns a resource. The live
   smoke harness (`internal/qualification/aws/live-smoke.sh`) keeps its own
   independent inventory, including the VPC, as qualification evidence.
   Volumes are worth the operator's attention from this release onward: the EBS
   CSI driver and default gp3 StorageClass (see *Platform storage* above) are what
   first make dynamically provisioned EBS volumes possible on this substrate. The
   class reclaims with `Delete`, but that only fires when the *PVC* is deleted
   through the API — tearing the cluster down without doing so leaves the volumes
   behind.

Passing `-var` to `terraform destroy` does **not** accomplish step 2 or 3. A destroy
plan contains only deletes, so the provider is handed prior state and never sees the
new value: `terraform plan -destroy -var x=B` on an applied `x = "A"` plans
`input = "A" -> null`. Both settings have to be applied *before* the destroy.

**Known gap:** `sol destroy` therefore cannot yet destroy a protected
production RDS instance. It runs the destroy only; it performs no preparatory
transition, and a `-var` it forwarded would be inert for the reason above. Until the
preparation step exists, the operator performs steps 2 and 3 directly (via
`terraform apply` or the `aws` CLI) and may then use either `terraform destroy` or
`sol destroy <target> --apply`.

What is fixed here is the Terraform-level defect: `skip_final_snapshot` is no longer
derived from `deletion_protection` — so permitting destruction no longer means
silently forgoing the final snapshot — and an identifier is always set when a
snapshot will be taken, so Terraform no longer refuses the destroy outright.
`sol destroy` now runs the Sol lifecycle skeleton (prepare → verify the
preparation landed → destroy platform → destroy cloud → verify absence); its AWS
preparation is a declared no-op until finding 9b supplies the RDS
deletion-protection transition and a unique snapshot identity per attempt. Until
then, steps 2 and 3 above remain the operator's explicit path.
