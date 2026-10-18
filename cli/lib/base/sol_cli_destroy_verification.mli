type lookup_result =
  | Answered of
      { status : int
      ; stdout : string
      ; stderr : string
      }
  | Unavailable of string

type state_evidence =
  | State_absent
  | State_residue of string list
  | State_unreadable of string

val state_evidence : (string list, string) result -> state_evidence

type sweep =
  | Sweep_not_run
  | Sweep_ran of
      { residues : string list
      ; indeterminate : string list
      }

type retention =
  | Retention_required_and_observed of string
  | Retention_not_required of string
  | Retention_violated of string
  | Retention_unknown of string

val retention_to_string : retention -> string

type observation =
  { state : state_evidence
  ; sweep : sweep
  ; retention : retention
  }

type verdict =
  { violations : string list
  ; unknowns : string list
  }

(** All required postconditions, including a completed residue inventory, must be
    established. An unreadable or missing observation is unknown, never success. *)
val classify : observation -> verdict

val is_verified : verdict -> bool
val verdict_message : verdict -> string
val report : observation -> string
