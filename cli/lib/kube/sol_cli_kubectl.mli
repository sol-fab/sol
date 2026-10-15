val run
  :  ?timeout_s:float
  -> ctx:Sol_cli_kube_destination.context
  -> string list
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val apply
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (unit, Sol_cli_process.error) result

val apply_dry_run
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (unit, Sol_cli_process.error) result

val get
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> name:string
  -> namespace:string
  -> output:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val get_raw
  :  ctx:Sol_cli_kube_destination.context
  -> args:string list
  -> (Sol_cli_process.output, Sol_cli_process.error) result

type reason =
  | Not_found
  | Already_exists
  | Conflict
  | No_resource_type
  | Refused
  | Unreachable
  | Other

val classify : Sol_cli_process.error -> reason

val get_if_present
  :  ctx:Sol_cli_kube_destination.context
  -> args:string list
  -> (string option, Sol_cli_process.error) result

val logs
  :  ctx:Sol_cli_kube_destination.context
  -> pod:string
  -> namespace:string
  -> container:string option
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val rollout_status
  :  ctx:Sol_cli_kube_destination.context
  -> kind_name:string
  -> namespace:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val rollout_status_with_timeout
  :  ctx:Sol_cli_kube_destination.context
  -> kind_name:string
  -> namespace:string
  -> timeout_s:int
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val rollout_restart
  :  ctx:Sol_cli_kube_destination.context
  -> kind:string
  -> namespace:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val patch
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> name:string
  -> namespace:string
  -> patch_type:string
  -> patch:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

(** As {!patch}, but the body comes from a file, so a patch carrying a secret value never
    enters the process argv. *)
val patch_file
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> name:string
  -> namespace:string
  -> patch_type:string
  -> file:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val create
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val replace
  :  ctx:Sol_cli_kube_destination.context
  -> file:string
  -> (Sol_cli_process.output, Sol_cli_process.error) result

val delete
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> name:string
  -> namespace:string
  -> (unit, Sol_cli_process.error) result

type presence =
  | Present
  | Absent of string
  | Uncheckable of string

type probe =
  | Succeeded of string
  | Failed of Sol_cli_process.failure

val presence : ctx:Sol_cli_kube_destination.context -> args:string list -> presence
val presence_of_probe_result : (probe, string) result -> presence

val probe_result
  :  ctx:Sol_cli_kube_destination.context
  -> args:string list
  -> (probe, string) result

type forward_error =
  | Not_started of Sol_cli_process.error
  | Not_ready
  | Readiness_check_failed of string

val temporary_port_forward
  :  ctx:Sol_cli_kube_destination.context
  -> service:string
  -> namespace:string
  -> local_port:int
  -> remote_port:int
  -> (unit, forward_error) result
