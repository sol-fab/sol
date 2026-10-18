val observations
  :  ?previously_attributed:(string * string list) list
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
