open Cmdliner
open Result.Syntax

let fail message = Sol_cli_exit.failure ~code:2 ("sol check: " ^ message)

let secret_authority_findings ~facts =
  let finding severity path message : Sol_cli_check.finding =
    { severity; path; message }
  in
  match
    Sol_cli_config.discover_target_paths ~root:facts.Sol_cli_workspace_model.root ()
  with
  | Error error ->
    [ finding
        Sol_cli_check.Severity.Error
        "sol/environments.yml"
        (Sol_cli_config.error_to_string error)
    ]
  | Ok target_paths ->
    target_paths
    |> List.concat_map (fun target_path ->
      match Sol_cli_config.load_for_target ~target:target_path with
      | Error error ->
        [ finding
            Sol_cli_check.Severity.Error
            "sol/environments.yml"
            (Sol_cli_config.error_to_string error)
        ]
      | Ok config ->
        (match Sol_cli_config.platform_shape config with
         | Error message ->
           [ finding Sol_cli_check.Severity.Error "sol/environments.yml" message ]
         | Ok platform_shape ->
           Sol_cli_workspace_model.workloads facts
           |> List.filter (fun (workload : Sol_cli_workspace_model.workload) ->
             not
               (Sol_cli_config.is_omitted_service
                  config
                  ~name:workload.service.Sol_cli_manifest.name))
           |> List.concat_map (fun (workload : Sol_cli_workspace_model.workload) ->
             match workload.config with
             | Error _ -> []
             | Ok toml ->
               let unit_address = workload.service.domain ^ "/" ^ workload.service.name in
               let required_keys =
                 Sol_cli_manifest.required_secret_keys
                   ~transport:(Sol_cli_manifest.kafka_transport platform_shape)
                   toml.secret_keys
               in
               let resolution =
                 Sol_cli_config.resolve_secret_authorities
                   config.target
                   ~unit_address
                   ~required_keys
               in
               let path = "sol/environments.yml" in
               List.map
                 (fun key ->
                    finding
                      Sol_cli_check.Severity.Error
                      path
                      (Printf.sprintf
                         "%s/%s has no authority mapping for target %s; declare \
                          authority: sol or external"
                         unit_address
                         key
                         target_path))
                 resolution.missing
               @ List.map
                   (fun key ->
                      finding
                        Sol_cli_check.Severity.Warning
                        path
                        (Printf.sprintf
                           "%s/%s maps an undeclared secret for target %s; it will not \
                            be projected"
                           unit_address
                           key
                           target_path))
                   resolution.additional)))
;;

let findings_for ~facts = function
  | None ->
    Ok
      (Sol_cli_check.run ~facts
       @ secret_authority_findings ~facts
       @ Sol_cli_check.generated_contract_findings ~facts)
  | Some requested ->
    let* selected =
      Sol_cli_workload_selection.resolve
        ~what:"--scope"
        (Some requested)
        (Sol_cli_workspace_model.services facts)
      |> Result.map_error fail
    in
    Ok
      (Sol_cli_check.run_services ~facts selected.services
       @ Sol_cli_check.declaration_findings_in_scope ~facts selected.request
       @ secret_authority_findings ~facts
       @ Sol_cli_check.generated_contract_findings ~facts)
;;

type outcome =
  { findings : Sol_cli_check.finding list
  ; result : (unit, Sol_cli_exit.failure) result
  }

let inspect scope =
  let* workspace = Sol_cli_workspace.enter_cwd () in
  let* facts =
    Sol_cli_workspace_model.load ~root:workspace.Sol_cli_workspace.root
    |> Sol_cli_exit.of_msg
  in
  let* findings = findings_for ~facts scope in
  let result =
    if Sol_cli_check.has_errors findings
    then Error (Sol_cli_exit.reported ~code:2 ())
    else Ok ()
  in
  Ok { findings; result }
;;

let run scope =
  let* outcome = inspect scope in
  outcome.findings
  |> List.iter (fun finding ->
    Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string finding));
  (match outcome.result with
   | Ok () -> Printf.printf "sol check: ok\n"
   | Error _ -> ());
  outcome.result
;;

let scope_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "scope" ]
        ~docv:"DOMAIN[/UNIT]"
        ~doc:
          "Check one domain (`payments`) or one unit (`payments/charge_svc`). A name \
           that matches nothing fails closed and says what does, rather than selecting \
           nothing and reporting success. Generated contract freshness is always checked \
           workspace-wide.")
;;

let cmd =
  Cmd.v
    (Cmd.info
       "check"
       ~doc:"Validate Sol workload declarations without Docker or Kubernetes.")
    Term.(const Sol_cli_exit.exit_on $ (const run $ scope_arg))
;;
