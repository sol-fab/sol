open Cmdliner
open Result.Syntax

let command_error message = Sol_cli_exit.error message

let runner argv =
  Sol_cli_serverless_runner.run argv
  |> Result.map (fun (output : Sol_cli_serverless_runner.output) ->
    ({ Sol_cli_cloud_run.stdout = output.stdout; stderr = output.stderr }
     : Sol_cli_cloud_run.output))
;;

let request
      ~project
      ~region
      ~service
      ~image
      ~max_attempts
      ~ack_deadline
      ~dlq_retention
      ~concurrency
      ~record
  =
  ({ Sol_cli_gcp_task.project
   ; region
   ; service
   ; image
   ; max_attempts
   ; ack_deadline_s = ack_deadline
   ; dlq_retention_s = dlq_retention
   ; concurrency
   ; record = Some record
   ; run = runner
   }
   : Sol_cli_gcp_task.request)
;;

let project_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "project" ] ~docv:"PROJECT" ~doc:"GCP project")
;;

let region_arg =
  Arg.(
    required & opt (some string) None & info [ "region" ] ~docv:"REGION" ~doc:"GCP region")
;;

let service_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "service" ] ~docv:"SERVICE" ~doc:"Sol task service name")
;;

let image_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "image" ] ~docv:"IMAGE" ~doc:"Immutable handler image")
;;

let record_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "record" ] ~docv:"PATH" ~doc:"Task ownership record")
;;

let max_attempts_arg =
  Arg.(
    value
    & opt int 5
    & info [ "max-attempts" ] ~docv:"N" ~doc:"Pub/Sub delivery budget (5-100)")
;;

let ack_deadline_arg =
  Arg.(
    value
    & opt int 60
    & info [ "ack-deadline" ] ~docv:"SECONDS" ~doc:"Pub/Sub ack deadline")
;;

let dlq_retention_arg =
  Arg.(
    value
    & opt int 604800
    & info [ "dlq-retention" ] ~docv:"SECONDS" ~doc:"Dead-letter retention")
;;

let concurrency_arg =
  Arg.(
    value
    & opt int 10
    & info [ "concurrency" ] ~docv:"N" ~doc:"Cloud Run maximum instances")
;;

let deploy_run
      project
      region
      service
      image
      max_attempts
      ack_deadline
      dlq_retention
      concurrency
      record
  =
  let request =
    request
      ~project
      ~region
      ~service
      ~image
      ~max_attempts
      ~ack_deadline
      ~dlq_retention
      ~concurrency
      ~record
  in
  let* release =
    Sol_cli_gcp_task.deploy request
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_cloud_run.failure_to_string failure))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_gcp_task.release_json release));
  Ok ()
;;

let deploy_cmd =
  Cmd.v
    (Cmd.info
       "deploy"
       ~doc:
         "Deploy a Pub/Sub topic, push subscription, dead-letter topic, and Cloud Run \
          handler")
    Term.(
      const
        (fun
            project
             region
             service
             image
             max_attempts
             ack_deadline
             dlq_retention
             concurrency
             record
           ->
           Sol_cli_exit.exit_on
             (deploy_run
                project
                region
                service
                image
                max_attempts
                ack_deadline
                dlq_retention
                concurrency
                record))
      $ project_arg
      $ region_arg
      $ service_arg
      $ image_arg
      $ max_attempts_arg
      $ ack_deadline_arg
      $ dlq_retention_arg
      $ concurrency_arg
      $ record_arg)
;;

let verify_run project region service record =
  let request =
    request
      ~project
      ~region
      ~service
      ~image:""
      ~max_attempts:5
      ~ack_deadline:60
      ~dlq_retention:604800
      ~concurrency:10
      ~record
  in
  let* release =
    Sol_cli_gcp_task.verify request ~record
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_cloud_run.failure_to_string failure))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_gcp_task.release_json release));
  Ok ()
;;

let verify_cmd =
  Cmd.v
    (Cmd.info
       "verify"
       ~doc:"Verify the Pub/Sub subscription, dead-letter policy, and Cloud Run URL")
    Term.(
      const (fun project region service record ->
        Sol_cli_exit.exit_on (verify_run project region service record))
      $ project_arg
      $ region_arg
      $ service_arg
      $ record_arg)
