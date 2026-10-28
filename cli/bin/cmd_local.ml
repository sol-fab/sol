open Cmdliner
open Sol_cli_manifest
open Result.Syntax

let prefix_lines_thread fd label redact =
  let ic = Unix.in_channel_of_descr fd in
  (try
     while true do
       let line = input_line ic in
       Printf.printf "[%s] %s\n%!" label (Sol_cli_process.apply_redactions redact line)
     done
   with
   | End_of_file | Sys_error _ -> ());
  try Unix.close fd with
  | _ -> ()
;;

let resolve_run ?(include_functions = true) ?(report_contract = true) workspace_dir scope =
  workspace_dir |> Option.iter Unix.chdir;
  let* facts = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg in
  if not (String.equal (Sys.getcwd ()) facts.Sol_cli_workspace_model.root)
  then Unix.chdir facts.Sol_cli_workspace_model.root;
  let inventory = Sol_cli_workspace_model.services facts in
  let* resolved =
    Sol_cli_workload_selection.resolve_nonempty
      ~none:
        "no Sol services found. Expected app/<domain>/<name>_{svc,worker,fn}/ \
         directories with a Dockerfile."
      scope
      inventory
    |> Sol_cli_exit.of_msg
  in
  let* services =
    if include_functions
    then Ok resolved.services
    else (
      let long_running, functions =
        List.partition
          (fun (service : Sol_cli_manifest.service) ->
             service.primitive <> Sol_cli_manifest.Fn)
          resolved.services
      in
      match functions with
      | [] -> Ok long_running
      | _ ->
        (match resolved.request with
         | Sol_cli_deployment_scope.Unit_named _ ->
           Error
             (Sol_cli_exit.error
                "a -fn is run-once; use `sol local invoke <domain/name> [--event \
                 <file>]`                  instead of `sol local run`")
         | Sol_cli_deployment_scope.Whole_workspace
         | Sol_cli_deployment_scope.Whole_domain _ ->
           List.iter
             (fun (service : Sol_cli_manifest.service) ->
                Printf.eprintf
                  "skipping %s/%s (-fn): use `sol local invoke %s/%s` to invoke it once\n\
                   %!"
                  service.domain
                  service.name
                  service.domain
                  service.name)
             functions;
           if long_running = []
           then
             Error
               (Sol_cli_exit.error
                  "the selection contains only -fn units; use `sol local invoke \
                   <domain/name>`")
           else Ok long_running))
  in
  let* secret_values =
    services
    |> Sol_cli_result.map_list (fun (service : Sol_cli_manifest.service) ->
      let unit_address = service.domain ^ "/" ^ service.name in
      Sol_cli_local_secret_input.load
        ~root:facts.Sol_cli_workspace_model.root
        ~unit_address
      |> Result.map (fun values -> unit_address, values))
    |> Sol_cli_exit.of_msg
  in
  let* plan =
    Sol_cli_local_run.plan
      ~secret_values
      ~root:facts.Sol_cli_workspace_model.root
      ~facts
      services
    |> function
    | Ok plan -> Ok plan
    | Error errors ->
      errors
      |> List.iter (fun (label, message) ->
        Printf.eprintf "error: %s %s\n%!" label message);
      Error (Sol_cli_exit.reported ())
  in
  let* () =
    if report_contract
    then
      Sol_cli_contract.report
        ~workspace:facts.Sol_cli_workspace_model.root
        ~registry_url:Sol_cli_local_run.dev_registry_url
        ~scope:resolved.requested_scope
        ~mode:Sol_cli_contract.Apply
      |> Sol_cli_exit.of_msg
    else
      Sol_cli_contract.run
        ~echo:false
        ~workspace:facts.Sol_cli_workspace_model.root
        ~registry_url:Sol_cli_local_run.dev_registry_url
        ~scope:resolved.requested_scope
        ~mode:Sol_cli_contract.Apply
      |> Result.map ignore
      |> Sol_cli_exit.of_msg
  in
  Ok (services, plan)
