(** One route in a target's shared HTTP API.

    A public HTTP function contributes exactly one route. Internal functions are
    deliberately not routable: their endpoint stays provider-private and keeps
    the workload-identity check. *)

type t =
  { service : string
  ; path : string
  ; backend : string
  }

val gateway_name : target_name:string -> string
val validate_routes : t list -> (unit, string) result

val of_release
  :  target:Sol_cli_config.target
  -> Sol_cli_toml.http_trigger
  -> Yojson.Safe.t
  -> (t option, string) result

(** The route a provider release record declares. Used by rollback/destroy to
    restore or remove exactly the owner's route without reconstructing it from
    current workspace configuration. *)
val of_record : target:Sol_cli_config.target -> Yojson.Safe.t -> (t option, string) result
