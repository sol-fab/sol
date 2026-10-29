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
  | Some "pubsub" ->
    let module Pubsub = Sol_task_pubsub.Make (Task_consumer) in
    (match Pubsub.run ~env:timed () with
     | Ok () -> ()
     | Error message -> failwith message)
  | Some "lambda" | None ->
    let module Lambda = Sol_task_lambda.Make (Task_consumer) in
    (match Lambda.run ~env:timed () with
     | Ok () -> ()
     | Error message -> failwith message)
  | Some other ->
    failwith (Printf.sprintf "SOL_TASK_RUNTIME must be lambda or pubsub (got %s)" other)
;;