;;

let build_services ?(progress = stdout) (plan : Sol_cli_local_run.plan) =
  Printf.fprintf progress "  Building...\n%!";
  let* () =
    plan.builds
    |> List.fold_left
         (fun acc (build : Sol_cli_local_run.command) ->
            match acc with
            | Error _ as e -> e
            | Ok () ->
              Sol_cli_process.run_shell (Sol_cli_local_run.build_line build)
              |> Result.map ignore
              |> Result.map_error (fun e ->
                Sol_cli_exit.error
                  (Printf.sprintf
                     "%s failed: %s"
                     (String.concat " " build.argv)
                     (Sol_cli_process.error_to_string e))))
         (Ok ())
  in
  Printf.fprintf progress "  Build done.\n\n%!";
  Ok ()
;;

let report_run_start ~dir ~services (plan : Sol_cli_local_run.plan) =
  Printf.printf "\n  Starting %d service(s) from %s\n" (List.length services) dir;
  plan.launches
  |> List.iter (fun (recipe : Sol_cli_local_run.recipe) ->
    let svc =
      List.find
        (fun svc -> String.equal (Sol_cli_local_run.label svc) recipe.label)
        services
    in
    Printf.printf
      "    [%s] %s → %s\n"
      (primitive_label svc.primitive)
      recipe.label
      recipe.artifact);
  Printf.printf "\n%!"
;;

let launch_services (plan : Sol_cli_local_run.plan) =
  Sol_cli_local_run.launch_all
    ~output:(fun (recipe : Sol_cli_local_run.recipe) ->
      let pipe_read, pipe_write = Unix.pipe ~cloexec:true () in
      let _t =
        Thread.create
          (fun () -> prefix_lines_thread pipe_read recipe.label plan.redact)
          ()
      in
      pipe_write)
    plan.launches
  |> Result.map_error Sol_cli_local_run.child_failure_to_string
  |> Sol_cli_exit.of_msg
;;

let supervise_children children =
  Printf.printf "  Services running — press Ctrl-C to stop all.\n\n%!";
  let on_status (child : Sol_cli_local_run.child) status =
    match status with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED code ->
      Printf.eprintf "[%s] exited with code %d\n%!" child.child_label code
    | Unix.WSIGNALED signal ->
      Printf.eprintf "[%s] was signalled (%d)\n%!" child.child_label signal
    | Unix.WSTOPPED signal ->
      Printf.eprintf "[%s] was stopped (%d)\n%!" child.child_label signal
  in
  match Sol_cli_local_run.supervise ~on_status children with
  | Ok () -> Ok ()
  | Error (Sol_cli_local_run.Interrupted signal) ->
    Printf.printf "\n  Stopping services...\n%!";
    Error (Sol_cli_exit.reported ~code:(Sol_cli_local_run.interrupt_exit_code signal) ())
  | Error failure ->
    Error (Sol_cli_exit.error (Sol_cli_local_run.child_failure_to_string failure))
;;

let dev_run workspace_dir scope =
  let dir = Option.value workspace_dir ~default:"." in
  let* services, plan =
    resolve_run ~include_functions:false ~report_contract:true workspace_dir scope
  in
  report_run_start ~dir ~services plan;
  let* () = build_services plan in
  let* children = launch_services plan in
  supervise_children children
;;

let local_down () =
  Printf.printf "Stopping Sol's local port-forwards...\n%!";
  Sol_cli_port_forward.stop_all ();
  Printf.printf
    "Port-forwards stopped. The %s cluster and its data were not touched.\n\
     Remove the cluster and its local data with: k3d cluster delete %s\n"
    Sol_cli_local_cluster.name
    Sol_cli_local_cluster.name;
  Ok ()
;;

