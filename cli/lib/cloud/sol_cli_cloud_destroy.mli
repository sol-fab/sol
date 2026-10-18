type resource =
  { address : string
  ; kind : string
  ; name : string option
  ; identifier : string option
  ; deletion_protection : bool option
  ; final_snapshot_identifier : string option
  ; skip_final_snapshot : bool option
  ; role : string option
  ; member : string option
  ; secret_id : string option
  ; email : string option
  }

type state_read =
  | State_empty
  | State_represented of resource list
  | State_unreadable of string

type substrate_presence =
  | Substrate_present
  | Substrate_absent
  | Substrate_unknown

val inventory_of_show_json : string -> state_read
val resources : state_read -> resource list
val addresses : state_read -> string list
val substrate_presence : state_read -> substrate_presence
val in_cluster_kind : string -> bool
val find_address : state_read -> string -> resource option

type preparation =
  | Nothing_prepared
  | Prepared of { retained : string option }

type cleanup =
  | Cleanup_not_needed
  | Cleanup_succeeded
  | Cleanup_failed of string

type reconciliation =
  | Nothing_to_reconcile
  | Reconciled of
      { evidence : string
      ; forgotten : string list
      }

type authority =
  | No_authority_required
  | Mechanism of
      { reconcile_and_enable : unit -> (unit, string) result
      ; remove_elevated_access : unit -> (unit, string) result
      }

type outputs_read =
  | Outputs_available
  | Outputs_unavailable of string
  | Outputs_unreadable of string

type failure =
  | Credentials_failed of string
  | Init_failed of string
  | Preparation_refused of string
  | Outputs_unreadable of string
  | Platform_destroy_failed of string
  | Substrate_destroy_failed of string
  | Verification_failed of string
  | Authorization_not_removed of string
  | Elevated_access_not_removed of string
  | Release_unestablished of string

(** Constructed only by [execute]: success means the authoritative verification
    verdict established every required postcondition. *)
type outcome = private
  | Destroy_succeeded of
      { preparation : preparation
      ; degradations : string list
      ; substrate : substrate_presence
      ; cleanup : cleanup
      ; verification : Sol_cli_destroy_verification.observation
      }
  | Destroy_blocked of { guarantee : string }
  | Destroy_failed of
      { failure : failure
      ; degradations : string list
      ; cleanup : cleanup
      ; verification : Sol_cli_destroy_verification.observation option
      }

val failure_message : failure -> string
val accept_unreleased_flag : string
val exit_clean : int
val exit_failure : int
val exit_code : outcome -> int
val completion_message : outcome -> string

type deps =
  { require_credentials : unit -> (unit, string) result
  ; terraform_init : unit -> (unit, string) result
  ; observe_state : unit -> (string, string) result
  ; reconcile_provable_absence : unit -> (reconciliation, string) result
  ; cloud_outputs : unit -> outputs_read
  ; prepare : state:state_read -> preparation Sol_cli_cloud_lifecycle.preparation_outcome
  ; authority : authority
  ; destroy_platform : unit -> (unit, string) result
  ; observe_window_before : unit -> (unit, string) result
  ; verify_window_after : unit -> (unit, string) result
  ; release_workloads : unit -> Sol_cli_workload_scope.release
  ; accept_unreleased : bool
  ; destroy_substrate : unit -> (unit, string) result
  ; destroy_authorization :
      unit -> (string * (string * string list) list, string) result
  ; observe_residue : pre_destroy:state_read -> Sol_cli_absence.observation list
  ; verify_destruction :
      pre_destroy:state_read
      -> preparation:preparation
      -> previously_attributed:(string * string list) list
      -> pre_inventory_failures:string list
      -> authorization_identities:(string * string list) list
      -> Sol_cli_destroy_verification.observation
  ; report : string -> unit
  ; warn : string -> unit
  }

val execute : deps:deps -> outcome
val guard_preparation_policy : addresses:string list -> Sol_cli_terraform_plan.policy

val bootstrap_enable_policy
  :  bootstrap:Sol_cli_terraform_plan.matcher list
  -> Sol_cli_terraform_plan.policy

val reconciliation_policy
  :  bootstrap:Sol_cli_terraform_plan.matcher list
  -> guarded:string list
  -> Sol_cli_terraform_plan.policy

val bootstrap_removal_policy
  :  bootstrap:Sol_cli_terraform_plan.matcher list
  -> Sol_cli_terraform_plan.policy
