# Compatibility contract (maturity A)

`production-single-region/v1` claims support only for the exact set below. A
target that selects the profile and resolves outside this set fails preflight
before anything is mutated; there is no "accepted but unverified" outcome
(DEC-026 §4).

All of these inputs are pinned in the repository rather than floating. A
workspace consumes the framework from workspace-owned, immutable opam
dependencies (DEC-025); it does not need `$SOL_HOME` or a Sol source checkout to
build. The workspace-independence proof is the CI job recorded in
`internal/ci/`.

## Framework languages

| Language | Verdict | Evidence or trigger |
|---|---|---|
| OCaml | **qualified** | The first profile's application language. A workload declares `language: ocaml` in `sol.yml`. |
| TypeScript | **staged — not qualified** | DEC-026 §2's triggers: `@sol-fab/worker` needs an `on_ready` equivalent, and the compatibility input below must be able to distinguish language/framework combinations before a TypeScript workload can claim the profile. Until then a profile target containing a TypeScript workload fails preflight. |

A workload declares its language in `sol.yml`:

```yaml
services:
  charge_svc:
    language: ocaml
```

Language is **declared, never inferred** from Dockerfiles, paths or package
metadata — DEC-022 §7 keeps language out of deployment identity, so inferring
it here would be the same wrong abstraction. A profile target fails preflight
if any deployed workload omits its language, or declares one the profile does
not qualify:

- `service "X" does not declare a language; add `language: ocaml` (or `typescript`) to its entry in sol.yml`
- `service "X" declares language typescript, which production-single-region/v1 does not qualify; the first profile is OCaml-only (DEC-026 §2)`

## Pinned inputs

| Input | Supported | Pinned in |
|---|---|---|
| Sol CLI | the built `sol --version` value (`git describe --tags --always --dirty` at build) | `cli/bin/dune` |
| OCaml | `>= 5.4.0` (qualified on 5.4.1) | `dune-project`, `sol-*.opam` |
| Kubernetes (EKS) | 1.36 | `platform/cloud/aws/cluster/variables.tf` (`kubernetes_version`) |
| Provider module | AWS (`platform/cloud/aws/cluster/`) — the only qualified provider; GCP is not qualified for this profile | `platform/cloud/aws/cluster/`, `Sol_cli_provider` |
| cert-manager chart | v1.14.4 | `platform/cloud/modules/platform/main.tf` |
| ingress-nginx chart | 4.10.1 | `platform/shared/components.json` (`versions`) |
| Argo CD chart | 6.7.3 | `platform/cloud/modules/platform/main.tf` |
| Redpanda chart | 26.1.11 | `platform/shared/components.json` (`versions`) |
| PostgreSQL chart | 18.8.17 | `platform/shared/components.json` (`versions`) |
| Loki chart | 18.12.1 | `platform/shared/components.json` (`versions`) |
| Grafana chart | 13.2.1 | `platform/shared/components.json` (`versions`) |
| Alloy chart | 1.12.1 | `platform/shared/components.json` (`versions`) |
| Tempo chart | 2.3.0 | `platform/shared/components.json` (`versions`) |
| Prometheus chart | 25.20.1 | `platform/shared/components.json` (`versions`) |
| Workspace framework deps | per-workspace immutable pins (DEC-025) | the workspace's `dune-project` and `*.opam` |

`dev` runs the same charts at single-replica scale, so the component versions
above are the ones local development exercises too. The shared charts' versions
are declared once in `platform/shared/components.json`; both the local platform
(`Sol_cli_local_platform`) and the production module
(`platform/cloud/modules/platform/main.tf`) project them from that one
declaration, so there is nothing to drift. The production-only charts
(cert-manager, Argo CD) stay pinned in the module.

## Operator-supplied External Secrets Operator

External authority values are delivered by ESO, which Sol neither installs nor
upgrades, so ESO is not part of the pinned set above and the profile does not
preflight its version. Sol renders `external-secrets.io/v1`; that API was
introduced in ESO v0.16, and v0.17 stopped serving the older `v1beta1` API. The
v0.16 requirement is an API-compatibility floor, not an upgrade-support range:
ESO itself supports only its current minor release, while this contract pins one
exact set and treats N/N-1 upgrades as out of scope.

Direct deploy, rollback and `sol secret status` share one readiness predicate.
It requires `Ready=True` with reason `SecretSynced` and a generation-bound
`status.syncedResourceVersion` whose prefix is `metadata.generation`. Upstream
ESO computes that value as `"<metadata.generation>-<hash>"`
(`pkg/controllers/util.GetResourceVersion`). The shape is an implementation
detail, not a documented API guarantee, so missing, unrecognized or lagging
evidence is refused as not ready. An ESO upgrade that changes the shape
therefore surfaces as a fail-closed readiness failure rather than a silently
stale Secret. Re-run the external-secrets qualification with the new
ESO/controller version recorded after such an upgrade; the live evidence owner
is
[`internal/qualification/external-secrets/README.md`](../../internal/qualification/external-secrets/README.md).

## Components a CSI-backed `byo` secret projection would add (not in the supported set)

`DEC-029` selects an external CSI-compatible store (e.g. Vault) as an option for
the `byo` × Kubernetes cell. That projection needs three always-on components the
supported set above does not contain, so adopting it is a `DEC-026` §9
re-qualification event, not an implementation detail. They are named here so the
matrix can account for them; none is qualified, and no Sol profile installs one
today.

| Component | Version observed (local mechanism run) | Role | Verdict |
|---|---|---|---|
| Secrets Store CSI driver | chart `1.4.8` (`1.6.1` declares `kubeVersion >=1.30.0-0`) | projects the provider's objects as a mounted file | **not qualified** |
| Provider for the store (Vault CSI provider) | shipped by the `hashicorp/vault` chart | fetches the objects, reports their versions | **not qualified** |
| The authority (e.g. Vault) | Vault `2.0.4` (dev mode, for the mechanism run only) | holds the value | **not qualified** |

Evidence: `internal/qualification/records/2026-10-03-byo-run1-secret-projection.md`.

## Scope

One exact supported set is sufficient for maturity A. N/N-1 upgrades, skew
policy, fleet waves and broad provider matrices are out of scope; adding a
second supported set is a later, explicit decision.
