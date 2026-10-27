open Cmdliner
open Result.Syntax

let command_error message = Sol_cli_exit.error message

let service_is_http name =
  let root =
    match Sol_cli_workspace.find_root ~dir:(Sys.getcwd ()) with
    | Some root -> root
    | None -> "."
  in
  match Sol_cli_config.load_declared ~root with
  | Error e -> Error (command_error (Sol_cli_config.error_to_string e))
  | Ok declared ->
    (match
       List.find_opt (fun (s : Sol_cli_config.service) -> s.name = name) declared.services
     with
     | None ->
       Error (command_error (Printf.sprintf "service %S is not declared in sol.yml" name))
     | Some { typ = Some ("http" | "svc"); _ } -> Ok ()
     | Some _ ->
       Error (command_error (Printf.sprintf "service %S is not an HTTP service" name)))
;;

let read_token_file path =
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
    |> Result.map (fun output -> output.Sol_cli_process.stdout)
    |> Result.map_error Sol_cli_process.error_to_string
  in
  let http ~url ~token =
    let config = Filename.temp_file "sol-cloud-run-curl-" ".conf" in
    let cleanup () = Sol_cli_fs.remove_reporting config in
    let write_config () =
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
        let* () =
          write_config ()
          |> Result.map_error (fun message -> "could not write curl config: " ^ message)
        in
        let argv =
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
        let* body_status = run argv in
        match String.rindex_opt body_status '\n' with
        | None ->
          (match int_of_string_opt (String.trim body_status) with
           | Some status -> Ok (status, "")
           | None -> Error "curl returned no HTTP status")
        | Some at ->
          let body = String.sub body_status 0 at in
          let status =
            String.sub body_status (at + 1) (String.length body_status - at - 1)
          in
          (match int_of_string_opt (String.trim status) with
           | Some status -> Ok (status, body)
           | None -> Error ("curl returned an invalid HTTP status: " ^ status))
      with
      | Sys_error message -> Error message)
  in
  { Sol_cli_cloud_run.run; http }
;;

let request
      ~project
      ~region
      ~service
      ~image
      ~unit
      ~issuer
      ~jwks_uri
      ~callers
      ~record
      ~ingress
  =
  Sol_cli_cloud_run.
    { project
    ; region
    ; service
    ; image
    ; identity = { unit; callers; issuer; jwks_uri }
    ; ingress
    ; record
    }
;;

let ingress_arg =
  Arg.(
    required
    & opt (some string) None
    & info
        [ "ingress" ]
        ~docv:"INGRESS"
        ~doc:"Explicit ingress mode; only public is supported")
;;

let record_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "record" ]
        ~docv:"PATH"
        ~doc:"Release/ownership record path (verify writes it)")
;;

let parse_ingress value =
  match Sol_cli_cloud_run.ingress_of_string value with
  | Ok ingress -> Ok ingress
  | Error failure -> Error (command_error (Sol_cli_cloud_run.failure_to_string failure))
;;

let common_terms =
  let project =
    Arg.(
      required
      & opt (some string) None
      & info [ "project" ] ~docv:"PROJECT" ~doc:"GCP project")
  and region =
    Arg.(
      required
      & opt (some string) None
      & info [ "region" ] ~docv:"REGION" ~doc:"GCP region")
  and service =
    Arg.(
      required
      & opt (some string) None
      & info [ "service" ] ~docv:"SERVICE" ~doc:"HTTP service name from sol.yml")
  and image =
    Arg.(
      required
      & opt (some string) None
      & info [ "image" ] ~docv:"IMAGE" ~doc:"Immutable image reference")
  and unit =
    Arg.(
      required
      & opt (some string) None
      & info [ "unit" ] ~docv:"UNIT" ~doc:"Sol workload unit/audience")
  and issuer =
    Arg.(
      required
      & opt (some string) None
      & info [ "issuer" ] ~docv:"ISSUER" ~doc:"Trusted workload issuer")
  and jwks_uri =
    Arg.(
      required
      & opt (some string) None
      & info [ "jwks-uri" ] ~docv:"URI" ~doc:"Explicit HTTPS JWKS URI")
  and callers =
    Arg.(
      value
      & opt_all string []
      & info [ "caller" ] ~docv:"UNIT=SUBJECT" ~doc:"Authorized caller entry; repeatable")
  in
  Term.(
    const (fun project region service image unit issuer jwks_uri callers ->
      project, region, service, image, unit, issuer, jwks_uri, callers)
    $ project
    $ region
    $ service
    $ image
    $ unit
    $ issuer
    $ jwks_uri
    $ callers)
;;

let deploy_run project region service image unit issuer jwks_uri callers ingress_value =
  let* () = service_is_http service in
  let* ingress = parse_ingress ingress_value in
  let* callers =
    let parse entry =
      match String.index_opt entry '=' with
      | None ->
        Error
          (command_error
             (Printf.sprintf "invalid --caller %S; expected UNIT=SUBJECT" entry))
      | Some at ->
        let unit = String.sub entry 0 at in
        let subject = String.sub entry (at + 1) (String.length entry - at - 1) in
        if unit = "" || subject = ""
        then
          Error
            (command_error
               (Printf.sprintf "invalid --caller %S; expected UNIT=SUBJECT" entry))
        else Ok (subject, unit)
    in
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | entry :: rest ->
        let* caller = parse entry in
        loop (caller :: acc) rest
    in
    loop [] callers
  in
  let request =
    request
      ~project
      ~region
      ~service
      ~image
      ~unit
      ~issuer
      ~jwks_uri
      ~callers
      ~record:None
      ~ingress
  in
  let* release =
    Sol_cli_cloud_run.deploy (runner ()) request
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_cloud_run.failure_to_string failure))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_cloud_run.release_json release));
  Ok ()
