# Releasing Sol

A Sol release is three stages: an immutable **candidate** built from one tagged
revision, an authorized live **qualification** of that candidate, and a
**promotion** that publishes exactly the candidate the qualification refers to.
Nothing publishes from a tag, and nothing publishes from a merge.

The governing principle is that development is continuous and releasing is
intentional: **a published release must be the exact artifact that passed
qualification.** Concretely:

- Ordinary development is continuous. A pull request runs the checks its change
  needs and a merge to `main` validates the merged commit; neither creates or
  publishes a release, and neither requires the billable AWS or GCP campaign.
- A release attempt is initiated deliberately — a `v*` tag pushed for one chosen
  revision of `main`, or `workflow_dispatch` to resume an interrupted build of
  that same tag. It produces an immutable candidate with an identity, not a
  user-facing release.
- Qualification is an operator-authorized, live action against that candidate,
  and promotion is a separate, explicit gate. A failed or inconclusive candidate
  is never published, and its artifacts are never replaced in place: correcting
  source or artifacts means initiating another candidate, with its own identity.
- A rerun that passes does not retroactively explain an earlier failure. The
  earlier failure stays in the record, and the earlier candidate stays failed.

## 1. Candidate (automated)

`.github/workflows/release.yml` runs on a `v*` tag (and on `workflow_dispatch`
to resume an interrupted build). It refuses a branch and a checkout that is not
the tag's commit, then builds from that revision:

- the release binary, stamped with `SOL_RELEASE_VERSION`;
- the platform bundle;
- the version-aligned migration-runner image, published once and reused by
  digest on a resume;
- the pinned public database setup image (`share/sol/<version>/setup-image`),
  taken from the repository variable `SOL_SETUP_POSTGRES_IMAGE`. The build fails
  closed when it is unset or is not a digest reference: an installed release
  refuses an ambient `SOL_SETUP_POSTGRES_IMAGE`, so a release that cannot name
  the image it tested would otherwise fail a deploy *after* creating a database;
- the product database declaration and its internal producer (see
  [declaration preparation](../../qualification/database-contract-projection.md)); these
  declare product facts and do not grant release-qualification authority;
- `candidate.json`, the candidate identity.

It records the candidate as a **draft** GitHub release with the bundle and
`candidate.json` attached, runs `internal/ci/smoke_installed_release.sh`, and
stops. A re-run of the same tag only succeeds when the recorded candidate
matches the rebuild, so the candidate cannot move underneath a qualification run.
A published version is never rebuilt.

The migration-runner image is pushed by the candidate build because qualification
installs the candidate by the digest the bundle records; the image is immutable
and reused by digest on a resume. What promotion gates is the user-facing
release: the bundle and the release page.

A fresh AWS or GCP cluster receives no registry credential: the migration Job
names the digest-pinned image and configures no `imagePullSecrets`. Before it
records the candidate, the workflow therefore proves that the exact digest
resolves **anonymously** — against an empty Docker config, never the publisher's
authenticated session — and fails closed if it does not. `ghcr.io` container
packages are private by default, and GitHub removed the API that changed an
existing package's visibility, so making `sol-migration-runner` public is a
one-time operator action in that package's settings. All later versions of the
package inherit the visibility, so the action is not repeated per candidate.

The image's namespace is the repository owner that builds the candidate:
`release.yml` derives it from `github.repository_owner` rather than naming an
account. GitHub Container Registry packages belong to the namespace that
published them and are not moved by a repository transfer, so a transfer changes
where the next candidate publishes while already-published digests stay under
the namespace that received them. Because `candidate.json` records the exact
digest, qualification and promotion keep resolving the image a candidate
actually recorded.

`candidate.json` is the identity qualification and promotion must agree on:

```json
{
  "version": "v0.1.0-alpha.9",
  "revision": "<40-hex commit>",
  "bundle": "sol-v0.1.0-alpha.9-linux-x86_64.tar.gz",
  "bundle_sha256": "<64-hex>",
  "runner_image": "ghcr.io/<owner>/sol-migration-runner@sha256:<64-hex>"
}
```

## 2. Qualification (operator-authorized, live)

