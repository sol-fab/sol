(** Minimal handler used by the durable-task live exercises.

    [ack] logs and acknowledges; [fail] logs and returns [Retry], so the
    provider's dead-letter path can be observed. The same binary selects the
    Lambda or Pub/Sub runtime from [SOL_TASK_RUNTIME]. *)

type t =
  | Ack_task
  | Fail_task

module T = struct
  type nonrec t = t

  let workspace = "task-live"

  let kind = function
    | Ack_task -> "ack"
    | Fail_task -> "fail"
  ;;

  let kinds = [ "ack"; "fail" ]

  let encode = function
    | Ack_task -> "ack"
    | Fail_task -> "fail"
  ;;

  let decode = function
    | "ack" -> Ok Ack_task
    | "fail" -> Ok Fail_task
    | other -> Error ("unknown task payload " ^ other)
  ;;

  let handle ~task_id ?idempotency_key task =
    Printf.eprintf
      "task_handler task_id=%s kind=%s idempotency_key=%s\n%!"
      task_id
      (kind task)
      (Option.value idempotency_key ~default:"-");
    match task with
    | Ack_task -> Sol_task.Ack
    | Fail_task -> Sol_task.Retry "live failure probe"
  ;;
end

let () =
  Eio_main.run
  @@ fun env ->
  let timed =
    object
      method net = env#net
      method clock = env#clock
      method mono_clock = env#mono_clock
    end
  in
  match Sys.getenv_opt "SOL_TASK_RUNTIME" with
  | Some "lambda" ->
    let module Lambda = Sol_task_lambda.Make (T) in
    (match Lambda.run ~env:timed () with
     | Ok () -> ()
     | Error message -> failwith message)
  | Some "pubsub" ->
    let module Pubsub = Sol_task_pubsub.Make (T) in
    (match Pubsub.run ~env:timed () with
     | Ok () -> ()
     | Error message -> failwith message)
  | other ->
    failwith
      (Printf.sprintf
         "SOL_TASK_RUNTIME must be lambda or pubsub (got %s)"
         (Option.value other ~default:"unset"))
;;