;;

let deploy_cmd =
  let doc = "Deploy or update one HTTP service on Cloud Run (experimental)." in
  let term =
    Term.(
      const
        (fun (project, region, service, image, unit, issuer, jwks_uri, callers) ingress ->
           Sol_cli_exit.exit_on
             (deploy_run
                project
                region
                service
                image
                unit
                issuer
                jwks_uri
                callers
                ingress))
      $ common_terms
      $ ingress_arg)
  in
  Cmd.v (Cmd.info "deploy" ~doc) term
;;

let verify_run
      project
      region
      service
      image
      unit
      issuer
      jwks_uri
      token_file
      record
      ingress_value
  =
  let* () = service_is_http service in
  let* ingress = parse_ingress ingress_value in
  let* token =
    match token_file with
    | None -> Error (command_error "verify requires --token-file")
    | Some path -> read_token_file path
  in
  let request =
    request
      ~project
      ~region
      ~service
      ~image
      ~unit
      ~issuer
      ~jwks_uri
      ~callers:[]
      ~record
      ~ingress
  in
  let* observed =
    Sol_cli_cloud_run.verify (runner ()) request ~token
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_cloud_run.failure_to_string failure))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_cloud_run.observed_json observed));
  Ok ()
;;

let verify_cmd =
  let token_file =
    Arg.(
      value
      & opt (some string) None
      & info
          [ "token-file" ]
          ~docv:"PATH"
          ~doc:"File containing the authorized caller token")
  in
  let doc =
    "Verify readiness and authorized/unauthorized /quote behavior on an existing Cloud \
     Run service."
  in
  let term =
    Term.(
      const
        (fun
            (project, region, service, image, unit, issuer, jwks_uri, _)
             token_file
             record
             ingress
           ->
           Sol_cli_exit.exit_on
             (verify_run
                project
                region
                service
                image
                unit
                issuer
                jwks_uri
                token_file
                record
                ingress))
      $ common_terms
      $ token_file
      $ record_arg
      $ ingress_arg)
  in
  Cmd.v (Cmd.info "verify" ~doc) term
;;

let rollback_run
      project
      region
      service
      image
      unit
      issuer
      jwks_uri
      revision
      token_file
      ingress_value
  =
  let* () = service_is_http service in
  let* ingress = parse_ingress ingress_value in
  let* token =
    match token_file with
    | None ->
      Error (command_error "rollback requires --token-file for serving verification")
    | Some path -> read_token_file path
  in
  let request =
    request
      ~project
      ~region
      ~service
      ~image
      ~unit
      ~issuer
      ~jwks_uri
      ~callers:[]
      ~record:None
      ~ingress
  in
  let* observed =
    Sol_cli_cloud_run.rollback (runner ()) request ~revision ~token
    |> Result.map_error (fun failure ->
      command_error (Sol_cli_cloud_run.failure_to_string failure))
  in
  print_endline (Yojson.Safe.to_string (Sol_cli_cloud_run.observed_json observed));
  Ok ()
;;

let rollback_cmd =
  let revision =
    Arg.(
      required
      & opt (some string) None
      & info [ "revision" ] ~docv:"REVISION" ~doc:"Revision to restore")
  in
  let token_file =
    Arg.(
      value
      & opt (some string) None
      & info
          [ "token-file" ]
          ~docv:"PATH"
          ~doc:"Authorized token file for serving verification")
  in
  let term =
    Term.(
      const
        (fun
            (project, region, service, image, unit, issuer, jwks_uri, _)
             revision
             token_file
             ingress
           ->
           Sol_cli_exit.exit_on
             (rollback_run
                project
                region
                service
                image
                unit
                issuer
                jwks_uri
                revision
                token_file
                ingress))
      $ common_terms
      $ revision
      $ token_file
      $ ingress_arg)
  in
  Cmd.v
    (Cmd.info "rollback" ~doc:"Restore a Cloud Run revision and verify its traffic.")
    term
;;

let destroy_run project region service record apply =
  let* () = if apply then Ok () else Error (command_error "destroy requires --apply") in
  let* () = service_is_http service in
  Sol_cli_cloud_run.destroy (runner ()) ~project ~region ~service ~record
  |> Result.map_error (fun failure ->
    command_error (Sol_cli_cloud_run.failure_to_string failure))
;;

let destroy_record_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "record" ] ~docv:"PATH" ~doc:"Ownership record written by verify")
;;

let destroy_cmd =
  let apply =
    Arg.(value & flag & info [ "apply" ] ~doc:"Confirm deletion of the named service")
  in
  let term =
    Term.(
      const (fun (project, region, service, _, _, _, _, _) record apply ->
        Sol_cli_exit.exit_on (destroy_run project region service record apply))
      $ common_terms
      $ destroy_record_arg
      $ apply)
  in
  Cmd.v
    (Cmd.info
       "destroy"
       ~doc:
         "Delete the named Cloud Run service and verify absence. The image repository is \
          an external prerequisite and is not removed.")
    term
;;

let cmd =
  Cmd.group
    (Cmd.info "cloud-run" ~doc:"Experimental Cloud Run HTTP lifecycle adapter")
    [ deploy_cmd; verify_cmd; rollback_cmd; destroy_cmd ]
;;
