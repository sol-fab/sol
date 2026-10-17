(** One candidate-bound, independently observed, durably evidenced qualification
    path. It composes the existing owners rather than adding another framework:
    the verified candidate and its complete obligations, the shared CA evaluator,
    the authenticated read boundary and the qualification-owned migration
    launcher. It produces no release verdict and does not decide policy
    applicability. *)

type outcomes =
  { application : Qual_database_ca.outcome list
  ; migration : Qual_database_ca.outcome list
  }

(** Observe the application CA obligations. Live callers run this after the final
    deploy, when the workloads exist; it is separate from {!migration} because the
    migration Job is gone by then. *)
val observe_application
  :  directory:string
  -> prepared:Qual_candidate_obligations.t
  -> recorder:Qual_evidence.t
  -> read:(Qual_kubernetes.query -> Qual_kubernetes.reply)
  -> (Qual_database_ca.outcome list, string) result

(** Run the verified candidate's own `migrate apply` at the lifecycle point the
    product performs it, capture the actual Job locator and observe its CA before
    cleanup. A reported skip is an unestablished migration family, never a
    satisfied execution. *)
val migration
  :  directory:string
  -> prepared:Qual_candidate_obligations.t
  -> recorder:Qual_evidence.t
  -> read:(Qual_kubernetes.query -> Qual_kubernetes.reply)
  -> establish:(unit -> (Qual_domain.read_context, string) result)
  -> expected:Qual_domain.kube_target
  -> binding:string
  -> timeout_s:float
  -> completion_timeout_s:float
  -> (Qual_database_ca.outcome list, string) result

(** Observe every declared application CA obligation and launch exactly one
    migration execution through the verified candidate, capturing its actual Job
    UID and observing its CA before the product's cleanup is released.

    [read] and [establish] must come from the authenticated transport. A recorder
    for another candidate assessment, a missing or ambiguous migration obligation,
    or an unreadable/expired transport is refused. Per-obligation failures remain
    in the returned outcomes; they are not collapsed into a PASS. Offline
    composition only; live callers use the phases at their lifecycle points. *)
val run
  :  directory:string
  -> prepared:Qual_candidate_obligations.t
  -> recorder:Qual_evidence.t
  -> read:(Qual_kubernetes.query -> Qual_kubernetes.reply)
  -> establish:(unit -> (Qual_domain.read_context, string) result)
  -> expected:Qual_domain.kube_target
  -> binding:string
  -> timeout_s:float
  -> completion_timeout_s:float
  -> (outcomes, string) result
