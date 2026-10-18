val observations
  :  ?pre_destroy:Sol_cli_cloud_destroy.state_read
  -> Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation list

val substrate_absence
  :  Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation

val class_names : string list
val unresolved : reason:string -> Sol_cli_absence.observation list
