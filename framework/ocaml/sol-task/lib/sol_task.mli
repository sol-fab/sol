(** Durable task handler contract shared by local Postgres, AWS SQS + Lambda,
    and GCP Pub/Sub push + Cloud Run.

    A task is a durable unit of work, not a Kafka fact and not a direct
    invocation. The transport owns delivery and retry; the application owns
    idempotency. A handler returns [Ack] only after its business side effect has
    committed, or [Retry] to leave the task eligible for another delivery.

    There is deliberately no application-selected dead-letter outcome in this
    first contract: each provider moves an exhausted task to its own
    dead-letter destination. There is also no promise that provider delivery
    counters equal handler invocations; the handler receives the stable
    [task_id] and optional [idempotency_key], not a delivery-attempt number. *)

type outcome =
  | Ack
  | Retry of string

type envelope =
  { task_id : string
  ; kind : string
  ; payload : string
  ; idempotency_key : string option
  }

type error =
  | Invalid of string
  | Too_large of
      { what : string
      ; limit : int
      ; actual : int
      }

(** The portable queue-message limit (256 KiB). It covers the encoded task
    envelope, so it fits both SQS and the shared contract even though Pub/Sub
    accepts larger messages. *)
val max_message_bytes : int

(** A stable opaque identity for a task. The local runtime stores it in the
    envelope; provider runtimes use the envelope identity rather than the
    provider's message id. *)
val new_task_id : unit -> string

val error_to_string : error -> string

module Envelope : sig
  type t = envelope

  (** [create] validates the kind, payload size, and optional identity. Omitting
      [task_id] generates one. It does not JSON-encode the envelope. *)
  val create
    :  kind:string
    -> payload:string
    -> ?task_id:string
    -> ?idempotency_key:string
    -> unit
    -> (t, error) result

  (** JSON-encode the envelope and enforce the portable message limit. *)
  val encode : t -> (string, error) result

  (** Parse and validate an envelope. A payload larger than the portable limit
      is rejected rather than truncated. *)
  val decode : string -> (t, error) result

  val to_json : t -> Yojson.Safe.t
end

module type TASK = sig
  type t

  (** The local Postgres queue scope. Cloud runtimes ignore it, but it keeps one
      handler module usable unchanged in every environment. *)
  val workspace : string

  val kind : t -> string

  (** Every kind this handler claims. The local runtime refuses to claim a row
      whose kind is not listed. *)
  val kinds : string list

  val encode : t -> string
  val decode : string -> (t, string) result

  (** Called once per delivery. [Ack] means the side effect committed; [Retry]
      means the task remains eligible for redelivery. Exceptions are treated as
      [Retry] by every runtime. *)
  val handle : task_id:string -> ?idempotency_key:string -> t -> outcome
end

val outcome_to_string : outcome -> string
