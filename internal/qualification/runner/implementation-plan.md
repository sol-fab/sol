# Qualification implementation and consolidation plan

This follows the [ownership proposal](architecture-proposal.md). It is a focused
implementation sequence, not another architecture exercise or permission to change
the active AWS campaign. PR #1487 remains draft. This revision implements none of
these mechanisms; the current prototype retains its documented `ca.crt` defect.

## Ordered changes and removal points

| Change | Implementation and validation | Exact consolidation/removal point |
|---|---|---|
| 1. Candidate contract inputs and CA-key correction | Generate the product-owned declaration deterministically from canonical typed definitions; bind supported schema/revision/bundle/declaration digests. Cross-check real rendered ConfigMap and workload/runtime inputs. Correct the prototype to use that authority and add actual `ca.pem` fixtures before it serves as an oracle. | Replace the prototype's hard-coded CA key and the adapter/fixture assumption that repeated it. Do not add a second maintained declaration table or old-release compatibility registry. Existing candidate verification stays with `sol-under-test.sh` / `candidate-binding.sh`. |
| 2. Shared domain and obligations | Implement pending/recorded/capture-failed outcomes, typed request/check variants, complete selection, catalog expansion and exact-key plan/outcome reconciliation. Keep runtime catalog experimental until the policy cutover below; hand-authored golden instance manifests independently check its membership/expansion. | Replace the prototype's implicit "all generated claims passed" acceptance and arbitrary `--consumer` lists as universal coverage proof. A manual list may remain a clearly partial diagnostic input. No production policy ownership moves yet. |
| 3. Durable evidence recorder | Implement synced immutable members, no-replace publication, verified manifest seal, continuation/conflict rules and failure injection at each write/sync boundary. Require typed observation receipts and decision persistence; keep authorized cleanup usable after storage failure. | Replace `command.ml`'s direct JSON/output writes and `main.ml`'s unsealed per-invocation report construction with one evidence owner. Reuse existing process mechanics; do not create another executor implementation merely for cleanup. |
| 4. Shared Kubernetes CA capability and pure evaluator | Implement CA projections, per-observation identity/endpoint proof, evaluator-only requirement/receipt matching, and the CA requirement. Run the current AWS `app_verify_database_ca` and the new path over the same hostile offline fixtures, without calling a live cluster. Document stricter key/mount checks as intentional differences. | Remove the prototype's embedded observer/predicate/reporting duplication in `main.ml` / `database_ca.ml` when the shared path takes over. Do not yet change either live harness. A CA-only mechanism cannot promote a release whose other applicable obligations remain unsupported. |
| 5. Policy cutover and AWS adoption, after campaign isolation | In a focused reviewed cutover, bind all current policy rows/scopes, make the catalog authoritative, and generate matrix policy projections. Require equivalence/mutation evidence and verified-seal consumption through the existing release-verdict path before using this apparatus for release claims. Adopt the shared CA check in an isolated harness revision after the active campaign. | Delete the Bash CA predicate body in AWS `app_verify_database_ca`, replacing its call with the shared contract result. Remove superseded provider required-check lists and manually maintained matrix policy columns at policy cutover, rather than leaving two authoritative catalogs. Preserve historical records. |
| 6. GCP and full database delivery | Use the same Kubernetes capability/evaluator with GCP's bound context. Extend closed requirements to DML, migration input and no-master-copy, plus separately required TLS probes, with exact obligation coverage and old/new hostile comparisons. | GCP currently has no equivalent CA predicate: adding the shared CA claim is an explicit coverage improvement, not a fictional deletion. As each non-CA check moves, delete its duplicated body from both providers' `app_verify_database_delivery`. Replace `app_database_declaration` / `app_database_field` parsing with the single candidate-bound decoder once all relevant callers move. |
| 7. Shared execution/evidence/failure accounting | Migrate AWS/GCP `run` and local `run_logged` to one execution/capture owner, preserving interactive setup and direct provider diagnostics. Integrate checkpoint/finalization and handled-failure teardown while retaining concrete provider phases. Keep independent absence adapters. | Remove duplicated command-recording/timeout logic, GCP's repeated `capture_app_evidence; freeze_evidence; finalise_bundle` failure branches, and manifest/validation implementations (`bundle_manifest`, `verify_bundle`, local `phase_capture`) as their shared replacements take over. Retain thin phase adapters only. |

