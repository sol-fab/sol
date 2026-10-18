type failure =
  | Terraform_failed of string
  | Refused of string

type outcome =
  | Applied
  | Apply_failed of
      { failure : failure
      ; cleanup : Sol_cli_cloud_destroy.cleanup
      }

type ('outputs, 'env, 'control) deps =
  { substrate_exists : unit -> (bool, string) result
  ; substrate_supported : unit -> (unit, failure) result
  ; plan : unit -> (Sol_cli_terraform_plan.change list, failure) result
  ; guarded_removals : string list
  ; confirm_guarded_removal : bool
  ; confirmation_flag : string
  ; apply_plan : unit -> (unit, failure) result
  ; discard_plan : unit -> unit
  ; outputs : unit -> ('outputs option, string) result
  ; open_window : 'outputs -> ('control option, string) result
  ; platform_vars : 'outputs -> (string list, string) result
  ; cloud_ready : 'outputs -> (unit, string) result
  ; with_cluster_access :
      'outputs -> ('env -> (unit, failure) result) -> (unit, failure) result
  ; platform_init : unit -> (unit, failure) result
  ; platform_installed : 'env -> bool
  ; apply_prerequisites : 'env -> string list -> (unit, failure) result
  ; await_crds : 'env -> bool
  ; verify_platform_prerequisites : 'env -> string list -> (unit, failure) result
  ; apply_platform : 'env -> string list -> (unit, failure) result
  ; await_readiness : 'env -> (string * Sol_cli_cloud_lifecycle.readiness) list
  ; remove_bootstrap_access : unit -> (unit, failure) result
  ; verify_deescalation : 'outputs -> 'control option -> (unit, string) result
  ; provisioner_effective : 'env -> bool
  ; report : string -> unit
  }

val failure_to_string : failure -> string
val execute : deps:('outputs, 'env, 'control) deps -> outcome
