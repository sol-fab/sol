open Cmdliner
open Result.Syntax

let command_error message = Sol_cli_exit.error message

let default_postgres_url () =
  Sol_cli_local_platform.postgres_url ~host:"localhost" ~port:5432
;;

let read_payload ~payload ~payload_file =
  match payload, payload_file with
  | Some _, Some _ ->
    Error (command_error "pass exactly one of --payload and --payload-file")
  | None, None -> Error (command_error "one of --payload or --payload-file is required")
  | Some payload, None -> Ok payload
  | None, Some path ->
    (try Ok (In_channel.with_open_bin path In_channel.input_all) with
     | Sys_error message -> Error (command_error message))
;;

let enqueue ~kind ~payload ~payload_file ~idempotency_key ~postgres_url =
  let* payload = read_payload ~payload ~payload_file in
  let* envelope =
    Sol_task.Envelope.create ~kind ~payload ?idempotency_key ()
    |> Result.map_error (fun error -> command_error (Sol_task.error_to_string error))
  in
  let* encoded =
    Sol_task.Envelope.encode envelope
    |> Result.map_error (fun error -> command_error (Sol_task.error_to_string error))
  in
  let workspace = Sol_cli_workspace.current_name () in
  let url = Option.value postgres_url ~default:(default_postgres_url ()) in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      match
        Pg_db.create_pool ~url ~pool_size:1 ~sw ~stdenv:(env :> Caqti_eio.stdenv) ()
      with
      | Error error ->
        Error
          (command_error
             ("could not connect to the local task queue: " ^ Pg_error.to_string error))
      | Ok pool ->
        (match
           Pg_db.transaction pool (fun tx ->
             Sol_jobs.enqueue_raw
               tx
               ~workspace
               ~kind
               ~payload:encoded
               ?dedupe_key:idempotency_key
               ())
         with
         | Error error ->
           Error
             (command_error
                ("could not enqueue the task (does the workspace have the sol_jobs \
                  migration?): "
                 ^ Pg_error.to_string error))
         | Ok () ->
           print_endline envelope.task_id;
           Ok ())))
;;

let kind_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "kind" ] ~docv:"KIND" ~doc:"Task kind claimed by the worker")
;;

let payload_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "payload" ]
        ~docv:"JSON"
        ~doc:"Raw task payload passed to the handler unchanged")
;;

let payload_file_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "payload-file" ]
        ~docv:"FILE"
        ~doc:"Read the raw task payload from FILE instead of --payload")
;;

let idempotency_key_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "idempotency-key" ]
        ~docv:"KEY"
        ~doc:
          "Application idempotency key. It is carried in the envelope and used as the \
           local dedupe key; a duplicate enqueue is a no-op.")
;;

let postgres_url_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "postgres-url" ]
        ~docv:"URL"
        ~doc:
          "Postgres URL for the local queue. Defaults to the local Sol Postgres at \
           localhost:5432.")
;;

let enqueue_term =
  Term.(
    const (fun kind payload payload_file idempotency_key postgres_url ->
      Sol_cli_exit.exit_on
        (enqueue ~kind ~payload ~payload_file ~idempotency_key ~postgres_url))
    $ kind_arg
    $ payload_arg
    $ payload_file_arg
    $ idempotency_key_arg
    $ postgres_url_arg)
;;

let enqueue_cmd =
  Cmd.v
    (Cmd.info
       "enqueue"
       ~doc:
         "Enqueue one durable task in the local Postgres queue. Prints the task id \
          unless an idempotency key made the enqueue a duplicate no-op.")
    enqueue_term
;;

let cmd =
  Cmd.group
    (Cmd.info "task" ~doc:"Operate on the local durable task queue")
    [ enqueue_cmd ]
;;