;;

let kind_arg =
  Arg.(required & opt (some string) None & info [ "kind" ] ~docv:"KIND" ~doc:"Task kind")
;;

let payload_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "payload" ] ~docv:"JSON" ~doc:"Raw task payload")
;;

let payload_file_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "payload-file" ] ~docv:"FILE" ~doc:"Read the raw task payload from FILE")
;;

let idempotency_key_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "idempotency-key" ] ~docv:"KEY" ~doc:"Application idempotency key")
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

let enqueue_run project region service record kind payload payload_file idempotency_key =
  let* payload = read_payload ~payload ~payload_file in
  let* envelope =
    Sol_task.Envelope.create ~kind ~payload ?idempotency_key ()
    |> Result.map_error (fun error -> command_error (Sol_task.error_to_string error))
  in
  let* body =
    Sol_task.Envelope.encode envelope
    |> Result.map_error (fun error -> command_error (Sol_task.error_to_string error))
  in
  let request =
    request
      ~project
      ~region
      ~service
      ~image:""
      ~max_attempts:5
      ~ack_deadline:60
      ~dlq_retention:604800
      ~concurrency:10
      ~record
  in
  let* message_id =
    Sol_cli_gcp_task.enqueue request ~record ~body
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_cloud_run.failure_to_string failure))
  in
  print_endline
    (Yojson.Safe.to_string
       (`Assoc [ "task_id", `String envelope.task_id; "message_id", `String message_id ]));
  Ok ()
;;

let enqueue_cmd =
  Cmd.v
    (Cmd.info "enqueue" ~doc:"Publish one task envelope to the deployed topic")
    Term.(
      const
        (fun project region service record kind payload payload_file idempotency_key ->
           Sol_cli_exit.exit_on
             (enqueue_run
                project
                region
                service
                record
                kind
                payload
                payload_file
                idempotency_key))
      $ project_arg
      $ region_arg
      $ service_arg
      $ record_arg
      $ kind_arg
      $ payload_arg
      $ payload_file_arg
      $ idempotency_key_arg)
;;

let to_revision_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "to-revision" ] ~docv:"REVISION" ~doc:"Cloud Run revision to restore")
;;

let rollback_run project region service record revision =
  let request =
    request
      ~project
      ~region
      ~service
      ~image:""
      ~max_attempts:5
      ~ack_deadline:60
      ~dlq_retention:604800
      ~concurrency:10
      ~record
  in
  let* release =
    Sol_cli_gcp_task.rollback request ~record ~revision
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_cloud_run.failure_to_string failure))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_gcp_task.release_json release));
  Ok ()
;;

let rollback_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Move Cloud Run traffic to a prior task revision")
    Term.(
      const (fun project region service record revision ->
        Sol_cli_exit.exit_on (rollback_run project region service record revision))
      $ project_arg
      $ region_arg
      $ service_arg
      $ record_arg
      $ to_revision_arg)
;;

let apply_arg = Arg.(value & flag & info [ "apply" ] ~doc:"Confirm destructive deletion")

let destroy_run project region service record apply =
  let request =
    request
      ~project
      ~region
      ~service
      ~image:""
      ~max_attempts:5
      ~ack_deadline:60
      ~dlq_retention:604800
      ~concurrency:10
      ~record
  in
  let* () =
    if apply then Ok () else Error (command_error "task destroy requires --apply")
  in
  Sol_cli_gcp_task.destroy request ~record
  |> Result.map_error (fun failure ->
    command_error (Sol_cli_cloud_run.failure_to_string failure))
;;

let destroy_cmd =
  Cmd.v
    (Cmd.info
       "destroy"
       ~doc:"Delete the task subscription, topics, service account, and Cloud Run service")
    Term.(
      const (fun project region service record apply ->
        Sol_cli_exit.exit_on (destroy_run project region service record apply))
      $ project_arg
      $ region_arg
      $ service_arg
      $ record_arg
      $ apply_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "gcp" ~doc:"GCP Pub/Sub + Cloud Run task lifecycle")
    [ deploy_cmd; verify_cmd; enqueue_cmd; rollback_cmd; destroy_cmd ]
;;
