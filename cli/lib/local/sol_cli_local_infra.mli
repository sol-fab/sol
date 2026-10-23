type install =
  { label : string
  ; run : unit -> (unit, string) result
  ; failure_diagnosis : unit -> string
  }

val max_in_flight_default : int
val run_bounded : ?max_in_flight:int -> install list -> (unit, string) result

type endpoint =
  { endpoint_label : string
  ; endpoint_required : bool
  ; endpoint_start : unit -> (unit, string) result
  ; endpoint_stop : unit -> unit
  }

type endpoint_outcome =
  | Ready
  | Optional_unavailable of string

val bring_up_endpoints : endpoint list -> (endpoint_outcome list, string) result
