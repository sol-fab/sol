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

### Grafana SSO (platform operator)

A production target installs one Grafana at
`https://grafana.<base_domain>`, protected by the `grafana-tls` certificate and
an OIDC login. Anonymous access is disabled. This is a **platform-operator**
prerequisite, not an app-developer step: application authors deploying a unit
do not create OIDC clients and do not need these values.

Create one OAuth web client per target/base domain at the identity provider.
For Google:

- **Internal** is the right choice for a Google Workspace organization. Only
  accounts in that organization can sign in.
- **External** is for other audiences. While the app is in *Testing*, only
  listed test users can sign in and refresh tokens expire quickly; production
  use requires Google verification or an internal audience.
- Register the exact redirect URI
  `https://grafana.<base_domain>/login/generic_oauth`. A client scoped to one
  target does not authorize another target's hostname.

Supply the values out of band so the client secret never appears in a target
file or on a Terraform command line:

```bash
export TF_VAR_grafana_oidc_client_id="<client-id>"
export TF_VAR_grafana_oidc_client_secret="<client-secret>"
# Google is the default provider; these are optional for it:
# export TF_VAR_grafana_oidc_allowed_groups='["sol-observability"]'
# export TF_VAR_grafana_oidc_role_attribute_path="contains(groups[*], 'sol-observability-admins') && 'Admin' || 'Viewer'"
sol deploy <target>
```

The production qualification preflight refuses before provisioning when the
client ID or secret is absent (and, for a custom provider, when the auth/token/
userinfo URLs are absent), naming the redirect URI above. A passing check means
the inputs are present, not that the identity provider accepts them.

For a standard OIDC provider other than Google, also set
`TF_VAR_grafana_oidc_provider=custom` and the explicit
`TF_VAR_grafana_oidc_auth_url`, `TF_VAR_grafana_oidc_token_url` and
`TF_VAR_grafana_oidc_api_url`; `TF_VAR_grafana_oidc_name` names the login button.
`TF_VAR_grafana_oidc_client_secret` is declared sensitive, so Sol refuses to
pass it as a Terraform `--var`; the environment is the supported path.

The break-glass admin password is generated when
`TF_VAR_grafana_admin_password` is unset. Read it from the chart's Secret:

```bash
kubectl -n monitoring get secret grafana   -o jsonpath='{.data.admin-password}' | base64 -d
```

No central Grafana spans targets: each target has its own instance, identity
configuration and URL.

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
