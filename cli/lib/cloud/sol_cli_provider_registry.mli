type resolution_failure =
  | Outputs_unreadable of string
  | State_unreadable of string
  | No_root of string

val resolution_failure_to_string : resolution_failure -> string

val of_root
  :  Sol_cli_provider.t
  -> target:Sol_cli_config.target
  -> chdir:string
  -> (Sol_cli_cluster.t option, resolution_failure) result

(** The provisioning configuration's [postgres_url] from a raw [terraform output -json]
    body, read through the provider's own output parser. [Ok None] is a null output — no
    database was created; [Error] is an unreadable output, which the database setup step
    must not confuse with "no database". *)
val postgres_url_of_outputs
  :  Sol_cli_provider.t
  -> string
  -> (string option, resolution_failure) result

(** The same dispatch for [postgres_ca_cert], the trust anchor [postgres_sslmode] verifies
    against.
    [Ok None] is a null output — no database was created; [Error] is an unreadable output. *)
val postgres_ca_cert_of_outputs
  :  Sol_cli_provider.t
  -> string
  -> (string option, resolution_failure) result

(** The mode this provider's connection authenticates the server with. The contract —
    encrypted transport with authenticated server identity — is provider-neutral; the
    mechanism is not. Both modes are explicit, so neither permits a downgrade. *)
val postgres_sslmode : Sol_cli_provider.t -> (string, resolution_failure) result

val destruction
  :  Sol_cli_provider.t
  -> Sol_cli_destruction.context
  -> Sol_cli_destruction.t

val observations
  :  ?previously_attributed:(string * string list) list
  -> ?pre_destroy:Sol_cli_cloud_destroy.state_read
  -> ?authorization_identities:(string * string list) list
  -> Sol_cli_provider.t
  -> Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation list

val kafka_generation
  :  Sol_cli_provider.t
  -> managed:bool
  -> Sol_cli_terraform_plan.change list
  -> (Sol_cli_kafka_authority.generation, string) result

(** Independent provider observation of the authority a [Reuse] decision relies on. *)
val kafka_authority
  :  Sol_cli_provider.t
  -> Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_kafka_authority.authority_state

(** Positive independent absence required before first credential generation. *)
val kafka_initialization_evidence
  :  Sol_cli_provider.t
  -> Sol_cli_config.target
  -> cluster_name:string
  -> namespace:string
  -> observe_broker:(unit -> Sol_cli_absence.observation)
  -> (Sol_cli_kafka_authority.initialization_evidence, string) result

val substrate_absence
  :  Sol_cli_provider.t
  -> Sol_cli_config.target
  -> cluster_name:string
  -> Sol_cli_absence.observation

val substrate_addresses : Sol_cli_provider.t -> string list
val substrate_kind : Sol_cli_provider.t -> string

val resource_identity
  :  Sol_cli_provider.t
  -> cluster_name:string
  -> project_id:string option
  -> Sol_cli_resource_identity.entry list

val credentials
  :  Sol_cli_provider.t
  -> operation:string
  -> leaves_target_standing:bool
  -> (unit, string) result

val authorization_state_identities
  :  Sol_cli_provider.t
  -> target:Sol_cli_config.target
  -> Sol_cli_cloud_destroy.state_read
  -> (string * string list) list
