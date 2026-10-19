type action =
  | Create
  | Update
  | Delete
  | Replace
  | Read
  | No_op
  | Unknown of string list

type change =
  { address : string
  ; resource_type : string
  ; mode : string
  ; action : action
  }

type matcher =
  | Exact of string
  | Resource of string
  | Type of string
  | Every_change
  | Except of matcher

type rule =
  { matches : matcher list
  ; allows : action list
  ; reason : string
  }

type policy =
  { phase : string
  ; rules : rule list
  }

val same_resource : string -> string -> bool
val action_to_string : action -> string
val changes_of_plan_json : string -> (change list, string) result

val show_and_record
  :  run_log:Sol_cli_run_log.t
  -> phase:string
  -> show:(unit -> (string, string) result)
  -> (string * change list, string) result

val violations : policy -> change list -> string list

type apply_failure =
  | Plan_failed of string
  | Plan_unreadable of string
  | Refused of string list
  | Apply_failed of string

val apply_failure_to_string : apply_failure -> string
val was_refused : apply_failure -> bool

val guarded_apply
  :  policy:policy
  -> plan:(unit -> (string, string) result)
  -> show_plan:(string -> (string, string) result)
  -> apply_plan:(string -> (unit, string) result)
  -> unit
  -> (unit, apply_failure) result

val removed_of_type : resource_type:string -> change list -> string list
