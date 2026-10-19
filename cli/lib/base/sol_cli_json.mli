type t = Yojson.Safe.t

val decode : what:string -> string -> (t, string) result

(** Decode credential-bearing JSON without quoting input in parse diagnostics. *)
val decode_sensitive : what:string -> string -> (t, string) result

val field : string list -> t -> t
val string : t -> string option
val int : t -> int option
val float : t -> float option
val bool : t -> bool option
val list : t -> t list option
val assoc : t -> (string * t) list option
val require : what:string -> string list -> (t -> 'a option) -> t -> ('a, string) result

val optional
  :  what:string
  -> string list
  -> (t -> 'a option)
  -> t
  -> ('a option, string) result

val items : what:string -> string -> (t list, string) result
