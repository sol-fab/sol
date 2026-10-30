(** The GCP Pub/Sub push + Cloud Run runtime for the shared task contract.

    Pub/Sub delivers one message per HTTP POST. The message data is a task
    envelope; the runtime calls the same [Sol_task.TASK] handler used locally
    and by Lambda. [200] acknowledges, [500] requests redelivery, and [400]
    rejects a malformed envelope. Pub/Sub's dead-letter policy supplies the
    terminal destination after its delivery-attempt limit.

    Incoming authentication is the Cloud Run IAM boundary: the service is
    deployed without public invoker access and grants [roles/run.invoker] only
    to the Pub/Sub push service account. The runtime does not add a second
    application authentication layer. *)

module Make (T : Sol_task.TASK) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> ?port:int
    -> ?drain_timeout_s:float
    -> ?stop:unit Eio.Promise.t
    -> unit
    -> (unit, string) result

  module For_testing : sig
    (** Parse a Pub/Sub push body and return the HTTP status and body. Exposed
        so the ack/retry/malformed mapping can be tested without a provider. *)
    val handle_push : string -> (int * string, string) result
  end
end
