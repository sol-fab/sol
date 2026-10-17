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

module For_testing : sig
  val backoff_s : rng:Random.State.t -> retry_policy -> attempt:int -> float
  val validate_retry_policy : retry_policy -> (unit, run_error) result
  val validate_timing : poll_interval_s:float -> lease_s:float -> (unit, run_error) result
  val validate_kinds : string list -> (unit, run_error) result
  val validate_workspace : string -> (unit, run_error) result
end