Selection helper removal is scoped to the question it answers. Database consumer
selection must stop deriving membership from `APP_UNITS`, `app_services`,
`app_namespaces` or `app_unit_addresses`. Some helpers also select images or Kafka
secret recipients; those distinct uses remain until their own canonical projections
replace them, with comments naming the separate question. Do not delete a whole
helper and accidentally change unrelated phase behavior.

`attempt.sh`, candidate binding, `transaction.py`, and the independent AWS/GCP/local
inventory mechanisms remain their current single owners until deliberately migrated.
Do not reimplement them alongside a new validator. A temporary old/new fixture
comparison is removed when its replacement becomes authoritative; it is not a
permanent production fallback or a second oracle.

## Acceptance criteria for the first shared-domain/CA implementation

These are tests to implement, not tests this documentation revision has run.

| Mutation or injected failure | Required result |
|---|---|
| Drop an expected consumer or use only observed workloads as selection | Independent expected-membership fixture or selection/outcome reconciliation fails; no universal PASS |
| Drop one planned CA, DML or TLS instance, or every TLS instance | Exact-key comparison against the unchanged bound obligation set fails before execution |
| Remove a catalog rule or weaken applicability | Reviewed hand-authored golden instance manifest disagrees; test fails without loading that golden as runtime policy |
| Duplicate/add an unexpected requirement or omit an outcome | Plan/outcome coverage fails; all returned PASS values cannot hide the discrepancy |
| Substitute another consumer/run/candidate/assessment's CA receipt | Pure evaluator rejects matching as UNKNOWN; recorder/coordinator contain no copy of that predicate |
| Return wrong namespace/endpoint or stale identity proof | Evaluator cannot establish the claim; requested role names or initial-run identity checks do not suffice |
| Return Forbidden, timeout, incomplete listing or malformed projection | Recorded UNKNOWN, never inferred absence; dependent undispatched checks are recorded NOT_RUN if storage permits |
| Render/project the wrong CA key in either side of the contract cross-test | Agreement test fails; an actual correctly scoped observation missing the candidate-declared key yields FAIL |
| Candidate omits a capability required by qualification policy | Required instances remain present and unacceptable, rather than silently excluded |
| Product projection differs across identical builds or from runtime/renderer artifacts | Determinism/consistency checks fail; candidate declaration alone does not prove implementation behavior |
| Fail persistence after a successful observation or after evaluating PASS | Capture-failed/unrecorded outcome, no fabricated receipt or conformant successful seal; cleanup still attempted under validated authority |
| Kill at each member/manifest write, file sync, publication and directory sync boundary | Continuation recognizes only fully verified committed dependencies; temporaries and partial manifests never qualify |
| Corrupt/delete a member after its receipt, or corrupt a dependency referenced by a sealed manifest | Finalization and manifest consumer reject integrity; no stale cached PASS |
| Concurrent writer or duplicate/conflicting outcomes in one assessment | Refuse writer access or fail coverage; no overwrite/last-write-wins acceptance |
| Append a reassessment after a failure | Preserve prior hashes/outcomes; explicit new assessment, reason and supersession, with required fresh reads; no automatic retry to green |
| Expected refusal with a nonzero action exit | A dedicated refusal requirement evaluates the action record plus independently observed post-state; exit code alone neither passes nor fails qualification |
| Deploy fails after possible mutation, database contract binding fails on continuation, or recorder is unwritable | Already authorized cleanup and independent inventory remain reachable from separately validated attempt ownership/identity; unknown ownership never authorizes destroy |
| One required provider inventory class is unreadable | Absence stays unestablished even after successful `sol destroy` |

The first slice must also preserve the current AWS hostile CA cases: a ConfigMap
only in the migration namespace, a missing consumer-namespace object, an unreadable
object, one workload pointing at another CA, and a workload missing its `db-ca`
volume. Nonempty `ca.pem` and actual consuming-container mount checks deliberately
strengthen existence/volume-reference-only assertions. Require those differences
to be explicit in comparison results, not silently relabelled fixture equivalence.

For each adoption PR, report the invalid states restricted, implementation deleted,
old failure cases retained, newly detected cases, and comparison/integrity evidence.
An abstraction is not migrated while equivalent production predicates remain in
both Bash and OCaml. Do not remove tests without explaining why; CI green after
lost hostile coverage is not evidence of correctness.

Live candidate qualification remains separately authorized under the existing
qualification/release rules. No active campaign, installed candidate, credentials,
evidence bundle or provider resources are altered by implementing and checking the
offline slice in its worktree.
