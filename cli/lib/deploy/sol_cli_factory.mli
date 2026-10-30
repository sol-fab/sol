type execution =
  { plan : Sol_cli_deployment_plan.t
  ; results : Sol_cli_executor.result list
  }

val plan_of_services
  :  workspace:string
  -> env:Sol_cli_deployment_plan.env_config
  -> facts:Sol_cli_workspace_model.t
  -> ?requested_scope:string
  -> ?declared:Sol_cli_config.declared
  -> platform_shape:Sol_cli_profile.platform_shape
  -> ?image_refs:(string * string) list
  -> ?inventory:Sol_cli_manifest.service list
  -> ?target:string
  -> database:Sol_cli_resource_binding.postgres
  -> ?kafka:Sol_cli_resource_binding.kafka
  -> ?telemetry_env:(string * string) list
  -> Sol_cli_manifest.service list
  -> (Sol_cli_deployment_plan.t, string) result

val execute
  :  Sol_cli_execution.context
  -> mode:Sol_cli_executor.mode
  -> ?before_apply:(Sol_cli_deployment_plan.service_spec -> (unit, string) result)
  -> Sol_cli_deployment_plan.t
  -> (Sol_cli_executor.result list, string) result

type request =
  { env : Sol_cli_deployment_plan.env_config
  ; requested_scope : string option
  ; declared : Sol_cli_config.declared option
  ; platform_shape : Sol_cli_profile.platform_shape
  ; target : string option
  ; database : Sol_cli_resource_binding.postgres
  ; kafka : Sol_cli_resource_binding.kafka
  }

val run
  :  Sol_cli_execution.context
  -> request:request
  -> mode:Sol_cli_executor.mode
  -> facts:Sol_cli_workspace_model.t
  -> Sol_cli_manifest.service list
  -> (execution, string) result

val affected_services
  :  plan:Sol_cli_deployment_plan.t
  -> results:Sol_cli_executor.result list
  -> Sol_cli_release_inspection.affected_service list
