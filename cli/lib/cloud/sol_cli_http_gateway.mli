(** The one target-scoped shared-HTTP-API dispatch boundary.

    A public HTTP function contributes one route to a single provider gateway per
    target. Internal functions are not routed here: they keep their private
    provider endpoint and workload-identity check. Every provider adapter owns
    the gateway's native identity and lifecycle; this module only chooses the
    adapter and derives the target's gateway name. *)

type route = Sol_cli_http_route.t

type endpoint =
  { name : string
  ; url : string
  }

val reconcile_public
  :  target:Sol_cli_config.target
  -> target_name:string
  -> routes:route list
  -> (endpoint option, string) result

val restore_public_route
  :  target:Sol_cli_config.target
  -> target_name:string
  -> route
  -> (endpoint option, string) result

val remove_public_route
  :  target:Sol_cli_config.target
  -> target_name:string
  -> path:string
  -> (unit, string) result
