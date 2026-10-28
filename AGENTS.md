# Sol maintainer context

Sol is a pre-alpha software factory for backend systems. The `sol` CLI and platform
are language-neutral; OCaml and TypeScript applications target the same application
and deployment contract.

## Repository map

- `cli/` — the `sol` CLI and typed deployment/lifecycle implementation.
- `framework/` — first-party application framework packages.
- `platform/` — Terraform, Helm values, templates, and other assets driven by Sol.
- `examples/` — runnable reference applications.
- `docs/` — user guidance, reference, and durable architecture.
- `internal/ci/` — executable repository/product guards.
- `internal/qualification/` — live behavioral claims, procedures, and evidence.
- `internal/fixtures/` — test fixtures.

Read the authority nearest the thing you are changing. Do not copy subsystem rules
into this file.

## Development posture

Sol is pre-alpha. Backwards compatibility is not a goal. There are no compatibility
guarantees for current APIs or repository structure: prefer the correct design over
compatibility shims, deprecated aliases, or version gates. Update callers and tests in the
same change.

When replacing a mechanism, remove the old path rather than retaining it as a fallback.
A second attribution, parsing, recovery, or lifecycle path is justified only by a distinct,
currently supported requirement, never by historical behavior. If the old path does serve
such a requirement, state that requirement instead of calling it compatibility.

GitHub Issues and pull requests are the work-state authority. Make every change in a Git
worktree, never by switching the primary checkout off `main`; branch and worktree names
carry no Sol-specific semantics. Open focused PRs, rely on required CI, request review
proportional to risk, and squash-merge. Do not recreate repository-local workflow state
with labels, bots, branch conventions, or custom tooling.

Independent work proceeds concurrently from current `main` in separate worktrees. Do not
wait for an open PR to merge merely because later work depends on it.
For a mechanical dependency, branch the dependent PR from the prerequisite PR's head and
open it against that branch, so its diff contains only its own changes. State the stack
relationship in the PR description. Once the parent merges, retarget and rebase or refresh
the child against `main`, then continue the stack. Use stacking only when the parent is
already the chosen implementation basis; resolve semantic or product-boundary decisions
before building on them. Keep each PR focused and reviewable.

When a PR is complete, validated, and intended to land on its correct base, use auto-merge
or the merge queue where the repository is configured for them, rather than repeatedly
polling CI or waiting synchronously. A stacked child is not ready to land on `main` until
its parent merges and the child is retargeted. Required CI, reviews, branch protection, and
conversation resolution remain authoritative; never bypass them. Resolve failing checks,
conflicts, review findings, and changed parents while independent or downstream work
continues.

**External operations:** Do not block on long-running external operations such as GitHub
Actions CI. After pushing a PR, check its status once and report any pending checks or
required reviews, then return control. Do not poll repeatedly or leave background polling
processes running unless explicitly requested. For asynchronous operations, distinguish
submitted work from completed work.

## Engineering quality and prioritization

Sol's primary engineering objective is a reliable, secure, maintainable lifecycle: provision
infrastructure, deploy healthy workloads, operate and update them, and destroy all Sol-owned
resources with independently verified absence on AWS and GCP.

- Prioritize concrete correctness gaps and obstacles to end-to-end qualification.
- Prefer one authoritative representation of each decision. Avoid independent reconstruction
  across planning, execution, rollback, and qualification.
- Keep modules cohesive, responsibilities explicit, and control flow understandable.
- Favor straightforward implementations over speculative abstractions or unnecessary
  compatibility machinery.
- Preserve strong error handling and fail-closed security boundaries.
- Tests must establish the behavior they claim. A passing test that cannot detect the regression
  is not evidence.
- Leave surrounding code simpler when practical, but avoid unrelated refactoring.
- Do not lower engineering standards to satisfy a qualification harness. Fix the underlying
  product problem.

A successful qualification run is evidence of correctness, not a substitute for good engineering.

## Build and validation

Set up the pinned support packages and dependencies as described in the README, then:

```sh
eval "$(opam env)"
dune build
```

