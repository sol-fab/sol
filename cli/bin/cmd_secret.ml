open Cmdliner
open Result.Syntax

type unit_key =
  { domain : string
  ; unit_name : string
  ; key : string
  }

let parse_unit_key value =
  match String.split_on_char '/' value with
  | [ domain; unit_name; key ] when domain <> "" && unit_name <> "" && key <> "" ->
    let* () = Sol_cli_secret.validate_key key in
    Ok { domain; unit_name; key }
  | _ -> Error "secret address must look like <domain>/<unit>/<KEY>"
;;

let read_stdin_value () =
  let value = In_channel.input_all stdin in
  let value =
    if String.ends_with ~suffix:"\n" value
    then String.sub value 0 (String.length value - 1)
    else value
  in
  let value =
    if String.ends_with ~suffix:"\r" value
    then String.sub value 0 (String.length value - 1)
    else value
  in
  if value = "" then Error "secret value must not be empty" else Ok value
;;

let read_file_value path =
  match In_channel.with_open_bin path In_channel.input_all with
  | value ->
    let value =
      if String.ends_with ~suffix:"\n" value
      then String.sub value 0 (String.length value - 1)
      else value
    in
    let value =
      if String.ends_with ~suffix:"\r" value
      then String.sub value 0 (String.length value - 1)
      else value
    in
    if value = "" then Error (path ^ " contains an empty secret value") else Ok value
  | exception Sys_error message ->
    Error (Printf.sprintf "could not read %s: %s" path message)
;;

let read_interactive_value () =
  if not (Unix.isatty Unix.stdin)
  then
    Error "interactive secret input requires a terminal; use --from-stdin or --from-file"
  else (
    let original = Unix.tcgetattr Unix.stdin in
    let hidden = { original with Unix.c_echo = false } in
    Printf.printf "Secret value: ";
    flush stdout;
    Fun.protect
      ~finally:(fun () -> Unix.tcsetattr Unix.stdin Unix.TCSANOW original)
      (fun () ->
         Unix.tcsetattr Unix.stdin Unix.TCSANOW hidden;
         let value = read_line () in
         Printf.printf "\n%!";
         if value = "" then Error "secret value must not be empty" else Ok value))
;;

let read_value ~from_stdin ~from_file =
  match from_stdin, from_file with
  | true, Some _ -> Error "choose only one of --from-stdin and --from-file"
  | true, None -> read_stdin_value ()
  | false, Some path -> read_file_value path
  | false, None -> read_interactive_value ()
;;

let load_target target =
  let* config =
    Sol_cli_config.load_for_target ~target
    |> Result.map_error Sol_cli_config.error_to_string
  in
  if Sol_cli_config.target_declared config.target
  then Ok config
  else
    Error
      (Printf.sprintf
         "target %S is not declared in %s"
         target
         (Sol_cli_config.target_source config.target))
;;

let find_unit_config facts address =
  match
    List.find_opt
      (fun (workload : Sol_cli_workspace_model.workload) ->
         workload.service.domain ^ "/" ^ workload.service.name = address)
      (Sol_cli_workspace_model.workloads facts)
  with
  | None -> Error (Printf.sprintf "unit %s is not present in this workspace" address)
  | Some { config = Error error; service; _ } ->
    Error
      (Printf.sprintf
         "could not load %s/sol.toml: %s"
         service.dir
         (Sol_cli_toml.parse_error_to_string error))
  | Some { config = Ok config; _ } -> Ok config
;;

let required_keys ~platform_shape (toml : Sol_cli_toml.t) =
  Sol_cli_manifest.required_secret_keys
    ~transport:(Sol_cli_manifest.kafka_transport platform_shape)
    toml.secret_keys
;;

let namespace_and_secret ~workspace ~domain ~unit_name =
  let* namespace = Sol_cli_deployment_plan.namespace_name ~workspace ~domain in
  let* secret_name = Sol_cli_deployment_plan.k8s_name unit_name in
  Ok (namespace, Sol_cli_manifest.workload_secret_name secret_name)
;;

let destination_context config =
  let* destination = Sol_cli_config.destination_of_target config.Sol_cli_config.target in
  Ok (Sol_cli_kube_destination.context_of_destination destination)
;;

let check_set_permissions config facts unit_address unit_name key =
  let* toml = find_unit_config facts unit_address in
  (* The same resolved input ownership the plan gate uses: a key the target's database
     binding supplies, or an external authority owns, is refused here even though the unit
     declares it. *)
  let* () =
    Sol_cli_deploy_selection.check_unit_secret_write
      ~config
      ~unit_address
      ~unit_name
      ~declared:toml.secret_keys
      ~key
  in
  Ok toml
;;

