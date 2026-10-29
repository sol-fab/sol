# CI and verification model

This page is the contributor map for Sol's CI. It records which suites exist,
which check is authoritative for merge, what each change category must run, and
where the current model still has limits. The workflow itself is
[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml); suite membership is
declared by the `dune` files, not by this page.

## Audit findings (2026-10-29)

- The execution boundaries are broadly coherent: application runtime packages
  depend on shared contracts/plumbing, not on the CLI; provider adapters sit
  below deployment policy; task core and provider runtimes are separate
  libraries. No package split was justified by a dependency cycle or a failed
  isolation test.
- The concrete boundary defect was `sol-task` missing from
  `prepare-framework-deps.sh`; a checkout switch could not install the public
  package. Fixed.
- Only `test` is required. The golden-path, example-Dockerfile and TypeScript
  jobs are advisory; making them required is a branch-protection decision.
- The required `test` job ran static/format checks after the product suites and
  the stubbed qualification harnesses. Moved them ahead of the product suites
  so a cheap failure is diagnosed first.
- The verification-tooling step repeated the preceding root dependency
  install; removed.
- Long test/qualification/setup steps lacked step timeouts; added bounded
  timeouts. The qualification harness was the longest unbounded step.
- Support-package pinning and per-job environment setup are the largest
  remaining setup costs; the support-pin cache shortcut was not taken because a
  stale pin could undermine the exact-commit guarantee.

## Required path

Branch protection for `main` requires **`test` only**. `classify` is not a
required check; it has `continue-on-error: true`, and every consumer treats an
empty classification as `source` and runs the full suite. The `test` job is the
authoritative required path; the other jobs are advisory and are deliberately
not required because they consume external services, build example workspaces,
or are filtered by language (see their comments in the workflow).

The `test` job runs, in this order:

1. `verify always` (every path, including docs-only)
2. environment setup, support-package pins, framework install
3. formatter install, build, and the static verification class
4. `@ci-unit`, `@ci-lifecycle`
5. broker/Postgres integration (`@ci-integration-kafka @ci-integration-pg`)
6. facts-to-jobs E2E (`@ci-e2e`)
7. stubbed qualification harnesses and the installed-release smoke

The static/format checks run before the product suites so a format or source
invariant failure fails the required check without first spending time on the
unit, lifecycle, integration and E2E suites. The 2026-10-29 reorder keeps the
same 33 test steps; only their order, step timeouts, one redundant command, and
the integration-diagnostics outcome guard changed.

## Suite map

| Command | Establishes | External services |
|---|---|---|
| `dune build @ci-unit` | Package-declared offline unit, contract and fake-provider tests, including `cli/test`'s `runtest` rules | none |
| `dune build @ci-lifecycle` | Offline cloud lifecycle / fake-provider command behavior (`cli/test` `runtest-lifecycle`) | none |
| `dune build @ci-integration-kafka` | Framework Kafka integration (schema registry, consumer behavior) | Redpanda |
| `dune build @ci-integration-pg` | Framework Postgres integration (jobs, outbox, task local runtime, migrations) | Postgres |
| `dune build @ci-e2e` | Facts-to-jobs golden path: transaction/outbox/worker/job boundaries, duplicate delivery and recovery | Redpanda, Postgres, Loki |
| `bash internal/tooling/scripts/verify.sh always` | Path-independent guards, including account-artifact and workflow checks | none |
| `bash internal/tooling/scripts/verify.sh static` | Source/config/product invariants and their mutation tests; reads the built CLI and provider printer | none (needs ocamlformat + built binaries) |
| `bash internal/ci/run_fast_checks.sh` | Local fast path: support pins, `dune build`, formatting, static class | none |
| `bash internal/tooling/scripts/run_tests.sh` | Local full suite: unit, Kafka, Postgres, E2E; starts local containers | Docker |
| `internal/qualification/gcp/stubbed-qual-test.sh` and the other stubbed qualification tests | Qualification harness state machines, mutation-tested, with every provider command stubbed | none |
| Live qualification (`internal/qualification/...`) | Real cloud behavior; never in ordinary PR CI | cloud credentials, explicit authorization |

`run_tests.sh` is the local full **product** suite, but it does not run the static
class, the qualification harness tests, the installed-release smoke, or the
advisory Docker/TypeScript/golden-path jobs. The CI `test` job plus the advisory
jobs remain the authoritative full path. Focused commands complement CI; they do
not replace it.

## Change category to required suites

