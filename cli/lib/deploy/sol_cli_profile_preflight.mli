type side =
  | Application
  | Target
  | Platform

type status =
  | Established
  | Unmet of side * string

type finding =
  { capability : Sol_cli_profile.capability
  ; side : side
  ; reason : string
  }

(** Which guarantees a caller evaluates now. [Structural] excludes [Immutable_artifacts],
    whose evidence cannot exist until the target root has created the registry; [Artifacts]
    evaluates only it. [All] is the default: refuse before any mutation. See the
    implementation for the full contract. *)
type evaluation =
  | All
  | Structural
  | Artifacts

val establish
  :  target:Sol_cli_config.target
  -> apply_mode:Sol_cli_release.apply_mode
  -> plan:Sol_cli_deployment_plan.t
  -> Sol_cli_profile.capability
  -> status

val check
  :  ?establish:(Sol_cli_profile.capability -> status)
  -> ?evaluation:evaluation
  -> target:Sol_cli_config.target
  -> apply_mode:Sol_cli_release.apply_mode
  -> Sol_cli_deployment_plan.t
  -> (unit, Sol_cli_profile.t * finding list) result

val side_to_string : side -> string
val finding_to_string : finding -> string
val report : Sol_cli_profile.t -> finding list -> string

(** The repositories a pending immutable artifact must be published into, derived from the
    plan's workload images. *)
val publish_repositories : Sol_cli_deployment_plan.t -> string list

(** The "provisioned, artifacts pending" diagnostic: not a failed provision, and not a
    workload change. *)
val pending_artifacts_report
  :  target:string
  -> profile:Sol_cli_profile.t
  -> Sol_cli_deployment_plan.t
  -> string
