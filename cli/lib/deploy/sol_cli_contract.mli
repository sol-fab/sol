type mode =
  | Check
  | Apply
  | Projection

val run
  :  echo:bool
  -> workspace:string
  -> registry_url:string
  -> scope:string
  -> mode:mode
  -> (string option, string) result

val has_projection : workspace:string -> bool

val report
  :  workspace:string
  -> registry_url:string
  -> scope:string
  -> mode:mode
  -> (unit, string) result

val plan_report
  :  workspace:string
  -> registry_url:string option
  -> scope:string
  -> (unit, string) result

val reconciliation_images
  :  Sol_cli_deployment_plan.service_spec list
  -> (string * string * string option) list

val reconcile_in_destination
  :  ctx:Sol_cli_kube_destination.context
  -> kafka:Sol_cli_resource_binding.kafka
  -> secret_name:string option
  -> namespace:string
  -> image:string
  -> (unit, string) result