The `*-eio` packages are pinned to the exact commits in `support-refs.txt`. A build
failure inside a framework package (`Https_eio`, `Kafka_eio`, ...) on a fresh checkout is
almost always a stale support-package pin, not a code defect: run
`bash internal/ci/pin-support-packages.sh` and rebuild before investigating further. The
fast checks detect drift and re-pin automatically; set `SOL_SKIP_SUPPORT_PIN=1` to be told
what to run instead.

Run the smallest relevant tests while developing. Before proposing a change, run the
cheap repository checks:

```sh
bash internal/ci/run_fast_checks.sh
```

Required GitHub CI is authoritative for merge. Live cloud qualification is separate from
ordinary development; follow `internal/qualification/README.md` when a claim requires it.
Releases are the deliberate path in `internal/tooling/release/README.md`: a merge never
creates or publishes one, and a published release is the exact artifact that passed
qualification.

A passing rerun does not explain an earlier failure. Preserve the original failure and its
evidence, then find the cause; a rerun that happens to pass is not a diagnosis. Report an
unresolved cause as unresolved rather than as a flake, and fix what you do find at its owning
boundary. Investigate through source, documented contracts and provider documentation before
adding defensive machinery or repeating a live test that costs money, and treat "the implementation
is correct and needs no change" as a valid conclusion. Investigate proportionately: an unexplained
failure is worth recording and carrying as stated risk, not necessarily an open-ended hunt or a
blocker for unrelated work.

### Patterns that have cost us twice

Short rules, each paid for by a specific defect. They are not preferences; each one is the
lesson of an incident whose evidence is in the linked issue.

1. **Green CI after a commit that removed a test is a warning, not a pass.** If a diff removes a
   `let%test` or a test file, the commit message must say why. A splice, a rebase or a bad edit
   that drops a test is a defect on its own, and CI cannot tell that from a passing change
   (#1455: the hostile-resource test vanished in a splice and `@ci-unit` stayed green because it
   was simply gone).
