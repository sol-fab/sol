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

(** Launch [install/bin/sol migrate apply REQUESTED_TARGET] with a private duplex
    socket as stdin and [binding]. The installed candidate is probed first and
    refused before any mutation when it does not advertise the receipt protocol.
    [establish] independently supplies the submission's observation context; it is
    never taken from the product.

    [consume] is called with the validated locator before the product is
    acknowledged, so the ephemeral Job still exists. Its result is returned.
    A failed channel, validation or [consume] never suppresses the product's own
    wait and cleanup: the launcher always acknowledges, closes the channel and
    reaps the child. The product's exit status is never a verdict. *)
val run
  :  install:string
  -> workspace:string
  -> requested_target:string
  -> expected:Qual_domain.kube_target
  -> binding:string
  -> timeout_s:float
  -> completion_timeout_s:float
  -> establish:(unit -> (Qual_domain.read_context, string) result)
  -> consume:(locator -> ('a, string) result)
  -> ('a, string) result
