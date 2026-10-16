# Internal qualification core

## Overview

I1 implements the pure shared domain and obligation accounting proposed in draft
PR #1487. It supports explicitly bound offline fixtures only. It cannot bind an
installed release, qualify alpha.37, emit release verdicts, or change live policy.
Fixture observations and results are always MECHANISM evidence. Their digest
references are fixture inputs, not proof of durable filesystem capture.

## Package structure

`lib/qual_domain.ml` and its interface own fixture contract identity, complete
consumer selection, a closed experimental database policy, typed requests/facts,
pure evaluation, exact coverage and claim-owner validation. `test/` contains
Alcotest adversarial tests, canonical intent, and hand-authored AWS/local golden
instance manifests. The policy has four per-consumer checks and one per database;
local plaintext TLS exclusion is explicit and never driven by candidate flags.

## API and configuration

See `lib/qual_domain.mli`. The central signatures are:

```ocaml
val select : run -> intent -> (selection, string) result
val bind_obligations : run -> scenario -> selection -> (obligations, string) result
val plan : instance -> request
val evaluate : recorded_check -> verdict
val accept_mechanism : obligations -> request list -> verdict list -> (unit, string) result
```

The fixture contract explicitly supplies CA key/path, credential key/class and
capabilities. Fixture run binding also requires a Kubernetes principal, cluster and
endpoint, separately from product intent. Intent supplies complete workloads, explicit
consuming-container membership, dependencies, declared CA addresses and prohibited
administrative Secret addresses. No naming rule is reimplemented. The evaluator owns semantic matching;
coverage compares keys and multiplicity, then the full canonical instance
(kind, subject, workload/database binding and run/contract identity). Distinct
abstract requirement wrappers prevent interchanging CA/DML/etc payloads. There are no subprocesses,
filesystem operations, mutable globals or provider dependencies in this module.

The experimental no-master-copy check proves only absence of references to the
explicitly declared administrative Secret. It does not inspect credential field
names or prove that arbitrary copied bytes are not administrative credentials.
Unresolved reference provenance is UNKNOWN. DML delivery checks the declared
binding class, not actual PostgreSQL privileges; a separate authority/behavioral
check is required before making any live DML-authority claim. Neither predicate
is production qualification authority.

## Example usage

Bind a fixture through `Qual_domain.Fixture.bind`, decode intent through
`Fixture.intent`, select consumers, bind obligations, and plan each instance.
Record explicitly synthetic facts through `Fixture.observe`; use the matching
typed checked constructor to call `evaluate`. Reconcile both planned requests and
outcomes against obligations before accepting mechanism success. Run offline tests:

```sh
eval "$(opam env)"
dune build @internal/tooling/sol_qualification/test/runtest
```

`check_ownership` validates an explicit independent claim universe against exactly
one legacy-matrix or typed-family assignment per claim, rejecting missing,
duplicate, unknown or anonymous owners. This supports family-scoped cutover;
there is no active production ownership manifest or claim transfer in I1.

## I2: immutable mechanism evidence

`Qual_evidence` adds private, SHA-256 addressed members with file sync, atomic
no-replace hard-link publication and directory sync. Dependencies commit before
observations/verdicts. `seal` reconciles I1's expected obligation set and every
current-assessment outcome; `verify_manifest` takes independently bound obligations
and verifies the explicit assessment,
candidate/specimen binding, every dependency and the selected decisions.
Receipt validation checks dependency kinds, same-assessment provenance and exact
verdict-evidence correspondence during both commit and recovery. Persisted verdicts also retain the domain owner's full requirement identity
(run/contract, kind/subject and workload/database bindings); sealing and recovery
compare it against independently bound obligations, rather than only string keys.
The evaluator alone owns observation-to-requirement matching. It never
searches for a green result or trusts a manifest's self-declared reduced universe.
`read_capture` returns verified persisted facts for
independent typed decoding; it does not compare facts against a requirement.

