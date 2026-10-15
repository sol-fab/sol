# `sol` command reference

Every command the `sol` binary registers: its positional argument, the flags it takes, what
a non-zero exit means, and the scopes it accepts.

The tables are **generated from the binary's own help** (`sol <command> --help=plain`) by
`internal/tooling/scripts/render-cli-reference.py`, and
`internal/ci/check_cli_reference.py` fails CI when the page and the binary disagree — a new
command cannot be added silently, and the page cannot document a command or a flag that does
not exist. To regenerate after a CLI change:

```bash
python3 internal/tooling/scripts/render-cli-reference.py
```

The narrative of what each command does in a deployment belongs to
[devops-pipeline.md](../architecture/devops-pipeline.md); this page is the exact spelling.

## Addressing

Remote lifecycle commands take an explicit target (`<env>/<provider>/<region>`).
Local development has two distinct workflows: `sol local deploy` establishes the
local cluster and its infrastructure and deploys the workspace to it, and
`sol local run` runs workspace services as native processes. There is no
ambient current remote target.

Local deploy establishes infrastructure before checking the workspace's migration
state. Pending migrations or checksum drift refuse workload application. Run
`sol local migrate` after the initial refusal, then retry `sol local deploy`;
migration needs only the local PostgreSQL service, not a successful workload deploy.
The retry reuses the local cluster. `--scope` selects workloads; the migration
prerequisite remains workspace-wide. The deploy gate always checks the cluster
PostgreSQL delivered to workloads, ignoring ambient `POSTGRES_URL`. Standalone
migration commands may use that override; unset it when migrating the cluster.
A dry run does not query migration state.

## Exit behaviour

- **0** — the command did what it says.
- **1** — it refused, or it failed. This is the default for every refusal and failure, and
  the code the cloud lifecycle uses for a target that did not reach its postcondition. The reason is
  on stderr, and a command that refuses before the billable boundary has changed nothing.
- **2** — a negative answer from `sol check`: validation ran and found invalid workspace
  declarations. Exit 1 means the command could not complete; exit 2 means the check completed
  and the answer is no.

No command uses any other code. A command whose own help carries an `EXIT STATUS` section is
marked `documented` in the tables below, and `sol <command> --help` is the authority for it.
Machine-readable output exists where the tables' flags say so (`--json`, `--emit-plan-to`,
`--emit-to`); plan output is the same shape `sol plan` prints.

First-run onboarding adds no command of its own: `sol deploy` observes the target's
durable installation, guides it in place, then reconciles the target's environment and
reaches the cluster as the target's deploy identity (DEC-058) — so the whole first run is
documented with that command rather than listed here.

## Target-addressed commands

The target is the positional. `sol deploy` reconciles the whole target and takes no
`--scope`; `sol local deploy` and `sol rollback` still narrow to a domain or unit with
`--scope`.

<!-- BEGIN GENERATED: target -->
| command | positional | flags | exit | purpose |
|---|---|---|---|---|
| `sol deploy` | TARGET | `--await-delegation=SECONDS`, `--confirm-ecr-removal`, `--confirm-group-change`, `--dry-run`, `--emit-plan-to=FILE`, `--emit-to=DIR`, `--image-ref=[SERVICE=]REPO@sha256:DIGEST`, `--image-tag=TAG`, `--keep-releases=N`, `--loki-push-url=URL`, `--registry=URL` | documented | Reconcile a target's infrastructure, authorization and |
| `sol destroy` | TARGET | `--accept-unreleased`, `--apply`, `--plan`, `--var=KEY=VALUE`, `--var-file=PATH` | documented | Reconcile a target toward empty: destroy its Sol-owned |
| `sol grants apply` | TARGET | `--var=KEY=VALUE`, `--var-file=PATH` | documented | Reconcile the target-wide workload authorization: |
| `sol grants plan` | TARGET | `--var=KEY=VALUE`, `--var-file=PATH` | documented | Plan the target-wide workload authorization |
| `sol migrate apply` | TARGET | `--dir=DIR`, `--dry-run`, `--table=TABLE` | documented | Apply all pending migrations (default subcommand) |
| `sol plan` | TARGET | `--image-ref=SERVICE=REPO@sha256:DIGEST`, `--var=KEY=VALUE`, `--var-file=PATH` | documented | Preview target infrastructure, authorization, workload |
| `sol releases` | — | `--target=ENV/PROVIDER/REGION` | documented | List the release records the target's cluster holds for |
| `sol target reconcile` | TARGET | `--dry-run`, `--explain`, `--var=KEY=VALUE`, `--var-file=PATH` | documented | Compare Terraform ownership with independently |
| `sol target show` | — | `--check`, `--json`, `--target=ENV/PROVIDER/REGION`, `-v` | documented | Show a deployment target |
| `sol uninstall` | TARGET | `--confirm`, `--confirm-dns-zone=DOMAIN`, `--var=KEY=VALUE`, `--var-file=PATH` | documented | Remove a Sol installation: its Sol-owned durable |
<!-- END GENERATED: target -->

