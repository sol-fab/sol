# Qualification

Qualification answers one question: **does independent observation establish the claim Sol makes?**

## Evidence model

A claim has one current home: the matrix that owns that product or provider surface. A passing
row cites the evidence that established it. Run records under `records/` are immutable evidence,
not project-management state.

Evidence classes are not interchangeable:

- **STATIC** — source/configuration inspection.
- **MECHANISM** — an executable mechanism or rendered artifact behaves as required.
- **BEHAVIORAL** — the claimed behavior was observed against the real system/provider.

A behavioral production claim can pass only with behavioral evidence. A failed, timed-out,
unauthorized, malformed, or otherwise unreadable observation is **UNKNOWN**, never absence or
success. A skipped capability is named as skipped; it is not silently promoted.

## Live-run rules

1. Qualify the released artifact a user installs, not a checkout build. `sol-under-test.sh`
   resolves and records the release identity, including the revision the bundle was built from,
   and the run builds the application under test from that revision: `candidate-binding.sh`
   refuses a workspace that is neither the candidate revision nor a descendant of it, a tree with
   modified tracked files, or a framework pin still on a moving ref, before anything is built. A stale checkout must not be able to
   substitute another revision's application while the run reports evidence for the candidate.

   The **harness** may run from the candidate revision or any descendant of it, and its own
   revision is recorded with the binding. A harness fix merged after the tag must be usable on
   that tag's window, or every fix would force a new candidate and the harness would never
   converge. What may not move is the application: it is materialized from the candidate
   revision, never from the working tree, so no working-tree state substitutes another
   revision's code. The tree must still be clean, so the harness that produced the evidence is
   a revision rather than a state.

   **Two providers' verdicts on one candidate are the same apparatus only if both records name
   the same harness revision.** If the AWS row ran on `harness@X` and the GCP row on
   `harness@Y`, "one tag, two providers" has not been met: bring the second run to the same
   revision, or cut a candidate that contains it.
2. Name the candidate, not just the prefix. `SOL_CANDIDATE` is the draft's `candidate.json`, and
   `sol-under-test.sh` verifies the installed release is that candidate — version, revision and
   pinned runner image — before anything is provisioned. Keep the recorded archive beside
   `candidate.json`: verification checks its `bundle_sha256` and compares the installed files
   with the archive, including the database setup image. An install prefix alone cannot say which
   candidate it holds, so a run told only a prefix could file another candidate's evidence under
   this one's name.
3. Give every disposable run a unique identity and evidence directory. `attempt.sh` refuses
   accidental reuse: one attempt is one candidate and one specimen, and a credential an earlier run
   left behind is never read as the current run's.
4. Exercise lifecycle through Sol. Qualification observes Sol; it must not reproduce Sol's
   Terraform/Helm resource orchestration.
5. Preserve evidence before cleanup. On any blocker while billable resources exist: capture the
   observation, run supported teardown, independently inventory the provider, and only then wait
   for human input.
6. `sol destroy` or Terraform success is not proof of absence. Provider-backed inventory
   must positively establish every relevant target-owned resource class as absent. An unreadable
   class makes the verdict UNKNOWN.
7. Durable qualification prerequisites (for example state storage or delegated DNS) are distinct
   from disposable target resources. Teardown must neither silently delete nor mistake them for
   target residue.
8. Keep credentials short-lived and target-specific. Never create long-lived cloud service-account
   keys for qualification.
9. A phase or command exit code is not itself a claim. Record the observation that satisfies or
   falsifies each row.
10. Live cloud qualification may incur cost. Do not start it without explicit operator
   authorization.

## Releases versus features — which method verifies what

**The harness qualifies releases. Direct runs verify features.**

Would-be verification of unreleased work arrives at rule 1's refusal — `candidate-binding.sh` rejects a
workspace at another revision or a tree with modified tracked files — because the harness exists to
qualify the artifact a user installs. That refusal is the harness working, not an obstacle to route
around: **do not loosen it to admit a feature branch.**

