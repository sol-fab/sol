(** A full image reference with Docker's repository-name grammar and a
    lowercase [sha256:<64 hex>] digest. This is the one image-reference rule;
    the deploy resolver, release-bundle assets and provider adapters use it. *)
val is_digest : string -> bool

val split_flag_value : string -> string option * string

val resolve
  :  service_names:string list
  -> (string option * string) list
  -> ((string * string) list, string) result

val resolve_with_previous
  :  service_names:string list
  -> (string option * string) list
  -> (string * string) list
  -> ((string * string) list, string) result

val plan_is_immutable : string list -> bool

(** The registry path a reference addresses, without its tag or digest. *)
val repository : string -> string
