type retry_policy = Sol_retry.policy =
  { base_delay_s : float
  ; max_delay_s : float
  ; max_attempts : int
  ; jitter_ratio : float
  }

val default_retry_policy : retry_policy

module type JOB = sig
  type t

  val workspace : string
  val kind : t -> string
  val kinds : string list
  val encode : t -> string
  val decode : string -> (t, string) result
  val handle : t -> (unit, string) result
end

type run_error =
  [ `Config of string
  | `Database of string
  ]

val run_error_to_string : run_error -> string

(** Insert one already-encoded payload into the durable queue. This is the
    transport-level insert used by clients that carry an encoded envelope (for
    example the task contract); it validates the same workspace and kind rules
    as {!Make.enqueue}. *)
val enqueue_raw
  :  Pg_db.tx
  -> workspace:string
  -> kind:string
  -> payload:string
  -> ?run_at:float
  -> ?dedupe_key:string
  -> unit
  -> (unit, Pg_error.t) result

module Make (J : JOB) : sig
  val enqueue
    :  Pg_db.tx
    -> ?run_at:float
    -> ?dedupe_key:string
    -> J.t
    -> (unit, Pg_error.t) result

  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> pool:Pg_db.pool
    -> ?retry_policy:retry_policy
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
    -> (unit, run_error) result
end

type backlog_row =
  { kind : string
  ; due : int64
  ; leased : int64
  ; scheduled : int64
  ; failed : int64
  ; oldest_due_s : float
  }

module For_testing : sig
  val backoff_s : rng:Random.State.t -> retry_policy -> attempt:int -> float
  val validate_retry_policy : retry_policy -> (unit, run_error) result
  val validate_timing : poll_interval_s:float -> lease_s:float -> (unit, run_error) result
  val validate_kinds : string list -> (unit, run_error) result
  val validate_workspace : string -> (unit, run_error) result
end

module Backlog_for_testing : sig
  val snapshot
    :  Pg_db.pool
    -> workspace:string
    -> kinds:string list
    -> (backlog_row list, Pg_error.t) result
end