Open with `open_store ~directory ~run ~secrets ()`, explicitly select an assessment
with `start_assessment ~reason ~previous ~required_captures`, capture safe projections, record evaluated
fixture verdicts with their actual observation references, then seal. A new assessment
must cite all previous assessment roots and an explicit reason. Old bytes remain
unchanged. A conflicting decision in an assessment is rejected; a later failed
assessment cannot select an old PASS. Published data are reverified/re-synced on
read/recovery; temporary/unreferenced observations do not become decisions.

Additional required captures are declared as (ID, subject) slots in the immutable
assessment definition **before** observations. `capture_required` fills a declared
slot; `seal ~captures` and manifest recovery reconcile every slot exactly once.
The verifier independently receives the same capture specification. A restart
cannot remove a slot or replace it with an unlabelled or wrong-subject observation.
A failed required capture must be recaptured after recovery before sealing, even
if every database verdict was already PASS. Optional diagnostics are not evidence
obligations: once a new process verifies the complete required graph, a lost optional
diagnostic does not invalidate it. There is no durable claim that the failed process
itself succeeded. The caller owns which captures are required; successful captures
do not define the universe. This is a fixture assessment input, not another policy
catalog or workflow-state store.

The error result contains a stage and safe diagnostic, never a fake receipt.
Persistence failure taints the current session against final success. The recorder
does not own cleanup or throw an action failure into an in-process lifecycle; the
later supervisor must perform authorized teardown independently. A fresh continuation
can use only complete, independently verified committed dependencies, not lost facts.

Register all secret inputs (including transformed values that may appear in output)
before capture. Registered strings are removed from payloads/diagnostics, sensitive
`data`, `stringData`, `env`, password/token/auth fields are suppressed, and encoded
envelopes are checked again before any temporary write. This is not an unknown-secret
detector: observers must still choose safe projections. No unredacted streaming API
exists. A one-MiB member bound and private regular-file checks constrain captures.
One Linux `flock` per attempt prevents competing writers, including handles in the
same process; the small FFI is isolated in `qual_lock_raw`/its C stub.

Tests kill child writers after temporary write, file sync, publication and directory
sync, for both observation and manifest commits. They also cover restart gaps,
explicit failed reassessment, corruption/deletion (including transitive observations),
scope mismatches, rehashed verdicts with detached or substituted observation dependencies,
writer/decision conflicts, I/O errors and secret-bearing subprocess
stdout/stderr/Kubernetes projections. All files, including temporaries, are scanned
for injected credential values. Process-kill tests do not simulate a disk/controller
that lies about `fsync`; acknowledged filesystem durability remains an assumption.

## Evidence trust boundary

The local evidence producer, qualification executable and operating-system account
are trusted. Private files and a single-writer lock protect against accidental misuse
and cooperating writers; SHA-256 and dependency validation detect incomplete writes,
corruption, conflicting records and incorrectly scoped receipts. Content addressing
does **not** authenticate the producer or prove that observed facts are truthful.
An actor able to replace the store and binding metadata can build an internally
consistent fabricated graph. This format is not an authentication protocol for
untrusted uploads. A future release consumer of remotely supplied evidence would
need a separately reviewed producer-authentication boundary; I2 adds no signatures
or remote service.

## I3: independent Kubernetes CA observation

`Qual_kubernetes` independently decodes `apps/v1` Deployment and `v1` ConfigMap
schemas and native typed lists. `Qual_database_ca.observe_all` derives every CA
request from complete obligations, captures the two reads per expected consumer,
reads the verified stored projections back, calls the domain's pure CA evaluator,
and records each verdict. Capture failures remain explicit per-consumer outcomes;
they cannot become recorded PASS. No renderer, product lifecycle or Bash assertion
is called. AWS and GCP use the same implementation with different fixture read contexts.

