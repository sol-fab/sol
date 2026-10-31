type backend =
  | Local
  | Self_hosted_durable
  | External

val backend_of_string : string -> backend option
val backend_to_string : backend -> string

val validate_external
  :  logs_url:string option
  -> metrics_url:string option
  -> traces_url:string option
  -> (unit, string) result

val validate_target : Sol_cli_config.target -> (unit, string) result
val export_terraform_secrets : Sol_cli_config.target -> (unit, string) result