| Change | Must run |
|---|---|
| Framework shared contract or runtime (`sol-svc-core`, `sol-runtime`, `sol-env`, `sol-obs`, `sol-retry`) | `@ci-unit`, fast checks; affected integration suite |
| Framework workload runtime (`sol-svc`, `sol-worker`, `sol-fn`, `sol-jobs`, `sol-outbox`, `sol-task`) | `@ci-unit`, fast checks; `@ci-integration-pg`/`kafka` where the package declares it; `@ci-e2e` for job/outbox/task orchestration |
| CLI base, workspace, kube or local layer | `@ci-unit`, static class, fast checks |
| CLI cloud lifecycle, release, ownership, rollback or provider adapter | `@ci-unit`, `@ci-lifecycle`, static class; full `test` for shared policy; live only with explicit authorization |
| Shared deployment/orchestration policy | Full `test` (all suites above); advisory jobs as applicable |
| CI workflow, guard, alias or test membership | Full `test` and every advisory job that the workflow defines; do not path-filter |
| Docs | `verify always`; `classify` may mark docs-only and skip the product suite by design |
| Dockerfile, scaffold/example workspace | `dockerfile-matrix` → `example-dockerfile-smoke`; `golden-path-smoke` for the OCaml scaffold path |
| TypeScript demo/scaffold | `ts-tests`, `golden-path-smoke-ts`, and the `demo_ts` Dockerfile jobs |

A shared-policy change is not allowed to run only the suites for the primitive it
happens to mention. The classifier deliberately routes mixed or unrecognized
changes to `source`, which runs the full `test` job.

## Measured cost (before the 2026-10-29 reorder)

Measured from the completed `test` job of PR #1785 (`actions/jobs/123373524658`):

| Step group | Seconds |
|---|---:|
| Setup, pins, dependencies, framework, build | ~274 |
| `@ci-unit` | 147 |
| `@ci-lifecycle` | 153 |
| Kafka/Postgres integration | 29 |
| facts-to-jobs E2E | 21 |
| formatter + static class | 75 |
| stubbed qualification harnesses + installed release | ~310 |
| **Total** | **~1008 s (~16.8 min)** |

The largest setup item was pinning support packages (114 s); the largest test
items were `@ci-unit`/`@ci-lifecycle` (300 s) and the stubbed qualification
harnesses (207 s + 75 s + smaller cases). The reorder does not remove any check,
so the successful path should remain approximately the same duration; its gain is
that a format/source failure stops before the ~350 s of product suites and the
qualification steps (up to ~660 s saved on that failure path). The after timings
must be read from the PR's own CI run; no success-path speedup is claimed without
that measurement.

The reorder also removes a redundant `opam install --deps-only --with-test` from
the verification-tooling step (the preceding dependency step already installs the
same test dependencies), and adds bounded step timeouts so a hung harness fails
at its own step with a clear name instead of consuming the job timeout.

## Cost opportunities not taken

- **Support-package pinning** (114 s measured) runs `opam pin` on every job.
  The switch cache restores packages, but the pin action still re-runs. A
  skip-if-already-at-`support-refs.txt` shortcut is not added: a stale pin that
  silently matched the restored switch would undermine the exact-commit
  guarantee, and the existing drift guard is a check, not a cache key.
- **Formatter install** (24 s) is a separate opam invocation. It could be folded
  into the dependency-install step, but that step has its own retry/diagnostics
  behavior and the saving is small.
- **Example Dockerfile builds** use `--no-cache` deliberately (FRIC-014);
  removing that would hide scaffold drift. The matrix jobs already run in
  parallel.
- **`test` is monolithic** because it is the only required check. Splitting it
  into parallel required checks would change branch-protection status names;
  that is an operator decision, not a workflow-only edit.
- **Qualification harnesses are serial.** They use independent `mktemp` trees,
  but a parallel wrapper would interleave their output and weaken per-step
  failure diagnosis. The measured long step (207 s) has a bounded timeout now.
- **Per-job environment setup** is repeated across `test`, `golden-path-smoke`
  and the TypeScript jobs; each can reuse the opam download/switch caches but
  they are separate runners. No cross-job build artifact is shared because the
  jobs target different workspaces.

## Limits of the current model

- The `test` job is monolithic and required. Splitting it into parallel required
  checks would require changing branch protection and the required status names;
  that is not done here.
- `golden-path-smoke`, `example-dockerfile-smoke`, `demo-ts-dockerfile-smoke`,
  `ts-tests` and `golden-path-smoke-ts` are advisory, not required. They cover
  scaffold/runtime behavior that the required `test` job does not duplicate.
  Making them required is a branch-protection decision, not a workflow-only one.
- The qualification harnesses are serial. They use `mktemp` and stubbed commands,
  but parallelizing them would interleave their logs and weaken per-step failure
  diagnosis; no parallel wrapper is introduced.
- The example Docker builds use `--no-cache` deliberately (FRIC-014); layer
  caching is not used to shorten that job.
- Live cloud qualification is never part of PR CI. It requires explicit
  authorization, bounded ownership, and independent cleanup under
  [`internal/qualification`](../qualification/README.md).
