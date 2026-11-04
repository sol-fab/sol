type trigger =
  | Cron
  | Lambda

module type FN = sig
  val trigger : trigger
  val run : unit -> (unit, string) result
end

type run_error =
  [ `Config of string
  | `Run of string
  | `Signalled
  ]

val run_error_to_string : run_error -> string

module Make (F : FN) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> ?pushgateway_url:string
    -> ?job:string
    -> ?ot:Sol_obs.t
    -> ?stop:unit Eio.Promise.t
    -> unit
    -> (unit, run_error) result
end

module type HTTP = sig
  val handle : Request.t -> Response.t
end

(** An HTTP-triggered function: one handler, one route. The declared exposure
    selects the request boundary. A [public] function treats the provider HTTP
    endpoint (ingress, function URL, or gateway) as the boundary and passes the
    request to the handler unauthenticated. An [internal] function keeps the
    Sol workload-identity check, so only a declared caller holding a projected
    token can invoke it.

    The same image runs both ways: on Lambda it speaks the Lambda runtime API
    and translates API Gateway/Function URL events; everywhere else it serves
    the route over HTTP, including the built-in [/healthz] and [/readyz]. *)
module Make_http (H : HTTP) : sig
  val run
    :  env:
         < net : _ Eio.Net.t
         ; clock : _ Eio.Time.clock
         ; fs : Eio.Fs.dir_ty Eio.Path.t
         ; .. >
    -> ?port:int
    -> ?ot:Sol_obs.t
    -> ?stop:unit Eio.Promise.t
    -> ?on_listen:(int -> unit)
    -> unit
    -> (unit, run_error) result

  module For_testing : sig
    val api_gateway_request : string -> (Request.t, string) result
    val api_gateway_response : Response.t -> string
  end
end
