val validate_key_format : string -> (unit, string) result
val validate_key : string -> (unit, string) result

val unit_secret_manifest
  :  namespace:string
  -> secret_name:string
  -> (string * string) list
  -> string

val apply_unit_values
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> (string * string) list
  -> (bool, string) result

val verify_required_keys
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> required_keys:string list
  -> (unit, string) result

val verify_workload_secret
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment_plan.service_spec
  -> (unit, string) result

val verify_external_secret_ready
  :  ?timeout_s:float
  -> ?poll_s:float
  -> ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment_plan.service_spec
  -> (unit, string) result

val external_secret_status
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> unit_name:string
  -> expected_keys:string list
  -> (string, string) result

val verify_external_secret_destination
  :  ctx:Sol_cli_kube_destination.context
  -> Sol_cli_deployment_plan.service_spec
  -> (unit, string) result

val verify_runtime_secret
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> (unit, string) result

val verify_runtime_secret_keys
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> required_keys:string list
  -> (unit, string) result

val set_unit_key
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> key:string
  -> value:string
  -> (bool, string) result

val platform_secret_keys : string list

(** The guard a delivered object passes before Sol writes it: what is already there must be
    absent or Sol's. A Secret is also refused where an ExternalSecret already targets it. *)
val assert_destination_is_sol
  :  ctx:Sol_cli_kube_destination.context
  -> resource:string
  -> namespace:string
  -> name:string
  -> (unit, string) result

val verify_platform_secret_destinations
  :  ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> (unit, string) result

val set_platform_key
  :  ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> key:string
  -> value:string
  -> (string list, string) result

val delete_platform_key
  :  ctx:Sol_cli_kube_destination.context
  -> namespaces:string list
  -> key:string
  -> (string list, string) result

val delete_unit_key
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> key:string
  -> (bool, string) result

val unit_secret_keys
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> secret_name:string
  -> (string list, string) result

val runtime_secret_keys
  :  ctx:Sol_cli_kube_destination.context
  -> namespace:string
  -> (string list, string) result