Instead, separate the two questions and the two methods:

- **A release claim** is qualified through the harness, against a released candidate, with records
  under `records/`.
- **An unreleased feature** is verified by running `sol` directly against a disposable target —
  deploy, observe the property, destroy. That evidence is real and can be recorded, but it does not
  promote a release claim, and it does not go through `candidate-binding.sh`.

State which one a verification is, so the next person does not rediscover the refusal and reach for
weakening the check.

## Typed qualification consolidation

The [accepted architecture](architecture.md) and [implementation plan](implementation-plan.md)
separate the merged offline MECHANISM core from future observer, policy and live-adoption
work. The implementation is documented in the
[qualification core package](../tooling/sol_qualification/sol_qualification.md).
Existing live entry points and matrices retain their current authority.

## Current executable surfaces

- `local/local-qual.sh` plus `rows-ocaml.sh` / `rows-ts.sh` — integrated local behavioral
  evidence. Local evidence never promotes a provider claim.
- `aws/live-qual.sh` — AWS lifecycle/application qualification; its `verify` phase runs
  `aws/absence.py`, the read-only tri-state absence inventory that decides teardown.
- `transaction.py` — the structural predicate every transaction execution path shares (the
  AWS in-cluster Job log, the AWS qualification transport, and the GCP port-forward
  scenario): an operation response must carry a typed nonempty identity and a read-back
  must contain an exact matching effect. Textual substring matching cannot establish a
  worker effect.
- `gcp/live-qual.sh` — GCP lifecycle/application qualification and provider-backed absence
  inventory.
- `record.sh` — emits a provider qualification record from the attempt ledger and an
  explicit evidence manifest using the verified `qualification-release` evaluator
  artifact. The harness owns the manifest's claim/evidence choices.
- provider matrices — claims, required evidence class, scenario, pass condition, and current
  evidence references.
- `observability/observability-diagnostic-matrix.md` — observability claims.
- `run-record-template.md` — concise record format for evidence that changes a current verdict.

The AWS and GCP cloud phases begin with the installed release's whole-target
`sol deploy <target>`, which establishes the durable installation inline (a fresh
account's setup offer is confirmed through a pty, using `script` from util-linux, which
the host must provide). The target declaration owns installation
configuration, including state storage, identities, and DNS ownership. An Unmet or
UNKNOWN installation stops the phase before disposable infrastructure is applied;
resolve the operator inputs named by Sol and continue the same attempt. Durable
installation resources remain distinct from disposable cleanup. `PLAN_ONLY=1` on
GCP skips bootstrap mutation entirely.

The offline harness tests protect fail-closed behavior and evidence accounting. They are regression
tests, not substitutes for live evidence.

## Managed Kafka evidence

AWS/GCP rows let Sol generate and persist the Kafka authority, initialize Redpanda,
and deliver consumer Secrets. They never seed broker or application Kafka credentials.
`kafka-delivery.py` observes delivery value-free. It verifies the public authority's name and
provider scope, every expected consumer's projection of the deploy-declared credential Secret
(SASL password env and broker CA volume), and the Secret's metadata in each consumer namespace.
It never reads the broker users Secret or any Secret data. The existing application transaction
remains the behavioral authentication/message-flow proof; matching Secret identity alone does
not establish broker behavior.

The separate declaration-only application-secret specimen reuses a candidate application
image and an existing application namespace. It requires a missing `SOL_API_KEY` and must
refuse before applying its workload. It never supplies that input or replaces Kafka's
generated credential with an operator input. Its real-CLI regression rejects workload
writes. Qualification requires the corresponding expected refusal, not any nonzero exit.

Remote Terraform state is streamed into a credential-free projection before capture;
`state/*.tfstate` evidence files are metadata, **not restorable Terraform state**. Provider
credentials are read only for comparisons, never logged or passed as CLI arguments.
The qualification identity needs target-scoped credential read permission for that check.

