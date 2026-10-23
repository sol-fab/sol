---
name: dogfood
description: Run a developer dogfood pass of Sol. Executes the golden path from sol new workspace through curl against a live service, times each step, and logs every friction point. Produces a dated report in internal/pipeline/dogfood/ and files blocking findings as ordinary GitHub Issues.
---

# /dogfood — Golden Path Dogfood Run

Executes the full Sol developer golden path as a first-time user would, following
the runbook at `internal/pipeline/dogfood/DOGFOOD.md`. Times every step, records friction, and
determines whether the two-minute deploy claim holds on a live local substrate.

Writes a completed report to `internal/pipeline/dogfood/RUN_<YYYY-MM-DD>.md` and materialises
each blocking or high-friction finding as a issue in

## Finding tracking

Search open and closed GitHub Issues before filing. File an ordinary issue only for a distinct actionable finding that is not already tracked. Do not create labels, status conventions, dependency validators, branch conventions, or other workflow metadata to replace the retired repository issue system.

## Steps

### 1. Read the runbook

Read `internal/pipeline/dogfood/DOGFOOD.md` in full before starting.

### 2. Check previous runs

Read the most recent report in `internal/pipeline/dogfood/` (highest date). Note which
friction items were logged — verify whether they are now resolved before logging
them again.

re-materialised. If it exists in `DONE/`, mark it resolved in the report — but
verify the fix is still actually live in `main` before trusting that (see
EXP-032: a `DONE` issue's merge can be reverted after the fact and never
refixed, leaving the issue falsely marked resolved). Run
not resolved.

### 3. Prepare the binary

Build the current CLI from the Sol checkout and place it first on PATH:

```bash
cd <sol-checkout>
eval $(opam env)
dune build cli/bin/main.exe
export SOL_HOME=$(pwd)
mkdir -p "$SOL_HOME/.dogfood-bin"
ln -sf "$SOL_HOME/_build/default/cli/bin/main.exe" "$SOL_HOME/.dogfood-bin/sol"
export PATH="$SOL_HOME/.dogfood-bin:$PATH"
hash -r
```

### 4. Run the golden path

Use a fresh workspace name (e.g. `dogfood-<YYYY-MM-DD>`). Record elapsed time
for each command using `/usr/bin/time -f 'elapsed=%E'` or `date +%s%3N` before
and after.

Work through each step in order. If a step fails, record the failure in the
friction log, attempt to diagnose it, and continue with subsequent steps where
possible.

**Steps to run:**

1. `sol new workspace <name>` — scaffold
2. `cd <name> && dune build` — build generated workspace
3. `sol local deploy` — create/reuse the k3d cluster, install local infrastructure, build, push and deploy; this is the only local entry point, and the first run stops at the pending-migration gate
4. `sol local migrate` — apply DB migrations
5. `sol local deploy` — deploy against the migrated schema
6. `kubectl get pods -A` — check workload health (Sol does not expose a status command)
7. `curl http://localhost:8080/health`
8. `curl -X POST http://localhost:8080/charges -H 'Content-Type: application/json' -d '{"customer_id":"cus_dogfood","amount_cents":999,"currency":"usd"}'`
9. Wait up to 10s for worker to consume, then `curl http://localhost:8080/notifications`
10. Open `http://localhost:3000` and verify the workspace/service dashboards show the request and worker logs and metrics; open Explore and query Loki for the service

For step 9: verify the notification row was written by `notify_worker` consuming
a Kafka event, not directly inserted by the HTTP service. If the row is present,
the Kafka path is proven.

### 5. Evaluate the two-minute claim

After the first successful `sol local deploy` that reaches `curl /health`,
measure the wall-clock time from `sol new workspace` through the first
successful health request. Does it stay under two minutes on an existing
substrate **with the image build cache warm**?

Two costs do not count against the claim, and both must be stated when measuring:

- the first `sol local deploy` on a fresh cluster creates the k3d cluster and
  installs the local infrastructure (~5 min); that is substrate bootstrap, not
  application deployment.
- the **first-ever image build**. The Docker build pulls
  `ocaml/opam:ubuntu-24.04-ocaml-5.4` and runs apt + `opam pin`/`opam install`
  inside the image. Measured 2026-09-13 (FRIC-024): **5m34s** for the first
  workspace versus **26s** end-to-end for the next fresh workspace once those
  layers are cached. A genuinely first-time user therefore does *not* see two
  minutes — report the cold number too, not only the warm one.

### 6. Write the report

Create `internal/pipeline/dogfood/RUN_<YYYY-MM-DD>.md` using the template from
`internal/pipeline/dogfood/DOGFOOD.md`. Fill in:

- Tool versions actually observed
- Timing for every step
- Whether the flow completed without manual intervention
- Friction log entries for every step that required knowledge outside the
  command output or docs, produced a confusing message, or failed
- Findings section for non-obvious correctness or UX observations
- List of any issues filed

### File actionable findings

For each distinct actionable finding not already represented by a GitHub Issue, create an ordinary issue with the problem, evidence, affected files, desired end state, and acceptance criteria. Prefer one coherent issue per ownership/refactor boundary over line-level findings.
