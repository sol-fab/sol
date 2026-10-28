open Cmdliner
open Result.Syntax

let command_error message = Sol_cli_exit.error message

let service_is_http name =
  let root =
    match Sol_cli_workspace.find_root ~dir:(Sys.getcwd ()) with
    | Some root -> root
    | None -> "."
  in
  let* declared =
    Sol_cli_config.load_declared ~root
    |> Result.map_error (fun e -> command_error (Sol_cli_config.error_to_string e))
  in
  let* () =
    match
      List.find_opt (fun (s : Sol_cli_config.service) -> s.name = name) declared.services
    with
    | None -> Error (command_error (Printf.sprintf "service %S is not declared" name))
    | Some { typ = Some ("http" | "svc"); _ } -> Ok ()
    | Some _ -> Error (command_error "not an HTTP service")
  in
  Sol_cli_lambda.provider_service_of name
  |> Result.map_error (fun f -> command_error (Sol_cli_lambda.failure_to_string f))
;;

let read_token path =
  try
    let token = String.trim (In_channel.with_open_bin path In_channel.input_all) in
    if token = ""
    then Error (command_error "token file is empty")
    else if String.exists (fun c -> c = '\n' || c = '\r') token
    then Error (command_error "token file must contain exactly one token")
    else Ok token
  with
  | Sys_error message -> Error (command_error message)
;;

let runner () =
  let run argv =
    Sol_cli_process.run (Sol_cli_process.cmd argv)
    |> Result.map (fun (o : Sol_cli_process.output) ->
      ({ Sol_cli_lambda.stdout = o.stdout; stderr = o.stderr } : Sol_cli_lambda.output))
    |> Result.map_error Sol_cli_process.error_to_string
  in
  let run_text argv =
    run argv |> Result.map (fun (o : Sol_cli_lambda.output) -> o.stdout)
  in
  let http ~url ~token =
    let config = Filename.temp_file "sol-lambda-curl-" ".conf" in
    let cleanup () = Sol_cli_fs.remove_reporting config in
    let write () =
      match token with
      | None -> Ok ()
      | Some token ->
        Sol_cli_fs.write_atomic
          ~perm:0o600
          config
          (Printf.sprintf "header = \"Authorization: Bearer %s\"\n" token)
    in
    Fun.protect ~finally:cleanup (fun () ->
      try
        let* () = write () |> Result.map_error (fun m -> m) in
        let* out =
          run_text
            [ "curl"
            ; "--silent"
            ; "--show-error"
            ; "--config"
            ; config
            ; "--output"
            ; "-"
            ; "--write-out"
            ; "\\n%{http_code}"
            ; url
            ]
        in
        match String.rindex_opt out '\n' with
        | None ->
          (match int_of_string_opt (String.trim out) with
           | Some s -> Ok (s, "")
           | None -> Error "curl returned no status")
        | Some at ->
          let body = String.sub out 0 at in
          let status = String.sub out (at + 1) (String.length out - at - 1) in
          (match int_of_string_opt (String.trim status) with
           | Some s -> Ok (s, body)
           | None -> Error "bad status")
      with
      | Sys_error m -> Error m)
  in
  run, http
;;

let request
      ~profile
      ~region
      ~service
      ~function_name
      ~image
      ~role
      ~unit
      ~issuer
      ~jwks_uri
      ~callers
      ~record
  =
  let run, http = runner () in
  { Sol_cli_lambda.profile
  ; region
  ; service
  ; function_name
  ; image
  ; role_arn = role
  ; identity = { unit; callers; issuer; jwks_uri }
  ; record
  ; run
  ; http
  }
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
    & info [ "service" ] ~docv:"SERVICE" ~doc:"Sol HTTP service")
;;

let image_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "image" ] ~docv:"IMAGE" ~doc:"Immutable image")
;;

let role_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "role" ] ~docv:"ARN" ~doc:"Lambda execution role ARN")
;;

let unit_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "unit" ] ~docv:"UNIT" ~doc:"Sol unit/audience")
;;

let issuer_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "issuer" ] ~docv:"ISSUER" ~doc:"Trusted issuer")
;;

let jwks_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "jwks-uri" ] ~docv:"URI" ~doc:"Trusted JWKS URI")
;;

let callers_arg =
  Arg.(value & opt_all string [] & info [ "caller" ] ~docv:"UNIT=SUBJECT" ~doc:"Caller")
;;

let record_arg =
  Arg.(
    value & opt (some string) None & info [ "record" ] ~docv:"PATH" ~doc:"Release record")
;;

let parse_callers values =
  List.map
    (fun entry ->
       match String.index_opt entry '=' with
       | None -> "", ""
       | Some at ->
         String.sub entry (at + 1) (String.length entry - at - 1), String.sub entry 0 at)
    values
;;

