(** Qualification-owned launcher for the verified candidate's migration execution.
    It supplies the private submission channel and requires the caller to persist
    the durable receipt and complete independent observation before the product's
    own cleanup is released. It produces no release verdict. *)

type locator = private
  { receipt : Sol_cli_migration_execution.receipt
  ; context : Qual_domain.read_context
  ; identity : Qual_domain.job_identity
  }

(** The installed candidate's bundled producer must advertise the receipt protocol
    before the launcher will let a candidate mutate a cluster. A missing, failing
    or mismatched producer is [Ok false] only when it answered with another
    protocol; an unreadable producer is [Error]. *)
val protocol_supported : install:string -> (bool, string) result

module Fixture : sig
  (** Process boundary without candidate authority, for offline fixtures only.
      It takes an explicit program instead of a verified candidate, so production
      callers must use {!run}. *)
  val run
    :  program:string
    -> workspace:string
    -> requested_target:string
    -> expected:Qual_domain.kube_target
    -> binding:string
    -> timeout_s:float
    -> completion_timeout_s:float
    -> establish:(unit -> (Qual_domain.read_context, string) result)
    -> consume:(locator -> ('a, string) result)
    -> ('a, string) result
end

(** Launch the verified candidate's own
    [install/bin/sol migrate apply REQUESTED_TARGET], where the install, workspace
    and requested target come from [verified] rather than a later caller-supplied
    path. The candidate is probed first and refused before any mutation when it
    does not advertise the receipt protocol.

    [establish] independently supplies the submission's observation context; it is
    never taken from the product, and it must name [expected] and still be fresh
    when the locator is handed to [consume].

    [consume] is called with the validated locator before the product is
    acknowledged, so the ephemeral Job still exists. Its result is returned unless
    the child outlives [completion_timeout_s]: an overdue child yields an explicit
    unestablished error naming the remaining cleanup responsibility, never a
    completed result. A failed channel, validation or [consume] never suppresses
    the product's own wait and cleanup. The product's exit status is never a
    verdict.

    [completion_timeout_s] must accommodate the product's full migration wait and
    cleanup budget. *)
val run
  :  verified:Qual_candidate.t
  -> expected:Qual_domain.kube_target
  -> binding:string
  -> timeout_s:float
  -> completion_timeout_s:float
  -> establish:(unit -> (Qual_domain.read_context, string) result)
  -> consume:(locator -> ('a, string) result)
  -> ('a, string) result
