val observations
  :  Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation list

val substrate_absence
  :  Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation

(** Resource classes derived from the executable provider probes. No provider calls. *)
val observed_classes : unit -> string list

val relinquished_residue_probes : (string * string) list
val unresolved : reason:string -> Sol_cli_absence.observation list
