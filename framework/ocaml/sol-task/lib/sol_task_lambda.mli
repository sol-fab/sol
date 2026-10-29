(** The AWS SQS + Lambda runtime for the shared task contract.

    The function is invoked with an SQS event. Each record's body is a task
    envelope; the runtime calls the same [Sol_task.TASK] handler used locally
    and returns [batchItemFailures] for records that must be retried. The event
    source mapping must enable [ReportBatchItemFailures].

    There is no Function URL and no HTTP authentication here: SQS is the
    trigger, and the Lambda execution role authorizes the function's AWS
    resource access. *)

module Make (T : Sol_task.TASK) : sig
  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> ?on_error:(string -> unit)
    -> unit
    -> (unit, string) result

  module For_testing : sig
    (** Parse an SQS Lambda event and return the batch response. Exposed so the
        partial-failure and retry mapping can be tested without a provider. *)
    val handle_event : string -> (string, string) result
  end
end
