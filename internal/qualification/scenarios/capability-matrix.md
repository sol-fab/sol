# Qualification capability matrix

Status distinguishes implementation from evidence. `live-qualified` is reserved
for behavioral evidence from a released candidate recorded through the shared
attempt/evidence contract.

| Capability | AWS | GCP |
|---|---|---|
| External queue/object bindings | Implemented, offline-tested | Implemented, offline-tested |
| Serverless runtime | Lambda SQS/S3 mechanism-live; not production-qualified | Phase 1 adapter implemented; not run |
| Kubernetes runtime | Implemented; not live-qualified | Implemented; not live-qualified |
| Mixed Kubernetes/serverless lifecycle | Existing harness; unqualified | Existing harness; unqualified |
| Interrupted apply/resume | Catalogued adapter only; not executable through shared runner | Not separately implemented |
| Resource inventory | Cross-cutting scenario requirement | Cross-cutting scenario requirement |
| Independent absence verification | Cross-cutting scenario requirement | Cross-cutting scenario requirement |
| External Secrets (ESO) | Existing scenario; NOT RUN | Existing scenario; NOT RUN |
| Provider-backed secrets / CSI | Shared-runner scenario implemented; offline-tested; plan-validated; not live | Shared-runner scenario implemented; offline-tested; plan-validated; not live |
| Provider-backed application secrets (CSI, no mirror) | Implemented, offline-tested; live procedure prepared, NOT RUN | Implemented, offline-tested; live procedure prepared, NOT RUN |

## Secret-management scenarios

The dedicated ESO scenarios live under `internal/qualification/external-secrets/`
and define externally managed store behavior. They are separate from Sol-managed
provider-backed application secrets, which live under `internal/qualification/secrets/` and
use the Secrets Store CSI driver. The two use different authorities, delivery objects and
failure modes and must not be folded together.

The provider-backed secret scenario runs through the shared attempt/candidate runner and
produces behavioral evidence for authority presence, mounted-file projection, absence of a
Kubernetes Secret mirror, per-unit authorization and revocation, rotation, missing-authority
fail-closed behavior, namespace recovery, and independent provider absence. It is a feature
verification, not a release-promotion record until the canonical contract/producer work adds
the claim family.

## Status vocabulary

- **implemented**: code exists and composes with the shared runner.
- **offline-tested**: executable tests exercise composition, failure paths, and cleanup verdicts.
- **plan-validated**: `--plan` runs the released-candidate and scenario checks without mutation.
- **live-qualified**: behavioral evidence from a real provider run recorded through the attempt/evidence contract.

The GCP Phase 1 and provider-secret scenarios are implemented, offline-tested, and
plan-validated. None is live-qualified. The interrupted-apply entry remains
catalogued only and is not executable through the shared runner.
