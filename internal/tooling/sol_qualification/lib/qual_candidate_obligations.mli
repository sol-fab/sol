(** Offline boundary only. No release verdict or live transport. *)
type t = private
  { run : Qual_domain.run
  ; intent : Qual_domain.intent
  ; obligations : Qual_domain.obligations
  ; requests : Qual_domain.request list
  ; required_captures : (string * string) list
  }

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
