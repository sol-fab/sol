(** Typed phase and attempt history for the live qualification row.

    The shell harness owns provider mechanics, but it must not re-derive whether an
    attempt completed one clean required sequence. This module is the authority for
    that decision: phase names are a closed variant, a verdict is parsed once, and
    [assess] is exhaustive over the required phases. *)

type phase =
  | Prepare
  | Cloud
  | Transport
  | App
  | Destroy
  | Verify
  | Inventory
  | Resume

val phase_of_string : string -> (phase, string) result
val string_of_phase : phase -> string

type verdict =
  { phase : phase
  ; exit_code : int
  ; at : string option
  }

type provenance =
  { attempt : string
  ; claim : string
  ; issuer : string
  ; resumed_from : string option
  ; promotion_eligible : bool
  }

type t =
  { provenance : provenance
  ; verdicts : verdict list
  }

type continuity =
  | Continuous
  | Resumed of string

type reason =
  | Missing_phase of phase
  | Failed_phase of phase
  | Repeated_phase of phase
  | Not_promotion_eligible of string
  | Resumed_attempt of string

val string_of_reason : reason -> string

type assessment =
  { attempt : string
  ; eligible : bool
  ; required_phases_ok : bool
  ; continuity : continuity
  ; reasons : reason list
  }

val required_phases : phase list

(** Parse an attempt identity and its append-only phase ledger from one attempt
    directory. Unknown phases and malformed verdicts are errors, not skipped
    lines: an unreadable history cannot establish a clean sequence. *)
val of_dir : string -> (t, string) result

val assess : t -> assessment
val assessment_to_yojson : assessment -> Yojson.Safe.t
