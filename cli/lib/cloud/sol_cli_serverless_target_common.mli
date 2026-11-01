(** Serverless target policy shared by the provider adapters.

    These are target-level decisions, not provider mechanics: which execution a target
    selects, how the serverless caller list is spelled, how a unit name is derived, and
    which combinations are refused before a provider call. Keeping them here means the
    AWS and GCP adapters cannot drift on those decisions. Provider identity and
    provider-native lifecycle stay in the provider adapters. *)

val required_field
  :  Sol_cli_config.target
  -> provider:string
  -> string
  -> (string, string) result

val callers : Sol_cli_config.target -> (string * string) list
val unit_of_service : project:string -> Sol_cli_manifest.service -> string

(** The lifecycle dispatcher establishes this once. Provider adapters may be called only
    through that dispatcher. *)
val services_by_backend
  :  Sol_cli_config.target
  -> Sol_cli_manifest.service list
  -> Sol_cli_manifest.service list * Sol_cli_manifest.service list

val ensure_serverless : Sol_cli_config.target -> (unit, string) result

(** Refuse a service that declares resource dependencies; serverless projection does not
    carry them yet. *)
val declared_uses : Sol_cli_config.t -> Sol_cli_manifest.service -> (unit, string) result

(** An HTTP service needs an explicit incoming caller policy. A run-once function does
    not use this. *)
val require_http_callers : Sol_cli_config.target -> (unit, string) result
