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
procedure (`aws/aws-run-procedure.md`, `gcp/gcp-production-single-region-v1-matrix.md`).

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
      "teardown": {"absence_verdict": "pass", "evidence": "aws-inventory-verdict.txt"}
    },
    "gcp": {
      "verdict": "pass",
      "required_rows": ["B1"],
      "rows": [{"id": "B1", "status": "pass", "evidence": "..."}],
      "teardown": {"absence_verdict": "pass", "evidence": "gcp-inventory-verdict.txt"}
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

## 3. Promotion (automated gate, operator-triggered)

`.github/workflows/promote.yml` never builds. It downloads the draft candidate
and the verdict attached to it, then, before deciding, establishes that every
Sol-owned artifact the candidate identifies still exists exactly as recorded:

- `promotion.py verify` hashes the attached bundle against the candidate's
  `bundle_sha256`;
- `verify_runner_image.sh` proves a fresh cluster can pull the exact
  `runner_image` digest anonymously in GHCR (read-only — no rebuild, republish
  or tag substitution);
- `promotion.py decide` checks the verdict.

Only then does it flip the draft to published with `gh release edit
--draft=false`. The published bundle is byte-for-byte the candidate that was
qualified.

The decision refuses when the verdict is missing, malformed, for another
candidate, missing a required provider, or has a failing/omitted/blocked
release-blocking row or no independent absence result, and promotion refuses
when the recorded bundle is absent or changed, or when a fresh cluster can no
longer pull the recorded runner anonymously. Its mechanics are
pinned by `internal/ci/test_candidate_promotion.py` and
`internal/ci/test_runner_image_resolution.sh`; those tests establish the
mechanics only and are not qualification evidence.

### Exact operator action

0. Initiate the attempt: push the `v*` tag for the chosen `main` revision, or run
   **Release** with `version=<tag>` to resume an interrupted build of it. The
   workflow refuses a tag that is not the checkout's commit, records the candidate
   as a draft, and never publishes.
1. Run the authorized AWS and GCP campaign against the installed candidate and
   write the verdict's `candidate` block from the draft's `candidate.json`.
2. Attach the verdict to the draft candidate:
   `gh release upload <version> qualification-verdict.json`.
3. Run **Promote release** with `version=<version>`.

Until step 3, the version is a draft and nothing a user installs can name it.

### When it fails

A candidate that fails or is blocked is not published and is not repaired in
place. Fix the product or the qualification defect on `main`, then initiate a new
candidate with a new version and run the campaign against that: the earlier
candidate keeps its identity, its verdict and its failure, and nothing is
rebuilt, re-tagged or replaced under an identity a qualification already refers
to. Correcting the verdict of an earlier candidate is never the fix.