Independent AWS/GCP teardown observes the native `kafka-secret` parent separately from
Sol's destruction verdict. AWS pending deletion remains PRESENT even after its scheduled
date; GCP disabled or pending-destruction versions do not establish parent absence.
Permission failures and malformed responses are UNKNOWN. Release promotion independently
requires the class, so omitting a probe or shrinking an evidence document cannot establish
qualified teardown. Provider-fake tests exercise these decisions; only an authorized live
run establishes a provider's production claim.

## Release qualification

A Sol release is published only from an immutable candidate, and only after the
AWS and GCP verdicts for that exact candidate are attached to it. The two-stage
model, the `qualification-verdict.json` schema, and the exact operator action
are in [`internal/tooling/release/README.md`](../tooling/release/README.md).
Promotion refuses a verdict that is missing, failed, stale or for another
candidate; a successful workflow run and a Terraform exit code are still not
qualification or absence evidence.

## Records

Keep a record when a run establishes, falsifies, or materially limits a current claim. The record
must identify the release/revision, target/provider, time, operator or execution identity,
commands/observations used for each affected row, deviations, teardown result, and what the run
**does not** establish.

Do not add chronological incident narrative to this README or to run procedures. Historical
attempts remain available in Git; records still cited by a current matrix remain live evidence.
Actionable work belongs in GitHub Issues.

## Provider records and evidence archives

A live attempt's phase ledger is the attempt authority: AWS has always written
`phase-verdicts.txt`; GCP now writes the same ledger for `prepare`, `cloud`,
`app`, `destroy`, `identity` and `verify`. A record is emitted only from that
ledger plus an explicit evidence manifest:

```sh
SOL_QUALIFICATION_EVALUATOR=/path/to/qualification-release \
  internal/qualification/record.sh \
    --provider aws \
    --attempt-dir "$LOG_DIR" \
    --candidate "$SOL_CANDIDATE" \
    --auto \
    --out aws-record.json
```

`qualification-release` is the evaluator artifact built from the release tag and
attached to the draft. `--auto` invokes `evidence_manifest.py`, which derives the required claims, phases,
profile and selection from the canonical contract and maps each claim family to
the evidence its operation produced (`app-transaction.log` /
`app-transaction-{ocaml,ts}.txt`, `cloud-destroy.log` + pre-teardown identities
for AWS I8, the phase transcripts, the target declaration, provider boundary and
permission evidence). It refuses a contract family or phase with no producer
mapping rather than omitting it. `--manifest` remains available for a reviewed
explicit map.

The adapter (`emit-record`) fills in the attempt identity,
contract id/digest and evaluator identity, hashes every evidence file, checks
the exact lifecycle phase sequence and per-provider claim set, and validates the
emitted record through `load_record` before writing it.

The manifest names evidence; it does not name policy. It contains `provider`,
`harness_revision`, a typed `profile` object (`production-single-region/v1` plus
its observation IDs), `selection`, `boundary`, `permission_binding`, `phases`,
`observations` and `claims`. The evaluator refuses a record whose profile is
missing, not the contract's profile, or supported only by mechanism evidence. Each evidence entry is
`{"path": "<inside attempt dir>", "class": "mechanism"|"behavioral"}`. A claim
names observation IDs, never its own evidence. Provider-specific omissions must
be contract exceptions; a record cannot invent one.

Package each provider's attempt directory as an uncompressed-content tarball
named `aws-evidence.tar.gz` / `gcp-evidence.tar.gz` (no absolute paths, `..`, or
links) and attach it beside `aws-record.json` / `gcp-record.json`. Promotion
extracts it with traversal/link refusal and runs the verified evaluator over the
record and that directory.

Historical records are not retrofitted: alpha.44 and alpha.52 predate this
contract and cannot authorize promotion.
