# Harness merge: the hook interface and its acceptance criteria

Status: **specification for review. No code.** Nothing here is implemented, and no
branch against harness files exists until the Kafka observation fix lands.

This document says what the provider-neutral qualification core owns, what a
provider hook owns, and how a reviewer tells whether an implementation kept the
boundary. The frozen harness inventory is the authority for *which* concerns move;
this document is the authority for *how* they move.

## Why this shape

Measured on `aws/live-qual.sh` and `gcp/live-qual.sh` at `1a9d83d6`:

| | count |
| --- | --- |
| top-level functions in the AWS suite (`^[a-z_]+()`) | 66 |
| top-level functions in the GCP suite | 127 |
| names present in both | 30 |
| of those, byte-identical bodies | **7** |
| of those, divergent bodies | **23** |
| names present in only one suite | 36 / 97 |

The seven identical functions (`app_class_credential_name`,
`app_database_field`, `app_kafka_credential_name`, `cloud_mutated`,
`environment_reconciled`, `on_terminate`, `pending_artifacts_refused`) are the part
that is already a decision rather than a provider's habit. The twenty-three
divergent ones with the same name are the merge surface: two files answering the
same question their own way (`destroy_kube_destination`, `app_namespaces`,
`ca_request`, the four `phase_*` functions). Same name, different answers, is the
conflation shape that produces the next defect, because a reader cannot tell
whether the difference is provider-required or accidental.

Not every divergence is drift. Of the 23, **16 are semantic drift**, 5 are
cosmetic, and 2 are legitimate provider differences that become hooks
(`cold_start_boundary`, whose observing principal differs because only one
provider splits cluster-access from deploy; and `disposable_state_present`, which
is one provider API call either way). The classification is recorded per function
in the merge work, and the count is expected to fall as phases merge.

## The interface

A phase is provider-neutral. It may not name a provider. It calls hooks:

```
phase_<name>()                  shared; owns ordering, verdicts, ledger writes
  hook_<concern>_<step>()       provider-supplied; owns the provider's mechanics
```

A hook declaration is a contract, not a suggestion:

| part | rule |
| --- | --- |
| name | `hook_<concern>_<step>`, `<concern>` from the resource/decision table below |
| inputs | only what the phase passes; no hook reads a phase's local variable or a provider global |
| outputs | one classified result on stdout, or an evidence file it names; never a raw provider document on stdout |
| evidence | writes what it read to the evidence directory; prints a verdict and the basename |
| failure | non-zero; the phase decides whether that is a refusal or a degradation, and records which |
| absence | a hook cannot answer `unknown` and let the phase treat it as `absent` |

A provider implements every hook its resources require. The table below is the
completeness authority: a resource class a provider creates is either in a hook's
scope or explicitly classified out of scope, with the reason.

## Row to hook map

The inventory's `merge-project-item` rows are the concerns below. Where this
document and the inventory disagree on a row's identifier, the inventory wins and
this table is wrong — the mapping is by concern, and the frozen table was not
reproducible in-tree when this was written.

| concern | shared phase owns | hook owns | notes |
| --- | --- | --- | --- |
| attempt lifecycle | `attempt_begin`, ledger, verdicts, continuity | nothing | shared today in neither suite; new |
| prepare | ordering, what counts as prepared | candidate build, image publication, registry login | the two suites' `phase_prepare` diverge |
| cloud | ordering, pre/post inventory, what a phase verdict means | substrate apply, kubeconfig/identity capture, node readiness | `destroy_kube_destination` divergence sits here |
| transport | window semantics, surface contract | principal creation, access mapping, window open/close | #1616 / #1626 own the AWS side; GCP has no qualifier principal |
| app | ordering, contract changes, migration gate | workflow invocation, credential delivery | `app_verify_*_delivery` diverge by provider credential mechanism |
| database CA | the CA predicate and its verdicts | where the CA is read from | shared predicate, divergent read |
| Kafka delivery | the delivery contract and its refusal classes | broker authority and credential mechanism | the pending Kafka fix lands here |
| cold start | what "positively absent" means | namespace/identity probes | `cold_start_boundary` and `cold_start_namespaces` diverge |
| destroy | lifecycle ordering, release gate, absence claim | substrate destroy, workload release | `--accept-unreleased` is a shared decision, not a hook |
| teardown inventory | the class list contract and the tri-state | provider reads per class | includes the access-entry class once #1627(a) lands |
| records | record shape, promotion eligibility | evidence file locations | shared today in neither suite |