Qualification is the live AWS and GCP campaign in
[`internal/qualification/`](../../qualification/README.md). It is **not**
automated by the release workflow: it provisions billable infrastructure and
performs destructive lifecycle actions, so an operator authorizes it
explicitly. Run it against the installed candidate — extract the draft's bundle
and set `SOL_INSTALL` to its `sol-<version>` prefix. Keep the draft’s archive beside
`SOL_CANDIDATE` (`candidate.json`): the harness verifies its recorded bundle hash and
compares installed files with that archive, including `setup-image`. Then follow the provider's
procedure (`aws/aws-run-procedure.md`, `gcp/production-single-region-v1-matrix.md`).

The bundle also names the revision it was built from
(`share/sol/<version>/REVISION`), and a live run binds the application and
framework it builds to that revision: the workspace must be that revision's
unmodified tree and every `sol-fab/sol.git` pin resolves to that commit rather
than to `main`. A checkout, or a `main` that moved after the candidate was cut,
therefore cannot substitute another revision's application while the run reports
evidence bound to this candidate; a mismatch stops the run before anything is
built (`candidate-binding.sh`, sol-fab/sol#1280).

The campaign produces one verdict document, `qualification-verdict.json`, whose
`candidate` block is the candidate identity above:

```json
{
  "candidate": {
    "version": "v0.1.0-alpha.9",
    "revision": "<40-hex commit>",
    "bundle_sha256": "<64-hex>",
    "runner_image": "ghcr.io/<owner>/sol-migration-runner@sha256:<64-hex>"
  },
  "providers": {
    "aws": {
      "verdict": "pass",
      "required_rows": ["B1", "I8"],
      "rows": [
        {"id": "B1", "status": "pass", "evidence": "..."},
        {"id": "I8", "status": "pass", "evidence": "..."}
      ],
      "teardown": {
        "absence_verdict": "pass",
        "binding": {
          "provider": "aws",
          "attempt": "<attempt>",
          "target": "<target>",
          "cluster": "<cluster>",
          "scope": {
            "account": "<account>",
            "region": "<region>"
          }
        },
        "evidence": {
          "path": "aws-inventory-verdict.json",
          "sha256": "<64-hex>"
        }
      }
    },
    "gcp": {
      "verdict": "pass",
      "required_rows": ["B1"],
      "rows": [{"id": "B1", "status": "pass", "evidence": "..."}],
      "teardown": {
        "absence_verdict": "pass",
        "binding": {
          "provider": "gcp",
          "attempt": "<attempt>",
          "target": "<target>",
          "cluster": "<cluster>",
          "scope": {
            "project": "<project>",
            "region": "<region>"
          }
        },
        "evidence": {
          "path": "gcp-inventory-verdict.json",
          "sha256": "<64-hex>"
        }
      }
    }
  }
}
```

Row status is `pass`, `fail`, `blocked`, `not_run` or `excluded`. Every
`required_rows` id must appear with `status: pass`; `blocked`, `not_run` and
`excluded` rows stay in the record with a reason and never become a pass through
omission.

`pass` means the claim was demonstrated and `fail` means it was contradicted.
`blocked` is the honest answer when a claim could not be established — including
when the environment failed rather than Sol: an external infrastructure failure is
not automatically a Sol defect, and it cannot count as qualification either. A
blocked or failed row keeps the candidate unpublished until a new candidate is
qualified. `teardown.absence_verdict` is the independent post-destroy absence
result — Sol's exit code and Terraform state are not absence evidence.

### Cross-provider parity

A passing AWS record and a passing GCP record are not, by themselves, a
cross-provider production claim. Promotion currently refuses before reading any
of these assets, so no record set can authorize a release.

The release authority for schema v2 is the typed `Qual_release` owner in
`internal/tooling/sol_qualification/lib/qual_release.ml`, using the
repository-owned contract at
`internal/qualification/qualification-contract.json`. It verifies raw-byte
evidence, binds the attempt and candidate, projects phases from
`Qual_lifecycle`, evaluates the contract's claim families and typed exceptions,
and binds the verdict to the contract, both records and the evaluator binary.
See
[the qualification core documentation](../sol_qualification/sol_qualification.md#typed-release-authority-qual_release-schema-v2).

The text below describes the superseded v1 Python gate. It is retained only until
the typed evaluator is wired into promotion and the v1 `decide`/`qualification_parity`
paths are removed. It is not promotion authority: `promote.yml` refuses earlier.

The contract owns the required claims, phases and selection; the parity tool
does not maintain a second requirement list. Every provider record names the
contract **id and digest**, its candidate identity, its harness revision, its
selection, its phase results and its claims. The parity verdict is bound to the
contract digest and to a content hash of each provider record, so it cannot be
detached from the evidence that justified it. A contract change invalidates
records and verdicts created under the old digest.

```sh
python3 internal/tooling/release/qualification_parity.py \
  --contract qualification-contract.json \
  --aws aws-record.json --gcp gcp-record.json \
  --out parity-verdict.json
```

The command exits 0 only for `verdict: PASS`; a refusal is written with reasons
and exits 1. It never grants promotion authority, and it never treats a missing,
blocked, unreadable or historical claim as parity. Provider-specific omissions
are allowed only through a declared, reasoned and tested contract exception.
Promotion remains a separate decision over the candidate, the parity verdict and
the applicable release policy.

### Teardown evidence

A `teardown` claim is promotion-eligible only when it names an attached evidence
document and that document verifies. The claim carries the binding it expects:

```json
"teardown": {
  "absence_verdict": "pass",
  "binding": {
    "provider": "aws",
    "attempt": "<attempt>",
    "target": "<target>",
    "cluster": "<cluster>",
    "scope": {
      "account": "<account>",
      "region": "<region>"
    }
  },
  "evidence": {
    "path": "aws-inventory-verdict.json",
    "sha256": "<64-hex>"
  }
}
```

The named file is attached to the draft beside `qualification-verdict.json`. It
is a JSON object of this shape:

```json
{
  "schema": 1,
  "policy": "sol-teardown-v1",
  "provider": "aws",
  "candidate": {
    "version": "...",
    "revision": "<40-hex>",
    "bundle_sha256": "<64-hex>",
    "runner_image": "<image>@sha256:<64-hex>"
  },
  "attempt": "...",
  "target": "...",
  "scope": {"cluster": "...", "region": "...", "account": "..."},
  "required_classes": ["eks-cluster", "..."],
  "classes": [
    {"class": "eks-cluster", "expectation": "absent", "state": "ABSENT", "detail": "..."},
    {"class": "durable-hosted-zone", "expectation": "present", "state": "PRESENT", "detail": "..."}
  ],
  "verdict": "ABSENT"
}
```

`decide` verifies, for each provider:

- the evidence names the release teardown policy it was produced under, and that
  name matches the policy the gate loaded;
- the file is a plain name inside the downloaded evidence directory and its
  SHA-256 matches the claim;
- `provider`, `attempt`, `target`, `scope.cluster` and every provider scope
  field the policy requires (`account`/`region` for AWS, `project`/`region` for
  GCP) match the claim's binding;
- `candidate` matches `candidate.json` exactly;
- `required_classes` and `classes` name exactly the policy's class set, once
  each;
- every class's recorded `expectation` equals the policy's disposition, every
  `absent` class is `ABSENT`, every `present` class is `PRESENT`, and no class is
  `UNKNOWN`;
- the document's own `verdict` is `ABSENT`.

#### Release teardown policy

The required class set and each class's disposition come from
[`teardown-policy.v1.json`](teardown-policy.v1.json), not from the evidence
document. The policy is a reviewed release artefact:

- `sol-teardown-v1` declares 20 AWS disposable classes plus the
  `durable-hosted-zone` prerequisite, and 19 GCP disposable classes, 3 scope
  classes and 2 durable prerequisites.
- It declares the provider scope fields the claim must bind: `account` and
  `region` for AWS, `project` and `region` for GCP.
- The gate refuses missing, extra or reclassified classes, and an evidence
  `policy` name it does not load. A self-consistent document that declares a
  smaller universe than the policy is therefore not promotion-eligible.

The producer inventories (`RESIDUE_CLASSES` in AWS `absence.py`,
`INVENTORY_CLASSES` in GCP `live-qual.sh`) remain the observation authority. The
policy is the release authority; `internal/ci/test_teardown_policy.py` is the
drift guard that fails when either producer's universe changes without a policy
update. The gate itself never imports a producer.

Independence of the observing identity is established by the campaign procedure
(the harness records the caller), not re-proven by `decide`. The gate is offline
and makes no provider read. The digest is an integrity check, not proof that the
producer is authentic; signatures and remote evidence storage are deliberately
out of scope.

A missing, malformed, unbound, incomplete or altered evidence file keeps the
candidate a draft. The original gap, its reproduction and the decision are
recorded in
[`internal/qualification/records/2026-10-17-promotion-teardown-evidence.md`](../../qualification/records/2026-10-17-promotion-teardown-evidence.md).

## 3. Promotion (automated gate, operator-triggered)

> **Temporarily disabled.** The merged v1 parity gate checked internally
> consistent records, not evidence-backed parity. Promotion refuses until the
> typed schema v2 gate lands (#1738); no v1 record set may authorize a release.

`.github/workflows/promote.yml` never builds. It downloads the draft candidate,
the qualification verdict, the canonical qualification contract, the two provider
records and the parity verdict, then establishes that every Sol-owned artifact
the candidate identifies still exists exactly as recorded:

- `promotion.py verify` hashes the attached bundle against the candidate's
  `bundle_sha256`;
- `verify_runner_image.sh` proves a fresh cluster can pull the exact
  `runner_image` digest anonymously in GHCR (read-only — no rebuild, republish
  or tag substitution);
- `promotion.py decide-parity` checks the qualification verdict and recomputes
  the cross-provider parity verdict from the contract and the exact provider
  records. The attached parity verdict is accepted only when it matches that
  recomputation.

Only then does it flip the draft to published with `gh release edit
--draft=false`. The published bundle is byte-for-byte the candidate that was
qualified.

The decision refuses when the verdict is missing, malformed, for another
candidate, missing a required provider, has a failing/omitted/blocked
release-blocking row, or carries a teardown claim whose attached evidence is
missing, unbound, under an unknown policy, incomplete against the release
policy, reclassified, or altered. It also refuses when the contract, provider
records or parity verdict are missing or unusable, when the records do not bind
the contract digest/candidate/harness revision/selection, when a required claim
or phase is missing, or when the recorded parity verdict differs from the
recomputation. Promotion also refuses when the recorded bundle is absent or
changed, or when a fresh cluster can no longer pull the recorded runner
anonymously. Its mechanics are pinned by
`internal/ci/test_candidate_promotion.py`,
`internal/ci/test_parity_promotion.py`, `internal/ci/test_teardown_policy.py`
and `internal/ci/test_runner_image_resolution.sh`; those tests establish the
mechanics only and are not qualification evidence.

### Exact operator action

0. Initiate the attempt: push the `v*` tag for the chosen `main` revision, or run
   **Release** with `version=<tag>` to resume an interrupted build of it. The
   workflow refuses a tag that is not the checkout's commit, records the candidate
   as a draft, and never publishes.
1. Run the authorized AWS and GCP campaign against the installed candidate and
   write the verdict's `candidate` block from the draft's `candidate.json`. The
   campaign writes the structured teardown documents
   `aws-inventory-verdict.json` and `gcp-inventory-verdict.json`, the provider
   records `aws-record.json` and `gcp-record.json`, and the parity verdict. The
   teardown `binding` must name the provider scope fields in the policy (`account`
   and `region` for AWS, `project` and `region` for GCP); the evidence document
   records the same values and names `sol-teardown-v1`.
2. Record each document's digest in the verdict and attach the verdict, the
   contract, the provider records, the parity verdict and both teardown documents
   to the draft candidate:
   `gh release upload <version> qualification-verdict.json qualification-contract.json aws-record.json gcp-record.json parity-verdict.json aws-inventory-verdict.json gcp-inventory-verdict.json`.
   Use `sha256sum <file>` for the digest; the digest is over the exact bytes
   attached, so compute it after the document is final.
3. Run **Promote release** with `version=<version>`.

Until step 3, the version is a draft and nothing a user installs can name it.

### When it fails

A candidate that fails or is blocked is not published and is not repaired in
place. Fix the product or the qualification defect on `main`, then initiate a new
candidate with a new version and run the campaign against that: the earlier
candidate keeps its identity, its verdict and its failure, and nothing is
rebuilt, re-tagged or replaced under an identity a qualification already refers
to. Correcting the verdict of an earlier candidate is never the fix.
