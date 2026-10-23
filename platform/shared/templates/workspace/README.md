# {{Name}}

A Sol workspace with two services: `charge_svc` (HTTP) and `notify_worker` (Kafka consumer).

## Prerequisites

System packages required before building:

```bash
sudo apt-get install -y librdkafka-dev libpq-dev libpq5
```

The Sol framework is an ordinary opam dependency, declared in `{{basename}}.opam`
alongside the rest of this workspace's dependencies. Nothing is vendored into
this directory, and the workspace has no knowledge of where Sol's source lives.

The framework packages are pinned to the exact Sol revision this workspace was
generated from. `opam install . --deps-only` fetches that commit, so the
workspace is reproducible and does not depend on a moving branch.

- **Normal build:** `opam install . --deps-only` uses the pinned revision. No
  Sol checkout is required.
- **Testing uncommitted framework changes:** install the framework from a local
  Sol checkout, which replaces the pinned package in your opam switch:

  ```bash
  bash /path/to/sol/platform/local/scripts/prepare-framework-deps.sh
  ```

  That is Sol's own bootstrap. It changes your switch, not the workspace pin;
  commit and regenerate the workspace when the framework revision changes.

## Build

```bash
eval $(opam env)
dune build
```

## Schema compatibility in CI

Set the GitHub Actions secret `SCHEMA_REGISTRY_URL` to the registry containing
the published schema history. The generated `sol-ci.yml` runs `dune runtest`
against it and fails when the URL is absent or compatibility cannot be checked.
On a developer machine, `dune runtest` visibly skips this check when the URL
is unset.

## Run locally

```bash
sol local deploy     # establish local cluster + infra, build images, deploy (~5 min first run)
sol local run        # run all workspace services locally (dune exec, dev env vars)
```

## Deploy to cluster

```bash
sol local deploy                    # build images and deploy to cluster
sol local migrate                   # apply database migrations
sol local releases                  # list recorded releases
sol local rollback <release-id>     # restore a recorded release
```

## Container images

Each unit's `Dockerfile` is a two-stage build:

- **Builder** -- `ocaml/opam:ubuntu-24.04-ocaml-5.4`, so the binary links against
  glibc 2.39, with the `librdkafka`/`libpq`/`libssl`/`libgmp` development packages
  installed.
- **Runtime** -- `ubuntu:24.04` with the matching runtime libraries only.

Dependencies are not listed in the Dockerfile. The builder reproduces the
environment this workspace declares in `{{basename}}.opam`
(`opam install --deps-only .`), so the workspace owns its dependency choices and
the Dockerfile only reconstructs them. That is why no Sol repository appears in
it: the framework packages carry their own `pin-depends` for anything not yet in
the public opam-repository (DEC-025; see Prerequisites above).

Three details are deliberate:

- `opam repository set-url default https://opam.ocaml.org` runs before the
  install. The base image's default remote is a local snapshot frozen when the
  image was built, which can predate a version a dependency needs (observed with
  `https-eio` needing `tls-eio >= 2.1.0`, unsatisfiable against that snapshot even
  after `opam update`). CI initialises a fresh index and never hits this.
- `{{basename}}.opam` is copied before the source, so the dependency layer stays
  cached independently of source changes.
- The image runs as uid 65534 (`nobody`), matching the `securityContext` Sol
  renders into the Kubernetes manifests. Change one without the other and the
  running workload no longer matches what the manifests declare.

The build context is the workspace root -- this directory, the one holding
`sol.yml` -- which is what `sol local deploy` uses. To build one image by hand:

```bash
docker build -f app/payments/charge_svc/Dockerfile -t charge-svc .
```

`sol local deploy` copies this root into a temporary build context first (excluding
`_build/` and `.git/`, as `.dockerignore` does). Symlinks are copied as
symlinks, exactly as Docker itself treats them: a link is never followed, so a
link that points outside the workspace stays a link rather than importing the
external file's contents into the context.

## Project layout

```
sol.yml                   ← workspace manifest (identifies this as a Sol workspace)
events/payments/          ← Charged event contract (payments team owns)
app/payments/charge_svc/  ← HTTP service (publishes Charged on POST /charges)
app/comms/notify_worker/  ← Kafka consumer (subscribes to Charged)
lib/                      ← shared storage module (used by svc and worker)
db/migrations/            ← SQL migration files
  *.sql                   ← forward migrations
  *.down.sql              ← rollback migrations (used by `sol migrate rollback`)
test/                     ← schema backward-compatibility CI gate
  test_schemas.ml
  dune
.dockerignore             ← excludes _build/ and .git/ from Docker build context
sol/secrets.local/        ← ignored per-unit credentials for local run and deploy
{{basename}}.opam              ← declares the Sol framework dependency (DEC-025)
```

This workspace's directory, OCaml module names, and SQL identifiers use the
OCaml-safe form `{{name}}` (lowercased, `-` → `_`). Kubernetes namespaces and
object names use the hyphenated form (`_` → `-`), e.g. `{{name}}-payments`; the
mapping is applied automatically.
