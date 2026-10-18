type outcome =
  | Established
  | Not_declared

val outcome_to_string : outcome -> string
val root_vars : Sol_cli_config.target -> ((string * string) list, string) result

val fence
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> (outcome, string) result

val verify_destroyed_state : string -> (unit, string) result

val destroy
  :  assets:Sol_cli_platform_assets.t
  -> run_log:Sol_cli_run_log.t
  -> target:Sol_cli_config.target
  -> (outcome, string) result
