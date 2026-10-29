(** A small durable-task handler used by the serverless queue demo.

    The same [Sol_task.TASK] contract runs on the local Postgres runtime and on
    the Lambda SQS runtime; only the deployment changes. The handler is
    deliberately idempotent: a redelivery logs the same stable [task_id] and
    acknowledges, because this probe has no external side effect. *)

type t =
  | Send_welcome of { user_id : string }
  | Fail

let workspace = "pluto"

let kind = function
  | Send_welcome _ | Fail -> "send_welcome"
;;

let kinds = [ "send_welcome" ]

let encode = function
  | Send_welcome { user_id } ->
    Printf.sprintf
      {|{"kind":"send_welcome","user_id":%s}|}
      (Yojson.Safe.to_string (`String user_id))
  | Fail -> "fail"
;;

let decode payload =
  if String.equal payload "fail"
  then Ok Fail
  else (
    match
      try Ok (Yojson.Safe.from_string payload) with
      | Yojson.Json_error message -> Error message
    with
    | Error message -> Error message
    | Ok (`Assoc fields) ->
      (match List.assoc_opt "kind" fields, List.assoc_opt "user_id" fields with
       | Some (`String "send_welcome"), Some (`String user_id) ->
         Ok (Send_welcome { user_id })
       | _ -> Error ("invalid task payload: " ^ payload))
    | Ok (`String "fail") -> Ok Fail
    | Ok _ -> Error ("invalid task payload: " ^ payload))
;;

let handle ~task_id ?idempotency_key task =
  match task with
  | Send_welcome { user_id } ->
    Printf.eprintf
      "task_consumer task_id=%s kind=%s user_id=%s idempotency_key=%s\n%!"
      task_id
      (kind task)
      user_id
      (Option.value idempotency_key ~default:"-");
    Sol_task.Ack
  | Fail ->
    Printf.eprintf
      "task_consumer task_id=%s kind=%s idempotency_key=%s\n%!"
      task_id
      (kind task)
      (Option.value idempotency_key ~default:"-");
    Sol_task.Retry "synthetic failure"
;;