let deploy_run profile region service image role unit issuer jwks_uri callers record =
  let* function_name = service_is_http service in
  let r =
    request
      ~profile
      ~region
      ~service
      ~function_name
      ~image
      ~role
      ~unit
      ~issuer
      ~jwks_uri
      ~callers:(parse_callers callers)
      ~record
  in
  let* release =
    Sol_cli_lambda.deploy r
    |> Result.map_error (fun f -> command_error (Sol_cli_lambda.failure_to_string f))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_lambda.release_json release));
  Ok ()
;;

let common =
  Term.(
    const (fun profile region service image role unit issuer jwks_uri callers record ->
      profile, region, service, image, role, unit, issuer, jwks_uri, callers, record)
    $ profile_arg
    $ region_arg
    $ service_arg
    $ image_arg
    $ role_arg
    $ unit_arg
    $ issuer_arg
    $ jwks_arg
    $ callers_arg
    $ record_arg)
;;

let deploy_cmd =
  Cmd.v
    (Cmd.info "deploy" ~doc:"Deploy or update an HTTP service on AWS Lambda")
    Term.(
      const
        (fun
            (profile, region, service, image, role, unit, issuer, jwks, callers, record)
           ->
           Sol_cli_exit.exit_on
             (deploy_run
                profile
                region
                service
                image
                role
                unit
                issuer
                jwks
                callers
                record))
      $ common)
;;

let token_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "token-file" ] ~docv:"PATH" ~doc:"Authorized token")
;;

let verify_run profile region service image role unit issuer jwks token_file =
  let* function_name = service_is_http service in
  let* token = read_token token_file |> Result.map_error (fun f -> f) in
  let r =
    request
      ~profile
      ~region
      ~service
      ~function_name
      ~image
      ~role
      ~unit
      ~issuer
      ~jwks_uri:jwks
      ~callers:[]
      ~record:None
  in
  let* o =
    Sol_cli_lambda.verify r ~token
    |> Result.map_error (fun f -> command_error (Sol_cli_lambda.failure_to_string f))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_lambda.observed_json o));
  Ok ()
;;

let verify_cmd =
  Cmd.v
    (Cmd.info "verify" ~doc:"Verify Lambda readiness and protected route")
    Term.(
      const (fun profile region service image role unit issuer jwks token ->
        Sol_cli_exit.exit_on
          (verify_run profile region service image role unit issuer jwks token))
      $ profile_arg
      $ region_arg
      $ service_arg
      $ image_arg
      $ role_arg
      $ unit_arg
      $ issuer_arg
      $ jwks_arg
      $ token_arg)
;;

let version_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "to-version" ] ~docv:"VERSION" ~doc:"Version to restore")
;;

let rollback_run profile region service image role unit issuer jwks version token_file =
  let* function_name = service_is_http service in
  let* token = read_token token_file |> Result.map_error (fun f -> f) in
  let r =
    request
      ~profile
      ~region
      ~service
      ~function_name
      ~image
      ~role
      ~unit
      ~issuer
      ~jwks_uri:jwks
      ~callers:[]
      ~record:None
  in
  let* o =
    Sol_cli_lambda.rollback r ~version ~token
    |> Result.map_error (fun f -> command_error (Sol_cli_lambda.failure_to_string f))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_lambda.observed_json o));
  Ok ()
;;

let rollback_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Restore a Lambda alias version")
    Term.(
      const (fun profile region service image role unit issuer jwks version token ->
        Sol_cli_exit.exit_on
          (rollback_run profile region service image role unit issuer jwks version token))
      $ profile_arg
      $ region_arg
      $ service_arg
      $ image_arg
      $ role_arg
      $ unit_arg
      $ issuer_arg
      $ jwks_arg
      $ version_arg
      $ token_arg)
;;

let destroy_run profile region service record =
  let* _ = service_is_http service in
  let r =
    request
      ~profile
      ~region
      ~service
      ~function_name:""
      ~image:"x"
      ~role:"x"
      ~unit:""
      ~issuer:""
      ~jwks_uri:""
      ~callers:[]
      ~record:None
  in
  Sol_cli_lambda.destroy r ~profile ~region ~service ~record
  |> Result.map_error (fun f -> command_error (Sol_cli_lambda.failure_to_string f))
;;

let destroy_record_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "record" ] ~docv:"PATH" ~doc:"Ownership record")
;;

let destroy_cmd =
  Cmd.v
    (Cmd.info "destroy" ~doc:"Delete a Lambda function and verify absence")
    Term.(
      const (fun profile region service record ->
        Sol_cli_exit.exit_on (destroy_run profile region service record))
      $ profile_arg
      $ region_arg
      $ service_arg
      $ destroy_record_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "lambda" ~doc:"Experimental AWS Lambda HTTP lifecycle adapter")
    [ deploy_cmd; verify_cmd; rollback_cmd; destroy_cmd ]
;;
