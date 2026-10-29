(** The local durable task runtime.

    Tasks are rows in the existing [sol_jobs] table. The application only
    supplies the task type, its workspace/kind declaration, and the handler; the
    shared envelope carries the stable task identity and optional idempotency
    key. Retry and terminal retention are the existing [sol-jobs] semantics:
    a [Retry] is retried with backoff until the handler budget is exhausted, then
    the row becomes [failed] and remains visible until the retention sweep.

    This is the local implementation of the shared task contract. It does not
    invent a second queue table or a second retry engine. *)

module Make (T : Sol_task.TASK) : sig
  (** Enqueue through the caller's transaction. When [idempotency_key] is
      supplied it is both carried in the envelope and used as the [sol_jobs]
      dedupe key, so a repeated enqueue in the retention window is a no-op. *)
  val enqueue
    :  Pg_db.tx
    -> ?run_at:float
    -> ?idempotency_key:string
    -> T.t
    -> (unit, Pg_error.t) result

  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> pool:Pg_db.pool
    -> ?retry_policy:Sol_jobs.retry_policy
    -> ?poll_interval_s:float
    -> ?lease_s:float
    -> ?execution_timeout_s:float
    -> ?ot:Sol_obs.t
    -> ?metrics_port:int
    -> ?on_ready:(unit -> unit)
    -> ?stop:unit Eio.Promise.t
    -> ?max_jobs:int
    -> ?max_claim_failures:int
    -> ?terminal_retention_s:float
    -> ?sweep_interval_s:float
    -> unit
    -> (unit, Sol_jobs.run_error) result

  module For_testing : sig
    val encode : T.t -> (string, string) result
    val decode : string -> (Sol_task.envelope * T.t, string) result
    val handle : Sol_task.envelope -> T.t -> (unit, string) result
  end
end
