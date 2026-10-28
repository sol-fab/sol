# Sol documentation

This is the map of Sol's documentation: what exists today, who each page is for,
and what is planned. It is also the roadmap for closing the documentation gaps
the product experience implies, so a page can be written against a stated
audience rather than reinvented each time.

The experience these pages document is defined in
[`developer-experience.md`](developer-experience.md). If a page and that document
disagree on intent, that document wins; if a page and a decision record disagree,
the decision record wins.

## Two audiences, two trees

- **`docs/` — for people using Sol.** Install it, build an application, deploy
  it, operate it, and understand the contract.
- **`internal/` — for people building Sol.** Pipeline machinery, tickets, audits,
  qualification, CI guardrails. Not a product surface.

Within `docs/`, the sections are:

| Section | Audience | Contents |
|---|---|---|
| `guides/` | New users | The end-to-end tutorial |
| `reference/` | Application authors | The language-neutral application contract (runtime, substrate) |
| `deployment/` | Operators | Production bootstrap, CI/CD, compatibility, escape hatches, recovery, observability backends |
| `architecture/` | Evaluators and contributors | The factory model, pipeline, ADRs |
| `hosted/` | Evaluators | The boundary statement for the (separate) hosted product |
| `legal/` | Everyone | Third-party licences |

`developer-experience.md` sits at the top of `docs/` because it is the entry
point for "what is Sol and what is it promising".

## The documentation set and its status

| Page | Audience | Status |
|---|---|---|
| [`developer-experience.md`](developer-experience.md) | Evaluators, all users | **Published** |
| [`guides/tutorial.md`](guides/tutorial.md) | New users | **Published** — local path, end to end |
| [`guides/installation.md`](guides/installation.md) | New users | **Published** — DOCS-026; installation and the first production deploy |
| [`guides/application-authoring.md`](guides/application-authoring.md) | Application authors | **Published** — DOCS-027 |
| [`guides/deployment.md`](guides/deployment.md) | Operators | **Published** — DOCS-028; the operator detail stays in `deployment/*` |
| [`guides/operations.md`](guides/operations.md) | Operators | **Published** — DOCS-029 |
| [`reference/README.md`](reference/README.md), [`reference/runtime.md`](reference/runtime.md), [`reference/substrate.md`](reference/substrate.md) | Application authors | **Published** |
| CLI reference | All users | **Published** — [`reference/cli.md`](reference/cli.md) |
| [`architecture/product-architecture.md`](architecture/product-architecture.md) and [`architecture/adr/`](architecture/adr/) | Evaluators, contributors | **Published** |
| [`architecture/ownership.md`](architecture/ownership.md) | Contributors | **Published** — the ownership proof per domain; the Kubernetes UID rule lands with `#1304` milestone 2 |
| [`hosted/README.md`](hosted/README.md) | Evaluators | **Published** — boundary only |

## Target information architecture

The intended shape, in reading order for a new user. The goal is that a reader
never needs a source checkout to complete the ordinary path.

### 1. Getting started

- **Installation** — install the CLI, verify the install, and understand what
  `sol` is about to do on your machine.
  [`guides/installation.md`](guides/installation.md) §1–2. *DOCS-026.*
- **Quickstart** — local cluster to a running service in one sitting; the
  existing [`tutorial.md`](guides/tutorial.md) is the reference implementation of
  this page.
- **First production deploy** — the guided first-run experience: detect the
  account, set up the installation, delegate DNS, reach a live endpoint.
  [`guides/installation.md`](guides/installation.md) §4. *DOCS-026, with
  FEAT-106/FEAT-107.*

### 2. Framework / application authoring

- **Application model** — workspaces, domains, units, events; how a Sol
  application is organised. *DOCS-027.*
- **The three primitives** — `-svc`, `-worker`, `-fn`; when to use each. *DOCS-027.*
- **Language guides** — OCaml and TypeScript as first-class application
  languages, and the parity contract between them (`DEC-022`). *DOCS-027.*

