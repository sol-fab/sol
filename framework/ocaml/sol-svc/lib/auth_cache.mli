type entry =
  { url : string
  ; fetched_at : float
  ; jwks : Jose.Jwks.t
  }

val ttl_s : float
val unknown_kid_refetch_interval_s : float
val failure_backoff_s : float
val peek : string -> entry option
val replace : entry -> unit
val urls : unit -> string list
val clear : unit -> unit
val last_failure : unit -> (string * float * string) option
val set_last_failure : (string * float * string) option -> unit
