(** Narrow metadata channel for an opt-in migration execution observer. A receipt
    identifies the selected API Job; it says nothing about CA delivery or success. *)
val environment : string

val protocol : Yojson.Safe.t

type receipt =
  { binding : string
  ; target : string
  ; namespace : string
  ; name : string
  ; uid : string
  ; principal : string
  ; cluster : string
  ; endpoint : string
  ; observed_at : int
  }

type message =
  | Execution of receipt
  | Unavailable

val encode : message -> string
val decode : string -> (message, string) result
val requested : unit -> string option

(** Bounded private duplex channel; callers retain fd ownership. No logs, Job
    bodies or credentials belong on it. Acknowledgment means capture finished,
    never that qualification passed. *)
val send : Unix.file_descr -> message -> (unit, string) result

val receive : ?timeout_s:float -> Unix.file_descr -> (message, string) result
val acknowledge : Unix.file_descr -> (unit, string) result
val notify : message -> (unit, string) result
