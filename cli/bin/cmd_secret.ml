open Cmdliner
open Result.Syntax

type unit_key =
  { domain : string
  ; unit_name : string
  ; key : string
  }

type secret_address =
  | Unit of unit_key
  | Platform of string

let parse_secret_address value =
  match String.split_on_char '/' value with
  | [ "@platform"; key ] ->
    let* () = Sol_cli_secret.validate_key key in
    Ok (Platform key)
  | [ domain; unit_name; key ] when domain <> "" && unit_name <> "" && key <> "" ->
    let* () = Sol_cli_secret.validate_key key in
    Ok (Unit { domain; unit_name; key })
  | _ -> Error "secret address must look like <domain>/<unit>/<KEY> or @platform/<KEY>"
;;

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

let required_keys (target : Sol_cli_config.target) (toml : Sol_cli_toml.t) =
  Sol_cli_manifest.required_secret_keys
    ~transport:
      (Sol_cli_manifest.kafka_transport
         (Sol_cli_profile.platform_shape target.Sol_cli_config.profile))
    toml.secret_keys
;;

let platform_keys (target : Sol_cli_config.target) =
  match
    Sol_cli_manifest.kafka_transport (Sol_cli_profile.platform_shape target.profile)
  with
  | Sol_cli_manifest.Plaintext -> [ "POSTGRES_URL" ]
  | Sasl_ssl -> [ "POSTGRES_URL"; "KAFKA_SASL_PASSWORD"; "KAFKA_SSL_CA_CERT" ]
;;

let target_namespaces ~config ~facts ~workspace =
  Sol_cli_workspace_model.services facts
  |> List.filter (fun (service : Sol_cli_manifest.service) ->
    not (Sol_cli_config.is_omitted_service config ~name:service.name))
  |> Sol_cli_result.map_list (fun (service : Sol_cli_manifest.service) ->
    Sol_cli_deployment_plan.namespace_name ~workspace ~domain:service.domain)
  |> Result.map (List.sort_uniq String.compare)
;;

let check_platform_key config key =
  if List.mem key (platform_keys config.Sol_cli_config.target)
  then Ok ()
  else Error (Printf.sprintf "%s is not required by this target's Sol platform Jobs" key)
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

let check_set_permissions config facts address key =
  let unit_address = address in
  let* toml = find_unit_config facts unit_address in
  if not (List.mem key (required_keys config.Sol_cli_config.target toml))
  then Error (Printf.sprintf "%s/%s is not a declared secret" unit_address key)
  else (
    match
      Sol_cli_config.secret_authority config.Sol_cli_config.target ~unit_address ~key
    with
    | None ->
      Error
        (Printf.sprintf
           "target %s has no authority mapping for %s/%s; add it under \
            targets.<provider>/<region>.secrets in sol/environments.yml"
           config.target.name
           unit_address
           key)
    | Some Sol_cli_config.Sol_managed -> Ok toml
    | Some (Sol_cli_config.External _) ->
      Error
        (Printf.sprintf
           "%s/%s is externally managed; sol secret set cannot write it"
           unit_address
           key))
;;

let restart_unit ~ctx ~namespace ~unit_name ~key =
  let kind = "deployment/" ^ unit_name in
  match Sol_cli_kubectl.rollout_restart ~ctx ~kind ~namespace with
  | Error error ->
    Error
      (Printf.sprintf
         "secret value was written for %s/%s, but %s could not be restarted: %s"
         namespace
         key
         kind
         (Sol_cli_process.error_to_string error))
  | Ok _ ->
    (match
       Sol_cli_kubectl.rollout_status_with_timeout
         ~ctx
         ~kind_name:kind
         ~namespace
         ~timeout_s:120
     with
     | Ok _ -> Ok ()
     | Error error ->
       Error
         (Printf.sprintf
            "secret value was written for %s/%s, but %s did not become ready: %s"
            namespace
            key
            kind
            (Sol_cli_process.error_to_string error)))
;;

