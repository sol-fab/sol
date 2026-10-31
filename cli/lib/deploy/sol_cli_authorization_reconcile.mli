type terraform_grant = Sol_cli_grant.target_grant =
  { unit : string
  ; capability : string
  ; resource : string
  ; namespace : string
  }

val unit_name : Sol_cli_manifest.service -> (string, string) result

val desired
  :  ?binding_config:Sol_cli_config.t
  -> Sol_cli_workspace_model.t
  -> (Sol_cli_authorization.grant list, string) result

val terraform_grants
  :  grants:Sol_cli_authorization.grant list
  -> namespace_of:(string -> string option)
  -> (terraform_grant list, string) result

val workloads
  :  grants:Sol_cli_authorization.grant list
  -> namespace_of:(string -> string option)
  -> (Sol_cli_provider_capabilities.authorization_workload list, string) result

val terraform_var : terraform_grant list -> string * string
val current_of_output_json : string -> (Sol_cli_authorization.grant list, string) result

val deployed_of_listing_json
  :  namespaces:string list
  -> string
  -> (Sol_cli_authorization.grant list, string) result
