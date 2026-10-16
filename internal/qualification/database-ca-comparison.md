# Offline database-CA comparison (I4)

This is temporary **MECHANISM migration evidence**, not release qualification or a second
runtime policy catalog. The executable comparison is
[`test_legacy_ca.ml`](../tooling/sol_qualification/test/test_legacy_ca.ml). It reads the
current AWS/GCP function bodies unchanged and runs them in isolated Bash processes;
it never sources their live entry points. Both Bash and I3 read the same simulated
Kubernetes objects and command failures through a private, offline `kubectl` transport.
Actual `jq` evaluates AWS's predicate. No cloud credentials, real Kubernetes executable,
provider tools, preflight, deployment or cleanup are available to that process.

Run through `dune runtest internal/tooling/sol_qualification/test`. The test reports the
source SHA-256, legacy acceptance and I3 classification for each scenario/provider.
Failures in extraction, unsupported queries or the comparison driver fail the test;
they cannot count as a successful negative scenario. The live scripts are Dune dependencies.
Remove this comparison when the corresponding migration is complete; keep the shared
observer's own adversarial regression tests.

## Expectation authority and scope

Fixture inputs use canonical `examples/pluto/sol.yml` service paths and `uses` declarations,
`Sol_cli_kubernetes_name` addresses, `Sol_cli_database_setup_render` database identity/report,
and `Sol_cli_manifest_cluster_env` CA key/path/volume definitions. They do not copy the
legacy CA constants. In particular the expected key is currently `ca.pem`, not the obsolete
prototype's `ca.crt`. Product libraries are linked by this **test only**; the observer still
independently decodes external Kubernetes schemas and the evaluator remains pure.

Each provider fixture selects its existing qualification scenario's workload subset, then
selects every database consumer within that declared specimen. This is not a claim that the
legacy provider lists are a complete production target declaration. AWS has four actual DB
consumers plus `checkout_svc`, which does not declare `uses: [app_db]`. GCP has four DB
consumers. The AWS compatibility baseline deliberately supplies an extra harmless CA volume
to checkout so the existing assertion can reach every actual consumer. It is not a claim
that Sol renders CA delivery to nonconsumers. A separate negative removes that extra volume.
Container name `application`, certificate bytes and observation identities are explicit fixture
inputs; no product container naming convention or authenticated cluster is inferred.

The legacy database-delivery credential prerequisites are healthy except in named controls.
For AWS's empty-selection and missing-CA-declaration cases only, the comparison invokes its
CA function directly so credential prerequisites cannot mask that boundary. GCP always runs
its actual database-delivery function. Its credential gate does **not** observe CA resources.

## Results that must remain distinguishable

`Reject` means a nonzero legacy assertion result. I3 `UNKNOWN` means unreadable or incorrectly
bound evidence, not absence. A missing exact object reported by a failed command stays UNKNOWN;
I3 requires successful complete native-list evidence to establish absence. `REFUSED` means
invalid/empty fixture binding or selection, before observation. All successful I3 comparisons
contain four persisted CA verdicts backed by eight independent reads; they do not seal a full
database qualification manifest, whose other obligations remain unestablished.

| Scenario group | AWS legacy | GCP legacy | I3 CA | Interpretation |
|---|---|---|---|---|
| Healthy compatibility baseline | Accept | Accept | PASS | Both comparison paths reach their predicates |
| One consumer CA missing; CA only in migration namespace | Reject | Accept | UNKNOWN | Preserves AWS required presence; new GCP CA coverage |
| Forbidden CA, failed command, timed-out Deployment, malformed Deployment | Reject | Accept | UNKNOWN | Preserves refusal without claiming absence (#1497) |
| One workload among neighbours has another source or no CA volume | Reject | Accept | FAIL | Preserves AWS per-workload check |
| Empty exercise / missing CA declaration | Reject | Accept | REFUSED | Preserves AWS non-vacuity; GCP has no corresponding CA assertion |
| Wrong/empty CA key | Accept | Accept | FAIL | Stronger, including `ca.pem`/`ca.crt` regression |
| Wrong object name/namespace; malformed or empty successful ConfigMap output | Accept | Accept | UNKNOWN | Stronger object scope/schema validation |
| Redirected, absent, sidecar-only, shadowed mount; omitted projected key | Accept | Accept | FAIL | Stronger actual consuming-container delivery |
| Legacy selector omits a missing declared consumer | Accept | Accept | UNKNOWN | Canonical fixture selection still requires that consumer |
| Wrong observation principal | Accept | Accept | UNKNOWN | Per-read context binding; legacy full-phase identity preflight is outside this slice |
| CA missing only in migration namespace | Reject | Accept | PASS | **AWS adoption gap:** consumer CA does not cover migration input |
| Correct source/path via consistently renamed volume | Reject | Accept | PASS | **AWS adoption gap:** I3 does not enforce canonical volume name |
| Nonconsumer checkout lacks CA volume | Reject | Accept | PASS | AWS over-selection; no DB delivery obligation applies to checkout |
| Missing DDL Secret / all DML Secrets missing | Reject | Reject | PASS | Credential-control failures outside CA scope |

The existing AWS `test-live-row.sh` CA regressions (absent consumer ConfigMap,
unreadable ConfigMap, one selected workload using another CA) map to the preserved rows.
The comparison additionally checks missing volumes, unreadable/malformed Deployment reads,
and zero-workload/declaration guards in the current predicate. It does not compare unrelated
release installation, transaction, image or teardown assertions. Existing I3 tests retain
coverage of candidate/assessment/subject receipt substitution, cluster/endpoint/freshness,
incomplete discovery, persistence failure and positively established native-list absence.
GCP's absence of CA checks is measured by asserting that its actual function makes no
Deployment or ConfigMap queries, not inferred from a passing negative alone.

## What blocks AWS adoption

**The entire AWS CA predicate cannot yet be deleted without losing guarantees.**
Its migration-namespace read must acquire an explicit independently evidenced owner (migration
input is a separate obligation), and canonical volume-name checking must be resolved against
the product declaration/policy before replacement. The comparison retains both mismatches as
passing counterexample tests, not waived compatibility requirements. Checkout over-selection
needs an explicit canonical selection cutover, rather than forcing the replacement to require
CA delivery to a nonconsumer.

A focused product-owned projection review must determine how to supply the candidate-bound
CA key, expected file path, ConfigMap name per database, workload namespace/name, consuming
container membership, and canonical volume identity if required. The migration-input owner
also needs the database namespace and relevant Job/container delivery bindings. Generate those
facts from canonical definitions and cross-test actual rendered artifacts; this comparison
does not create the projection, authenticate candidates, or support old released artifacts.

Before live adoption also review process transport/authentication, per-read context freshness,
claim-family policy ownership and final-manifest consumption. Deployment templates do not
prove running Pod filesystem delivery, certificate validity, rollout health or successful TLS.
Actual DML authority remains a required future obligation; Secret names/references and the
existing unit-Secret field check cannot establish it. No live predicate or policy authority is
removed by I4, and GCP's credential assertions remain necessary until independently replaced.
