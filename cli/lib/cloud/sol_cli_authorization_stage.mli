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

val verify_destroyed_state : Sol_cli_cloud_destroy.state_read -> (unit, string) result

val destroy
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> (outcome, string) result