## Acceptance criteria

Each is a review gate. A change that misses one is not a partial merge; it is a
change that does not meet the interface.

1. **Shared test shell = helpers and semantics only.** The shared shell carries the
   assertion helpers and their semantics. Provider test cases stay in the
   per-provider file. An `if PROVIDER ==` in the shared file is a review reject,
   and so is a shared helper that takes a provider name to decide what to assert.
2. **No provider name in a phase file.** Phases call hooks; hooks own provider
   logic. A provider name, ARN shape, or endpoint pattern in a phase file is a
   review reject.
3. **Hooks-table completeness test.** Every resource class a provider creates is
   in the table or explicitly classified out of scope with a reason. An
   unclassified class fails the test. Fail-closed: a class the table cannot place
   is a failure, never a skip. This is #1627(a) — an EKS access entry carrying
   `AmazonEKSClusterAdminPolicy` would be caught here.
**Named limit of the hooks guard (G3).** The completeness and call-site checks prove that every declared hook is implemented and called. They prove nothing about *order*. An ordering rule -- freeze the evidence bundle before a heavy read, verify a boundary after the apply -- is carried by `internal/qualification/mutation-manifest.txt`, and an ordering assertion with no manifest entry is untested rather than implicitly covered by the guard. A green hooks guard is not ordering evidence.

4. **Per-shared-phase mutation proof, red test first.** For each merged phase, the
   proof is a mutation of the phase that must fail a specific assertion, and the
   test must be written before the phase is. A phase merged without a mutation
   that fails is unproven. Record the failing assertion, not just the count.
5. **Trace discipline in `common.sh`.** Any name the harness reads that the
   candidate declares (target, cluster, namespace, role) is read from the
   candidate's declaration, not reconstructed by the harness. A harness-side rule
   that reproduces a declaration is a defect even when it agrees today.
6. **The tail is a whitelist, not `tail -n 40`.** A phase's console output is a
   set of harness-emitted lines with recognised prefixes; the tail prints from that
   set, never from raw captured provider output. Provider text is written to
   evidence and referenced by basename. This is #1629's class made structurally
   impossible rather than fixed once per call site.
7. **Typed core stays deferred**, and states its triggers.

## Non-goals, and what would reopen them

Not in this merge: a typed core, a plugin ABI, a state machine, provider capability
tiers, or a second qualification framework. Each would have to be justified by a
failure the hook interface cannot express.

Reopen the typed-core question only on an observable trigger, named in advance:

- a hook whose inputs or outputs cannot be expressed as text plus an evidence file
  without a parsing rule the harness would have to reproduce (criterion 5's shape);
- two providers needing the same hook with genuinely incompatible contracts, such
  that the shared phase must know which one it has;
- a shared phase whose failure classification cannot be derived from the hook's
  exit status and its printed verdict.

Absent one of those, the typed core is deferred, and "we are adding a second
provider" is explicitly not a trigger — a hook table with a completeness test is
the answer to that.

## Sequencing

The merge stays gated behind the Kafka observation fix. The order that keeps the
proofs honest:

1. Kafka fix lands and the staging attempt produces a real `error_class`.
2. `common.sh` gains criteria 5 and 6, because every later phase inherits them.
3. Phases merge one at a time, each with its mutation proof (criterion 4).
4. The hooks-table completeness test (criterion 3) lands with the first merged
   phase that creates resources, not after the last.

Merging all phases and then writing the table is the failure mode this ordering
exists to prevent: at that point the table describes what was built rather than
deciding what may be built.
