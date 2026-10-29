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
  | Some "local" ->
    let url =
      match Sys.getenv_opt "POSTGRES_URL" with
      | Some url when String.trim url <> "" -> url
      | _ -> failwith "POSTGRES_URL is required for SOL_TASK_RUNTIME=local"
    in
    Eio.Switch.run
    @@ fun sw ->
    (match
       Pg_db.create_pool ~url ~pool_size:1 ~sw ~stdenv:(env :> Caqti_eio.stdenv) ()
     with
     | Error error -> failwith ("local task pool: " ^ Pg_error.to_string error)
     | Ok pool ->
       let module Local = Sol_task_local.Make (Task_consumer) in
       (match Local.run ~env:timed ~pool ~metrics_port:0 () with
        | Ok () -> ()
        | Error error -> failwith (Sol_jobs.run_error_to_string error)))
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
