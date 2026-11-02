# Production workload credentials and rotation (SEC-004)

Two guarantees for `production-single-region`:

1. **No ambient Kubernetes credential.** A workload receives no mounted
   service-account token unless a declared capability requires one.
2. **Supported runtime credentials rotate without undefined behavior.** A
   rotated database/API credential is used by the workload, the old value is
   revoked, and the workload returns to healthy state — without hand-editing
   generated manifests.

## No ambient token

Every Sol-rendered workload uses a per-workload ServiceAccount, and the renderer
sets `automountServiceAccountToken: false` on it
(`Sol_cli_manifest_yaml.service_account_doc`). Because the token is projected
into the pod only when the ServiceAccount permits it, a default workload pod has
no Kubernetes API token and no in-cluster API access.

This is a Sol-owned property of the rendered plan, so the profile preflight's
`credential_posture` guarantee is established for every plan. Maturity A ships
**no** opt-back-in capability: exposing a "this workload may call the Kubernetes
API" knob without a meaningful least-privilege permission model would be worse
than not offering it, so it is deferred until a concrete workload needs one.
(Workload identity federation, service-to-service authorization, admission
policy and multi-team RBAC remain out of maturity A per DEC-026 §7.)

The provider-backed secret mount is a CSI volume, not an API credential: the
Secrets Store CSI driver reads the provider store with the pod's own identity and
projects files; the workload still has no Kubernetes API token.

## Where an application value lives

On a **durable AWS/GCP target**, an ordinary Sol-managed application value is
authoritative in AWS Secrets Manager or GCP Secret Manager, scoped to the target,
unit and key (see [ADR 0009](../architecture/adr/0009-provider-backed-application-secret-authority.md)).
Set or rotate one with the target and exact `domain/unit/key` address:

```bash
your-secret-tool get payment-api-key \
  | sol secret set prod/aws/us-east-1 payments/charge_svc/PAYMENT_API_KEY --from-stdin
```

`sol secret set` resolves the target and the key's declared authority before
opening the input. It refuses external keys before reading a value. A changed
value becomes a new provider version; the container and its ownership metadata
are created when the key is first written. The value is never placed on a
provider command line, in a log, or in a plan.

A **local** target keeps the unit's Kubernetes Secret (`<unit>-secrets`), and an
**externally managed** key keeps its ESO-delivered Secret. `sol secret status`
reports the owner and state without printing a value; on a durable target it
reports the provider authority (`owner=sol-provider`).

### Runtime delivery

For provider-backed keys the renderer emits a per-unit `SecretProviderClass`
prerequisite and mounts it at `/var/run/sol/secrets`. Each key is one file named
exactly `<KEY>`. The container receives `KEY_FILE=/var/run/sol/secrets/<KEY>` and
`SOL_SECRETS_DIR=/var/run/sol/secrets`; the value is **not** placed in an
environment variable. Ordinary values are never mirrored back into a Kubernetes
Secret through `secretObjects`.

Applications consume the file through the portable contract:

- `Sol_runtime.secret key` resolves `<KEY>_FILE`, then `SOL_SECRETS_DIR/<KEY>`,
  then the environment variable `KEY`. Existing environment-based consumption
  therefore keeps working wherever a file is not projected.
- `Sol_runtime.secret_result` reports an unreadable projected file separately from
  an absent optional value. Required secrets must use it.

AWS uses the Secrets Store CSI driver with the AWS provider and the pod's EKS Pod
Identity association (never the node role), with secret rotation polling at two
minutes. GKE enables the Secret Manager add-on with a two-minute rotation
interval. A mounted file is refreshed by the driver; a process that captured the
value at startup does not observe the refresh until it is restarted.

**Setting writes; activation is explicit.** Sol does not restart a workload. A
running process keeps the value it started with, and a value written before the
workload exists has nothing to restart — which is not a failure, and is the state
a deploy's own secret precondition requires (#1350, #1434). An unchanged deploy
does not restart a running process. A sequence of `sol secret set` calls is not
an atomic rotation transaction: a process that starts between two writes can
observe the newer value.

### Deploy, migration and recovery

On first deploy, `sol secret set` must have created the provider authority; the
deploy fails closed if it is missing, unowned, unreadable, unversioned or pending
provider deletion. It never generates a replacement.