let run_set target address from_stdin from_file =
  let* address = parse_unit_key address in
  let* config = load_target target in
  let* facts = Sol_cli_workspace_model.load_cwd () in
  let workspace = Sol_cli_workspace.current_name () in
  let* ctx = destination_context config in
  let unit_address = address.domain ^ "/" ^ address.unit_name in
  let* _toml =
    check_set_permissions config facts unit_address address.unit_name address.key
  in
  let* namespace, secret_name =
    namespace_and_secret ~workspace ~domain:address.domain ~unit_name:address.unit_name
  in
  (* Resolve ownership and destination before opening confidential input. *)
  let* value = read_value ~from_stdin ~from_file in
  let* changed =
    Sol_cli_secret.set_unit_key ~ctx ~namespace ~secret_name ~key:address.key ~value
  in
  (* **Set writes; activation is explicit.** Sol updates the value and stops there. A
     running process keeps reading the value it started with until something restarts it,
     and a value written before the workload exists has nothing to restart -- which is not
     a failure, and is exactly the state a deploy's own secret precondition requires
     (#1350, #1434). An unchanged deploy does not restart a running process; the
     operator activates the value through the workload's Kubernetes rollout tool.
     This also means a sequence of `sol secret set` calls is not an atomic rotation
     transaction: a process that starts between two writes can observe the newer value. *)
  Printf.printf
    (if changed
     then "Secret updated for %s/%s.\n%!"
     else "Secret for %s/%s already had the requested value.\n%!")
    unit_address
    address.key;
  Ok ()
;;

let current_release_uses_key ~ctx ~workspace ~unit_address ~key =
  match Sol_cli_release_store.current_record ~ctx ~workspace with
  | Error message ->
    Error ("could not establish current release secret consumers: " ^ message)
  | Ok None -> Ok false
  | Ok (Some release) ->
    Ok
      (List.exists
         (fun (workload : Sol_cli_release.recorded_workload) ->
            let spec = workload.spec in
            spec.domain ^ "/" ^ spec.name = unit_address
            && List.mem
                 key
                 (Sol_cli_manifest.required_secret_keys
                    ~transport:(Sol_cli_manifest.kafka_transport_of_config spec.config)
                    (List.map fst spec.secrets)))
         release.workloads)
;;

let run_delete target address =
  let open Result.Syntax in
  let* address = parse_unit_key address in
  let* config = load_target target in
  let* platform_shape = Sol_cli_config.platform_shape config in
  let* facts = Sol_cli_workspace_model.load_cwd () in
  let* ctx = destination_context config in
  let unit_address = address.domain ^ "/" ^ address.unit_name in
  let* toml = find_unit_config facts unit_address in
  let* is_currently_declared =
    Ok (List.mem address.key (required_keys ~platform_shape toml))
  in
  if is_currently_declared
  then
    Error
      (Printf.sprintf
         "refusing to delete %s/%s: the unit currently declares this key"
         unit_address
         address.key)
  else (
    match
      Sol_cli_config.secret_authority config.target ~unit_address ~key:address.key
    with
    | None ->
      Error
        (Printf.sprintf
           "target %s has no authority mapping for %s/%s"
           target
           unit_address
           address.key)
    | Some (Sol_cli_config.External _) ->
      Error
        (Printf.sprintf
           "%s/%s is externally managed; Sol cannot delete it"
           unit_address
           address.key)
    | Some Sol_cli_config.Sol_managed ->
      let* workspace =
        Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
        |> Result.map_error Sol_cli_workspace.workspace_error_to_string
      in
      let* in_release =
        current_release_uses_key ~ctx ~workspace ~unit_address ~key:address.key
      in
      if in_release
      then
        Error
          (Printf.sprintf
             "refusing to delete %s/%s: the recorded deployed release consumes this key"
             unit_address
             address.key)
      else
        let* namespace, secret_name =
          namespace_and_secret
            ~workspace
            ~domain:address.domain
            ~unit_name:address.unit_name
        in
        let* deleted =
          Sol_cli_secret.delete_unit_key ~ctx ~namespace ~secret_name ~key:address.key
        in
        Printf.printf
          (if deleted
           then "Secret deleted for %s/%s.\n%!"
           else "No secret value existed for %s/%s.\n%!")
          unit_address
          address.key;
        Ok ())
;;

let run_status target =
  let open Result.Syntax in
  let* config = load_target target in
  let* platform_shape = Sol_cli_config.platform_shape config in
  let* facts = Sol_cli_workspace_model.load_cwd () in
  let* ctx = destination_context config in
  (* The namespace is "<workspace-name>-<domain>", named for the workspace directory's
     basename. The resolved root is an absolute path, which is not a namespace; `set` and
     `delete` derive the same name this way. *)
  let workspace = Sol_cli_workspace.current_name () in
  let* rows =
    Sol_cli_workspace_model.workloads facts
    |> Sol_cli_result.map_list (fun (workload : Sol_cli_workspace_model.workload) ->
      let unit_address = workload.service.domain ^ "/" ^ workload.service.name in
      match workload.config with
      | Error error -> Error (Sol_cli_toml.parse_error_to_string error)
      | Ok toml ->
        let keys = required_keys ~platform_shape toml in
        let* namespace, secret_name =
          namespace_and_secret
            ~workspace
            ~domain:workload.service.domain
            ~unit_name:workload.service.name
        in
        let* existing = Sol_cli_secret.unit_secret_keys ~ctx ~namespace ~secret_name in
        let external_keys =
          keys
          |> List.filter (fun key ->
            match Sol_cli_config.secret_authority config.target ~unit_address ~key with
            | Some (Sol_cli_config.External _) -> true
            | _ -> false)
        in
        let* external_state =
          if external_keys = []
          then Ok None
          else
            let* unit_name =
              Sol_cli_deployment_plan.k8s_name_result workload.service.name
              |> Result.map_error (fun error ->
                Sol_cli_deployment_plan.plan_error_to_string error)
            in
            Sol_cli_secret.external_secret_status
              ~ctx
              ~namespace
              ~unit_name:(Sol_cli_deployment_plan.k8s_name_to_string unit_name)
              ~expected_keys:external_keys
            |> Result.map Option.some
        in
        Ok
          (keys
           |> List.map (fun key ->
             let owner =
               match Sol_cli_config.secret_authority config.target ~unit_address ~key with
               | None -> "unmapped"
               | Some Sol_cli_config.Sol_managed -> "sol"
               | Some (Sol_cli_config.External _) -> "external"
             in
             let state =
               match Sol_cli_config.secret_authority config.target ~unit_address ~key with
               | Some Sol_cli_config.Sol_managed ->
                 if List.mem key existing then "present" else "missing"
               | Some (Sol_cli_config.External _) ->
                 let state = Option.value external_state ~default:"unknown" in
                 state ^ "; restart required or process freshness unverified"
               | None -> "unmapped"
             in
             Printf.sprintf "%s/%s owner=%s state=%s" unit_address key owner state)))
  in
  List.iter (Printf.printf "%s\n%!") (List.concat rows);
  Ok ()
;;

let target_arg =
  Arg.(required & pos 0 (some Sol_cli_args.text) None & info [] ~docv:"TARGET")
;;

let address_arg =
  Arg.(required & pos 1 (some Sol_cli_args.text) None & info [] ~docv:"ADDRESS")
;;

let from_stdin_arg =
  Arg.(value & flag & info [ "from-stdin" ] ~doc:"Read the secret value from stdin.")
;;

let from_file_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "from-file" ] ~docv:"PATH" ~doc:"Read the secret value from a file.")
;;

