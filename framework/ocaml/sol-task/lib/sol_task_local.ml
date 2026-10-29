open Result.Syntax

let envelope_error error =
  Pg_error.Query_error ("sol-task: " ^ Sol_task.error_to_string error)
;;

module Make (T : Sol_task.TASK) = struct
  module Wrapped = struct
    type t =
      { envelope : Sol_task.envelope
      ; task : T.t
      ; encoded : string
      }

    let workspace = T.workspace
    let kinds = T.kinds
    let kind (t : t) = t.envelope.kind
    let encode (t : t) = t.encoded

    let decode text =
      let* envelope =
        Sol_task.Envelope.decode text |> Result.map_error Sol_task.error_to_string
      in
      let* task =
        T.decode envelope.payload
        |> Result.map_error (fun message ->
          Printf.sprintf "task %s payload: %s" envelope.task_id message)
      in
      Ok { envelope; task; encoded = text }
    ;;

    let handle (t : t) =
      match
        T.handle
          ~task_id:t.envelope.task_id
          ?idempotency_key:t.envelope.idempotency_key
          t.task
      with
      | Sol_task.Ack -> Ok ()
      | Sol_task.Retry message -> Error message
    ;;
  end

  module Jobs = Sol_jobs.Make (Wrapped)

  let enqueue tx ?run_at ?idempotency_key task =
    let* envelope =
      Sol_task.Envelope.create
        ~kind:(T.kind task)
        ~payload:(T.encode task)
        ?idempotency_key
        ()
      |> Result.map_error envelope_error
    in
    let* encoded = Sol_task.Envelope.encode envelope |> Result.map_error envelope_error in
    Jobs.enqueue
      tx
      ?run_at
      ?dedupe_key:idempotency_key
      { Wrapped.envelope; task; encoded }
  ;;

  let run = Jobs.run

  module For_testing = struct
    let encode task =
      let* envelope =
        Sol_task.Envelope.create ~kind:(T.kind task) ~payload:(T.encode task) ()
        |> Result.map_error Sol_task.error_to_string
      in
      Sol_task.Envelope.encode envelope |> Result.map_error Sol_task.error_to_string
    ;;

    let decode text =
      let* wrapped = Wrapped.decode text in
      Ok (wrapped.envelope, wrapped.task)
    ;;

    let handle envelope task = Wrapped.handle { Wrapped.envelope; task; encoded = "" }
  end
end
