type outcome =
  | Established
  | Not_declared

(** Whether the durable authorization state requires destruction. The decision is taken
    from the authorization root's Terraform state, not from the target's current trust
    declaration: a target that created the reconciler and later removed the declaration
    must still be torn down. *)
type destroy_decision =
  | Never_established
  | Destroy_established
  | Destruction_unknown of string

val destroy_decision
  :  declared_trust:string option
  -> state:Sol_cli_cloud_destroy.state_read
  -> destroy_decision

val outcome_to_string : outcome -> string

(** The root variables for a destruction, including the placeholder trust principal when
    the current configuration no longer declares one. The placeholder only lets Terraform
    plan the destruction of the state resource; it grants no trust. *)
val destroy_root_vars : Sol_cli_config.target -> ((string * string) list, string) result

val root_vars : Sol_cli_config.target -> ((string * string) list, string) result

val fence
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> (outcome, string) result

val apply_serverless_identities
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> Sol_cli_grant.serverless_unit list
  -> ((string * string) list, string) result

val verify_destroyed_state : Sol_cli_cloud_destroy.state_read -> (unit, string) result

type destroy_result =
  { outcome : outcome
  ; identities : (string * string list) list
  }

(** The resource identities the authorization root's pre-destroy state records, grouped
    by the observation class they belong to. These are the target's own authorization
    resources, not the environment-level names a sibling target could share. *)
val identities_of_state
  :  target:Sol_cli_config.target
  -> Sol_cli_cloud_destroy.state_read
  -> (string * string list) list

val destroy_with_identities
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> (destroy_result, string) result

val destroy
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> (outcome, string) result

val apply_scheduler_identities
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> Sol_cli_grant.scheduler_unit list
  -> ((string * string) list, string) result
