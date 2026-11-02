# PRD: resource inventory for Sol-provisioned targets

**Status:** Implemented in PR #1911 (2026-11-02); see §18 for the actual surface and limitations.
**Date:** 2026-11-01
**Related:** [#1119](https://github.com/sol-fab/sol/issues/1119),
[#1605](https://github.com/sol-fab/sol/issues/1605),
[ADR 0003](../adr/0003-lifecycle-phases-authority-and-policy.md),
[ADR 0005](../adr/0005-sol-owns-only-its-contract-boundary.md),
[resource ownership](../ownership.md),
[partial-state recovery](../../guides/partial-state-recovery.md)

## 1. Summary

Add a read-only, target-scoped resource inventory:

```sh
sol resources <target>
sol resources <target> --json
```

The command answers one question: **what does Sol record as owned for this target, what does the provider actually hold, and which differences are safe to act on?** It joins the three authorities Sol already has:

1. **Recorded ownership** — Terraform state for the installation, cloud, platform and authorization roots, plus direct serverless release records where they exist.
2. **Observed reality** — the provider inventories that already back `sol target reconcile` and `sol destroy`.
3. **Operation history** — the supervised Terraform operation record and `errored.tfstate` presence, so a timed-out or partial apply is visible rather than inferred.

The inventory is a **display and classification** feature. It never imports, deletes, unlocks, or adopts anything. Adoption stays where it already is: `sol target reconcile`.

The important design constraint is that “observed” is not “owned”. A resource the provider holds is reported as *unrecorded* until Terraform state (or, for direct serverless, the adapter's release record; for Kubernetes, the live UID match) proves Sol owns it. That is what makes the command useful after a timed-out apply while keeping observation and ownership distinct. It relies on the bounded recovery exception already implemented by `sol target reconcile`; §10 asks the review to record that exception explicitly, because ADR 0005's wording does not name it.

The review decisions are recorded in §15: `sol resources <target>`, all four Terraform roots, live-by-default, strict 0/1 success, `errored.tfstate` presence only, and partial results as display-only. The remaining narrow question is the required-class list for M1 versus M2.

## 2. Problem

### 2.1 The operator cannot see the whole picture

Today the information exists but is split across surfaces:

| Surface | What it answers | What it does not answer |
|---|---|---|
| `sol plan <target>` | Intended changes (infrastructure, authorization, workload intent), including live readiness/drift reads | The complete recorded/observed resource set and ownership classification |
| `sol target show --target <target> --check` | Target identity, installation status, drift summary, substrate contract | Which resources exist, and which are unowned |
| `sol target reconcile <target> --explain` | Provider resources that Terraform does not own, and what can be adopted | The complete set of resources Terraform owns (it reports only observed ones), resources missing from the provider, durable/installation resources, or a complete inventory |
| `terraform state list` / provider console | Raw state or raw provider resources | Sol attribution, ownership classification, redaction, or a reconciliation verdict |
| `sol releases` / release records | Application releases | Cloud substrate and installation resources |

An operator diagnosing a failed deployment has to combine all of these and still may not know whether a resource was created by the interrupted operation.

### 2.2 The timed-out-apply case is the motivating case

Terraform can return an error, or be killed, after a provider has created a resource but before Terraform records it. The provider then holds an object that Terraform state does not own, so a state-driven destroy cannot reach it. The repository already handles the important parts of this:

- `Sol_cli_supervised` records a Terraform operation as `Unresolved` when it was killed or did not finish its own shutdown.
- `Sol_cli_state_guard` refuses the next constructive apply while `errored.tfstate` exists or the previous operation is unresolved.
- `sol target reconcile` observes the provider independently, maps attributable resources to Terraform addresses through the identity registry, and imports the recoverable ones. It runs automatically before apply and destroy.
- `sol destroy` independently verifies absence and fails closed on unknown observations.

The gap is **visibility before and around reconciliation**. `sol target reconcile` reports only the provider resources its observation surfaced and their dispositions; it does not enumerate the state. It does not show:

- the complete set of recorded resources, including ones the observation did not surface (unobserved classes, addresses with no registry entry),
- the resources that are recorded but no longer present (or unreadable),
- resources in the installation root (state bucket, lock table, identities, DNS),
- resources in the platform and authorization roots,
- resources that are present and attributable but cannot be recovered because their class has no registry entry (the GKE-managed children in [#1605](https://github.com/sol-fab/sol/issues/1605)),
- which resource classes were not independently observed at all.

[#1605](https://github.com/sol-fab/sol/issues/1605) explicitly decided that the product needs an **operator-visible enumeration** for the unrecoverable case, not a one-off runbook. This command is that affordance.

### 2.3 “What has Sol provisioned?” has no single answer

A target can contain resources from four Terraform roots, direct serverless release records, and Kubernetes workload release records. No current command presents them in one place, with a common status vocabulary and a common safety rule.

This is also a natural extension of the plan/status surface: `sol plan` already resolves the target, the roots, the provider identity and the declared boundary. The inventory reuses that resolution but reports **recorded and observed reality**, not desired changes.

## 3. Users and jobs

| User | Job |
|---|---|
| Operator after a failed or timed-out apply | See what the provider created, what state recorded, and what to do next |
| Operator before `sol destroy` | Review every resource the target records, including retained/durable ones, before authorizing removal |
| Operator diagnosing drift | See which resources are recorded, missing, unowned, or unobservable |
| CI / qualification | Consume a stable, secret-free JSON inventory in live mode to assert presence or absence; `--state-only` is explicitly not a presence/absence gate |
| Maintainer | Get one place to add a new provider class, with visible coverage gaps |

## 4. Goals and non-goals

### Goals

1. **One read-only command** for a target’s resource inventory, with human-readable and JSON output.
2. **Complete within Sol’s boundary** — every resource represented in a target’s Sol-owned Terraform roots, plus the direct serverless records when that adapter lands (§11.4). It is not a general account scanner.
3. **Three-way classification** — recorded, observed, and unknown are distinct. “Observed” never becomes “owned” without a record.
4. **Partial-apply visibility** — surface the supervised operation state, `errored.tfstate`, state-only resources, and provider-only resources in the same view.
5. **Actionable, not destructive** — each row says whether to do nothing, adopt through `sol target reconcile`, investigate, or use `sol uninstall`; the command itself mutates nothing.
6. **Reuse, don’t duplicate** — the provider observations, identity registry, reconciliation dispositions, state parser, and coverage checks remain the single implementation. `sol target reconcile` and the new command consume the same read-only core.
7. **Fail closed and secret-free** — unreadable observations are `unknown`, never absent; sensitive values never leave the state/release record.
8. **Two honest completeness axes** — every run says whether inventory and verification are complete. `reconciled`/exit `0` requires both; a coverage gap is `incomplete`, never a clean result.

### Non-goals

- A general inventory of the AWS account or GCP project. Resources outside Sol’s declared roots are not discovered or reported ([ADR 0005](../adr/0005-sol-owns-only-its-contract-boundary.md)).
- Cost or billing reporting.
- Real-time watching or a daemon.
- Mutating, importing, adopting, repairing, or deleting anything. That remains `sol target reconcile`, `sol deploy`, `sol destroy`, and `sol uninstall`.
- Replacing Terraform state or the provider console as authorities.
- Kubernetes object-level diffing in the first version. Release records already answer “which workloads are live”; the inventory summarizes them later.
- A second persisted inventory database. State and release records remain the records; the command is a projection.

## 5. Existing machinery this builds on

This is not a greenfield feature. The relevant pieces already exist and should be composed:

| Existing mechanism | Role in the inventory |
|---|---|
| `Sol_cli_cloud_destroy.inventory_of_show_json` | Reads `terraform show -json` recursively into `resource` records (address, kind, selected attributes) |
| `Sol_cli_provider_registry.observations` | Dispatches to the AWS/GCP independent inventories |
| `Sol_cli_aws_absence` / `Sol_cli_gcp_absence` | Enumerate target-owned classes as `Absent` / `Present` / `External` / `Not_attributable` / `Unobservable` |
| `Sol_cli_resource_identity` | Maps a provider class + observed name to a Terraform address and import identity, with an ownership kind |
| `Sol_cli_ownership_reconciliation` | Turns observations + state addresses into `Recover` / `Already_owned` / `By_contract` / `Cannot_recover` / `Unmapped` / `Unresolved` |
| `Sol_cli_cloud_wiring.reconcile_ownership` | Reads state, observes the provider, computes dispositions, optionally imports |
| `Sol_cli_terraform.previous_operation` / `Sol_cli_supervised` | Per-root operation status and unresolved/errored state |
| `Sol_cli_installation` | Durable installation configuration (state bucket, identities, zone, project) |
| `Sol_cli_serverless_inventory` / release records | Maps target/service to a release-record path; loading the record yields the provider identities |
| `Sol_cli_release_id.owned_object` | Kubernetes object identity captured at apply |
| `test_inventory_coverage.ml` / `check_destroy_completeness.py` | Existing guarantees that every required class has an executable probe and every native resource has an ownership story |

Placement matters for the dependency direction: `Sol_cli_absence`, `Sol_cli_serverless_inventory` and `Sol_cli_release_id` live in `cli/lib/base`; the wiring, reconciliation and provider modules live in `cli/lib/cloud`.

The implementation should extract the read-only core of `reconcile_ownership` rather than reimplement it. Two callers must not answer “which provider resources exist and what is their disposition?” with two different inventories.

## 6. Proposed product surface

### 6.1 Command

Working name:

```sh
sol resources <target>
```

`<target>` uses the same positional path as `sol plan`, `sol deploy`, and `sol target reconcile` (`<env>/<provider>/<region>`).

Alternatives are discussed in §13. The name is deliberately a decision for review; the model and behavior matter more than the word.

### 6.2 Flags

| Flag | Behavior |
|---|---|
| `--json` | Stable JSON schema (§8). Never includes sensitive values. |
| `--state-only` | Read Terraform state and release records only; no independent provider probes. The state backend still requires credentials and network; this is not an offline mode. Always yields `verdict: unverified` and exit `1`; it cannot establish presence or absence. |
| `--all` | Include `in_cluster`, `synthetic`, and absent classes that the default view summarizes. |
| `--class=CLASS` | Filter by resource class (repeatable). |
| `--status=STATUS` | Filter by inventory status (repeatable). |
| `--explain` | Add the evidence for each row: state address, observed identity, import identity, attribution rule, probe/command, reason. |
| `--verbose` | Show provider identities and root details that are normally condensed. |

_Implementation note:_ `sol resources` does not take `--var`/`--var-file`; reading state and observing the provider does not evaluate the root configuration, and those flags would not change the result.

There is intentionally **no** `--reconcile`, `--import`, `--delete`, or `--fix`. The output points to the existing command.

### 6.3 Default behavior

By default the command:

1. Resolves the target and its Sol-owned roots.
2. Reads each root’s Terraform state and operation status.
3. Runs the existing provider observations for the classes in scope.
4. Computes a single resource list and verdict.
5. Prints a summary and the material rows, then a next action.
6. Exits without changing anything.

`--state-only` is the explicit no-provider-probe mode; it is **not** an offline mode, because the state backend is remote and `terraform show` still needs its credentials and network. It always yields `verdict: unverified` and exit `1`, and must not be used as a presence/absence gate. The default live mode is what makes the command useful after a partial apply; the cost is provider calls, which the existing reconcile path already performs.

### 6.4 Human output (illustrative)

```text
Target   prod/aws/us-east-1
Roots    installation 4 recorded · cloud 23 recorded · platform 41 in-cluster · authorization 8 recorded
State    installation readable · cloud readable · platform readable · authorization readable
Last op  cloud: unresolved — terraform was killed after starting apply (2026-11-01T18:22:41Z)
Verdict  attention_required — 1 unrecorded, 1 missing; verification incomplete: IAM role unobserved

LAYER          STATUS       CLASS                 NAME                  ACTION
cloud          owned        EKS cluster           sol-prod              none
cloud          owned        RDS instance          sol-prod-postgres     none
cloud          unrecorded   EKS node group        sol-prod-nodes        adopt
cloud          missing      security group        sol-prod-nodes        investigate
authorization  recorded     IAM role              sol-prod-deploy       none (unverified)
installation   external     S3 state bucket       sol-prod-tfstate      retain

Summary  23 owned · 1 unrecorded (recoverable) · 1 missing · 0 unknown
         1 recorded class (IAM role) has no independent probe; verification incomplete.
Next     sol target reconcile prod/aws/us-east-1 --dry-run --explain
```

The exact columns are a review detail. The important properties are:

- **The root/layer is always visible** — installation, cloud, platform, authorization, serverless, workload.
- **Status is a word, not a color** — usable in logs and CI.
- **`ACTION` never overstates authority** — `adopt` means run reconcile; `retain` means use `sol uninstall`; `investigate` means Sol will not guess.
- **Unverified coverage is printed** — the operator is not left to assume every recorded resource was independently checked.

### 6.5 Exit status and the meaning of success

The command follows `sol target reconcile`'s 0/1 convention, but **exit `0` has a strict meaning**: the inventory is complete and independently verified, and no discrepancy remains.

| Exit | Meaning |
|---|---|
| `0` | `verdict: reconciled`: every declared root's state/release record was read successfully, every required class was independently observed, and there is no `unrecorded` or `missing` status, no `uid_mismatch`, and no `unrecoverable`/`unmapped` recovery disposition. |
| `1` | Any other verdict: `attention_required`, `incomplete`, `unknown`, or `unverified`. The JSON `verdict`, `coverage`, and `unknowns` distinguish a confirmed discrepancy from missing evidence. |

This is deliberately stricter than “no known discrepancy was found”. A run that lacks evidence of a problem is **not** exit `0`; it is `incomplete` and exit `1`. In particular:

- A `recorded` resource whose class has no executable probe makes verification incomplete, unless the registry classifies it `In_cluster`, `Synthetic`, or `External_by_contract` (no independent provider identity exists by contract).
- `--state-only` always exits `1` with `verdict: unverified`; it is a recorded view, not a presence/absence verdict. No CI gate that asserts presence or absence may use `--state-only`.
- An unreadable root or a failed required observation is `verdict: unknown`, never `reconciled` and never absence.

The JSON contract carries `coverage.inventory.complete` and `coverage.verification.complete` so a consumer can tell which axis failed. Formally:

```text
reconciled          = inventory.complete && verification.complete && no discrepancy
incomplete          = inventory.complete && !verification.complete && no discrepancy && !state_only
unverified          = --state-only
attention_required  = inventory.complete && no failed required observation && confirmed discrepancy
unknown             = !inventory.complete || a required observation failed
```

`attention_required` outranks `incomplete` because a confirmed discrepancy is actionable even when other classes are unverified; both exit `1`, and the JSON carries both axes. A failed read outranks both because it means the inventory itself is incomplete. `--state-only` forces `unverified` even though verification is incomplete; it is an explicit mode, not a coverage verdict. In implementation, `unverified` is evaluated before `attention_required`, so a state-only run can never be mistaken for a live discrepancy report.

## 7. Resource model

### 7.1 Status vocabulary

The model is a projection of existing `Sol_cli_absence.observation`, `Sol_cli_cloud_destroy.state_read`, and `Sol_cli_ownership_reconciliation.disposition`. It does not introduce a second ownership rule.

| Recorded? | Provider/ownership evidence | Status | Meaning |
|---|---|---|---|
| Yes | `Present` at the same identity | `owned` | The provider holds what the record owns (requires a class the inventory maps to that address) |
| Yes | `Absent` (positive absence for a registry-mapped identity) | `missing` | Recorded, and a successful provider read for its class says it is gone |
| Yes | `Unobservable` / no probe | `unknown` (if a read failed) or the recorded/by-contract status (`recorded`, `external`, `in_cluster`, `synthetic`) | Not verified; never “absent” |
| No | `Present`, exact registry match | `unrecorded` | Recovery is `recoverable`; `sol target reconcile` can adopt it |
| No | `Present`, no registry entry | `unrecorded` | Recovery is `unmapped`; Sol will not guess and the operator gets the enumeration |
| No | `Present`, registry says not recoverable | `unrecorded` | Recovery is `unrecoverable`; composite/controller-created/ambiguous, handled through its owner |
| Yes (or declared) | `External` | `external` | Durable or external by contract (state backend, delegated DNS); recorded by Sol, but not target residue |
| Yes | `In_cluster` / `Synthetic` ownership kind | `in_cluster` / `synthetic` | Terraform declares it, but it has no separate provider identity |
| Workload record | Live `metadata.uid` matches / differs | `owned` / `uid_mismatch` | The release record plus live UID proof; a record alone is not ownership |
| No | `Absent` | `absent` | A class the inventory checks and the provider reports absent; not a resource row, shown with `--all` for coverage |
| Unreadable | Any | `unknown` | No completeness claim |

`status` and `recovery` are separate concepts. `status` says what the inventory knows about the resource; `recovery` says whether Sol can restore Terraform ownership of an observed object. A resource can be observed accurately while its recovery is `unrecoverable` or `unmapped`; the JSON must preserve both (§8).

Two rules are non-negotiable:

1. **`missing` requires a positive provider absence.** A failed, timed-out, or unreadable provider read is `unknown`.
2. **`unrecorded` is not “provisioned by Sol”.** The row says the provider holds it and Sol has no record of owning it. Only `sol target reconcile` (or an explicit adopted record) changes that.

Rows are deduplicated by record identity: an address that is both recorded and observed is one `owned` row, not a state row plus a provider row. A provider object that maps to a recorded address joins that row; one that maps to no address is its own `unrecorded` row.

`missing` is not a `dispositions` value today (`Sol_cli_ownership_reconciliation` iterates `Present`/`Unobservable` and says nothing about a state address). The inventory must compute it as an explicit join: **state address → registry entry with an exact `observed_as` → that class's successful `Absent` observation**. A state resource with no registry entry is `recorded`/unverified, never `missing`; a class-level absence with a wildcard identity does not make every state address `missing`. This join belongs in the inventory module, not in a second provider inventory.

Kubernetes workload rows are a separate ownership domain. A release record is not ownership proof: a workload is `owned` only when the live object's `metadata.uid` equals the UID captured at apply (`Sol_cli_release_id.owned_object` and `Sol_cli_workload_ownership.owns`). Without a live read it is `recorded`; a UID mismatch is `uid_mismatch`/unowned, never `owned`. This rule applies before M4, not after it.

### 7.2 Row shape

```ocaml
type layer =
  | Installation
  | Cloud
  | Platform
  | Authorization
  | Serverless
  | Workload

type record_presence =
  | In_record
  | Not_recorded
  | Record_unreadable of string

type provider_presence =
  | Observed
  | Provider_absent
  | Unobservable of string
  | Not_checked

type status =
  | Owned
  | Recorded
  | Missing
  | Unrecorded
  | External
  | In_cluster
  | Synthetic
  | Uid_mismatch of string
  | Absent
  | Unknown of string

type recovery =
  | Not_applicable
  | Recoverable of { address : string; import_identity : string }
  | Unrecoverable of string
  | Unmapped of string

type observation_coverage =
  | Observed
  | Unobserved
  | By_contract
  | Failed of string

type action =
  | No_action
  | Adopt
  | Investigate
  | Retain
  | Uninstall

type row =
  { layer : layer
  ; root : string
  ; address : string option
  ; resource_class : string
  ; name : string option
  ; identity : string option
  ; observed_as : string option
  ; ownership_kind : string option
  ; uid : string option
  ; uid_status : [ `Match | `Mismatch | `No_record | `Not_applicable ]
  ; import_identity : string option
  ; status : status
  ; recovery : recovery
  ; observation : observation_coverage
  ; action : action
  ; reason : string option
  ; checked_with : string option
  ; lifetime : [ `Installation | `Target | `Workload ]
  ; deletion_protection : bool option
  }
```

`Not_checked` is an inventory-only provider-presence projection for a class with no executable probe. It is not an observation and must never be read as absence. `observation` is the coverage axis: `Observed` means an independent probe ran and succeeded; `Unobserved` means no probe ran; `By_contract` means no provider identity exists by contract; `Failed` means the probe ran and failed (unknown, not absent). `ownership_kind` carries the existing registry kind (`Direct`, `Direct_not_recoverable`, `In_cluster`, `Synthetic`, `External_by_contract`); the renderer must not recompute it from names. `Absent` is a class-level coverage row (no address/name) shown only with `--all`; it is not a resource row.

The implementation must preserve the distinction described above: a state record is not `owned` unless the provider was actually checked at the same identity. The names should follow the existing `Sol_cli_absence` vocabulary where possible.

### 7.3 Root and coverage model

Each root is reported separately because its state, operation record, credentials and lifetime differ:

| Layer | Root | Records | Provider verification in v1 |
|---|---|---|---|
| Installation | `Bootstrap` (`bootstrap/<provider>/default.tfstate`) | state bucket, lock table, identities, DNS (installation-wide) | reuse installation probes; state always shown |
| Cloud | `Cluster` (`sol/<target>/cloud.tfstate`) | network, cluster, database, registry, secrets, DNS records | full existing inventory |
| Platform | `Platform` (`sol/<target>/platform.tfstate`) | Kubernetes/Helm objects | summarize `in_cluster`/`synthetic`; no independent provider identity |
| Authorization | `Authorization` (`sol/<target>/authorization.tfstate`) | IAM roles/policies, service accounts, bindings | recorded + the existing authorization probes; thread the existing authorization identities into the new core |
| Serverless | release records | Cloud Run, Lambda, SQS/Pub/Sub task resources | phase 2 |
| Workload | release records / `sol releases` | Kubernetes workload objects | phase 2/3 |

This table is also the **coverage disclosure**. A root or class that is not independently observed is labelled `recorded`/`unverified`, not `owned`.

The inventory reports **two independent completeness axes**, because “I read every record” and “I verified every resource” are different claims:

| Axis | Complete when | Incomplete when | JSON |
|---|---|---|---|
| Inventory | Every declared root's state/release record is `empty` or `represented` | Any root is `unreadable`, or a release record cannot be read | `coverage.inventory.complete` |
| Verification | Every required class is `Observed` or `By_contract` | Any required class is `Unobserved` or `Failed` | `coverage.verification.complete` |

A class is `By_contract` when the registry says it has no independent provider identity (`In_cluster`, `Synthetic`, `External_by_contract`); that is not a coverage gap. A class with no executable probe and no by-contract ownership kind is `Unobserved` and makes verification incomplete. A probe that ran and failed is `Failed` and makes the verdict `unknown`, never absence.

The initial four-root scope does not pretend that every platform/authorization class is independently observed. Platform in-cluster/synthetic objects are `By_contract`; authorization classes are `Unobserved` until M2 threads the existing identities. Any required class that is unobserved makes the verdict `incomplete`; the coverage block names it. A missing observation must never silently disappear: an expectable class that is not in the executable probe set appears in `coverage.verification.unobserved_classes`, and an acceptance test asserts that removing it from the output fails.

Provider observation is attributed by the target's `cluster_name`, project and region, exactly as `sol target reconcile` does today. A target without a usable `cluster_name` can still show its recorded state, but its provider checks must be `unknown`/`unobserved`, not `absent`; `sol target reconcile` already refuses that case rather than guessing.

The installation/bootstrap root is **provider-scoped, not target-scoped**: `bootstrap/<provider>/default.tfstate` is shared by every target that uses the same state bucket. Its rows are installation-wide and must not be counted as this target's residue; `sol uninstall` owns them.

Authorization probes already run in every `observations` call, and the identities are already produced by `Sol_cli_provider_registry.authorization_state_identities`. The missing piece is that `reconcile_ownership` never passes `~authorization_identities`; with the default `[]`, `filter_to_prior` reduces every `Present` authorization observation to `Absent`, which `dispositions` drops. `collect_ownership` must pass the existing identities through. That is one argument in the new core, not a new provider adapter or a later milestone; fold it into M2.

## 8. JSON contract

```json
{
  "schema": 1,
  "target": "prod/aws/us-east-1",
  "generated_at": "2026-11-01T18:30:00Z",
  "verdict": "attention_required",
  "coverage": {
    "inventory": {
      "complete": true,
      "roots": [
        { "layer": "installation", "root": "bootstrap", "state": "represented" },
        { "layer": "cloud", "root": "cluster", "state": "represented" },
        { "layer": "platform", "root": "platform", "state": "represented" },
        { "layer": "authorization", "root": "authorization", "state": "represented" }
      ]
    },
    "verification": {
      "complete": false,
      "required_classes": ["EKS cluster", "RDS instance", "EKS node group", "IAM role"],
      "observed_classes": ["EKS cluster", "RDS instance", "EKS node group"],
      "by_contract_classes": ["S3 state bucket"],
      "unobserved_classes": ["IAM role"],
      "failed_classes": [],
      "recorded_unverified": []
    }
  },
  "roots": [
    {
      "layer": "cloud",
      "root": "cluster",
      "durable": false,
      "state": "represented",
      "recorded": 23,
      "observed": 20,
      "unobserved": 3,
      "failed": 0,
      "last_operation": {
        "status": "unresolved",
        "reason": "terraform was killed after starting apply",
        "started_at": "2026-11-01T18:22:41Z"
      },
      "errored_state": "present"
    }
  ],
  "resources": [
    {
      "layer": "cloud",
      "root": "cluster",
      "address": "aws_eks_cluster.main",
      "resource_class": "EKS cluster",
      "name": "sol-prod",
      "status": "owned",
      "status_reason": null,
      "observation": "observed",
      "recovery": { "disposition": "not_applicable" },
      "action": "none",
      "record": "present",
      "provider": "present"
    },
    {
      "layer": "cloud",
      "root": "cluster",
      "resource_class": "EKS node group",
      "name": "sol-prod-nodes",
      "status": "unrecorded",
      "status_reason": null,
      "observation": "observed",
      "recovery": {
        "disposition": "recoverable",
        "address": "aws_eks_node_group.main",
        "import_identity": "sol-prod:sol-prod-nodes"
      },
      "action": "adopt",
      "record": "not_recorded",
      "provider": "present",
      "reason": "provider object maps exactly to this target's Terraform address"
    }
  ],
  "summary": {
    "owned": 23,
    "recorded": 3,
    "unrecorded": 1,
    "missing": 0,
    "uid_mismatch": 0,
    "unknown": 0,
    "external": 4,
    "in_cluster": 41,
    "synthetic": 6
  },
  "unknowns": []
}
```

Rules for the JSON contract:

- `schema` is an integer; adding fields is allowed, changing meaning requires a new schema.
- No secret values, database URLs, tokens, passwords, or raw `sensitive_values`.
- `coverage.inventory.complete` is true only when every declared root's state/release record is `empty` or `represented`; any `unreadable` root makes it false.
- `coverage.verification.complete` is true only when every required class is `observed` or `by_contract`, every recorded row is verified, and no observation failed. `unobserved`, `failed`, or `recorded_unverified` makes it false. `by_contract` classes have no independent provider identity and are not a coverage gap.
- `unknowns` carries every unreadable state/root and every failed observation with its reason, separately from confirmed resources. `coverage.verification.failed_classes` names the failed probes; `coverage.verification.recorded_unverified` lists recorded addresses/classes the inventory could not verify.
- `roots[].errored_state` is read from the root directory (`errored.tfstate` existence), not from `Sol_cli_terraform.previous_operation`, which returns the supervised status only.
- `verdict` is one of `reconciled`, `incomplete`, `attention_required`, `unknown`, `unverified`, with this precedence: `unknown` → `unverified` → `attention_required` → `incomplete` → `reconciled`. `unverified` is the explicit `--state-only` mode and outranks `incomplete` so a state-only run cannot be mistaken for a live incomplete run; a live run never produces it.
  - `unknown`: inventory incomplete (a root/record could not be read) or a required observation failed.
  - `attention_required`: a confirmed discrepancy — any `unrecorded` row (with `recoverable`, `unrecoverable` or `unmapped` recovery), `missing`, or `uid_mismatch`.
  - `unverified`: `--state-only`.
  - `incomplete`: live mode, inventory complete, verification incomplete, and no confirmed discrepancy.
  - `reconciled`: inventory complete, verification complete, and no confirmed discrepancy.
- `recovery` is `not_applicable`, `recoverable`, `unrecoverable`, or `unmapped`. `recoverable` carries `address` and `import_identity`; `unrecoverable`/`unmapped` carry `reason`.
- JSON spellings are fixed: `record` is `present` / `not_recorded` / `unreadable`; `provider` is `present` / `absent` / `unobservable` / `not_checked`; `observation` is `observed` / `unobserved` / `by_contract` / `failed`; `roots[].state` is `empty` / `represented` / `unreadable`; `status` is `owned` / `recorded` / `missing` / `unrecorded` / `external` / `in_cluster` / `synthetic` / `uid_mismatch` / `absent` / `unknown`; `status_reason` is a string for `unknown`/`uid_mismatch` and null otherwise; `verdict` is the five values above. A variant that is not listed is not serialized.
- Rows are stable-sorted by layer, class, address/name so diffs are reviewable.

## 9. The timed-out / partial-apply path

This sequence is the acceptance case.

1. `sol deploy` starts a Terraform apply. A provider creates a resource (for example, a Cloud SQL instance), then the provider wait returns an error or Terraform is killed.
2. `Sol_cli_supervised` records the operation as `Unresolved` (or records an exit outcome with `errored.tfstate` present).
3. `sol resources <target>` reports, per root:
   - the operation status and whether `errored.tfstate` exists;
   - the state addresses it can read;
   - the provider objects it observes.
4. A provider object absent from state is shown as `unrecorded`:
   - `recoverable` when the identity registry maps it exactly to a direct Terraform address (the Cloud SQL parent case);
   - `unrecoverable`/`unmapped` when it is a controller-created child or has no registry entry (the GKE-managed children in #1605), with the observed identity and the reason.
5. The command prints the next action:
   - `sol target reconcile <target> --dry-run --explain` for recoverable resources;
   - `--explain` output for unrecoverable resources, so the operator has the enumeration #1605 requires;
   - `sol plan` or `sol deploy` only after reconciliation, never instead of it.
6. The inventory does not import anything. `sol target reconcile` remains the only path that restores Terraform ownership.
7. After a successful reconcile, re-running `sol resources` shows the resource as `owned`, and the ordinary destroy path can act on it.

### 9.1 What “timed out” covers

The implementation must handle all of these without collapsing them into one message:

| Condition | Evidence | Display |
|---|---|---|
| Process killed / suspended | `Sol_cli_supervised` `Unresolved` | root `last_operation: unresolved`; state may be incomplete |
| Terraform exited non-zero without `errored.tfstate` | supervised `Resolved (Exited N)` | root `last_operation: resolved (exit N)`; state may be partially updated |
| Terraform exited non-zero after failing to persist state | supervised `Unresolved` (the classifier folds an errored exit into `Unresolved`) plus `errored.tfstate` | root `last_operation: unresolved`; `errored_state: present` |
| State lock held by a running operation | `Running` status | `in_progress`; do not advise apply/destroy; do not unlock |
| State readable, provider readable | `state_read` + observations | full matrix |
| State readable, provider class unreadable | `Unobservable` | `unknown` for that class |
| State unreadable | `State_unreadable` | `unknown` for the root; provider-only rows may still be shown |
| Provider create succeeded but state not written | observed `Present`, state `Absent` | `unrecorded`; no “Sol provisioned” claim |

`Sol_cli_terraform.previous_operation` returns the supervised status only. `errored_state` is a separate fact read from the root directory (`errored.tfstate` existence), as `Sol_cli_state_guard` does; the inventory must not infer it from the status. `last_operation`, `errored_state`, and `state` are three independent facts: the file’s presence does not establish authority, and its absence does not prove the operation succeeded.

The command must not read `errored.tfstate` as current state. It reports the file’s presence and lets the existing state guard/operator procedure handle it. Parsing it by default would create a second state authority and risk exposing secrets. v1 must not parse or use its contents as ownership evidence; a future parsing feature is a separate design decision with explicit provenance, redaction and conflict-resolution rules.

### 9.2 What the inventory does not claim

It does not claim a resource is absent because a class has no probe: an uncovered class is `recorded`/unverified and disclosed in `coverage`. It does not claim completeness when a required root or class is unreadable; blockers force `verdict: unknown` and are listed in `unknowns`. An unobserved required class makes verification incomplete (`verdict: incomplete`); a confirmed discrepancy makes `verdict: attention_required`; both exit `1`. A successful empty read for a covered class is the only basis for `absent` or `missing`. `--state-only` never establishes presence or absence; it reports `verdict: unverified` and exits `1`.

## 10. Scope and boundary

The command reports only resources Sol’s contracts place in its boundary. “In boundary” means:

- represented in a target’s Sol-owned Terraform root, or
- recorded in a Sol release record for a target (and, for Kubernetes, matched by live UID before it is called owned), or
- a durable installation resource Sol created or adopted by declaration (`dns_zone_ownership: sol`, state backend, identities).

It does **not** enumerate arbitrary AWS/GCP resources, import ambient infrastructure, or treat a name/label/creation time as ownership. This is the same boundary as [ADR 0005](../adr/0005-sol-owns-only-its-contract-boundary.md) and [`ownership.md`](../ownership.md). A user-owned bucket, VPC, database or DNS zone is not reported merely because a Sol workload uses it.

There is one explicit tension. `sol target reconcile` already restores Terraform ownership of unrecorded provider objects that the identity registry attributes exactly to a Sol target. That is bounded recovery of Sol's own stale state ([#1119](https://github.com/sol-fab/sol/issues/1119)), not ambient external discovery, but ADR 0005's sentence “the only adoption is a declaratively-owned resource Sol must not duplicate” does not name it. This PRD relies on the existing exception. Resolution: if accepted, record the exception in ADR 0005 (or a short new ADR) before implementation relies on it; until then, the inventory reports `unrecorded` read-only and does not add recovery authority. The recommendation is to record it.

The output should say “Sol-owned boundary” explicitly, so an operator does not read the inventory as an account audit.

## 11. Architecture and implementation plan

### 11.1 New module

Add `Sol_cli_resource_inventory` (name illustrative) in `cli/lib/cloud`. It depends only on existing cloud/base modules:

- `Sol_cli_terraform` and `Sol_cli_cloud_destroy` for state reads;
- `Sol_cli_provider_registry` for observations and identity entries;
- `Sol_cli_ownership_reconciliation` for dispositions;
- `Sol_cli_absence` for the observation vocabulary;
- `Sol_cli_supervised` for operation status.

It must not depend on `sol_cli_deploy`. Direct serverless/workload rows can be passed in by the CLI command from base/deploy readers in a later milestone, preserving the dependency direction in [`docs/architecture/execution-boundaries.md`](../execution-boundaries.md).

### 11.2 Refactor the read-only core

`Sol_cli_cloud_wiring.reconcile_ownership` currently does state read + observations + dispositions + optional adoption in one function, and returns a single `Error` on any state or identity failure. Extract the read-only part into a **partial** collection:

```text
type root_read =
  | Read_empty
  | Read_represented
  | Read_unreadable of string

type class_observation =
  | Observed
  | Unobserved
  | By_contract
  | Failed of string

type collection =
  { roots : root_inventory list          (* each carries root_read *)
  ; observations : Sol_cli_absence.observation list
  ; dispositions : Sol_cli_ownership_reconciliation.disposition list
  ; inventory_complete : bool
  ; verification_complete : bool
  ; blockers : string list
  }

val collect_ownership
  :  provider:Sol_cli_provider.t
  -> target_cfg:Sol_cli_config.target
  -> cluster_name:string option
  -> roots:root_descriptor list      (* chdir + exact backend_config *)
  -> var_files:string list
  -> vars:string list
  -> collection
```

The partial shape is what lets the inventory show data while `sol target reconcile` stays fail-closed:

- **Empty is not unreadable.** `Read_empty` is a successful read with no resources. `Read_unreadable` is a blocker and becomes `unknown`, never an empty resource list. A failed observation is `Failed`, never `Absent`.
- **Inventory completeness** is false if any declared root is `Read_unreadable` or a release record cannot be read. **Verification completeness** is false if any required class is `Unobserved` or `Failed`; `By_contract` classes are not a gap.
- A per-root state read failure, a cluster-name mismatch, an unnamed/ambiguous cluster, or an absent `cluster_name` becomes a **blocker plus an `unknown`/`unobserved` projection**, not an early `Error`.
- `reconcile_ownership` calls `collect_ownership` and retains today’s fail-closed checks: `Error` on state/identity blockers, the existing `Unresolved`/outstanding verdict for unobservable classes, and the exact same adoption candidates. It does not consume a partial collection as authorization; the collection is display-only. Any tightening of adoption eligibility is a separate behavior change with its own tests.
- `sol resources` calls `collect_ownership` and renders the partial inventory; blockers set `verdict: unknown`, missing verification sets `incomplete`, and either exits `1`.
- `cluster_name` is optional here: without it, state rows are still shown, provider observations are `Unobserved`, and the blocker names why. `sol target reconcile` continues to refuse.

Each root descriptor carries its `chdir` and exact backend config. The operation record key is derived from both (`Sol_cli_terraform.operation_key`); the inventory must use the same key or it will read `No_previous` incorrectly.

`reconcile_ownership` becomes `collect_ownership` + the existing adoption loop. `sol target reconcile` keeps its current output, exit status, and adoption set exactly. `sol resources` calls `collect_ownership` with no adoption.

This is the main “one decision, one place” requirement: there must not be a second provider inventory, a second identity mapping, or a second disposition computation. Characterization tests for the existing reconcile output, exit status and adoption behavior are a hard acceptance criterion, not optional guidance.

### 11.3 CLI wiring

- New `cli/bin/cmd_resources.ml`, registered in `cli/bin/main.ml`.
- Reuse `Sol_cli_target_arg.positional`, `Sol_cli_terraform_vars`, `Sol_cli_platform_assets` and the existing `workdir`/backend resolution.
- Give the command an `EXIT STATUS` man section stating the 0/1 verdict; the generated CLI table marks a command `documented` only when its help carries that section, not when its codes are checked.
- Update the generated tables in [`docs/reference/cli.md`](../../reference/cli.md) through `internal/tooling/scripts/render-cli-reference.py`, not by hand.
- Add a guide at `docs/guides/resource-inventory.md` (task-oriented) and cross-link from `operations.md` and `partial-state-recovery.md`.

### 11.4 Milestones

| Milestone | Scope | Exit criterion |
|---|---|---|
| M1 | Model, state reads for all four roots, provider observations for cloud/installation, text + JSON | Offline tests; cloud inventory matches existing reconcile dispositions; authorization (and any unprobed platform class) reports `Unobserved`; platform in-cluster/synthetic is `By_contract`; verdict is `incomplete`, never `reconciled`; no behavior change to reconcile |
| M2 | Authorization/platform provider observations (thread the existing authorization identities), per-root operation status, coverage/unknown disclosure | Authorization observations are no longer dropped by `filter_to_prior`; platform/authorization coverage is explicit; a full target can reach `reconciled` only when its required classes are observed |
| M3 | Direct serverless records (Cloud Run, Lambda, tasks) | A target with a deployed Cloud Run service/Lambda function shows its provider identity and release record. The release record is the ownership record; without an independent provider read the row is `recorded`, not `owned`. |
| M4 | Workload summary from release records; docs and qualification | `sol releases`/release UIDs summarized; live read-only evidence recorded |

M1/M2 satisfy the motivating Terraform case. M3/M4 make “what Sol provisioned” complete for the current serverless and workload lifecycles.

## 12. Safety and invariants

1. **Read-only.** No provider mutation, no state write, no `terraform import`, no `state rm`, no lock release, no `errored.tfstate` push.
2. **State is ownership; provider is reality.** Observation never authorizes adoption. Only `sol target reconcile` can import, and only for exact registry matches.
3. **Unknown is not absent.** A failed, denied, timed-out, or malformed read makes the class `unknown`; it never becomes `missing` or `absent`.
4. **No secret leakage.** `inventory_of_show_json` calls `Sol_cli_json.decode_sensitive`, but it also reads the full `values` object; redaction is enforced by that parser's fixed attribute whitelist plus the new renderer, not by the decode call alone. The renderer must never print `values` or `sensitive_values`, and tests must assert no fixture secret appears. Database URLs, passwords, tokens and secret versions are redacted. `--json` has the same rule. Provider and Terraform diagnostics are preserved as emitted, with sensitive values redacted; Sol adds context rather than replacing the error.
5. **No account-wide discovery.** Only declared roots and their provider classes (ADR 0005).
6. **No target-scoped operation database.** Per-root supervised records are read as they exist. `No_previous` is reported as such. A foreign-host in-flight record classifies as `Running`; only `Running` carries a host, so host detail is shown only there. The command must reproduce the lifecycle's `operation_key` (`chdir` plus the exact backend config), or it will read `No_previous` for an operation that exists. This respects [ADR 0003](../adr/0003-lifecycle-phases-authority-and-policy.md) (“the phase record is not infrastructure truth”).
7. **Durable resources are labelled.** Installation state, DNS and the state backend are `external`/`installation` and point at `sol uninstall`, not `sol destroy`. The installation/bootstrap root is provider-scoped and shared by every target using the same state bucket; it is never this target’s residue.
8. **Two completeness axes.** `reconciled` requires both inventory and verification complete. An unobserved required class is `incomplete`, not success; a failed read is `unknown`, not an empty list. The JSON and the text summary must show both axes.
9. **Partial is display-only.** `collect_ownership` never authorizes adoption. `reconcile_ownership` keeps its existing validated dispositions, fail-closed checks and exact adoption set; a partial inventory is not an input to the import path.
10. **Same credentials, no new authority.** The command uses the target’s existing provider identities and does not create keys.

## 13. Alternatives considered

| Alternative | Why not |
|---|---|
| Extend `sol target show --check` | It is already the identity/status summary. Dumping a potentially large inventory into it conflates “is this target healthy?” with “what is recorded?”. It has a target JSON shape but no resource-level model, and would grow flags without a clean boundary. |
| Extend `sol plan` | `sol plan` already performs live readiness/drift reads, so “avoid live reads” is not the reason. It is the **desired-change/apply-preview** surface: a complete inventory would make plan output unbounded and conflate “what will change” with “what exists”. A plan can omit unchanged state resources; the inventory is the actual-state view. |
| Wrap `terraform state list` / `terraform show` | Fast to build, but no provider reality, no attribution, no ownership classification, no redaction, and no reconciliation disposition. It would also expose raw state. |
| Provider console only | The status quo. It cannot tell the operator which objects Sol attributes to the target, or which are adoptable. |
| Persist an inventory database | [ADR 0003](../adr/0003-lifecycle-phases-authority-and-policy.md) rejects phase/state databases; Terraform state and release records are already the records. A cache would go stale exactly when it matters (after a failed apply). |
| A universal resource abstraction across AWS/GCP/Kubernetes | [ADR 0005](../adr/0005-sol-owns-only-its-contract-boundary.md) forbids turning Sol into a general orchestrator. This feature is a projection over existing provider-specific inventories, not a new abstraction. |
| Make `sol resources` adopt by default | Adoption is destructive authority. Keeping it in `sol target reconcile` preserves the existing review/`--dry-run`/`--explain` path and the fail-closed rules. |

## 14. Validation plan

### Acceptance criteria

1. When every required class is independently observed, a clean deployed target yields `verdict: reconciled`, exit `0`, every readable Terraform state resource as `owned` or `recorded`, and no `unrecorded`, `missing`, or `uid_mismatch` rows.
2. After a deliberate interrupted apply, it exits `1` with `verdict: attention_required`, shows the provider-created resource as `unrecorded` with its `recovery` disposition, and names `sol target reconcile` as the next step.
3. `--json` is valid against the documented schema, stable across runs, contains no fixture secret value, and carries both `coverage.inventory.complete` and `coverage.verification.complete`.
4. An unreadable state root or a failed required observation produces `verdict: unknown` and exit `1`; it never produces `missing` or `absent`.
5. A resource recorded in state but positively absent at the provider produces `status: missing` and `verdict: attention_required` with exit `1`, only when its class was actually observed.
6. A target with a recorded but unobserved required class (for example an authorization class before M2) yields `verdict: incomplete`, exit `1`, and names it in `coverage.verification.unobserved_classes`; it is not `reconciled`.
7. `--state-only` yields `verdict: unverified`, exits `1`, and never produces `owned`, `missing`, or `absent`; a CI gate that asserts presence or absence does not use it.
8. `sol target reconcile` output, exit status and adoption behavior are unchanged by the refactor; the partial collection is never passed to adoption; a characterization test covers the current output.
9. Removing a required class from the coverage output makes the inventory `incomplete`/exit `1`; a missing observation cannot silently disappear.
10. An empty state root is a successful read (`state: empty`), not `unknown`; a failed read is `unreadable` and never an empty resource list.

### Offline (ordinary CI)

- Unit matrix: state present/absent/unreadable × observation observed/unobserved/by-contract/failed × recovery recoverable/unrecoverable/unmapped → expected status/recovery/verdict.
- Coverage matrix: `inventory_complete` is false only for unreadable roots; `verification_complete` is false for unobserved/failed required classes; `by_contract` does not make it false.
- `missing` is produced only by a positive `Absent` observation; a `Failed` observation produces `unknown`.
- `unrecorded` + exact registry match produces `recovery: recoverable`; no match produces `unmapped`; ambiguous/not-recoverable produces `unrecoverable`; status remains `unrecorded` in all three.
- Empty root vs unreadable root: only the latter produces `unknown`, and never an empty list.
- A partial collection is never passed to the adoption loop. A blocker causes no import; a fixture asserts that reconcile uses its existing validated dispositions, not the inventory's partial view.
- A fixture with an unresolved supervised operation and `errored.tfstate` shows both and recommends reconcile, not destroy; the file is reported, never parsed as state.
- `--state-only` is `unverified`/exit `1`, with no `owned`/`missing`/`absent` rows.
- The existing `test_inventory_coverage.ml` and `check_destroy_completeness.py` still pass; removing a provider probe still fails the coverage test.
- `sol target reconcile` output, exit status and adoption behavior are unchanged; add a characterization test for the current output because no full golden test exists today.

### Live (separate authorization)

No live mutation is authorized by this document; each step below requires explicit operator authorization on a disposable target. Read-only first:

1. Deploy a target; run `sol resources`; every Terraform state resource is `owned` or `recorded`, and the provider observations agree. If authorization (or an unprobed platform class) is required but not yet observed, expect `verdict: incomplete` and the coverage list, not a false `reconciled`.
2. Delete a non-critical provider resource out-of-band in a class the inventory observes; `sol resources` shows `missing` (not `unknown`), and `sol plan`/`deploy` can recreate it.
3. Run `sol target reconcile <target> --dry-run --explain`; the inventory and reconcile agree on counts/classes.

Then a deliberate interrupted apply, only with explicit operator authorization:

4. Kill Terraform after a provider create (or use the recorded #1605 specimen procedure); run `sol resources`; the provider-created parent is `unrecorded`/`recoverable`, and controller-created children are enumerated as `unrecoverable`/`unmapped` with reasons.
5. Run `sol target reconcile --dry-run`, then the mutating reconcile; re-run `sol resources`; the parent is `owned`. If the existing reconcile path refuses the import because the root's configuration cannot be evaluated (the cluster-loss case recorded in #1119), the inventory must report that refusal and keep the parent `unrecorded`; that is the correct outcome, not a successful recovery. The live acceptance for this PRD is the enumeration and the supported path, not a promise that every import succeeds.
6. Run `sol destroy --apply`; the parent is now reachable by the ordinary lifecycle, and final absence is independently verified.

This is the same evidence boundary as [#1119](https://github.com/sol-fab/sol/issues/1119): a passing offline test is MECHANISM, not proof that a live partial apply is recoverable.

### Qualification record

The live run should record the command output, the JSON, the provider observation (redacted), the state read, and the before/after reconcile counts under `internal/qualification/records/`. The inventory is read-only evidence; `sol destroy` remains the absence authority.

## 15. Resolved review decisions and remaining questions

The review decisions are now part of the design, not open questions:

| Decision | Resolution |
|---|---|
| Command name | `sol resources <target>`. |
| Initial scope | All four Terraform roots in the inventory model. Platform in-cluster/synthetic objects are `By_contract`; authorization classes are `Unobserved` until M2 threads the existing identities. Any required unobserved class yields `incomplete`, never `reconciled`. |
| Live versus state-only | Live by default. `--state-only` is an explicitly `unverified` inspection mode, exits `1`, and is never a presence/absence gate. |
| Exit codes | `0`/`1`. `0` is reserved for `verdict: reconciled` — inventory complete, verification complete, no discrepancy. Every other verdict is `1`. |
| `errored.tfstate` | Report presence only. Do not parse it or treat its contents as ownership evidence in v1. |
| Ownership and recovery | Reuse the existing identity registry and reconciliation decisions. `status` (what the inventory knows) and `recovery` (whether Terraform ownership can be restored) are separate fields. No name/label/timestamp guessing. |
| Partial results | Display only. A partial collection is never authorization to adopt; `sol target reconcile` keeps its fail-closed behavior and exact adoption set. |
| Durable resources | Installation/DNS/state rows are shown by default as `external`/`retain`; hiding them would make target destroy look cleaner than it is. |
| Serverless/workload inventory | Deferred to M3/M4. The initial implementation must not claim it inventories every resource Sol can provision. |
| Text detail | Class and name by default; full provider/import identities under `--explain`/`--verbose`. |
| ADR | If accepted, record the bounded stale-state recovery exception to ADR 0005 (or a short new ADR) before implementation relies on it. |

The implementation resolved these:

1. **Required-class list.** It is the provider's executable probe set ∪ the identity registry's non-empty classes ∪ the provider's required controller-created classes. A state class with no registry entry is added as `Unobserved`; `By_contract` classes are not required. Authorization classes are required only through the executable probe set; per-address authorization coverage remains partial (see §18).
2. **ADR.** [ADR 0012](../adr/0012-resource-inventory-and-bounded-recovery.md) records the read-only projection and the bounded stale-state recovery exception, and ADR 0005 links to it.
3. **Verdict precedence.** Implemented as `unknown` → `unverified` (state-only) → `attention_required` → `incomplete` → `reconciled`. A confirmed discrepancy outranks a coverage gap; a failed read and state-only mode outrank both.
4. **M1 delivery shape.** Delivered with the honest `incomplete` verdict for unobserved required classes; no fake verification. A read-only live GCP run after teardown reported `unknown` because two existing provider probes return 404 after their parent is absent; the inventory correctly refused to call those absence (§18).

Remaining work is recorded as limitations in §18, not as unresolved design choices.

## 16. Risks

| Risk | Mitigation |
|---|---|
| The inventory is read as an account-wide audit | State “Sol-owned boundary” in output; reuse ADR 0005 scope; no ambient discovery |
| False `missing` due to provider eventual consistency or transient reads | `missing` only on a successful `Absent` observation; errors are `unknown`; no retry that turns unknown into absent |
| Success hides missing evidence | `reconciled`/exit `0` requires both inventory and verification complete; an unobserved required class is `incomplete`/exit `1` |
| Empty result mistaken for a failed read | `root_read` distinguishes `Read_empty` from `Read_unreadable`; a failed read never becomes an empty list; test both |
| A partial collection becomes adoption authority | `collect_ownership` is display-only; `reconcile_ownership` keeps its fail-closed checks, exact adoption set, and validated dispositions; a fixture asserts the partial view is not the import input |
| An unobserved class silently disappears | `coverage.verification.unobserved_classes` is part of the contract; removing a required class from coverage fails the acceptance test |
| Sensitive values in Terraform state leak | `decode_sensitive` plus the parser whitelist and renderer; never print `values`/`sensitive_values`; redaction tests |
| Provider reads are slow or costly | Reuse the existing observation set; `--state-only`; per-root summary; no extra probes for classes already covered |
| `terraform show` is unreadable when provider configuration depends on a missing cluster (the #1119 GCP case) | Report root `state: unreadable` and row `status: unknown` with the original error; do not infer an empty state; provider-only rows still shown |
| Operation records are host-local/stale | Use the exact `operation_key`; report `No_previous` as such; show host only for `Running`; never infer an operation from state; never unlock or advance state |
| Coverage gaps mislead | `coverage.inventory`/`coverage.verification`, `incomplete`/exit `1`, and `recorded`/unverified status; existing `test_inventory_coverage` keeps required classes probed |
| Scope creep into a general orchestrator | Keep the module a projection; no new provider mutation; ADR 0005 boundary; review the class list |
| The refactor changes `sol target reconcile` behavior | Characterization test for existing reconcile output/exit status; the inventory core is extracted, not reimplemented |

## 17. References

- [Resource ownership](../ownership.md) — state is the ownership proof; names/labels are not.
- [ADR 0003](../adr/0003-lifecycle-phases-authority-and-policy.md) — lifecycle phases; no second infrastructure state database.
- [ADR 0005](../adr/0005-sol-owns-only-its-contract-boundary.md) — Sol owns only its declared boundary.
- [Recovering partial Terraform ownership](../../guides/partial-state-recovery.md) — current operator procedure.
- [CLI reference](../../reference/cli.md) — command surface and generated tables.
- [#1119](https://github.com/sol-fab/sol/issues/1119) — bounded destruction coverage and partial-state recovery.
- [#1605](https://github.com/sol-fab/sol/issues/1605) — Cloud SQL create timeout; decision to expose an unrecoverable enumeration.
- `cli/lib/cloud/sol_cli_ownership_reconciliation.ml` — dispositions and JSON vocabulary.
- `cli/lib/cloud/sol_cli_resource_identity.ml` — address/class/import-identity registry.
- `cli/lib/cloud/sol_cli_aws_absence.ml`, `sol_cli_gcp_absence.ml` — provider inventories.
- `cli/lib/cloud/sol_cli_cloud_destroy.ml` — `terraform show -json` state parser.
- `cli/lib/cloud/sol_cli_terraform.ml`, `sol_cli_supervised.ml`, `sol_cli_state_guard.ml` — operation status and unresolved state.
- `cli/test/inline/test_inventory_coverage.ml`, `internal/ci/check_destroy_completeness.py` — existing coverage guarantees.

## 18. Implementation record (2026-11-02)

This section supersedes the “review questions” framing above for implementation
behaviour. The design is unchanged; this records what landed and what remains.

### Surface

- `sol resources <target>` in `cli/bin/cmd_resources.ml`.
- `Sol_cli_resource_inventory` in `cli/lib/cloud` owns the model, classification,
  coverage computation, verdict, JSON and text rendering.
- `Sol_cli_cloud_wiring.collect_cloud` is the extracted read-only cloud-root collector.
  `reconcile_ownership` uses it and keeps its previous errors, exit status and adoption
  set; `sol resources` uses the same collector with no adoption.
- `Sol_cli_provider_registry.observed_classes` exposes the executable probe set.
- `Sol_cli_report.install_terminal_stderr` keeps `--json` stdout machine-readable.

### Verdict and coverage as implemented

- `reconciled` requires `coverage.inventory.complete`, `coverage.verification.complete`,
  no `unrecorded`/`missing`/`uid_mismatch` status, and no `unrecoverable`/`unmapped`
  recovery disposition.
- `verification.complete` is false for any unobserved/failed required class **and** for
  any recorded row the inventory could not verify (`coverage.verification.recorded_unverified`).
- `unknown` means the inventory itself is incomplete or a required probe failed.
- `unverified` is the explicit `--state-only` mode and exits `1`.
- `attention_required` means a confirmed discrepancy; `incomplete` means the records are
  complete but a required class was not observed.
- All non-reconciled verdicts exit `1`. A partial collection is never an input to the
  adoption loop.

### Qualification integrated

- `cli/test/inline/test_resource_inventory.ml`: six tests for reconciliation, incomplete
  coverage, unrecorded/attention, unreadable/unknown, state-only/unverified, and
  status/recovery JSON separation.
- `cli/test/test_resources_command.sh`: command-level test with a fake Terraform state
  and fake AWS credentials/API; checks the `unverified` exit, both coverage axes,
  state-only makes no provider probes, `--json` is parseable, and `--class`/`--status`
  filter rows.
- `internal/qualification/inventory_contract.py`: validates a JSON inventory against its
  claimed verdict. `internal/qualification/test_inventory_contract.py` covers the
  reconciled/incomplete/attention/unknown/unverified distinctions.
- `aws/live-qual.sh inventory` and `gcp/live-qual.sh inventory`: read-only phases that run
  the installed candidate's `sol resources <target> --json`, validate it with the
  contract, and never mutate or tear down. `verify` remains the independent absence
  inventory.
- Read-only live evidence on `probe/gcp/us-central1` (checkout binary):
  - after the target was torn down, `sol resources --json` read all four roots and
    returned `verdict: unknown`, `coverage.inventory.complete: true`,
    `coverage.verification.complete: false`, exit `1`. Twenty-two classes were observed;
    `Cloud NAT` and `GKE node pool` returned provider 404s because their parent was
    absent. The inventory correctly reported `unknown` rather than absence;
    evidence: `internal/qualification/records/2026-11-02-resource-inventory-live-gcp/`;
  - `--state-only` returned `verdict: unverified`, verification incomplete, exit `1`,
    with no provider probe.
- The Artifact Registry probe was corrected at its owning boundary where the live run
  exposed a benign listing notice on stderr. The Cloud NAT/GKE node pool 404s remain
  unknown by design: the existing absence contract refuses to turn a failed enumeration
  into absence. A parent-child absence rule would be a separate provider-contract
  decision with its own tests and live qualification.

### Limitations

- **Authorization per-address mapping is partial.** The probes and identities exist and
  are threaded, but only the reconciler role, workload-boundary policy, workload roles,
  reconciler service account/role/binding are mapped to state addresses. Scheduler,
  serverless runtime identities, secret IAM members, and role policies remain recorded
  but unobserved until a later mapping; that makes a deployed target `incomplete`, not
  falsely `reconciled`.
- **Platform custom Terraform** is reported as `recorded`/unverified unless its type is
  by-contract. Workspace overlays that add arbitrary provider resources therefore keep
  verification incomplete.
- **Serverless and workload inventory (M3/M4)** is not implemented. Direct Cloud
  Run/Lambda/task release records and Kubernetes workload UIDs are not yet rows; the
  initial implementation must not claim it inventories every resource Sol can provision.
- **Interrupted-apply live evidence is not executed here.** The read-only path and the
  `attention_required` contract are implemented and tested; a deliberate interrupted
  apply is a destructive live qualification that requires explicit operator
  authorization. The existing `docs/guides/partial-state-recovery.md` now includes the
  `sol resources` observation before and after `sol target reconcile`.
- **GCP post-destroy absence probes.** `Cloud NAT` and `GKE node pool` return 404 when
  their router/cluster is already absent, so the live inventory reports `unknown` for a
  fully torn-down GCP target. The existing absence contract intentionally does not read a
  failed enumeration as absence; fixing this requires a separately qualified parent-child
  absence rule. Until then `live-qual.sh inventory --expect reconciled` cannot pass on
  such a target.
- **AWS live read-only evidence** was not run in this environment; the command and
  offline tests are provider-neutral and the AWS probes are the existing ones.
- `--state-only` still needs state-backend credentials and network; it is not an offline
  mode.
