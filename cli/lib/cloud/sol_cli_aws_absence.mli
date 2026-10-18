val observations
  :  ?previously_attributed:(string * string list) list
  -> ?pre_destroy:Sol_cli_cloud_destroy.state_read
  -> ?authorization_identities:(string * string list) list
  -> Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation list

val substrate_absence
  :  Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation

val class_names : string list
val unresolved : reason:string -> Sol_cli_absence.observation list

val authorization_state_identities
  :  target:Sol_cli_config.target
  -> Sol_cli_cloud_destroy.state_read
  -> (string * string list) list