The current boundaries are [qual_kubernetes.mli](lib/qual_kubernetes.mli) and
[qual_database_ca.mli](lib/qual_database_ca.mli). The injected reader must perform the
structured exact namespaced query (or a native list restricted by `metadata.name`),
using its actual context. Fixture readers supply command outcomes and observed
principal/cluster/endpoint/timing. There is no installed CLI, production transport,
provider identity authenticator or live cloud read in I3; authenticating those
contexts remains a prerequisite before live adoption, not something fixture tags prove.

The evaluator checks each read's bound requirement/subject, target principal, cluster,
endpoint, temporal ordering, credential expiry and the five-minute identity freshness
window. It then checks actual workload/ConfigMap namespaces and names, nonempty
candidate-declared key, volume-to-ConfigMap linkage and every explicitly declared
consuming container. It resolves direct ConfigMap item paths, directory/file subPaths
and the most-specific covering mount, so a sidecar-only or shadowed CA does not pass.
It never derives container names, ConfigMap names or key/path conventions.

Nonzero exits (including NotFound), timeout, signal and spawn failure are UNKNOWN.
Empty/malformed output, duplicate fields, wrong object schemas and incomplete lists
are UNKNOWN. Positive absence requires a successful native exact-list result with
resource version, no continuation/remaining items and zero objects. It yields FAIL
for required CA presence. If one peer is absent and the other unreadable, the compound
claim stays UNKNOWN; both read records are preserved. A successful empty result never
establishes CA delivery. Wrong identity/context cannot establish the bound claim.

The recorder sees only the safe projection: CA key presence/nonempty flags,
object UID/resource version, relevant volume/container/mount fields and read context
or diagnostics. Certificate bytes, raw stdout, unrelated annotations and environment
values are not written. Provider error codes/diagnostics survive with I2 redaction.
Evaluation uses that persisted projection, including any redaction, rather than
unrecorded raw responses. Receipt substitution, wrong resource roles and post-capture
corruption remain detectable at the typed-evaluation or evidence boundary.

I3 deliberately supports direct ConfigMap volumes and textual `data`; projected
volumes and binary ConfigMap data are UNKNOWN. Dynamic `subPathExpr` cannot establish
the CA path. This observes declared Deployment pod-template delivery, not running Pod
filesystem contents, rollout health, certificate validity or TLS behavior. Those are
separate observations/obligations. Non-CA requirements remain in the catalog: a CA-only
set cannot seal a full successful database qualification manifest.

Offline fixtures use real API shapes independently authored from the test intent,
with AWS/GCP context records. Hostile cases cover the previous `ca.pem`/`ca.crt` defect,
namespace/consumer mismatch, absent objects, failed commands (#1497), missing and
redirected mounts, sidecar-only delivery, shadowing, projected key paths, identity
expiry, malformed/incomplete discovery, foreign receipts, persistence failure and
safe diagnostics. I4 must still compare against the existing harness fixtures;
no live predicate has been consolidated or removed in I3.

Schema semantics follow the Kubernetes documentation for
[ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) and
[ConfigMap volume mounts and key paths](https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/).

## Required follow-up qualification coverage

Actual DML authority verification remains a required future qualification obligation
before database delivery can qualify a release. Absence of an administrative Secret
reference and a delivered credential's declared DML class do not discharge it.

The shared Kubernetes observer retains [#1497](https://github.com/sol-fab/sol/issues/1497)
as an adversarial classification case: Forbidden, timeout and process-launch failures
are unreadable observations (UNKNOWN), never established absence. A failed provider
command cannot establish Absent. Absence requires a positively established authoritative
result for the bound subject; empty output or a failure exit status is insufficient.
I3 establishes these cases only with offline mechanism fixtures. Live provider
transport and observation identity must be reviewed before adoption; live harnesses
remain unchanged.

## Out of scope

Candidate product projection generation/bundling is a separate focused product change before
any release binding after offline I3/I4. Existing candidates without that projection stay unsupported;
no source-text parsing or version guessing is provided. AWS/GCP comparison and
claim-family policy/adoption changes require later reviewed work. No old predicate
is removed in I1/I2/I3: these increments prepare consolidation and do not claim it.
