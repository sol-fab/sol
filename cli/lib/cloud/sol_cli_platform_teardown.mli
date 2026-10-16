val kinds_of_api_resources : string -> string list

val unserved_of_show_json
  :  served:string list
  -> string
  -> ((string * string) list, string) result

(** The platform namespaces whose absence the teardown verifies. *)
val platform_namespaces : string list

(** One namespace's state, classified explicitly: [Namespace_absent] is a positive observation
    (the API server answered NotFound), and every other failure is [Namespace_unknown] -- a
    failed read is never read as absence (sol-fab/sol#1497). *)
type namespace_state =
  | Namespace_present
  | Namespace_absent
  | Namespace_unknown of string

val namespace_state : env:(string * string) list -> string -> namespace_state

(** Every platform namespace must read ABSENT; the first one that is present or could not be
    established is reported with which of the two it was. *)
val verify_absent : env:(string * string) list -> (unit, string) result

val absent : (string * string) list -> bool

val destroy
  :  run_log:Sol_cli_run_log.t
  -> env:(string * string) list
  -> chdir:string
  -> vars:string list
  -> (unit, string) result
