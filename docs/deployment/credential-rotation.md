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

## Rotation: preserve each consumer's scope

Application values are stored in a unit's own `<unit>-secrets` object. Set or
rotate one with the target and exact `domain/unit/key` address:

```bash
your-secret-tool get payment-api-key \
  | sol secret set prod/aws/us-east-1 payments/charge_svc/PAYMENT_API_KEY --from-stdin
```

Sol resolves the target and the key's declared authority before opening the
input. It refuses external keys before reading a value. A changed value updates
only that unit's Secret. **Setting writes; activation is explicit**: Sol does not
restart the workload, so a running process keeps reading the value it started
with until something restarts it, and a value written before the workload exists
has nothing to restart — which is not a failure. An unchanged `sol deploy` does
not restart a running process or guarantee adoption of the new value. `secret set` neither updates `sol-secrets`
nor writes to another unit. Secret values are redacted from command output.

That also bounds the guarantee: a sequence of `sol secret set` writes is **not**
an atomic rotation transaction, because a process that starts between two writes
can observe the newer value. Coordinate credential overlap and the explicit
activation of each affected workload; neither writing nor deploying makes
multiple credential changes atomic.

Platform credentials used by Sol's internal Jobs have a separate target scope.
Database credentials are no longer one of them: the deploy delivers
`<target>-dml-creds` to consuming units and `<target>-ddl-creds` to the migration
Job from the target's binding, so there is no `@platform/POSTGRES_URL` to rotate.
For SASL_SSL targets, the contract Job still requires the platform Kafka
password and CA certificate:

```bash
your-secret-tool get kafka-sasl-password \
  | sol secret set prod/aws/us-east-1 @platform/KAFKA_SASL_PASSWORD --from-stdin
```

Platform writes update only `sol-secrets` objects in active target namespaces;
they never copy values into application Secrets or restart application
workloads. `sol secret status TARGET` reports key owners and presence without
printing values.

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
starts with the then-current Secret; an already-running Job retains its startup
values. Do not rerun a Job merely to refresh a secret unless repeating its work
is intended.

After replacement, verify the application's authenticated behavior against the
resource before revoking the old credential. Neither Secret presence, ESO sync,
nor healthy rollout alone proves successful use of the new credential.

### Deploy and rollback

Deploy and rollback preserve secret values. They verify required unit Secrets
and the shared platform inputs needed by the operation. For an external key,
`sol deploy` waits for ESO `SecretSynced` with a generation-bound synced version,
verifies the materialized key set, then verifies workload rollout. `sol secret
status` evaluates that same readiness state without waiting. ESO sync does not
prove that an already-running process has loaded a rotated value. Rotate at the
external authority, wait for ESO, then restart the affected workload with
Kubernetes rollout tooling; an unchanged `sol deploy` does not restart it.

Sol-owned unit and platform values update their existing Kubernetes Secret in
place. A later deploy cannot restore a previous value from CI or a local shell.
Required platform inputs cannot be deleted while the target's Sol Jobs require
them; TLS-only Kafka inputs can be removed after the target no longer uses TLS.

## What is deliberately out of scope

- **A Kubernetes-API-access capability.** No maturity-A workload may have
  ambient API access; adding a narrow Role/RoleBinding grant needs a concrete
  capability and a least-privilege permission set first.
- **File-mounted secret refresh.** The env-var contract is kept, so kubelet's
  file-refresh behavior is not relied on.
- **Versioned secret names.** Names churn and leak history; in-place update plus
  restart is simpler and auditable.
- **Build-time secrets** (FEAT-053) — a different lifecycle, not a substitute
  for runtime rotation.
