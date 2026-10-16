# Qualification implementation and consolidation plan

This plan applies the [accepted architecture](architecture.md). It preserves the reviewed
migration decisions from [#1487](https://github.com/sol-fab/sol/pull/1487), whose original
prototype is not a source of product expectations and is not included in the implementation.
GitHub issues and PRs own work status; this document owns the sequence and acceptance gates.

## Implemented foundation

| Increment | Implementation | Boundary |
|---|---|---|
| I1 — [#1490](https://github.com/sol-fab/sol/pull/1490) | Shared typed domain, complete expected selection, independent obligation expansion, exact plan/outcome accounting, distinct requirement types and full instance identity | Explicitly bound offline MECHANISM fixtures; no production policy transfer |
| I2 — [#1494](https://github.com/sol-fab/sol/pull/1494) | Immutable evidence, explicit assessments, required capture slots, full verdict-identity and dependency verification, recovery and secret-safe capture | Local trusted-producer model; no executor, release binding or live lifecycle integration |
| I3 — [shared offline CA observation](../tooling/sol_qualification/lib/qual_database_ca.mli) | One independent Kubernetes schema decoder and pure CA evaluator, complete expected consumers/containers, persisted read/evaluate/verdict path, identity/freshness and hostile classification fixtures | No production transport/authentication or live assertion replacement |
| I4 — [offline comparison](database-ca-comparison.md) | Actual extracted AWS/GCP predicates and shared I3 observer against identical offline objects/failures, canonical product inputs, explicit stronger/new coverage and counterexamples | Temporary migration evidence only; stronger/new coverage is distinguished from preserved legacy behavior |

The [package contract](../tooling/sol_qualification/sol_qualification.md) and actual
[domain](../tooling/sol_qualification/lib/qual_domain.mli) /
[evidence](../tooling/sol_qualification/lib/qual_evidence.mli) interfaces describe implemented
behavior. Their hostile fixtures cover omitted consumers/requirements, duplicate and same-key
mismatched instances, unreadable facts, corrupt/detached evidence, process death at commit
boundaries, failed required capture followed by restart, conflicting assessments and secrecy.
The old prototype is retired rather than maintained alongside these owners. No live predicate
has been removed yet; implementation of an abstraction alone is not consolidation.

The product-owned projection ([#1503](https://github.com/sol-fab/sol/pull/1503)) now
shares deployment selection, is cross-tested against the complete deployment plan
and rendered/runtime inputs, and is included with its producer in candidate bundles.
The shared migration-CA observer ([#1504](https://github.com/sol-fab/sol/pull/1504))
checks an independently supplied actual Job name/UID, not a reconstructed name.
I4's migration namespace gap therefore has an offline requirement/evaluator; a
real execution-receipt source remains necessary. Volume names are internal linkage,
not an application-facing guarantee; source and delivered path remain mandatory.

The verified-candidate obligation boundary consumes the existing installed-candidate
binding owner and the product-owned schema codec. It pins assessment provenance,
retains the full declared inventory and expands the experimental catalog independently
of candidate capabilities. Durable binding capture reuses I2. Unsupported consumer
kinds or database delivery contracts fail closed before selection. It is still
MECHANISM-only: it grants neither release-verdict nor live observation authority.

## Remaining reviewable increments

| Increment | Deliverable and acceptance | Exact removal or consolidation point |
|---|---|---|
| Candidate execution and observation prerequisites | Establish a reviewed source of the actual migration execution receipt, including Job UID and observation identity. Retain snapshot freshness and full assessment binding; handle ephemeral Jobs whose absence after completion cannot retroactively establish execution. Support or explicitly refuse every consuming workload resource kind. | No inferred Job names, fixture execution receipt promoted to live evidence, or declaration mistaken for independent observation. Any new product execution-receipt authority requires review. |
| I5 — Scoped AWS adoption and family policy transfer | After comparison and a supported projected candidate, review the exact migrated claim-family boundary and verified-manifest consumption. Retain unrelated matrix owners. Adopt in an isolated harness revision outside active campaigns. | Delete the migrated AWS `app_verify_database_ca` predicate body and superseded required-check declarations. Generate the migrated family's matrix policy projection; preserve historical records. No CA-only path can promote a release with other required claims unestablished. |
| I6 — GCP adoption and remaining database requirements | Reuse the shared observer/evaluator. Compare and migrate DML delivery, migration inputs, TLS and administrative-binding checks. Implement independently evidenced actual DML authority verification as a required obligation; reference/class checks do not satisfy it. | Remove migrated predicates from both providers' `app_verify_database_delivery`. Replace duplicate `app_database_declaration` / `app_database_field` parsing when their callers use the single candidate-bound decoder. GCP CA verification is added coverage, not a fictional deletion. |
| I7 — Shared execution, capture and failure supervision | Consolidate AWS/GCP `run` and local `run_logged`, then checkpoint/finalization and handled-failure cleanup. Preserve interactive setup, direct provider diagnostics, concrete phases and independent absence verification. | Remove duplicated command/capture/timeout handling, GCP failure-bookkeeping branches, and manifest/validation code only as shared replacements assume those guarantees. No generic workflow engine. |

A suitable published candidate carrying the projection is a prerequisite for **live
adoption**, not for testing offline machinery. Existing alpha.37 is unsupported and unchanged. The family policy transfer is a prerequisite for
that family's adoption, not for migrating every unrelated qualification matrix.

## One policy owner per claim family

At each cutover, establish an independently enumerated claim universe and a machine-checked
assignment of exactly one owner to every claim. I1 has fixture-level ownership validation,
not a production ownership manifest. The adoption PR must supply and validate the real mapping.

1. Bind the typed catalog for the precise family and compare its IDs, applicability and subject
   expansion with current matrix policy. Keep unrelated claims with their existing owners.
2. Verify catalog membership against independently reviewed golden manifests; do not generate
   the golden oracle from the catalog under test.
3. Transfer the family's assertions and policy authority in one reviewed change. Generate its
   matrix policy projection and remove superseded predicates/declarations together.
4. Reject missing, duplicate or unexpected ownership. Retain evidence references as historical
   records; they are not policy definitions.

A candidate's missing capability cannot make an imposed requirement inapplicable. Applicability
and exclusions need qualification-owned rules and recorded reasons. Planned requests, captured
facts or observed resources cannot define their own required universe.

## Adoption gates

| Adversarial change | Required result |
|---|---|
| Remove a consumer, catalog member, planned requirement or outcome | Independent golden/coverage check rejects; all returned PASS values are insufficient |
| Keep a key but change kind, subject, workload/database binding, candidate or assessment | Planning, evaluation or persisted-identity verification rejects at its owning boundary |
| Forbidden, timeout, launch failure, malformed output or incomplete listing (#1497) | UNKNOWN/unreadable, never absence; blocked work is NOT_RUN only with persisted blocker evidence |
| Missing CA object/key/mount or CA available only in the migration namespace | Correctly scoped negative evidence yields FAIL; wrong identity/context yields UNKNOWN |
| Projection disagrees with actual rendered/runtime artifacts | Product cross-test fails, including mutation of either side's CA key |
| Required capture fails after all PASS verdicts, then process restarts | The persisted required slot remains missing; no seal until actual recapture |
| Detach a verdict's evidence, change its instance binding, corrupt/delete a transitive member or interrupt publication | Seal/consumer rejects; no cached or self-declared PASS |
| Concurrent writer, conflicting outcome or failed reassessment followed by an older PASS | Preserve immutable history; no overwrite or automatic green-assessment selection |
| Secret appears in stderr, authentication error, environment or Kubernetes projection | Safe capture removes registered/sensitive data before temporary writes; scan the full store |
| Action refuses as expected, or destroy returns success | Interpret the action alongside independent post-state; neither exit status establishes the claim |
| Contract binding or recorder fails after possible infrastructure mutation | Already-authorized cleanup/inventory remain reachable from independently validated scope; unknown ownership never grants permission |
| A provider inventory class is unreadable | Absence remains unestablished; retaining prerequisites cannot hide disposable residue |

Preserve AWS's current hostile CA cases, including another CA reference and a missing volume.
Nonempty candidate-declared key and actual container mount checks are deliberate strengthening;
report those differences rather than claiming identical semantics. Tests must demonstrate that
removing or weakening the replacement causes failure, not merely that the happy path passes.

## Existing owners and review boundaries

Keep `candidate-binding.sh`, `sol-under-test.sh`, `attempt.sh`, `transaction.py` and independent
AWS/GCP/local inventory as single owners until deliberately migrated. Sharing their types or
schemas does not make their own deployment output independent observation.

Consumer membership must stop depending on manually chosen `APP_UNITS`/service/namespace
lists when selection migrates. Some helpers also select images or Kafka recipients: preserve
those distinct uses until their own canonical projections replace them. Remove the duplicated
decision, not a whole helper with unrelated callers.

Each adoption PR must name the invariant established, implementation actually deleted, old
hostile failures retained, new failures detected and evidence establishing replacement trust.
Stop for review at product contract authority, release-policy authority and live qualification
behavior. No active campaign, candidate, credential store, evidence bundle or provider resource
is changed by offline implementation or this documentation.


## First AWS CA adoption: remaining concrete gates

1. Bind a suitable immutable candidate and specimen through the existing verifier;
   there is no fallback for candidates without the projection. Retain assessment,
   target, bundle/definition/specimen digests and independently established identity.
2. Review actual Kubernetes transport/authentication and migration execution-receipt
   authority. Current reads and Job execution receipts are injected offline fixtures.
   This authority review is the next boundary before replacing a live assertion.
3. Run the shared application and migration CA checks against the supported complete
   declared set. Refuse unsupported CronJob/Rollout consumers or implement and compare
   their schemas in a separate offline increment; never prune them from the universe.
4. Review the narrow CA-family policy ownership/cutover and final manifest consumer.
   CA-only success must remain separate from unestablished DML, TLS and other claims.
   DML authority remains mandatory future work, distinct from reference checking.
5. In one reviewed adoption change, remove AWS `app_verify_database_ca` and its
   superseded assertions while retaining every required application/migration CA
   guarantee. Preserve unrelated legacy claims, independent absence verification and
   historical evidence. Do not claim consolidation before that deletion actually lands.

No live harness, qualification matrix, existing release record or provider resource
is changed by these offline prerequisites. #1505's original TypeScript smoke failure
remains unresolved; a later passing run does not explain or fix it.

The existing [migration submitter](../../cli/lib/deploy/sol_cli_migration_job.ml)
owns the actual Job name and cleanup. Its returned handle currently has namespace,
name and optional ConfigMap, but no UID or durable execution receipt. The separate
[database setup runner](../../cli/lib/deploy/sol_cli_database_setup_run.ml) reads its
own setup Job UID; that is not the migration execution identity and must not be
substituted. The next authority review should address the migration submitter's
actual execution handle and independent observation while that ephemeral Job exists,
without changing cleanup merely to accommodate qualification.