let down_cmd =
  Cmd.v
    (Cmd.info
       "down"
       ~doc:
         "Stop Sol's local port-forwards. The k3d cluster and its data are left in \
          place; remove them with 'k3d cluster delete sol-local'.")
    Term.(const Sol_cli_exit.exit_on $ (const local_down $ const ()))
;;

let run_workspace_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "workspace"; "C" ]
        ~docv:"DIR"
        ~doc:"Workspace root directory (default: current directory)")
;;

let run_scope_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "scope" ]
        ~docv:"DOMAIN[/UNIT]"
        ~doc:
          "Run one domain (`payments`) or one unit (`payments/charge_svc`). Omit to run \
           every service in the workspace.")
;;

let run_subcmd =
  Cmd.v
    (Cmd.info
       "run"
       ~doc:"Run workspace services as native processes, with unit-scoped local secrets.")
    Term.(
      const Sol_cli_exit.exit_on $ (const dev_run $ run_workspace_arg $ run_scope_arg))
;;

let invoke_unit_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"DOMAIN/NAME" ~doc:"The -fn unit to invoke once")
;;

let invoke_event_arg =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "event" ]
        ~docv:"FILE"
        ~doc:
          "Supply the file's exact bytes on stdin. Omit for empty stdin; Sol does not \
           parse            the payload.")
;;

let read_event = function
  | None -> Ok None
  | Some path ->
    (try Ok (Some (In_channel.with_open_bin path In_channel.input_all)) with
     | Sys_error message -> Error (Sol_cli_exit.error message))
;;

let invoke_unit workspace_dir unit event =
  let dir = Option.value workspace_dir ~default:"." in
  let* event = read_event event in
  let* services, plan =
    resolve_run ~include_functions:true ~report_contract:false workspace_dir (Some unit)
  in
  let* () =
    match services with
    | [ service ] when service.primitive = Sol_cli_manifest.Fn -> Ok ()
    | [ _ ] ->
      Error
        (Sol_cli_exit.error
           (Printf.sprintf
              "%s is not a -fn unit; `sol local invoke` requires a run-once function"
              unit))
    | _ ->
      Error
        (Sol_cli_exit.error
           (Printf.sprintf
              "select exactly one -fn unit, not %d units"
              (List.length services)))
  in
  let* () = build_services ~progress:stderr plan in
  match plan.launches with
  | [ recipe ] ->
    (match Sol_cli_local_run.invoke ~event recipe with
     | Ok 0 -> Ok ()
     | Ok code ->
       Error
         (Sol_cli_exit.failure
            ~code
            (Printf.sprintf "%s exited with status %d" unit code))
     | Error (Sol_cli_local_run.Signaled { signal; _ }) ->
       let code = 128 + signal in
       Error
         (Sol_cli_exit.failure ~code (Printf.sprintf "%s was signalled (%d)" unit signal))
     | Error failure ->
       Error
         (Sol_cli_exit.error
            (Printf.sprintf
               "%s failed: %s"
               unit
               (Sol_cli_local_run.child_failure_to_string failure))))
  | launches ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf
            "expected one invocation recipe for %s, got %d"
            dir
            (List.length launches)))
;;

let invoke_subcmd =
  Cmd.v
    (Cmd.info
       "invoke"
       ~doc:
         "Invoke one -fn unit once. Event bytes go to stdin; output and exit status \
          are           passed through for scripting.")
    Term.(
      const Sol_cli_exit.exit_on
      $ (const invoke_unit $ run_workspace_arg $ invoke_unit_arg $ invoke_event_arg))
;;

let cmd =
  Cmd.group
    (Cmd.info "local" ~doc:"Operate on Sol's own local cluster (k3d)")
    [ Cmd_local_deploy.cmd
    ; down_cmd
    ; Cmd_rollback.local_cmd
    ; Cmd_migrate.local_cmd
    ; Cmd_releases.local_cmd
    ; run_subcmd
    ; invoke_subcmd
    ]
;;
