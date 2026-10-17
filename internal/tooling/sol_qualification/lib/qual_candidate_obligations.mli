(** Offline boundary only. No release verdict or live transport. *)
type t = private
  { verified : Qual_candidate.t
  ; run : Qual_domain.run
  ; intent : Qual_domain.intent
  ; obligations : Qual_domain.obligations
  ; requests : Qual_domain.request list
  ; required_captures : (string * string) list
  }

(** The exact verified candidate these obligations were bound to. A launcher uses
    this handle instead of accepting a later, possibly unrelated installation. *)
val verified : t -> Qual_candidate.t

val prepare
  :  verified:Qual_candidate.t
  -> scenario:Qual_domain.scenario
  -> attempt:string
  -> assessment:string
  -> kubernetes:Qual_domain.kube_target
  -> (t, string) result

(** Uses the existing recorder; a missing/interrupted binding capture blocks seal
    across restart even when all claim verdicts have been persisted. *)
val capture_binding
  :  t
  -> Qual_evidence.t
  -> (Qual_evidence.reference, Qual_evidence.error) result
