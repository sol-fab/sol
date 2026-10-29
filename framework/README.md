# Framework

First-party implementations of Sol's [application contract](../docs/reference/).

- [`ocaml/`](ocaml/) — the OCaml framework packages ([`sol-svc-core`](ocaml/sol-svc-core/sol-svc-core.md), `sol-svc`, `sol-worker`,
  `sol-fn`, `sol-jobs`, `sol-task`, `sol-obs`, plus the internal `sol-runtime`/`sol-env`
  plumbing and `kafka-eio-service`). These are the supported application-facing
  API; each package's `.md` next to its `lib/` is its spec.
- [`typescript/`](typescript/README.md) — the TypeScript framework packages
  (`@sol-fab/kafka`, `@sol-fab/obs`, `@sol-fab/svc`, `@sol-fab/worker`). They
  are published to npm from their own public repositories, the same extraction
  pattern as the OCaml `*-eio` packages, so the directory holds a pointer README
  rather than the implementation. The [`demo_ts`](../examples/pluto/app/demo_ts/README.md)
  showcase is in this repository.

The OCaml framework packages are consumed exactly like any other OPAM packages. Their
contracts are the `.opam` files at the repository root (see
[`../dune-project`](../dune-project), DEC-025); a workspace installed through
`opam` needs no enclosing Sol checkout.
