# Deploy and recover

Sol owns the operations it starts: planning a change, reconciling a deployment,
verifying workload readiness, restoring a recorded application release, and
removing a declared environment. It does not provide a second interface for
routine diagnosis of a running system.

## Deploy

```bash
sol check
sol plan <target>
sol deploy <target>
```

`sol check` validates the workspace, including generated contract freshness. `--scope` narrows declaration and workload findings; generated contract freshness is always checked workspace-wide.

`sol deploy` verifies the resulting workload rollout and reports failures from
the underlying provider or Kubernetes operation with Sol context. A successful
deploy reports its release identifier. Use `sol releases` to find retained
release identifiers for rollback.

For ongoing diagnosis, use the installed system's tools: Kubernetes for
workload and event details, Grafana/Loki/Prometheus for telemetry, and the cloud
provider for managed resources. Sol's deployment result establishes whether its
own operation reached the required postconditions; it is not a replacement for
those systems' operational interfaces.

## Roll back an application release

```bash
sol releases --target <target>
sol rollback <release-id> --target <target>
```

Rollback restores the immutable application release boundary and verifies the
live workloads before advancing the current-release pointer. It refuses when
release ownership or migration compatibility cannot be established. Application
rollback does not roll back database state.

## Remove an environment

```bash
sol destroy <target>             # inspect the plan
sol destroy <target> --apply     # authorize removal
```

Destroy removes Sol-owned workloads before their substrate and independently
verifies absence. It fails closed when state or ownership is unknown. Absence is
claimed only for a scope Sol can name: the GCP project, or the AWS account declared
by the target's role ARNs with the active caller in that account. A failed provider
enumeration is unknown, never absence. An AWS target that declares no role ARN
cannot establish its account, so destroy refuses to claim absence until one is
declared. Installation resources have a separate lifetime and are removed with
`sol uninstall`.

## Database migrations and secrets

Migration and secret commands remain available while their replacement workflows
are designed. See the [migration guide](deployment.md) and
[secret reference](../reference/substrate.md) for their current contracts.