let exit_msg result = Sol_cli_exit.exit_on (Sol_cli_exit.of_msg result)

let set_cmd =
  let man =
    [ `S Manpage.s_description
    ; `P "ADDRESS is DOMAIN/UNIT/KEY for one application unit."
    ; `P
        "Resource-owned inputs are not writable here. A database consumer reads the \
         deploy-delivered `<target>-dml-creds` / `<target>-ddl-creds` class Secrets, and \
         a Kafka consumer reads the target's resolved Kafka projection: managed Kafka is \
         delivered to `<target>-kafka-creds`, while external Kafka keeps its ESO Secret. \
         These resource-owned inputs are refused by `sol secret set`."
    ]
  in
  Cmd.v
    (Cmd.info "set" ~doc:"Create or update a Sol-owned unit secret" ~man)
    Term.(
      const (fun target address from_stdin from_file ->
        exit_msg (run_set target address from_stdin from_file))
      $ target_arg
      $ address_arg
      $ from_stdin_arg
      $ from_file_arg)
;;

let delete_cmd =
  let man =
    [ `S Manpage.s_description
    ; `P "ADDRESS is DOMAIN/UNIT/KEY for one application unit."
    ; `P
        "A key consumed by the current configuration or recorded deployed release cannot \
         be deleted."
    ]
  in
  Cmd.v
    (Cmd.info "delete" ~doc:"Delete an unused Sol-owned unit secret" ~man)
    Term.(
      const (fun target address -> exit_msg (run_delete target address))
      $ target_arg
      $ address_arg)
;;

let status_cmd =
  Cmd.v
    (Cmd.info "status" ~doc:"Show secret owners and delivery readiness for a target")
    Term.(const (fun target -> exit_msg (run_status target)) $ target_arg)
;;

let cmd =
  Cmd.group
    (Cmd.info "secret" ~doc:"Set and inspect unit secrets and platform Job inputs")
    [ set_cmd; delete_cmd; status_cmd ]
;;
