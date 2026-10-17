# Promotion accepts an operator attestation as teardown absence (2026-10-17)

**Status: resolved by #1531. The reproduction below predates the fix and is
retained as the record of the gap. The gate now verifies the attached evidence
document's digest, candidate/provider/attempt/target binding, class coverage and
own `ABSENT` verdict.**

The release promotion gate (`internal/tooling/release/promotion.py`) refuses a
candidate whose provider verdict lacks `teardown.absence_verdict == "pass"`. It
never reads the `teardown.evidence` field that names the observation behind that
result, so a verdict document can assert absence without naming — let alone
carrying — any evidence. This record states the declared contract, the
implemented gate, a reproduction, and the smallest fix.

It is a source-level finding. No campaign evidence suggests a bad release was
promoted; the gap is that the last gate cannot tell an independently observed
absence from a transcribed one.

## Declared contract

`internal/tooling/release/README.md` describes the campaign verdict:

> `teardown.absence_verdict` is the independent post-destroy absence result —
> Sol's exit code and Terraform state are not absence evidence.

and the decision:

> The decision refuses when the verdict is missing, malformed, for another
> candidate, missing a required provider, or has a failing/omitted/blocked
> release-blocking row or no independent absence result …

`promotion.py`'s module docstring likewise says promotion

> refuses unless a qualification verdict refers to the candidate by identity and
> reports the required AWS and GCP rows passing, each with an independently
> observed absence verdict.

The declared contract is therefore **evidence-backed**: the result is meant to
be an observation, not an assertion.

## Implemented gate

`internal/tooling/release/promotion.py:173-176`:

```python
    teardown = entry.get("teardown")
    if not isinstance(teardown, dict) or teardown.get("absence_verdict") != "pass":
        reasons.append(
            f"the {provider} verdict has no independently observed passing absence result"
        )
```

`evidence` is not read here or anywhere else in `decide`. The providers' `rows`
have the same shape: `row.evidence` is never validated either, but a row's
`status` is the claim, so the absence result is the one field whose name
promises an observation.

## Reproduction

```console
$ python3 /tmp/promotion_repro.py
baseline decision: []
  evidence file exists? aws-inventory-verdict.txt False
  evidence file exists? gcp-inventory-verdict.txt False
teardown with no evidence field: []
teardown evidence is a number: []
```

The verdict used names `aws-inventory-verdict.txt` and
`gcp-inventory-verdict.txt`; neither file exists in the working directory. A
teardown entry with **no** `evidence` field is accepted, and so is one whose
`evidence` is the number `17`. `decide` returns `[]`, i.e. "eligible".

The reproduction calls `promotion.decide` directly, which is the same call the
promote workflow makes after verifying the candidate bundle
(`.github/workflows/promote.yml`). It is not a workflow test: it establishes
that the decision function itself cannot distinguish the cases.

## Producer side

- AWS `absence.py` writes `aws-inventory.txt`, `aws-inventory-verdict.txt` and
  `aws-inventory-verdict.json` into the evidence bundle.
- GCP emits `inventory-post.tsv` and `inventory-post.identities.tsv`; **no
  `gcp-inventory-verdict.txt` exists**, although the documented verdict example
  names it.

So today a GCP verdict following the documented field names points at an
artifact the harness never produces, and nothing notices.

## Why it matters

Promotion is the step that turns a draft into a published release. Every other
gate in that path verifies bytes: the bundle against `bundle_sha256`, the runner
image by an anonymous pull. The teardown claim is the one input that is accepted
as a string. Three concrete consequences:

1. A typo, a copy-paste from a previous candidate, or a misplaced `pass` is
   indistinguishable from an observed absence.
2. An operator cannot tell, from the verdict alone, which evidence file the
   claim refers to or whether it belongs to this campaign.
3. The GCP harness's absence verdict is not an artifact at all, so even a
   diligent operator has nothing to name.

## What this record does not claim

- It does not claim a release was promoted without evidence.
- It does not claim the campaign procedure is lax; the verdict is
  operator-authored by design, and the operator is authorized.
- It does not treat `evidence` as needing a provider read inside
  `promotion.py`. The module deliberately makes no provider call. Binding the
  claim to a recorded observation is a different thing from re-observing it.

## Smallest fix, in order of strength

**A. Digest-bound evidence member (recommended).** Require

```json
"teardown": {"absence_verdict": "pass",
             "evidence": {"path": "aws-inventory-verdict.json",
                          "sha256": "<64 hex>",
                          "provider": "aws"}}
```

and verify, at `decide` time, that the named member is present in the attached
campaign evidence, its digest matches, and its own verdict is `ABSENT`. The
promotion path already hashes an attached artifact for the bundle, so the
mechanism exists; the change is to attach the absence report (or its digest
manifest) with the verdict. This closes the gap rather than renaming it.

**B. Require a nonempty string and a sibling digest.** A weaker variant that
still lets `promotion.py` stay offline: require `evidence` to be a nonempty
string and a `sha256` beside it, and have the operator attach the named file to
the draft. Verification is then "the attached file has this digest", not "the
observation happened".

**C. Presence only.** Reject a missing or non-string `evidence`, and make the
GCP harness emit `gcp-inventory-verdict.txt`. This closes the "no evidence at
all" and "wrong type" cases and nothing else; it must be labelled an attestation
in the README, not an independent result.

C is not sufficient on its own. A is the smallest fix that matches the declared
contract.

## Producer prerequisite

The GCP inventory must emit a verdict artifact before A or C can be satisfied.
That is a sibling change to the inventory work: the post-teardown decision
already exists in `verify_absent`, and the file is a projection of the same
rows, not a second decision.

## Acceptance tests for the fix

Mutation-style, in `internal/ci/test_candidate_promotion.py`:

| Change | Required result |
|---|---|
| `teardown` has no `evidence` | refuse |
| `evidence` is not an object/string of the agreed shape | refuse |
| named path is not in the attached evidence | refuse |
| digest does not match the attached bytes | refuse |
| evidence belongs to the other provider | refuse |
| evidence's own verdict is not `ABSENT` | refuse |
| evidence is complete and matches | allow |

Each case must fail if the corresponding check is removed.

## Non-change

This record adds no runtime check. `promotion.py`, its tests and the promote
workflow are unchanged. The README gains a pointer here so the current limit is
stated where the contract is described.
