open Cmdliner

let print_opt label = function
  | None -> ()
  | Some v -> Printf.printf "  %-14s %s\n" label v
;;

let print_index (index : Sol_cli_config.index) =
  Printf.printf "    index %s" index.index_name;
  match index.partition_key, index.sort_key with
  | None, None -> Printf.printf "\n"
  | partition_key, sort_key ->
    Printf.printf
      " (partition_key=%s sort_key=%s)\n"
      (Option.value partition_key ~default:"?")
      (Option.value sort_key ~default:"?")
;;

let fail_unimplemented (issues : Sol_cli_workspace_model.declaration_issue list) =
  let describe (issue : Sol_cli_workspace_model.declaration_issue) =
    Printf.sprintf "%s: %s" issue.path issue.message
  in
  Sol_cli_exit.error
    (Printf.sprintf
       "sol.yml declares units this workspace does not implement:\n  %s"
       (String.concat "\n  " (List.map describe issues)))
;;

let check_declared_units services =
  let open Result.Syntax in
  let* root =
    Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
    |> Result.map_error (fun e ->
      Sol_cli_exit.error (Sol_cli_workspace.workspace_error_to_string e))
  in
  let* scan =
    match Sol_cli_manifest.scan_workspace ~root () with
    | Ok scan -> Ok scan
    | Error Sol_cli_manifest.Missing_app_dir ->
      Ok { Sol_cli_manifest.workloads = []; unexpected = [] }
    | Error e -> Error (Sol_cli_exit.error (Sol_cli_manifest.discover_error_to_string e))
  in
  let issues = Sol_cli_workspace_model.declaration_issues ~scan services in
  let warnings, errors =
    List.partition
      (fun (issue : Sol_cli_workspace_model.declaration_issue) ->
         issue.severity = `Warning)
      issues
  in
  List.iter
    (fun (issue : Sol_cli_workspace_model.declaration_issue) ->
       Printf.eprintf "warning: %s: %s\n%!" issue.path issue.message)
    warnings;
  match errors with
  | [] -> Ok ()
  | _ -> Error (fail_unimplemented errors)
;;

let run target_name image_refs var_file vars =
  let open Result.Syntax in
  let* cfg =
    Sol_cli_config.load_for_target ~target:target_name
    |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
  in
  let project = Option.value cfg.project ~default:(Filename.basename (Sys.getcwd ())) in
  let target = cfg.target in
  let* () =
    match Sol_cli_config.execution_of_target target with
    | Sol_cli_config.Kubernetes -> Ok ()
    | Sol_cli_config.Serverless ->
      Error
        (Sol_cli_exit.error
           "sol plan does not implement execution: serverless targets; use the provider \
            lifecycle or sol deploy target dispatch, which fails closed on unsupported \
            configuration")
  in
  let resources = Sol_cli_config.resources cfg in
  let services = Sol_cli_config.services cfg in
  let* () = check_declared_units services in
  let* facts = Sol_cli_workspace_model.load_cwd () |> Sol_cli_exit.of_msg in
  let inventory = Sol_cli_workspace_model.services facts in
  let selected =
    List.filter
      (fun (service : Sol_cli_manifest.service) ->
         not (Sol_cli_config.is_omitted_service cfg ~name:service.name))
      inventory
  in
  let service_names = List.map (fun (s : Sol_cli_manifest.service) -> s.name) selected in
  let image_refs = List.map Sol_cli_image_ref.split_flag_value image_refs in
  let* provided =
    Sol_cli_image_ref.resolve ~service_names image_refs |> Sol_cli_exit.of_msg
  in
  let* previous =
    if List.length provided = List.length service_names
    then Ok []
    else
      let* destination =
        Sol_cli_config.destination_of_target target
        |> Result.map_error (fun message ->
          Sol_cli_exit.error
            (Printf.sprintf
               "cannot inherit workload images because the target Kubernetes destination \
                is unavailable (%s); supply --image-ref for every workload"
               message))
      in
      let ctx = Sol_cli_kube_destination.context_of_destination destination in
      match
        Sol_cli_release_store.current_record
          ~ctx
          ~workspace:(Sol_cli_workspace.current_name ())
      with
      | Error message ->
        Error
          (Sol_cli_exit.error
             (Printf.sprintf
                "cannot inherit workload images from the current release (%s); supply \
                 --image-ref for every workload"
                message))
      | Ok None -> Ok []
      | Ok (Some release) ->
        Ok
          (List.filter_map
             (fun (service : Sol_cli_manifest.service) ->
                let primitive = Sol_cli_manifest.primitive_label service.primitive in
                match
                  List.filter
                    (fun (workload : Sol_cli_release.recorded_workload) ->
                       workload.spec.domain = service.domain
                       && workload.spec.name = service.name
                       && workload.spec.primitive = primitive)
                    release.workloads
                with
                | [ workload ] -> Some (service.name, workload.spec.image)
                | _ -> None)
             selected)
  in
  let* image_refs =
    Sol_cli_image_ref.resolve_with_previous ~service_names image_refs previous
    |> Sol_cli_exit.of_msg
  in
  let registry = Option.value target.registry ~default:"resolved-image-refs" in
  let* planning =
    Sol_cli_deploy_selection.plan
      { workspace = Sol_cli_workspace.current_name ()
      ; registry
      ; sha = "unused"
      ; emit_to = None
      ; config = cfg
      ; facts
      ; inventory
      ; requested_scope = "target"
      ; image_refs
      ; services = selected
      }
    |> Result.map_error (function
      | Sol_cli_deploy_selection.Refused message -> Sol_cli_exit.error message
      | Preflight (profile, findings) ->
        Sol_cli_exit.failure (Sol_cli_profile_preflight.report profile findings))
  in
  Printf.printf "Project: %s\n" project;
  Printf.printf "Target: %s\n\n" target_name;
  Printf.printf "Target config:\n";
  print_opt "env" (Some target.env);
  print_opt "provider" (Some (Sol_cli_provider.to_string target.provider));
  print_opt "region" (Some target.region);
  print_opt "registry" target.registry;
  print_opt "cluster" target.cluster_name;
  print_opt "domain" target.base_domain;
  print_opt "cluster issuer" target.cluster_issuer;
  Printf.printf "\nResources:\n";
  if resources = [] then Printf.printf "  (none)\n";
  resources
  |> List.iter (fun (r : Sol_cli_config.resource) ->
    let type_suffix =
      match r.typ with
      | None -> ""
      | Some t -> " (" ^ t ^ ")"
    in
    Printf.printf "  - %s%s\n" r.name type_suffix;
    List.iter print_index r.indexes);
  Printf.printf "\nServices:\n";
  if services = [] then Printf.printf "  (none)\n";
  services
  |> List.iter (fun s ->
    let type_suffix =
      match s.Sol_cli_config.typ with
      | None -> ""
      | Some t -> " (" ^ t ^ ")"
    in
    Printf.printf "  - %s%s\n" s.Sol_cli_config.name type_suffix;
    print_opt "path" s.path;
    if s.uses <> []
    then
      Printf.printf
        "    uses: %s\n"
        (String.concat ", " (List.map Sol_cli_config.format_use_ref s.uses));
    match s.scale_min, s.scale_max with
    | None, None -> ()
    | min, max ->
      Printf.printf
        "    scale: %s..%s\n"
        (Option.fold ~none:"?" ~some:string_of_int min)
        (Option.fold ~none:"?" ~some:string_of_int max));
  Printf.printf "\nWorkload plan (all target workloads):\n";
  if planning.Sol_cli_deployment_plan.services = [] then Printf.printf "  (none)\n";
  List.iter
    (fun (service : Sol_cli_deployment_plan.service_spec) ->
       Printf.printf
         "  - %s/%s image=%s\n"
         service.domain
         service.source_name
         service.image)
    planning.services;
  let* secret_authorities =
    Sol_cli_deploy_selection.secret_authorities_for_plan ~config:cfg planning
    |> Sol_cli_exit.of_msg
  in
  Printf.printf
    "\nDeclared secret authorities (configuration does not prove provider access):\n";
  List.iter
    (fun (unit_address, key, authority) ->
       let source =
         match authority with
         | Sol_cli_secret_source.Sol_managed ->
           "declared Sol-managed Kubernetes Secret; value state deferred"
         | External { store; key } ->
           Printf.sprintf
             "declared ESO SecretStore %s key %s; sync state deferred"
             store
             key
         | Target_kafka { secret } ->
           Printf.sprintf
             "delivered by the target's managed Kafka authority into Secret %s; value \
              state deferred"
             secret
       in
       Printf.printf "  - %s/%s: %s\n" unit_address key source)
    secret_authorities;
  let workspace = Sol_cli_workspace.current_name () in
  let declared =
    List.map
      (fun (spec : Sol_cli_deployment_plan.service_spec) ->
         { Sol_cli_workload_ownership.resource =
             Sol_cli_deployment_plan.resource_of_spec spec
         ; namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace
         ; name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name
         })
      planning.services
  in
  let delta =
    match Sol_cli_config.destination_of_target target with
    | Error message -> Sol_cli_plan_delta.Deferred message
    | Ok destination ->
      let ctx = Sol_cli_kube_destination.context_of_destination destination in
      let evidence =
        Sol_cli_release_store.current_record ~ctx ~workspace
        |> Result.map (function
          | None -> []
          | Some (release : Sol_cli_release.t) ->
            List.concat_map
              (fun (w : Sol_cli_release.recorded_workload) -> w.Sol_cli_release_id.owned)
              release.workloads)
      in
      Sol_cli_plan_delta.compute ~ctx ~workspace ~evidence ~declared
  in
  Printf.printf "\n%s\n" (Sol_cli_plan_delta.to_string delta);
  let var_file =
    let cwd = Sys.getcwd () in
    let workspace_root =
      Option.value (Sol_cli_workspace.find_root ~dir:cwd) ~default:cwd
    in
    Sol_cli_terraform_vars.var_file
      ~cwd
      ~workspace_root
      ~flag:var_file
      ~target:target.terraform_var_file
  in
  let run_log = Sol_cli_run_log.create ~prefix:"plan" () in
  let* installation_established =
    match Sol_cli_installation.of_target target with
    | Error message ->
      Printf.printf
        "\n\
         Infrastructure and bootstrap plans deferred: installation configuration is \
         incomplete (%s).\n"
        message;
      Ok false
    | Ok configuration ->
      let verdicts =
        Sol_cli_provider_capabilities.installation_probes target.provider configuration
        |> Sol_cli_installation.observe
             ~run:
               (Sol_cli_provider_capabilities.installation_observation
                  ~provider:target.provider)
      in
      Printf.printf
        "\nInstallation prerequisites:\n%s\n"
        (Sol_cli_installation.summary verdicts);
      (match Sol_cli_installation.all_established verdicts with
       | Ok () ->
         let* () = Cmd_cloud_tf.check_terraform () in
         let* assets = Cmd_cloud_tf.resolve_assets () in
         (match
            Sol_cli_environment_stage.plan_config
              ~assets
              ~run_log
              ~config:cfg
              ~var_file
              ~vars
              ()
          with
          | Ok () -> Ok true
          | Error failure ->
            Error
              (Sol_cli_exit.error (Sol_cli_environment_stage.failure_to_string failure)))
       | Error _ ->
         let entirely_unmet =
           verdicts <> []
           && List.for_all
                (function
                  | _, Sol_cli_installation.Unmet _ -> true
                  | _ -> false)
                verdicts
         in
         if entirely_unmet
         then
           let* () = Cmd_cloud_tf.check_terraform () in
           let* assets = Cmd_cloud_tf.resolve_assets () in
           Sol_cli_installation_stage.plan_fresh
             ~assets
             ~provider:target.provider
             ~configuration
             ~run_log
             ~run:
               (Sol_cli_provider_capabilities.installation_observation
                  ~provider:target.provider)
             ()
           |> Sol_cli_exit.of_msg
           |> Result.map (fun () -> false)
         else (
           Printf.printf
             "\n\
              Infrastructure plan deferred: installation prerequisites are partially \
              established or unknown, so the durable root cannot be safely planned from \
              empty state.\n";
           Ok false))
  in
  let capabilities = Sol_cli_provider_capabilities.capabilities_of target.provider in
  let* () =
    if
      installation_established
      && capabilities.authorization_reconciler_field <> ""
      && List.mem_assoc capabilities.authorization_reconciler_field target.provider_fields
    then
      let* () =
        Cmd_grants.run
          ~config:cfg
          ~action:Cmd_grants.Plan
          ~target:target_name
          ~var_file
          ~vars
          ()
        |> Result.map_error (fun (failure : Sol_cli_exit.failure) -> failure)
      in
      Ok ()
    else (
      Printf.printf
        "\n\
         Authorization plan deferred: installation or target reconciler prerequisites \
         are not established.\n";
      Ok ())
  in
  let* () =
    Sol_cli_contract.plan_report
      ~workspace:(Sys.getcwd ())
      ~registry_url:(Sys.getenv_opt "SCHEMA_REGISTRY_URL")
      ~scope:"workspace"
    |> Sol_cli_exit.of_msg
  in
  Ok ()
;;

let target_arg =
  Sol_cli_target_arg.positional ~doc:"Deployment target path: <env>/<provider>/<region>."
;;

let image_ref_arg =
  Arg.(
    value
    & opt_all Sol_cli_args.text []
    & info
        [ "image-ref" ]
        ~docv:"SERVICE=REPO@sha256:DIGEST"
        ~doc:
          "Immutable image identity for one workload. Repeat for every target workload.")
;;

let var_file_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "var-file" ]
        ~docv:"PATH"
        ~doc:"Terraform variable file for target infrastructure planning.")
;;

let var_arg =
  Arg.(
    value
    & opt_all Sol_cli_args.text []
    & info [ "var" ] ~docv:"KEY=VALUE" ~doc:"Terraform variable. Repeatable.")
;;

let cmd =
  Cmd.v
    (Cmd.info
       "plan"
       ~doc:
         "Preview target infrastructure, authorization, workload intent, and the live \
          workload delta without applying changes.")
    Term.(
      const (fun target refs var_file vars ->
        Sol_cli_exit.exit_on (run target refs var_file vars))
      $ target_arg
      $ image_ref_arg
      $ var_file_arg
      $ var_arg)
;;
