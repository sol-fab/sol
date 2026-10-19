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

(** Resource classes derived from the executable provider probes. No provider calls. *)
val observed_classes : unit -> string list

val unresolved : reason:string -> Sol_cli_absence.observation list

val authorization_state_identities
  :  target:Sol_cli_config.target
  -> Sol_cli_cloud_destroy.state_read
  -> (string * string list) list

val kafka_storage
  :  region:string
  -> namespace:string
  -> Sol_cli_absence.observation
  -> Sol_cli_absence.observation

(** Independently observe the durable Kafka secret and its active version.
    This is the reuse decision's evidence; a Terraform plan alone is not. *)
val kafka_authority
  :  region:string
  -> cluster_name:string
  -> Sol_cli_kafka_authority.authority_state
