# External Secrets Operator qualification

This qualification covers external secret delivery from provider authority,
through ESO, into a Sol workload. Renderer and fake-kubectl tests establish only
the modeled contract; they do not establish provider authentication or a running
workload receiving the value.

## Version and upgrade assumption

Sol renders `external-secrets.io/v1`: ESO v0.16 introduced that API and v0.17
stopped serving `v1beta1`. The floor is an API requirement, not a supported
upgrade range; upstream ESO supports only its current minor release. Readiness
assumes `status.syncedResourceVersion` is `"<metadata.generation>-<hash>"`,
computed by upstream `pkg/controllers/util.GetResourceVersion`; the shape was
checked against ESO v0.16.1 and v2.13.0 (2026-10-17). It is an implementation
detail rather than a documented API guarantee. Every run records the
ESO/controller version, and an upgrade that changes or omits the value must fail
closed and be re-qualified; never fall back to `Ready` alone.

## Evidence required

For each provider row, record the installed Sol revision, ESO/controller version,
target and namespace-scoped `SecretStore`, controller identity, provider-side
permissions, and the exact ExternalSecret condition and materialized Kubernetes
Secret observations. Then deploy a workload that reads the declared environment
variable and establish that it receives the expected test value without recording
the value itself. Demonstrate that an unauthorized or missing remote key fails
closed and does not advance the recorded release. Do not claim that ESO sync proves
an already-running process loaded a rotated value; rotation remains manual.

Live qualification can create billable cloud resources and requires explicit
operator authorization under `../README.md`. Until run, the provider rows below
remain **NOT RUN**.

| Row | Provider path | Required live evidence | Status |
|---|---|---|---|
| ESO-AWS | Namespace `SecretStore` authenticating to AWS Secrets Manager | Authorized read, ExternalSecret `Ready=True` / `SecretSynced`, the `status.syncedResourceVersion` generation prefix matching `metadata.generation`, exact materialized key set, workload environment consumption, unauthorized-read failure | NOT RUN |
| ESO-VAULT | Namespace `SecretStore` authenticating to Vault | Authorized read, ExternalSecret `Ready=True` / `SecretSynced`, the `status.syncedResourceVersion` generation prefix matching `metadata.generation`, exact materialized key set, workload environment consumption, unauthorized-read failure | NOT RUN |
| ESO-GCP | Namespace `SecretStore` authenticating to Google Secret Manager | Not currently claimed; add a row only when Sol documents and supports this provider path | NOT CLAIMED |

Direct deployment and GitOps emission must use the same ExternalSecret and
workload references. A live GitOps row additionally needs evidence that the
configured GitOps controller applies the emitted objects and ESO reconciles them.
