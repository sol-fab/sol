val scope_class : string

type attribution =
  | Named_for_target of string
  | Within_target of string

type observation =
  | Absent of
      { resource_class : string
      ; identity : string
      ; attribution : attribution
      ; checked_with : string
      }
  | Present of
      { resource_class : string
      ; identity : string
      ; found : string list
      ; attribution : attribution
      ; checked_with : string
      }
  | External of
      { resource_class : string
      ; identity : string
      ; reason : string
      }
  | Not_attributable of
      { resource_class : string
      ; reason : string
      }
  | Unobservable of
      { resource_class : string
      ; reason : string
      ; checked_with : string
      }

type verdict =
  | All_absent
  | Some_present of string list
  | Some_unknown of string list

val verdict : observation list -> verdict
val permits_absence_claim : verdict -> bool
val residue : verdict -> string list
val to_sweep : observation list -> Sol_cli_destroy_verification.sweep
val report : observation list -> string
val summary : observation -> string
val attribution_rule : attribution -> string
val lines : string -> string list
val not_found : needles:string list -> string -> bool
val unresolved : reason:string -> observation list
val scope_failure : reason:string -> observation list
val durable_state_bucket : identity:string -> observation
