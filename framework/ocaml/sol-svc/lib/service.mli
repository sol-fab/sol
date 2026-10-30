module type HANDLER = sig
  val routes : Route.t list
end

type run_error = [ `Config of string ]

val run_error_to_string : run_error -> string

type error_reporter = operation:string -> exn:exn -> unit

val stderr_error_reporter : error_reporter

module Make (H : HANDLER) : sig
  val run
    :  env:
         < net : _ Eio.Net.t
         ; clock : _ Eio.Time.clock
         ; fs : Eio.Fs.dir_ty Eio.Path.t
         ; .. >
    -> ?port:int
    -> ?metrics_auth:Auth.level
    -> ?ot:Sol_obs.t
    -> ?observe:Observation.sink
    -> ?max_body_bytes:int
    -> ?drain_timeout_s:float
    -> ?shutdown_delay_s:float
    -> ?stop:unit Eio.Promise.t
    -> ?on_listen:(int -> unit)
    -> unit
    -> (unit, run_error) result
end

val run
  :  Route.t list
  -> env:
       < net : _ Eio.Net.t
       ; clock : _ Eio.Time.clock
       ; fs : Eio.Fs.dir_ty Eio.Path.t
       ; .. >
  -> ?port:int
  -> ?metrics_auth:Auth.level
  -> ?ot:Sol_obs.t
  -> ?observe:Observation.sink
  -> ?max_body_bytes:int
  -> ?drain_timeout_s:float
  -> ?shutdown_delay_s:float
  -> ?stop:unit Eio.Promise.t
  -> ?on_listen:(int -> unit)
  -> unit
  -> (unit, run_error) result

module For_testing : sig
  val respond_or_500 : ?report_error:error_reporter -> (unit -> Response.t) -> Response.t
  val reset_jwks_cache : unit -> unit
  val cached_jwks_urls : unit -> string list
  val seed_stale_jwks_cache : url:string -> age_s:float -> jwks:string -> unit

  val dispatch
    :  ?report_error:error_reporter
    -> ?read_api_key:(unit -> string option)
    -> ?fetch_jwks:(string -> (Jose.Jwks.t, string) result)
    -> ?fetch_workload_jwks:(string -> (Jose.Jwks.t, string) result)
    -> ?workload_identity:Auth.workload_identity_config
    -> ?on_boundary:(Observation.boundary -> unit)
    -> ?on_workload_principal:((string * string) option -> unit)
    -> routes:Route.t list
    -> Http.Request.t
    -> Cohttp_eio.Body.t
    -> Response.t

  val workload_identity_config
    :  Route.t list
    -> Auth.level
    -> (Auth.workload_identity_config option, run_error) result

  val parse_called_by : string -> (string * string) list
  val workload_identity_requested : Route.t list -> Auth.level -> bool
  val jwks_uri_of_discovery : issuer:string -> string -> (string, string) result
  val numeric_https_uri : string -> string
end