## Scope-addressed commands

The scope is the positional (omitted means the workspace); `--target` selects the target.

<!-- BEGIN GENERATED: scope -->
| command | positional | flags | exit | purpose |
|---|---|---|---|---|
| `sol check` | — | `--scope=DOMAIN[/UNIT]` | documented | Validate Sol workload declarations without Docker or |
<!-- END GENERATED: scope -->

## Workspace commands

No positional: the command acts on the workspace, and a target or scope is a narrowing flag.

<!-- BEGIN GENERATED: workspace -->
| command | positional | flags | exit | purpose |
|---|---|---|---|---|
| `sol assets` | — | — | documented | Show where this sol's own assets come from (a source |
| `sol ci init` | PROVIDER | `--force` | documented | Write the supported CI workflow into the current |
| `sol contract generate` | — | `--check` | documented | Generate application peer and event bindings |
| `sol migrate rollback` | — | `--dir=DIR`, `--table=TABLE` | documented | Roll back the last applied migration |
| `sol migrate status` | — | `--dir=DIR`, `--json`, `--table=TABLE` | documented | Show per-file applied/pending status, and drift |
| `sol new event` | TEAM/NAME | — | documented | Add a typed Kafka event contract to the current |
| `sol new fn` | DOMAIN/NAME | `--language=LANGUAGE` | documented | Add a scheduled function to the current workspace |
| `sol new svc` | DOMAIN/NAME | `--language=LANGUAGE` | documented | Add an HTTP service to the current workspace |
| `sol new worker` | DOMAIN/NAME | `--language=LANGUAGE` | documented | Add a Kafka consumer worker to the current workspace |
| `sol new workspace` | NAME | — | documented | Scaffold a new Sol workspace with a working |
| `sol rollback` | RELEASE_ID | `--target=ENV/PROVIDER/REGION` | documented | Restore a recorded release boundary. Refuses on a |
| `sol secret delete` | — | — | documented | Delete an unused Sol-owned unit or platform Job |
| `sol secret set` | — | `--from-file=PATH`, `--from-stdin` | documented | Create or update a Sol-owned unit secret or platform |
| `sol secret status` | — | — | documented | Show secret owners and delivery readiness for a |
<!-- END GENERATED: workspace -->

## Local commands

`sol local …` drives Sol's own local k3s cluster. There is no target and no cloud account.

<!-- BEGIN GENERATED: local -->
| command | positional | flags | exit | purpose |
|---|---|---|---|---|
| `sol local deploy` | — | `--confirm-group-change`, `--dry-run`, `--keep-releases=N`, `--scope=DOMAIN[/UNIT]`, `--tag=TAG` | documented | Build images, synthesize k8s manifests, and deploy |
| `sol local down` | — | — | documented | Stop Sol's local port-forwards. The k3d cluster and |
| `sol local migrate` | — | `--dir=DIR`, `--dry-run`, `--table=TABLE` | documented | Apply migrations against the local cluster's |
| `sol local releases` | — | — | documented | List the release records Sol's local cluster |
| `sol local rollback` | RELEASE_ID | — | documented | Restore a recorded release boundary on the local |
| `sol local run` | — | `-C`, `--scope=DOMAIN[/UNIT]` | documented | Run workspace services as native processes, with |
<!-- END GENERATED: local -->

## Sources of truth

- The registration itself: `cli/bin/` — `main.ml` for the groups, and each `cmd_*.ml` for its
  command and flags. The guard reads the built binary, so the reference cannot drift from it.
- The axis rule: `DEC-031` and `DEC-032`.
- The scope grammar and its deliberate exceptions: `AGENTS.md` § *Core design principles*.
