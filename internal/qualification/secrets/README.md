# Provider-backed secrets: controlled live qualification

This scenario verifies the implementation merged in [#1915](https://github.com/sol-fab/sol/pull/1915)
against a real AWS or GCP target. It is **not** a release-promotion record and it does not
claim qualification from offline tests. The canonical release contract does not yet carry a
provider-secret claim family; until the parity/producer work (#1734/#1737) adds it, this
scenario produces behavioral feature evidence and binds the current contract digest for the
record producer to consume.

## What it establishes

| Property | AWS observation | GCP observation |
|---|---|---|
| Provider is authoritative | `secretsmanager describe-secret`/`list-secret-version-ids`; value never read | `gcloud secrets describe`/`versions list`; value never read |
| Direct CSI projection | rendered `SecretProviderClass`, mounted `/var/run/sol/secrets/<KEY>`, probe reads the file | same, GKE Secret Manager add-on |
| No Kubernetes mirror | no Secret in the namespace contains the key; SPC has no `secretObjects` | same |
| Workload-specific authorization | `iam:SimulatePrincipalPolicy` for the unit role; pod restart after grant removal does not become ready | exact `secretAccessor` member on the secret; pod restart after removal does not become ready |
| Rotation/refresh | new provider version; file fingerprint changes within the bound; measured | same, 2-minute add-on interval |
| Missing authority fails closed | delete the authority; the next deploy fails before applying the workload; re-seed recovers | same |
| Namespace recovery | delete the probe namespace; redeploy re-projects the same authority | same |
| Independent absence | destroy through Sol, then provider reads for secret, cluster, RDS, VPC | destroy, then secret, cluster, Cloud SQL, disks |

The scenario does **not** test full cluster replacement (a target destroy removes the provider
authority by design) or managed PostgreSQL/Kafka rotation. Those remain separate operator
procedures.

## Prerequisites (all operator-supplied)

1. **Explicit approval** for a billable live run. Do not run the execute step without it.
2. A **released candidate** (`SOL_INSTALL` prefix, `SOL_CANDIDATE` document and its archive)
   accepted by `sol-under-test.sh`; the candidate revision must be a descendant of #1915
   (`c6ec37e7`). The scenario refuses a pre-#1915 candidate before preparing anything.
3. A **fresh target** declared in a private environments file copied from
   [`target.example.yml`](target.example.yml). The target's cluster must not exist, and its
   `secrets` mapping must contain `probe/secret_probe_worker: SOL_PROBE_SECRET: { authority: sol }`.
   The target's **durable installation** (state backend, provisioner/deploy identities, DNS
   ownership and any provider bootstrap) must already be established; this scenario starts at
   the disposable target and does not drive the first-run installation offer. Use the provider
   harness's cloud phase (or the documented bootstrap) first if it is absent.
4. Provider identities:
   - AWS: provisioner, cluster-access, deploy and operator roles plus the reconciler role used by
     `sol grants apply`; `QUAL_WORKLOAD_IDENTITY` is the probe unit's workload role ARN.
   - GCP: deploy/provisioner service accounts, the reconciler service account, Workload Identity,
     and `secretmanager.googleapis.com` enabled.
5. Registry push access to `QUAL_REGISTRY` (an existing ECR repository or Artifact Registry
   repository the cluster can pull). The scenario builds and pushes a tiny pinned BusyBox probe;
   node pull permission must already exist. For AWS, set `QUAL_PROBE_REPOSITORY` to the
   **dedicated** ECR repository name (for example `secret-qual-probe`); the scenario removes
   that repository during teardown so it does not appear as target residue.
6. `kubectl`, `docker` (classic builder works; the scenario sets `DOCKER_BUILDKIT=0`), `jq`,
   `curl`, `python3` with PyYAML, `git` (candidate ancestry), and the provider CLI
   authenticated to the intended identity.
7. `script` from util-linux is not needed by this scenario, but the target's first whole-target
   deploy may use the same installation path as the provider harness; keep it available.
8. **Qualifier permissions** beyond the target's deploy/provisioner identities:
   - AWS: `eks:DescribeCluster`/`DescribeAddonVersions`, `secretsmanager:DescribeSecret`/
     `ListSecrets`, `iam:SimulatePrincipalPolicy`, registry push, and Kubernetes
     `get/list/watch` on pods, `delete` on pods, `delete` on namespaces (a disposable
     namespace), and `create` on `pods/portforward`.
   - GCP: `container.clusters.get`, `secretmanager.secrets.get`/`list`/`getIamPolicy`,
     `cloudsql.instances.list`, `compute.disks.list`, registry push, and the same Kubernetes
     pod/namespace/port-forward actions.
   The scenario does not call `kubectl exec`; it reads the mounted file through the probe's
   HTTP endpoint over `port-forward`, so no container exec permission is needed.
9. The target's reconciler identity must be available to `sol grants apply`. Export the same
   authorization variables the provider harness uses (`SOL_AUTHORIZATION_ROLE_ARN` for AWS,
   `SOL_AUTHORIZATION_SERVICE_ACCOUNT`/`SOL_WORKLOAD_IDENTITY_PROVIDER` for GCP) or already be
   impersonating that identity. The scenario itself never writes IAM outside `sol grants`.

## Commands

Plan (read-only; resolves the candidate and prints the steps/cost):

```sh
export SOL_INSTALL=/opt/sol/v0.x.y
export SOL_CANDIDATE=/path/to/candidate.json
export LOG_DIR=/path/to/evidence/attempt-1
export ATTEMPT=secret-aws-1
export PROVIDER=aws
export SOL_TARGET=qual/aws/us-east-1
export QUAL_TARGET_FILE=/secure/qual-environments.yml
export QUAL_CLUSTER=qual-secret-aws
export QUAL_REGION=us-east-1
export QUAL_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
export QUAL_WORKLOAD_IDENTITY=arn:aws:iam::123456789012:role/sol/qual/sol-qual-secret-probe-worker

QUAL_PLAN_PREFLIGHT=1 internal/qualification/scenarios/run.sh \
  --scenario internal/qualification/secrets/aws-scenario.sh --plan
```

Plan mode resolves the candidate and target, checks the candidate capability, target
declaration, required tools, provider identity/read permissions, and fresh-cluster
precondition. It writes `plan-preflight.txt` with one `PASS`/`FAIL`/`UNKNOWN` line per
check and exits non-zero if any check is not `PASS`. It never builds/pushes the image or
mutates a provider.

Execute (only after approval; this creates billable resources and mutates IAM through Sol):

```sh
export APPROVED=1
internal/qualification/scenarios/run.sh \
  --scenario internal/qualification/secrets/aws-scenario.sh
```

GCP uses `PROVIDER=gcp`, `SOL_TARGET=qual/gcp/us-central1`,
`QUAL_REGION=us-central1`, `QUAL_PROJECT=<project>`, and
`gcp-scenario.sh`; it does not require `QUAL_WORKLOAD_IDENTITY` because the
scenario derives the exact KSA principal from the plan namespace/workload and project.
The shared runner binds the attempt identity and the candidate; it refuses an attempt that
reuses another attempt's evidence directory.

## Expected outcomes and evidence

The run succeeds only when all of these hold:

- The shared runner records `inventory-before.txt` (after prepare, before the authority
  and workload exist), `inventory-after.txt` (after execute, before teardown),
  `absence.txt` (after teardown), and `cleanup-verdict.txt` (`cleanup=PASS|FAIL`,
  `absence=PASS|FAIL|UNKNOWN`). The scenario supplies the provider reads; it does not
  write those runner-owned files itself.
- `phase-verdicts.txt` records `prepare`, `cloud`, `app`, `destroy`, `verify`.
- `projection.json` has `correct_status=200` and `wrong_status=401`; `fingerprint` is a
  SHA-256 of the value, never the value.
- `pod-projection.txt` shows a CSI volume, `/var/run/sol/secrets` mount and
  `KEY_FILE`/`SOL_SECRETS_DIR`; no `secretKeyRef` for the key.
- `kubernetes-secret-absence.txt` has `kubernetes_secret_holders=0`.
- `spc.yaml` names `provider: aws` with `usePodIdentity: "true"` or `provider: gke`; no
  `secretObjects`.
- `rotation.json` shows a changed fingerprint within `QUAL_ROTATION_TIMEOUT_S` (default 300s).
- `authorization.json` records the allowed decision before revocation and the denied/absent
  decision after; `authorization-revoked.txt` shows no new pod became ready with the grant
  removed; `authorization-restored.txt` shows recovery.
- `missing-failclosed.log` is non-zero and names the missing provider authority;
  `recovery.txt` shows a successful re-seed and probe.
- `namespace-recovery.txt` shows a successful redeploy after namespace deletion.
- `cleanup-verdict.txt` has `cleanup=PASS` and `absence=PASS`; `absence.txt` is the
  independent provider read behind that verdict. On AWS it includes the authoritative
  `internal/qualification/aws/absence.py` inventory (`full_inventory=ABSENT`) captured from
  `aws-absence-prior.json`, not only the focused secret/cluster/RDS/VPC checks. Set
  `QUAL_QUALIFIER_ARN` when the transport principal has an EKS access entry that must be
  attributed.

If any of these is missing, the run is not evidence and must not be recorded as a pass.
The scenario deliberately refuses to turn an unreadable provider response into absence.

## Cleanup and independent absence

`scenario_execute` calls `sol destroy TARGET --apply` itself and then
`hook_absence`, so a normal run includes teardown and absence before `scenario_assert`.
The runner's trap calls `scenario_cleanup` on an earlier failure; it still destroys and
records what it observed but cannot make the run pass. If the host is killed, run:

```sh
sol destroy "$SOL_TARGET" --apply
```

and then re-run the provider absence commands from `aws.sh`/`gcp.sh` manually. A successful
destroy request is not absence; only the independent provider reads are.

The tiny probe image is pushed to `QUAL_REGISTRY` with the attempt tag; it is not part of the
target's teardown. Remove the tag after the attempt with the registry's own lifecycle policy
or `aws ecr batch-delete-image` / `gcloud artifacts docker images delete`; record that
cleanup in the attempt if the registry is shared.

## Estimated cost

List on-demand prices, November 2026; verify in the provider console before approval. The
scenario's target has no profile, database or Kafka resource, but the cluster root still
creates the control plane, four nodes, NAT and storage. A 2-4 hour window is approximately:

| Provider | Main hourly cost | 2h | 4h |
|---|---|---|---|
| AWS | EKS control plane + 4 × `m6i.xlarge` + NAT/disks ≈ USD 1.1-1.5/h | USD 3-5 | USD 6-10 |
| GCP | GKE control plane + 4 × `e2-standard-4` + NAT/disks ≈ USD 0.8-1.2/h | USD 2-4 | USD 4-8 |

Budget USD 15-25 per provider for overruns, image pulls/builds and provider data transfer. A
failed run still bills until teardown; the destroy is part of the run, not a follow-up.

## Known live risks to confirm, not work around

- AWS Pod Identity with `automountServiceAccountToken: false`: the workload has a Pod
  Identity association and the SPC sets `usePodIdentity: "true"`. If ASCP cannot obtain the
  pod's credentials, the run records a product finding; do not weaken the token posture to
  pass it.
- CSI file ownership/mode: the workload runs non-root. If the projected file is not
  readable by that user, record the provider/driver finding and the actual mode; do not add a
  broad filesystem permission or a Kubernetes Secret mirror.
- Provider IAM propagation: a just-applied grant/revocation can take time to become effective.
  The scenario's pod-restart and simulation checks are bounded; a timeout is UNKNOWN, not a
  pass. Re-run a fresh attempt rather than editing IAM by hand.
- `iam:SimulatePrincipalPolicy` alone does not establish effective access: it does not model
  permissions boundaries, resource policies or SCPs. The scenario records it as policy-level
  evidence and treats a fresh pod's mount/readiness as the effective check. A simulation
  `allowed` is not sufficient for the authorization cell.
- The AWS add-on version is pinned and preflight re-reads the regional catalog. If the catalog
  no longer serves the pin, stop; do not fall back to `most_recent`.
- AWS absence is the authoritative `internal/qualification/aws/absence.py` inventory,
  captured before teardown and collected after cleanup; it is not only the focused
  authority/cluster/RDS/VPC check. GCP still uses focused provider reads plus the GCP
  harness's full absence phase when a promotion-eligible attempt needs it.

## Evidence contract and coordination

The scenario uses the shared runner (`internal/qualification/scenarios/run.sh`), `attempt.sh`,
`sol-under-test.sh`, and the canonical evidence classes. `contract.txt` records the id,
revision and SHA-256 of `internal/qualification/qualification-contract.json`; it does not
modify that contract or the pinned evaluator. It is registered in
`internal/qualification/scenarios/catalog.json` as `implemented-unqualified`.

The scenario now implements the shared runner's canonical evidence slots
(`scenario_inventory`, `scenario_absence`, `cleanup-verdict.txt`) rather than only a
scenario-local absence check. The canonical release producer (#1734/#1737) still needs to
add the provider-secret claim family and map those evidence files into a provider record. Until that lands, treat this as
feature verification only, not a promotion artifact. The catalog and the capability matrix
name it separately from the ESO scenarios and the Kafka/application claims.