let run_set target address from_stdin from_file =
  let open Result.Syntax in
  let* address = parse_secret_address address in
  let* config = load_target target in
  let* facts = Sol_cli_workspace_model.load_cwd () in
  (* The namespace is "<workspace-name>-<domain>", where the name is the workspace directory's
     basename — the same value every other command uses (`current_name`). Passing the resolved
     root instead made the name an absolute path, so the namespace started with "/" and the
     whole `sol secret set` flow failed validation. *)
  let workspace = Sol_cli_workspace.current_name () in
  let* ctx = destination_context config in
  let* destination =
    match address with
    | Unit address ->
      let unit_address = address.domain ^ "/" ^ address.unit_name in
      let* _toml = check_set_permissions config facts unit_address address.key in
      let* namespace, secret_name =
        namespace_and_secret
          ~workspace
          ~domain:address.domain
          ~unit_name:address.unit_name
      in
      Ok (`Unit (unit_address, namespace, secret_name, address))
    | Platform key ->
      let* () = check_platform_key config key in
      let* namespaces = target_namespaces ~config ~facts ~workspace in
      if namespaces = []
      then Error "target has no active workload namespaces for Sol platform Jobs"
      else
        let* () = Sol_cli_secret.verify_platform_secret_destinations ~ctx ~namespaces in
        Ok (`Platform (key, namespaces))
  in
  (* Resolve authority and the exact destination before opening secret input. *)
  let* value = read_value ~from_stdin ~from_file in
  match destination with
  | `Unit (unit_address, namespace, secret_name, address) ->
    let* changed =
      Sol_cli_secret.set_unit_key ~ctx ~namespace ~secret_name ~key:address.key ~value
    in
    let unit =
      Sol_cli_workspace_model.workloads facts
      |> List.find_opt (fun (workload : Sol_cli_workspace_model.workload) ->
        workload.service.domain = address.domain
        && workload.service.name = address.unit_name)
    in
    let is_long_running =
      match unit with
      | Some
          { service = { primitive = Sol_cli_manifest.Svc | Sol_cli_manifest.Worker; _ }
          ; _
          } -> true
      | _ -> false
    in
    let* () =
      if changed && is_long_running
      then restart_unit ~ctx ~namespace ~unit_name:address.unit_name ~key:address.key
      else Ok ()
    in
    Printf.printf
      (if changed
       then "Secret updated for %s/%s%s.\n%!"
       else "Secret for %s/%s already had the requested value%s.\n%!")
      unit_address
      address.key
      (if changed && is_long_running then " and workload restarted" else "");
    Ok ()
  | `Platform (key, namespaces) ->
    let* changed = Sol_cli_secret.set_platform_key ~ctx ~namespaces ~key ~value in
    Printf.printf
      "Platform Job secret %s updated in %d namespace(s).\n%!"
      key
      (List.length changed);
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
  let* address = parse_secret_address address in
  let* config = load_target target in
  let* facts = Sol_cli_workspace_model.load_cwd () in
  let* ctx = destination_context config in
  match address with
  | Platform key ->
    if List.mem key (platform_keys config.target)
    then
      Error
        (Printf.sprintf
           "refusing to delete @platform/%s: the target's Sol Jobs require this key"
           key)
    else
      let* workspace =
        Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
        |> Result.map_error Sol_cli_workspace.workspace_error_to_string
      in
      let* namespaces = target_namespaces ~config ~facts ~workspace in
      let* deleted = Sol_cli_secret.delete_platform_key ~ctx ~namespaces ~key in
      (match deleted with
       | [] -> Printf.printf "No platform Job secret value existed for %s.\n%!" key
       | _ ->
         Printf.printf
           "Platform Job secret %s deleted in %d namespace(s).\n%!"
           key
           (List.length deleted));
      Ok ()
  | Unit address ->
    let unit_address = address.domain ^ "/" ^ address.unit_name in
    let* toml = find_unit_config facts unit_address in
    let* is_currently_declared =
      Ok (List.mem address.key (required_keys config.target toml))
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
  let* facts = Sol_cli_workspace_model.load_cwd () in
  let* ctx = destination_context config in
  let* workspace =
    Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
    |> Result.map_error Sol_cli_workspace.workspace_error_to_string
  in
  let* rows =
    Sol_cli_workspace_model.workloads facts
    |> Sol_cli_result.map_list (fun (workload : Sol_cli_workspace_model.workload) ->
      let unit_address = workload.service.domain ^ "/" ^ workload.service.name in
      match workload.config with
      | Error error -> Error (Sol_cli_toml.parse_error_to_string error)
      | Ok toml ->
        let keys = required_keys config.target toml in
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
  let* namespaces = target_namespaces ~config ~facts ~workspace in
  let* platform_rows =
    Sol_cli_result.map_list
      (fun namespace ->
         Sol_cli_secret.runtime_secret_keys ~ctx ~namespace
         |> Result.map (fun present -> namespace, present))
      namespaces
  in
  let platform_rows =
    platform_keys config.target
    |> List.map (fun key ->
      let missing =
        List.filter_map
          (fun (namespace, present) ->
             if List.mem key present then None else Some namespace)
          platform_rows
      in
      let state =
        if namespaces = []
        then "unavailable (no active workload namespace)"
        else if missing = []
        then "present"
        else "missing in " ^ String.concat ", " missing
      in
      Printf.sprintf "@platform/%s owner=sol state=%s" key state)
  in
  List.iter (Printf.printf "%s\n%!") (List.concat rows @ platform_rows);
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
    ; `P
        "ADDRESS is either DOMAIN/UNIT/KEY for one application unit or @platform/KEY for \
         a Sol Job input."
    ; `P
        "Platform keys are limited to POSTGRES_URL and, for TLS targets, \
         KAFKA_SASL_PASSWORD and KAFKA_SSL_CA_CERT. Platform values are written only to \
         sol-secrets objects in active target namespaces."
    ]
  in
  Cmd.v
    (Cmd.info
       "set"
       ~doc:"Create or update a Sol-owned unit secret or platform Job input"
       ~man)
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
    ; `P
        "ADDRESS is either DOMAIN/UNIT/KEY for one application unit or @platform/KEY for \
         a Sol Job input."
    ; `P
        "Required platform Job inputs cannot be deleted. Kafka platform inputs may be \
         deleted when this target does not use TLS."
    ]
  in
  Cmd.v
    (Cmd.info "delete" ~doc:"Delete an unused Sol-owned unit or platform Job input" ~man)
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