If a Sol-owned Kubernetes copy predates the provider authority, the deploy adopts
it: the value is written to the provider first, then the Kubernetes key is
retired. An interrupted adoption leaves both copies; the next deploy resumes by
retiring the Kubernetes copy. When both exist, the provider is authoritative; a
disagreeing Kubernetes value is reported and retired rather than silently chosen.
A provider authority outlives a namespace or cluster replacement, so redeploying
recreates the authorization, `SecretProviderClass` and mount without changing the
value.

### Explicit activation

First select the target's configured kube context, actual namespace and workload
name. Unit names use Kubernetes spelling (`charge_svc` becomes `charge-svc`);
namespace selection follows the target's plan. For a Deployment (service or worker):

```bash
kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout restart deployment/charge-svc
kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout status deployment/charge-svc --timeout=5m
```

For an Argo Rollout, use the installed Argo Rollouts plugin:

```bash
kubectl argo rollouts restart charge-svc --context "$CONTEXT" -n "$NAMESPACE"
kubectl argo rollouts get rollout charge-svc --context "$CONTEXT" -n "$NAMESPACE" --watch
```

Argo's [restart operation](https://argoproj.github.io/argo-rollouts/features/restart/)
recreates pods using `spec.restartAt`. Wait for the previous pods to be replaced
and the new pods to become healthy; an already-healthy Rollout status alone does
not prove that a scheduled restart has finished. A scheduled function's next Job
starts with the then-current value; an already-running Job retains its startup
values. Do not rerun a Job merely to refresh a secret unless repeating its work
is intended.

After replacement, verify the application's authenticated behavior against the
resource before revoking the old credential. Neither authority presence, ESO
sync, a mounted file, nor healthy rollout alone proves successful use of the new
credential.

## Resource credentials

Resource credentials are delivered through the target's bindings. Database
consumers read `<target>-dml-creds`, and migration Jobs read `<target>-ddl-creds`.
Managed Kafka consumers and contract Jobs read `<target>-kafka-creds`; external
Kafka uses its declared ESO source. These are not operator-written application
secrets.

The PostgreSQL DDL/DML **passwords** are authoritative in the provider store
(`sol/<env>/<target>/databases/authority` on AWS). The class URLs remain
Kubernetes delivery projections written after the setup Job succeeds. An ordinary
deploy re-applies an established record, so it is a repair rather than a rotation;
a pending record re-runs the bootstrap, whose script refuses an existing role.
Missing, unreadable or unowned authority fails closed, and Sol never generates a
replacement. PostgreSQL rotation remains an operator procedure; managed Kafka
credential rotation and partial Kafka deprovisioning remain unsupported, and an
ordinary deployment refuses authority replacement or deletion.

### Deploy and rollback

Deploy and rollback verify application authority and deliver resource credentials
from the current target's bindings. For an external key, `sol deploy` waits for
ESO `SecretSynced` with a generation-bound synced version, verifies the
materialized key set, then verifies workload rollout. `sol secret status`
evaluates that same readiness state without waiting. ESO sync does not prove that
an already-running process has loaded a rotated value. Rotate at the external
authority, wait for ESO, then restart the affected workload with Kubernetes
rollout tooling; an unchanged `sol deploy` does not restart it.

Rollback restores the release's recorded **requirements** against the current
target's authorities: a Sol-managed application key is projected from the current
provider authority, not from a stale recorded value.

A key consumed by the current configuration or recorded deployed release cannot be
deleted through `sol secret delete`. Intentional target destruction lists and
removes the target's provider authorities and re-observes the store; a successful
delete request is not absence.

## Identity requirements

Writing application authority (`sol secret set`) and destroying a target require
the target's provisioner/operator identity. The deploy identity only reads the
authority to verify it; it cannot create or write application values. Workload
identities receive read access to their exact declared secrets only.

## What is deliberately out of scope

- **A Kubernetes-API-access capability.** No maturity-A workload may have
  ambient API access; adding a narrow Role/RoleBinding grant needs a concrete
  capability and a least-privilege permission set first.
- **Versioned application secret names.** Names are stable; a new provider
  version is the rotation unit, and history retention is the provider's.
- **Managed PostgreSQL or Kafka rotation.** Both need overlapping credentials or
  an explicitly disruptive procedure, which is an operator decision rather than a
  deploy side effect.
- **Build-time secrets** (FEAT-053) — a different lifecycle, not a substitute
  for runtime rotation.
- **Live qualification.** The offline suite does not establish provider IAM,
  CSI driver behavior, file-refresh timing or eventual deletion; see #1118 and
  #1360.
