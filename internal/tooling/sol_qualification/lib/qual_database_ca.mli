(** I3 fixture-bound CA observation/evaluation. One mechanism for AWS/GCP contexts;
    no installed-release binding, policy transfer, executor or live harness call. *)
type recorded = private
  { verdict : Qual_domain.verdict
  ; receipt : Qual_evidence.reference
  ; observations : Qual_evidence.reference list
  }

type outcome = private
  { instance : Qual_domain.instance
  ; result : (recorded, Qual_evidence.error) result
  }

(** Reads verified persisted projections before calling the pure evaluator;
    never evaluates transient raw responses. Observation-to-requirement matching stays in Qual_domain. *)
val evaluate_recorded
  :  directory:string
  -> run:Qual_domain.run
  -> requirement:Qual_domain.ca_requirement
  -> deployment:Qual_evidence.reference
  -> configmap:Qual_evidence.reference
  -> (Qual_domain.verdict, Qual_evidence.error) result

(** Every expected CA obligation is accounted for, including capture failures.
    This is not full database/release qualification; non-CA obligations remain
    required by the existing catalog and prevent a CA-only final PASS. *)
val observe_all
  :  directory:string
  -> run:Qual_domain.run
  -> obligations:Qual_domain.obligations
  -> recorder:Qual_evidence.t
  -> read:(Qual_kubernetes.query -> Qual_kubernetes.reply)
  -> (outcome list, string) result
