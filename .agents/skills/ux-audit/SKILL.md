---
name: ux-audit
description: Run a developer experience audit of Sol. Verifies that a startup engineer can start a project, develop locally, and deploy to the cloud using only Sol's documented commands — without DevOps knowledge. Files actionable findings as ordinary GitHub Issues.
---

# /ux-audit — Developer Experience Audit


The core question for every check: *would a startup engineer need knowledge outside this repo to get past this step?* If yes, that is a finding.

Also check whether the experience teaches and preserves Sol's mission: autonomous domain teams, typed event contracts, generated infrastructure, explicit auth, day-2 operations through Sol commands, and AI-agent-friendly structure.

## Finding tracking

Search open and closed GitHub Issues before filing. File an ordinary issue only for a distinct actionable finding that is not already tracked. Do not create labels, status conventions, dependency validators, branch conventions, or other workflow metadata to replace the retired repository issue system.

## Steps

### 1. Read the template
Read `internal/pipeline/audits/UX_AUDIT.md` in full before starting.

### 2. Check previous findings
Note which findings were already open — verify whether they are now resolved before logging them again.


### 3. Work through each stage

**Stage 1 — Installation:**
- Check `README.md` for a single-command install path
- Check whether the install method works without a language toolchain already installed
- Note any prerequisites listed and whether they are reasonable for a startup engineer

**Stage 2 — Project Creation:**
- Read `README.md` for `sol new workspace` instructions
- Read `cli/bin/cmd_new.ml` — count the generated files, verify library names are workspace-namespaced
- Check whether the generated README explains the project layout clearly enough without prior Sol knowledge

**Stage 3 — Local Development:**
- Check `README.md` or a linked guide for `sol local deploy` and `sol local run` instructions
- Check whether `sol local deploy` creates the local cluster and infrastructure, and `sol local run` exists
- Verify the guide explains how to observe the message flow end-to-end (Grafana URL, what to query)

**Stage 4 — Cloud Setup:**
- Check `README.md` or a linked guide for the first-run `sol deploy` flow, the target declaration and the installation/identity steps
- Check whether `sol deploy <target>` detects an absent installation and guides the operator in place
- Check `platform/cloud/` — verify Terraform modules exist for both supported providers

**Stage 5 — First Deploy:**
- Check `README.md` or a linked guide for `sol deploy` instructions with the required target positional (`<env>/<provider>/<region>`) and all required flags
- Verify `sol deploy <target>` exists and works end-to-end
- Check whether the command prints the deployed service URL on completion

**Stage 6 — Shipping a Change:**
- Check whether the guide describes the change → deploy cycle in Sol commands only
- Check whether `sol rollback` exists

**Stage 7 — Day-2 Operations:**
- Check the docs for `sol releases`, `sol rollback`, `sol migrate`, `sol destroy` and `sol uninstall`
- Check that routine logs, metrics and traces are documented through the per-target Grafana URL, with a login path that does not require Kubernetes access
- Verify `sol new svc` / `sol new worker` / `sol new fn` are documented

**Stage 8 — Adding a Domain Event Flow:**
- Check whether the docs show `sol new event <domain>/<name>` and a worker consuming that contract
- Verify the generated event lives under `events/<domain>/`
- Verify consumers import event contract modules rather than producer service modules
- Verify schema compatibility is checked by a documented Sol command or generated test path
- Verify the new workflow does not require hand-editing Kafka or Kubernetes manifests

**Stage 9 — AI-Agent-Assisted Change:**
- Inspect generated workspace docs and templates for predictable edit points
- Verify service handlers, worker handlers, event contracts, migrations, and entrypoints are easy to locate
- Check whether framework-owned concerns are separated from business logic
- If reproducing the stage, make a narrow business change and verify it compiles using documented Sol commands only

### 5. File the findings

read it before filing; the report-shaped content below becomes the issue body:

- the observation and the exact command or line that shows it
- the mechanism, and what the product actually does
- what it would take to fix, and what would make a fix fail (the acceptance criteria)

### File actionable findings

For each distinct actionable finding not already represented by a GitHub Issue, create an ordinary issue with the problem, evidence, affected files, desired end state, and acceptance criteria. Prefer one coherent issue per ownership/refactor boundary over line-level findings.
