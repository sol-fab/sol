val install_signal_handler : sw:Eio.Switch.t -> unit Eio.Promise.u -> unit
val setting : string -> string option

(** The file a secret is projected into, when one is. Resolution order is the portable
    contract: an explicit [<NAME>_FILE], then [SOL_SECRETS_DIR/<NAME>] (the directory Sol
    mounts provider-backed values into), and otherwise [None]. A caller that reads files
    itself (for example through Eio) uses this to keep the routing rule in one place. *)
val secret_file : name:string -> string option

(** The value of a secret, from the projected file when there is one and otherwise from
    the environment variable of the same name. This keeps existing environment-based
    consumption working while provider-backed values never need an environment value. *)
val secret_result : string -> (string option, string) result

(** [secret name] is [secret_result name] with unavailability reported as [None]. Required
    secrets should use {!secret_result} so an unreadable projection is not mistaken for an
    absent optional value. *)
val secret : string -> string option

val contains_substring : needle:string -> string -> bool
