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
capabilities. Intent supplies complete workloads, dependencies and declared CA
addresses and prohibited administrative Secret addresses. No naming rule is reimplemented. The evaluator owns semantic matching;
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

## Out of scope

Durable receipts, restart recovery and secrecy enforcement belong to I2. Candidate
product projection generation/bundling is a separate focused product change before
release binding in I3. Existing candidates without that projection stay unsupported;
no source-text parsing or version guessing is provided. AWS/GCP comparison and
claim-family policy/adoption changes require later reviewed work. No old predicate
is removed in I1: this increment prepares consolidation and does not claim it.
