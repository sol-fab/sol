val observations
  :  ?authorization_identities:(string * string list) list
  -> Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation list

val substrate_absence
  :  Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation

val class_names : string list
val relinquished_residue_probes : (string * string) list
val unresolved : reason:string -> Sol_cli_absence.observation list

val authorization_state_identities
  :  target:Sol_cli_config.target
  -> Sol_cli_cloud_destroy.state_read
  -> (string * string list) list