2. **One decision, one place.** Two call sites answering the same question either share one
   implementation or carry a comment saying which question each answers. A second resolve without
   a comment is the shape that becomes the next conflation (#1424: findings 2, 6, 12).
3. **When a fix removes a conflation between two concepts, look for it one level up and one level
   down before calling the fix complete.** The same pairing tends to exist in the caller and in
   the callee (#1424: the fix for target-vs-namespace contained target-vs-namespace; also
   historical/current in #1422, plan/apply in #1425, writer/reader in the row assertion).
4. **A test named "is the interface" must assert every member of the interface, or the name is a
   lie.** Check the sentinel, the field set, the shape — everything the record claims is the
   contract (#1424: finding 3 was a partial interface test, fixed and then fixed again).
5. **Never reimplement a naming or formatting rule in the reader.** If the reader needs a name,
   the writer declares it; if the declaration is unstable, fix the declaration. A reader that
   reproduces the rule is correct only by coincidence (#1424: the rows derived the namespace
   before the deploy declared it).
6. **A `Result` is not a fallback.** Do not substitute a default for an `Error` unless the error is
   provably unreachable, and say so in code where it is, not in your head (#1424: finding 11
   swallowed a real `make_namespace` failure behind `Error _ -> workspace`).

## Naming conventions

Naming is artifact-specific; do not force one case across every artifact.

- **Sol identities** — service keys, unit IDs, OCaml modules/files, and Sol-authored
  JSON/YAML fields use `snake_case`. A service is declared once in `sol.yml`; callers
  and generated bindings reference that declaration.
- **Provider resources** — Kubernetes and Cloud Run resource names use `kebab-case`.
  They are derived from the declared Sol service name through
  `Sol_cli_kubernetes_name`; never declare a second provider name. A normalized-name
  collision must refuse before mutation.
- **CLI** — commands and flags use `kebab-case` (`--jwks-uri`, `cloud-run`). Environment
  variables use `SCREAMING_SNAKE_CASE`.
- **OCaml files** — `snake_case` `.ml`/`.mli` names. Hyphens and kebab-case are not
  valid OCaml module filenames.
- **Markdown** — new documentation filenames use `kebab-case`; standard ecosystem names
  such as `README.md`, `AGENTS.md`, and `SKILL.md` are exceptions. Existing legacy
  documentation names are migrated deliberately, not copied into new files.

New code and docs should follow these rules. The static naming check enforces the
filenames that can be checked mechanically; service-key conventions remain a review
rule until a full declaration migration is justified.

## Durable invariants

- Sol owns only its declared contract boundary. Users may integrate arbitrary
  infrastructure against that boundary; Sol neither plans nor manages it.
- Destructive lifecycle decisions fail closed on unknown state. Absence must be
  positively established, and live qualification independently verifies absence.
- The declarative Sol contract is canonical for application/deployment intent; generated
  language bindings and artifacts are projections, not competing authorities.
- Production Kafka uses authenticated, encrypted transport; local development may use
  deliberate plaintext configuration. Do not infer that local and production settings
  must be identical.
- Generated artifacts are outputs. Change their typed/source owner rather than patching
  generated YAML or other projections as the primary implementation.
- Preserve OCaml/TypeScript behavioral contract parity without requiring implementation
  parity.
- Security ambiguity, destructive live actions, and architectural decisions require
  explicit operator judgment. Ordinary implementation work should proceed autonomously.

## Documentation ownership

- `README.md` — product entry point and source-build path.
- `docs/reference/` — current application/CLI contract.
- `docs/guides/` — task-oriented user guidance.
- `docs/architecture/` — current architecture and durable ADRs.
- package-local docs — package-specific public/maintainer contracts.
- `internal/qualification/` — qualification claims, procedures, and evidence.

## Simplicity budget

Repository-wide process or tooling must protect a concrete guarantee that Git, GitHub, or existing
CI does not already provide. Prefer the smallest implementation that correctly fulfills Sol's
declared contract: own only the responsibilities the dependencies do not already handle, and treat
Terraform, Kubernetes and the cloud providers as authoritative in their domains rather than
duplicating their documented behavior with Sol-side validation, reconciliation, retries, watchers or
state. Before adding a guard, abstraction, retry, state file, or process, ask what responsibility it
fulfills, why the dependency cannot fulfill it, and whether simplifying or deleting would solve the
problem instead: complexity is better deleted at its owning boundary than coordinated with more
machinery. When a mechanism goes, keep the guarantee it carried and say which test still establishes
it. Prefer a simpler design or a test at the failure boundary over turning an incident into a
permanent global rule. Historical state belongs in Git and pull requests unless it is a current
product, architecture, or qualification authority.

Prefer contract-driven tests over simulations of dependencies. Test documented behavior at its
owning boundary, mock external interfaces minimally, and exercise real Sol components wherever
practical. Use live qualification for claims that require real provider behavior. Before adding
test infrastructure, evidence machinery, validation, recovery, or another abstraction, identify
the concrete failure it detects, whether existing mechanisms already detect it, and whether the
assurance justifies the maintenance cost. Do not build a second implementation of Sol or its
dependencies merely to test the first. When simplifying, preserve meaningful regression coverage
rather than historical test machinery.

Enforcement machinery must buy a guarantee, not restate a shape. A small regression test that
refuses an unsafe Terraform import, or proves that a failed run still exposes its diagnostic
output, is valuable. A source-shape guard that only asserts a workflow, file or function contains
expected names or fields is not evidence of the behavior it stands for, and testing the guard's own
mutations does not add behavioral evidence. Add such a guard only when it catches a concrete
failure that CI review and a test at the failure boundary cannot reasonably detect; state the
failure and the evidence that justifies the machinery. We want better guarantees, not a growing
collection of systems that assert them.

Preserve the original diagnostics Terraform, Kubernetes and cloud providers emit, including error
codes and messages. Add concise Sol context when it helps, but do not replace, obscure or
speculatively reinterpret the underlying error, and redact sensitive values where necessary.

History belongs in Git and pull requests, not current instructions. If prose conflicts
with executable behavior, verify the implementation and fix or remove the stale prose
rather than adding another authority.
