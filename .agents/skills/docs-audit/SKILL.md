---
name: docs-audit
description: Run a documentation truth audit of Sol. Verifies README, tutorial, roadmap, generated docs, package specs, and documented CLI commands against implementation reality. Files actionable findings as ordinary GitHub Issues.
---

# /docs-audit — Documentation Truth Audit


The core question: *can a startup engineer trust this documentation as the truth without reading source code or old work summaries?*

## Finding identity

Use descriptive GitHub Issue titles. Historical issue-number sequences are retired and do not need to continue.

## Steps

### 1. Read the template

Read `internal/pipeline/audits/DOCS_AUDIT.md` in full before starting.

### 2. Check previous findings


### 3. Verify source-of-truth docs

- Read `README.md`, `docs/developer-experience.md`, and `docs/guides/tutorial.md`
- Check whether status claims match implementation and tests
- Identify historical sections that could be mistaken for current product state
- Compare product framing and terminology across docs

### 4. Verify documented commands

- Read `cli/bin/main.ml` and `cli/bin/cmd_*.ml`
- Build a list of registered commands and flags
- Compare against every documented `sol ...` command in root docs and generated README templates
- Verify documented output promises by reading implementation or running commands where practical

### 5. Verify quickstart and generated docs

- Read generated README templates in `cli/bin/cmd_new.ml`
- Check quickstart commands, ports, health paths, curl examples, Grafana queries, and working directories
- Confirm normal workflows use Sol commands first and do not require repo-local bash scripts

### 6. Verify package specs

- for each package-level `*.md` under `framework/`, compare public API claims against nearby `.mli` files
- Mark deferred or speculative claims as findings if they are not clearly labeled

### 5. File the findings

read it before filing; the report-shaped content below becomes the issue body:

- the observation and the exact command or line that shows it
- the mechanism, and what the product actually does
- what it would take to fix, and what would make a fix fail (the acceptance criteria)

### File actionable findings

For each distinct actionable finding not already represented by a GitHub Issue, create an ordinary issue with the problem, evidence, affected files, desired end state, and acceptance criteria. Prefer one coherent issue per ownership/refactor boundary over line-level findings.
