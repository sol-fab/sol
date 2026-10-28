# Sol Framework: Documentation Truth Audit

This is a reusable audit template. When performing an audit, copy this file or use it as the blank exam, work through every section, and record every finding in the Findings Log format at the bottom. Do not record findings in this file.

**What this audits:** Whether Sol's documentation accurately represents the product that exists. A startup engineer should be able to trust the docs without cross-checking source code, tribal knowledge, or old work summaries.

**Truth standard:** If a document claims a command, guarantee, status, workflow, generated file, or production behavior, the audit must verify it against implementation or a reproducible command. Historical notes are acceptable only when clearly labeled as historical.

---

## 1. Source-of-Truth Alignment

Sol has several root-level and package-level docs. They must agree on what Sol is, what is complete, and what is still planned.

**Source locations:** `README.md` · `docs/developer-experience.md` · `docs/guides/tutorial.md` · package-level `*.md` specs

### Checklist

* [ ] **Project identity is consistent:** Every high-level doc describes Sol as an OCaml production platform for startups built around autonomous domain teams and typed event contracts.
* [ ] **Status claims match implementation:** Any "complete", "planned", "in progress", or "deferred" claim is backed by code, tests, or a clearly marked roadmap item.
* [ ] **Historical sections are labeled:** Old roadmap or work-summary material cannot be mistaken for current product state.
* [ ] **Terminology is stable:** Workspace, domain, event, service, worker, function, deploy, up, dev, migrate, rollback, and cloud terms are used consistently.
* [ ] **No conflicting quickstarts:** README, tutorial, generated workspace README, and package docs do not give contradictory first-run instructions.

---

## 2. Command Truth

Every documented `sol` command must exist, have the documented shape, and behave close enough to the documented promise that a user is not misled.

**Source locations:** `README.md` · `docs/guides/tutorial.md` · `cli/bin/main.ml` · `cli/bin/cmd_*.ml`

### Checklist

* [ ] **Every documented command exists:** `sol new`, `sol local`, `sol local deploy`, `sol deploy`, `sol destroy`, `sol target show`, `sol target reconcile`, `sol migrate`, `sol rollback`, and any documented subcommands are registered in the CLI.
* [ ] **Documented flags exist:** Flags shown in docs are present in the Cmdliner definitions and have the documented names, defaults, and required/optional status.
* [ ] **Output promises are true:** If docs say a command prints URLs, health, endpoints, rollback status, or provisioned resources, the command actually prints them.
* [ ] **Local vs CI deploy semantics are clear:** `sol local deploy` and `sol deploy` are documented with their real responsibilities and failure modes.
* [ ] **Docs use Sol commands first:** User-facing docs do not require raw `kubectl`, `docker`, `rpk`, `terraform`, cloud CLIs, or repo-local bash scripts for normal workflows unless explicitly labeled as advanced or fallback.

---

## 3. Quickstart Reproducibility

The quickstart is the product's trust test. It must be executable exactly as written.

**Source locations:** `README.md` · `docs/guides/tutorial.md` · the generated workspace README template in `platform/shared/templates/workspace/` (written by `cli/lib/workspace/sol_cli_cmd_new.ml` via `cli/lib/base/sol_cli_scaffold_tree.ml`)

### Checklist

* [ ] **Prerequisites are complete and minimal:** The docs state the real prerequisites without hiding toolchain or system-package requirements.
* [ ] **Install path is accurate:** The documented path to getting a `sol` binary on `PATH` works from a fresh machine or is clearly marked as source-build-only.
* [ ] **Commands run in the stated order:** The quickstart sequence does not require undocumented setup between steps.
* [ ] **Paths are valid from the documented working directory:** Commands do not rely on knowing the Sol framework repo location after scaffolding a separate workspace.
* [ ] **Verification examples match generated code:** `curl` paths, response bodies, ports, service names, Grafana queries, and health endpoints match the scaffolded workspace.

---

## 4. Generated Documentation

Generated docs are part of the product. They must teach the intended architecture and avoid obsolete or repo-local instructions.

**Source locations:** `cli/lib/workspace/sol_cli_cmd_new.ml` · `cli/lib/base/sol_cli_scaffold.ml` · the templates under `platform/shared/templates/`

### Checklist

* [ ] **Generated README explains ownership:** The generated workspace README makes it clear which domain owns each event, service, worker, storage module, and migration.
* [ ] **Generated README uses current commands:** It references current `sol` commands only for normal workflows.
* [ ] **Generated README has no framework-repo paths:** It does not instruct users to run scripts from `<path-to-sol>` or another checkout.
* [ ] **Generated docs explain edit points:** Handler logic, worker logic, event contracts, migrations, and `sol.toml` overrides are easy to find.
* [ ] **Generated docs preserve security posture:** Auth, secrets, Kafka security, and production overrides are described accurately and explicitly.

---

## 5. Package Spec Accuracy

Package-level specs should be useful implementation references, not stale design notes.

**Source locations:** `framework/ocaml/kafka-eio-service/kafka-eio-service.md` · `framework/*/*.md`

### Checklist

* [ ] **Public APIs match specs:** Module types, function signatures, config records, and result/error behavior in specs match `.mli` files.
* [ ] **Behavioral guarantees match tests:** Claims about retry, acking, shutdown, auth, metrics, migrations, and schema registration have matching tests or documented gaps.
* [ ] **Deferred features are marked:** Planned behavior is clearly labeled and not mixed into current API guarantees.
* [ ] **Examples compile or are clearly illustrative:** Code snippets either compile as written in context or are labeled as pseudocode.
* [ ] **Cross-package dependencies are accurate:** Specs do not imply a worker pulls in HTTP, or a service pulls in Kafka, unless the code actually does.

---

## 6. Mission and Audience Fit

Docs should make Sol feel like a coherent platform, not a pile of implementation notes.

### Checklist

* [ ] **Docs reinforce the same product promise:** The reader consistently sees "write business logic; Sol handles infrastructure and operations."
* [ ] **Architecture is explained before tools:** Domain teams, typed events, and generated infrastructure are presented as the model; Kubernetes/Kafka details support that model.
* [ ] **Advanced details do not obscure first-use flow:** FFI, Terraform, raw Kafka, and low-level debugging details are available but not required to understand the product.
* [ ] **AI-agent-first design is concrete:** Docs explain how conventions, generated structure, and types make agent-assisted changes reliable.
* [ ] **No overclaiming:** Docs do not imply enterprise-scale guarantees, vendor integrations, or production hardening that Sol does not yet provide.

---

## Findings Log

Record every gap found during this audit run below. Use one entry per finding.

```
### [DOCS-NNN] — Document / Claim Name
* **Category:** Command Truth | Quickstart | Generated Docs | Package Spec | Status Claim | Mission Fit
* **Severity:** Critical | High | Medium | Low
* **Location:** `path/to/doc.md` (Lines X-Y) and implementation source if relevant
* **Description:** What the docs claim and why it is inaccurate, confusing, stale, or incomplete.
* **Impact:** How this damages user trust, onboarding, production safety, or mission clarity.
* **Remediation:** The concrete doc update, code update, or status clarification required.
```
