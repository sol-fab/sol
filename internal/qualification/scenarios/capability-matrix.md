# Qualification capability matrix

Status distinguishes implementation from evidence. `live-qualified` is reserved
for behavioral evidence from a released candidate recorded through the shared
attempt/evidence contract.

| Capability | AWS | GCP |
|---|---|---|
| External queue/object bindings | Implemented, offline-tested | Implemented, offline-tested |
| Serverless runtime | Lambda SQS/S3 mechanism-live; not production-qualified | Phase 1 prepared; not run |
| Kubernetes runtime | Implemented; not live-qualified | Implemented; not live-qualified |
| Mixed Kubernetes/serverless lifecycle | Existing harness; unqualified | Existing harness; unqualified |
| Interrupted apply/resume | Existing resume harness; unqualified | Not separately implemented |
| Resource inventory | Cross-cutting scenario requirement | Cross-cutting scenario requirement |
| Independent absence verification | Cross-cutting scenario requirement | Cross-cutting scenario requirement |
| External Secrets (ESO) | Existing scenario; NOT RUN | Existing scenario; NOT RUN |

## Secret-management scenarios

The dedicated ESO scenarios live under `internal/qualification/external-secrets/`
and already define the provider-side evidence required for AWS Secrets Manager
and Vault. GCP Secret Manager is not claimed. They must not be folded into
external queue/object scenarios: the failure modes and evidence are distinct.
Add GCP Secret Manager only after Sol documents and supports that provider path.
