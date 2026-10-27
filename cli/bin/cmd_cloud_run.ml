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

let runner () =
  let run argv =
    Sol_cli_process.run (Sol_cli_process.cmd argv)
    |> Result.map (fun output -> output.Sol_cli_process.stdout)
    |> Result.map_error Sol_cli_process.error_to_string
  in
  let http ~url ~token =
    let config = Filename.temp_file "sol-cloud-run-curl-" ".conf" in
    let cleanup () =
      try Sys.remove config with
      | Sys_error _ -> ()
    in
    let write_config () =
      let channel = open_out_gen [ Open_creat; Open_trunc; Open_text ] 0o600 config in
      Fun.protect
        ~finally:(fun () -> close_out channel)
        (fun () ->
           match token with
           | None -> ()
           | Some token ->
             output_string
               channel
               (Printf.sprintf "header = \"Authorization: Bearer %s\"\n" token))
    in
    Fun.protect ~finally:cleanup (fun () ->
      try
        write_config ();
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
        | None -> Error "curl returned no HTTP status"
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
  and record =
    Arg.(
      value
      & opt (some string) None
      & info [ "record" ] ~docv:"PATH" ~doc:"Write the release record to PATH")
  in
  Term.(
    const (fun project region service image unit issuer jwks_uri callers record ->
      project, region, service, image, unit, issuer, jwks_uri, callers, record)
    $ project
    $ region
    $ service
    $ image
    $ unit
    $ issuer
    $ jwks_uri
    $ callers
    $ record)
;;

let deploy_run
      project
      region
      service
      image
      unit
      issuer
      jwks_uri
      callers
      record
      ingress_value
  =
  let* () = service_is_http service in
  let* ingress = parse_ingress ingress_value in
  let callers =
    List.filter_map
      (fun entry ->
         match String.index_opt entry '=' with
         | None -> None
         | Some at ->
           let unit = String.sub entry 0 at in
           let subject = String.sub entry (at + 1) (String.length entry - at - 1) in
           if unit = "" || subject = "" then None else Some (subject, unit))
      callers
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
      ~record
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

let with_common f =
  Term.(
    const
      (fun (project, region, service, image, unit, issuer, jwks_uri, callers, record) ->
         f project region service image unit issuer jwks_uri callers record)
    $ common_terms)
;;

let deploy_cmd =
  let doc = "Deploy or update one HTTP service on Cloud Run (experimental)." in
  let term =
    Term.(
      const
        (fun
            (project, region, service, image, unit, issuer, jwks_uri, callers, record)
             ingress
           ->
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
                record
                ingress))
      $ common_terms
      $ ingress_arg)
  in
  Cmd.v (Cmd.info "deploy" ~doc) term
;;

let verify_run project region service image unit issuer jwks_uri token_file ingress_value =
  let* () = service_is_http service in
  let* ingress = parse_ingress ingress_value in
  let* token =
    match token_file with
    | None -> Error (command_error "verify requires --token-file")
    | Some path ->
      (try Ok (String.trim (In_channel.with_open_bin path In_channel.input_all)) with
       | Sys_error message -> Error (command_error message))
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
            (project, region, service, image, unit, issuer, jwks_uri, _, _)
             token_file
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
                ingress))
      $ common_terms
      $ token_file
      $ ingress_arg)
  in
  Cmd.v (Cmd.info "verify" ~doc) term
;;

let rollback_run project region service image unit issuer jwks_uri revision ingress_value =
  let* () = service_is_http service in
  let* ingress = parse_ingress ingress_value in
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
    Sol_cli_cloud_run.rollback (runner ()) request ~revision
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
  let term =
    Term.(
      const
        (fun
            (project, region, service, image, unit, issuer, jwks_uri, _, _)
             revision
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
                ingress))
      $ common_terms
      $ revision
      $ ingress_arg)
  in
  Cmd.v
    (Cmd.info "rollback" ~doc:"Restore a Cloud Run revision and verify its traffic.")
    term
;;

let destroy_run project region service apply =
  let* () = if apply then Ok () else Error (command_error "destroy requires --apply") in
  let* () = service_is_http service in
  Sol_cli_cloud_run.destroy (runner ()) ~project ~region ~service
  |> Result.map_error (fun failure ->
    command_error (Sol_cli_cloud_run.failure_to_string failure))
;;

let destroy_cmd =
  let apply =
    Arg.(value & flag & info [ "apply" ] ~doc:"Confirm deletion of the named service")
  in
  let term =
    Term.(
      const (fun (project, region, service, _, _, _, _, _, _) apply ->
        Sol_cli_exit.exit_on (destroy_run project region service apply))
      $ common_terms
      $ apply)
  in
  Cmd.v
    (Cmd.info "destroy" ~doc:"Delete the named Cloud Run service and verify absence.")
    term
;;

let cmd =
  Cmd.group
    (Cmd.info "cloud-run" ~doc:"Experimental Cloud Run HTTP lifecycle adapter")
    [ deploy_cmd; verify_cmd; rollback_cmd; destroy_cmd ]
;;
