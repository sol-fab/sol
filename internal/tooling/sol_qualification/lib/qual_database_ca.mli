(** Shared CA observation/evaluation for AWS/GCP contexts. Callers bind expected
    contracts and inject readers; the separate read-only transport does not transfer
    policy or install release-qualification authority. *)
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

(** Migration CA requirements remain separate from application consumers. Each
    evaluation depends on a verified persisted execution receipt and exact Job UID.
    No deterministic Job-name reconstruction or execution-receipt production path exists. *)
val evaluate_migration_recorded
  :  directory:string
  -> run:Qual_domain.run
  -> requirement:Qual_domain.migration_ca_requirement
  -> execution:Qual_evidence.reference
  -> job:Qual_evidence.reference
  -> configmap:Qual_evidence.reference
  -> (Qual_domain.verdict, Qual_evidence.error) result

val observe_migrations
  :  directory:string
  -> run:Qual_domain.run
  -> obligations:Qual_domain.obligations
  -> recorder:Qual_evidence.t
  -> read:(Qual_kubernetes.query -> Qual_kubernetes.reply)
  -> execution:
       (Qual_domain.migration_ca_requirement
        -> (Qual_evidence.reference, Qual_evidence.error) result)
  -> (outcome list, string) result

(** Persist a submission locator committed by a qualified launcher. The caller
    must already have validated its provenance: it came from the verified
    candidate's launched execution, matched the caller's binding and requested
    target, and carries a context the caller independently established. This
    function only commits the payload under the run's assessment. *)
val capture_execution
  :  Qual_evidence.t
  -> Qual_domain.migration_ca_requirement
  -> context:Qual_domain.read_context
  -> Qual_domain.job_identity
  -> (Qual_evidence.reference, Qual_evidence.error) result

module Fixture : sig
  (** Offline-named alias for tests; the payload source, not this function,
      decides whether a locator is production evidence. *)
  val capture_execution
    :  Qual_evidence.t
    -> Qual_domain.migration_ca_requirement
    -> context:Qual_domain.read_context
    -> Qual_domain.job_identity
    -> (Qual_evidence.reference, Qual_evidence.error) result
end