### 3. Deployment

- **Targets and environments** — the addressing model, and why the environment
  is a property of the target (`DEC-016`). *DOCS-028.*
- **Provisioning and deploying a target** — `sol plan` previews and `sol deploy` reconciles infrastructure, authorization and workloads; `sol destroy <target>` tears the target down.
- **Deploying the application** — direct and GitOps modes. *DOCS-028.*
- **CI and continuous deployment** — [`deployment/ci.md`](deployment/ci.md): the generated
  workflow, its OIDC identities and the gated authorization job.
- **Escape hatches** — [`deployment/escape-hatches.md`](deployment/escape-hatches.md).
- **Production bootstrap and identities** — [`deployment/production-bootstrap.md`](deployment/production-bootstrap.md).
- **Compatibility and profile** — [`deployment/compatibility.md`](deployment/compatibility.md).

### 4. Operations

The published page is [`guides/operations.md`](guides/operations.md): the day-two command
set, rollback, diagnostics, the operational UIs, destroy, and uninstall.

- **Everyday operations** — `check`, `releases`, `rollback`, `destroy`, `uninstall`;
  logs, metrics and traces through the target's Grafana.
- **Releases and rollback** — the release contract and `sol rollback`.
- **Destroy and uninstall** — the environment/installation distinction, and the
  explicit teardown of each (`sol destroy`, `sol uninstall`).
- **Recovery** — [`deployment/application-data-recovery.md`](deployment/application-data-recovery.md),
  [`deployment/credential-rotation.md`](deployment/credential-rotation.md),
  [`deployment/workload-availability.md`](deployment/workload-availability.md),
  [`deployment/migration-ordering.md`](deployment/migration-ordering.md).

### 5. CI without Sol hosting

- **Generating a CI workflow** — `sol ci init github` and the supported
  short-lived identity flow. *DOCS-028 with FEAT-109.*
- **GitOps** — emitting manifests for Argo CD. *DOCS-028.*

### 6. Reference

- **Application contract** — [`reference/README.md`](reference/README.md).
- **Runtime contract** — [`reference/runtime.md`](reference/runtime.md).
- **Substrate contract** — [`reference/substrate.md`](reference/substrate.md).
- **CLI reference** — every command, flag and exit behaviour. *DOCS-030.*
- **Configuration schema** — `sol.yml`, `sol.toml`, target files, and the
  escape-hatch keys. *DOCS-030.*

### 7. Architecture

- **Product architecture** — [`architecture/product-architecture.md`](architecture/product-architecture.md).
- **Factory pipeline** — [`architecture/devops-pipeline.md`](architecture/devops-pipeline.md).
- **Resource ownership** — [`architecture/ownership.md`](architecture/ownership.md): what proves Sol owns a resource, per domain, and where each rule is enforced.
- **Observability design** — [`architecture/observability-design.md`](architecture/observability-design.md).
- **Architecture decision records** — [`architecture/adr/`](architecture/adr/).

## Conventions

- **One source of truth per fact.** A page links to the authority rather than
  restating it. `docs/reference/README.md` is the model: it points at the
  runtime, substrate and source declarations instead of keeping a second copy.
- **State the status.** A page that describes intended behaviour says so, and
  links the ticket. The status markers used in
  [`developer-experience.md`](developer-experience.md) are the convention.
- **User-facing commands come first.** A documented workflow uses `sol` commands
  before repository scripts; a reader with an installed release should not need a
  source checkout for the ordinary path.
- **A page ships with the change that makes it true.** When a ticket changes what
  an application author does, it updates the affected page or example in the same
  change (see `AGENTS.md`).

## Maintaining this map

This page is the place to record a new documentation page and its audience before
writing it. When a planned page lands, change its status to **Published** here
and close its ticket. When a whole documentation area is added or retired, update
the two-audience tree above in the same change.
