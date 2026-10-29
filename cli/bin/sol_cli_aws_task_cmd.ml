open Cmdliner
open Result.Syntax

let command_error message = Sol_cli_exit.error message

let runner argv =
  Sol_cli_serverless_runner.run argv
  |> Result.map (fun (output : Sol_cli_serverless_runner.output) ->
    ({ Sol_cli_aws_lambda_common.stdout = output.stdout; stderr = output.stderr }
     : Sol_cli_aws_lambda_common.output))
;;

let request
      ~profile
      ~region
      ~service
      ~image
      ~role
      ~max_attempts
      ~visibility_timeout
      ~dlq_retention
      ~concurrency
      ~record
  =
  ({ Sol_cli_aws_task.profile
   ; region
   ; service
   ; image
   ; role_arn = role
   ; max_attempts
   ; visibility_timeout_s = visibility_timeout
   ; dlq_retention_s = dlq_retention
   ; concurrency
   ; record = Some record
   ; run = runner
   }
   : Sol_cli_aws_task.request)
;;

let profile_arg =
  Arg.(
    value & opt (some string) None & info [ "profile" ] ~docv:"PROFILE" ~doc:"AWS profile")
;;

let region_arg =
  Arg.(
    required & opt (some string) None & info [ "region" ] ~docv:"REGION" ~doc:"AWS region")
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

let role_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "role" ] ~docv:"ARN" ~doc:"Lambda execution role ARN")
;;

let record_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "record" ] ~docv:"PATH" ~doc:"Task ownership record")
;;

let max_attempts_arg =
  Arg.(
    value & opt int 5 & info [ "max-attempts" ] ~docv:"N" ~doc:"Handler delivery budget")
;;

let visibility_timeout_arg =
  Arg.(
    value
    & opt int 60
    & info [ "visibility-timeout" ] ~docv:"SECONDS" ~doc:"SQS visibility timeout")
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
    & info [ "concurrency" ] ~docv:"N" ~doc:"Maximum concurrent SQS invocations")
;;

let deploy_run
      profile
      region
      service
      image
      role
      max_attempts
      visibility_timeout
      dlq_retention
      concurrency
      record
  =
  let request =
    request
      ~profile
      ~region
      ~service
      ~image
      ~role
      ~max_attempts
      ~visibility_timeout
      ~dlq_retention
      ~concurrency
      ~record
  in
  let* release =
    Sol_cli_aws_task.deploy request
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_aws_lambda_common.failure_to_string failure))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_aws_task.release_json release));
  Ok ()
;;

let deploy_cmd =
  Cmd.v
    (Cmd.info
       "deploy"
       ~doc:
         "Deploy an SQS queue, dead-letter queue, Lambda handler, and event source \
          mapping")
    Term.(
      const
        (fun
            profile
             region
             service
             image
             role
             max_attempts
             visibility_timeout
             dlq_retention
             concurrency
             record
           ->
           Sol_cli_exit.exit_on
             (deploy_run
                profile
                region
                service
                image
                role
                max_attempts
                visibility_timeout
                dlq_retention
                concurrency
                record))
      $ profile_arg
      $ region_arg
      $ service_arg
      $ image_arg
      $ role_arg
      $ max_attempts_arg
      $ visibility_timeout_arg
      $ dlq_retention_arg
      $ concurrency_arg
      $ record_arg)
;;

let verify_run profile region service record =
  let request =
    request
      ~profile
      ~region
      ~service
      ~image:""
      ~role:""
      ~max_attempts:5
      ~visibility_timeout:60
      ~dlq_retention:604800
      ~concurrency:10
      ~record
  in
  let* release =
    Sol_cli_aws_task.verify request ~record
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_aws_lambda_common.failure_to_string failure))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_aws_task.release_json release));
  Ok ()
;;

let verify_cmd =
  Cmd.v
    (Cmd.info "verify" ~doc:"Verify the task queue, mapping, and Lambda alias")
    Term.(
      const (fun profile region service record ->
        Sol_cli_exit.exit_on (verify_run profile region service record))
      $ profile_arg
      $ region_arg
      $ service_arg
      $ record_arg)
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

let enqueue_run profile region service record kind payload payload_file idempotency_key =
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
      ~profile
      ~region
      ~service
      ~image:""
      ~role:""
      ~max_attempts:5
      ~visibility_timeout:60
      ~dlq_retention:604800
      ~concurrency:10
      ~record
  in
  let* message_id =
    Sol_cli_aws_task.enqueue request ~record ~body
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_aws_lambda_common.failure_to_string failure))
  in
  print_endline
    (Yojson.Safe.to_string
       (`Assoc [ "task_id", `String envelope.task_id; "message_id", `String message_id ]));
  Ok ()
;;

let enqueue_cmd =
  Cmd.v
    (Cmd.info "enqueue" ~doc:"Send one task envelope to the deployed SQS queue")
    Term.(
      const
        (fun profile region service record kind payload payload_file idempotency_key ->
           Sol_cli_exit.exit_on
             (enqueue_run
                profile
                region
                service
                record
                kind
                payload
                payload_file
                idempotency_key))
      $ profile_arg
      $ region_arg
      $ service_arg
      $ record_arg
      $ kind_arg
      $ payload_arg
      $ payload_file_arg
      $ idempotency_key_arg)
;;

let to_version_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "to-version" ] ~docv:"VERSION" ~doc:"Lambda version to restore")
;;

let rollback_run profile region service record version =
  let request =
    request
      ~profile
      ~region
      ~service
      ~image:""
      ~role:""
      ~max_attempts:5
      ~visibility_timeout:60
      ~dlq_retention:604800
      ~concurrency:10
      ~record
  in
  let* release =
    Sol_cli_aws_task.rollback request ~record ~version
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_aws_lambda_common.failure_to_string failure))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_aws_task.release_json release));
  Ok ()
;;

let rollback_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Move the Lambda task alias to a prior version")
    Term.(
      const (fun profile region service record version ->
        Sol_cli_exit.exit_on (rollback_run profile region service record version))
      $ profile_arg
      $ region_arg
      $ service_arg
      $ record_arg
      $ to_version_arg)
;;

let apply_arg =
  Arg.(
    value
    & flag
    & info
        [ "apply" ]
        ~doc:"Confirm destructive deletion; without it, destroy does nothing")
;;

let destroy_run profile region service record apply =
  let request =
    request
      ~profile
      ~region
      ~service
      ~image:""
      ~role:""
      ~max_attempts:5
      ~visibility_timeout:60
      ~dlq_retention:604800
      ~concurrency:10
      ~record
  in
  let* () =
    if apply then Ok () else Error (command_error "task destroy requires --apply")
  in
  Sol_cli_aws_task.destroy request ~record
  |> Result.map_error (fun failure ->
    command_error (Sol_cli_aws_lambda_common.failure_to_string failure))
;;

let destroy_cmd =
  Cmd.v
    (Cmd.info
       "destroy"
       ~doc:"Delete the task mapping, function, source queue, and dead-letter queue")
    Term.(
      const (fun profile region service record apply ->
        Sol_cli_exit.exit_on (destroy_run profile region service record apply))
      $ profile_arg
      $ region_arg
      $ service_arg
      $ record_arg
      $ apply_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "aws" ~doc:"AWS SQS + Lambda task lifecycle")
    [ deploy_cmd; verify_cmd; enqueue_cmd; rollback_cmd; destroy_cmd ]
;;
