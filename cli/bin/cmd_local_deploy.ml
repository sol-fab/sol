open Cmdliner
open Sol_cli_manifest
open Sol_cli_helm
open Result.Syntax

(* Establishing local prerequisites (cluster, infrastructure, port-forwards) is
   part of the local deploy, so one command takes a workspace from nothing to
   running workloads. It is idempotent: an existing cluster and its data are
   reused, never recreated, so a re-run cannot lose local state. *)

let check_tool name install_url =
  match Sol_cli_process.run (Sol_cli_process.cmd [ "which"; name ]) with
  | Ok _ -> Ok ()
  | Error _ ->
    Error
      (Sol_cli_exit.error
         (Printf.sprintf "%S not found in PATH.\n  Install: %s" name install_url))
;;

let require_tools () =
  let* () = check_tool "k3d" "https://k3d.io/" in
  let* () = check_tool "helm" "https://helm.sh/" in
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/"
;;

let helm_install_job (release : Sol_cli_local_platform.release)
  : Sol_cli_local_infra.install
  =
  { label = release.label
  ; run =
      (fun () ->
        upgrade_install
          ~ctx:Sol_cli_kube_destination.local_context
          ~release:release.name
          ~chart:release.chart
          ~namespace:release.namespace
          ?version:release.version
          ~values:release.values
          ?values_yaml:release.values_yaml
          ()
        |> Result.map ignore
        |> Result.map_error (function
          | Sol_cli_process.Non_zero r -> Sol_cli_process.failure_message r
          | e -> Sol_cli_process.error_to_string e))
  }
;;

let apply_yaml yaml =
  Sol_cli_fs.with_temp_file ~prefix:"sol-local-" ~suffix:".yaml" yaml (fun file ->
    Sol_cli_kubectl.apply ~ctx:Sol_cli_kube_destination.local_context ~file
    |> Result.map_error Sol_cli_process.error_to_string)
  |> Result.join
  |> Result.map_error (fun msg -> Sol_cli_exit.error ("kubectl apply failed: " ^ msg))
;;

let install_local_grafana_config ~dashboards ~prometheus ~tempo =
  let* () = apply_yaml dashboards in
  let* () =
    apply_yaml
      (Sol_cli_dev_observability.loki_datasource_configmap_yaml
         ~namespace:Sol_cli_manifest.monitoring_namespace)
  in
  let* () =
    if prometheus
    then
      apply_yaml
        (Sol_cli_dev_observability.prometheus_datasource_configmap_yaml
           ~namespace:Sol_cli_manifest.monitoring_namespace)
    else Ok ()
  in
  if tempo
  then
    apply_yaml
      (Sol_cli_dev_observability.tempo_datasource_configmap_yaml
         ~namespace:Sol_cli_manifest.monitoring_namespace)
  else Ok ()
;;

let prepare_helm_repositories_best_effort req =
  if Sol_cli_local_platform.needs_any_chart req
  then (
    Sol_cli_local_platform.repositories
    |> List.iter (fun (name, url) ->
      Sol_cli_helm.repo_add ~name ~url
      |> Result.iter_error (fun e ->
        Printf.eprintf
          "warning: helm repo add %s: %s\n%!"
          name
          (Sol_cli_process.error_to_string e)));
    Sol_cli_helm.repo_update ()
    |> Result.iter_error (fun e ->
      Printf.eprintf
        "warning: helm repo update: %s\n%!"
        (Sol_cli_process.error_to_string e)))
;;

let install_releases ~req ~local =
  Sol_cli_local_platform.releases ~req ~assets:local
  |> List.map helm_install_job
  |> Sol_cli_local_infra.run_bounded
  |> Sol_cli_exit.of_msg
;;

let deploy_infra ~(req : Sol_cli_workspace.infra_requirements) ~local =
  prepare_helm_repositories_best_effort req;
  let* () = install_releases ~req ~local in
  if Sol_cli_local_platform.needs_grafana req
  then
    install_local_grafana_config
      ~dashboards:local.dashboards
      ~prometheus:req.prometheus
      ~tempo:req.tempo
  else Ok ()
;;

let endpoint_start (e : Sol_cli_local_platform.endpoint) : Sol_cli_local_infra.endpoint =
  { Sol_cli_local_infra.endpoint_label = e.forward.name
  ; endpoint_required = e.required
  ; endpoint_start =
      (fun () ->
        Printf.printf
          "  port-forward  %-14s localhost:%d → %s/%s:%d (waiting for readiness)\n%!"
          e.forward.name
          e.forward.local_port
          e.forward.namespace
          e.forward.target
          e.forward.remote_port;
        Sol_cli_port_forward.ensure_ready
          ~ctx:Sol_cli_kube_destination.local_context
          e.forward
        |> Result.map_error Sol_cli_port_forward.readiness_error_to_string)
  ; endpoint_stop = (fun () -> Sol_cli_port_forward.stop e.forward.name)
  }
;;

let print_endpoint_summary endpoints outcomes =
  Printf.printf "\n";
  Printf.printf "  cluster      ✓  %s\n" Sol_cli_local_cluster.name;
  Printf.printf "  registry     ✓  localhost:%d\n" Sol_cli_local_cluster.registry_port;
  List.iter2
    (fun (e : Sol_cli_local_platform.endpoint) outcome ->
       match outcome with
       | Sol_cli_local_infra.Ready -> print_endline e.summary
       | Sol_cli_local_infra.Optional_unavailable message ->
         Printf.printf "  %-14s –  optional; not available (%s)\n" e.forward.name message)
    endpoints
    outcomes;
  Printf.printf "\n"
;;

let start_port_forwards ~(req : Sol_cli_workspace.infra_requirements) =
  let endpoints = Sol_cli_local_platform.endpoints ~req in
  let* outcomes =
    endpoints
    |> List.map endpoint_start
    |> Sol_cli_local_infra.bring_up_endpoints
    |> Sol_cli_exit.of_msg
  in
  print_endpoint_summary endpoints outcomes;
  Ok ()
;;

let establish_prerequisites ~root =
  let* () = require_tools () in
  let* () = Sol_cli_state.ensure () |> Result.map_error Sol_cli_exit.error in
  Sol_cli_port_forward.stop_all ();
  Printf.printf "\nEstablishing local prerequisites...\n%!";
  Printf.printf "\n[1/4] Provisioning local cluster...\n%!";
  let* () = Sol_cli_local_cluster.provision () |> Result.map_error Sol_cli_exit.error in
  Printf.printf "\n[2/4] Reading the workspace's declared resources...\n%!";
  let* req =
    Sol_cli_config.local_infra ~root
    |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
  in
  Printf.printf
    "  kafka=%-5b  postgres=%-5b  loki=%-5b  prometheus=%-5b  tempo=%b\n%!"
    req.kafka
    req.postgres
    req.loki
    req.prometheus
    req.tempo;
  let* local = Sol_cli_local_platform.read_assets () |> Sol_cli_exit.of_msg in
  Printf.printf "\n[3/4] Deploying local infrastructure...\n%!";
  let* () = deploy_infra ~req ~local in
  Printf.printf "\n[4/4] Starting and verifying port-forwards...\n%!";
  start_port_forwards ~req
;;

(* Local workload deploy (formerly `sol up`). *)

let print_header ~workspace ~sha ~dry_run =
  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  if dry_run then Printf.printf "(dry-run)\n";
  Printf.printf "\n%!"
;;

let build_plan ~requested_scope ~workspace ~sha ~facts ~declared ~services =
  Sol_cli_up_execution.local_plan
    ~requested_scope
    ~workspace
    ~sha
    ~facts
    ~declared
    services
  |> Sol_cli_exit.of_error Sol_cli_deployment_plan.plan_error_to_string
;;

let check_contract ~facts ~services =
  let findings = Sol_cli_check.run_services ~facts services in
  findings
  |> List.iter (fun f -> Printf.eprintf "%s\n" (Sol_cli_check.finding_to_string f));
  if Sol_cli_check.has_errors findings then Error (Sol_cli_exit.reported ()) else Ok ()
;;

let ensure_postgres_url () =
  match Sol_cli_string.env "POSTGRES_URL" with
  | None ->
    Unix.putenv
      "POSTGRES_URL"
      "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"
  | Some _ -> ()
;;

let to_manifest_primitive = Sol_cli_up_execution.manifest_primitive

let print_service_start spec =
  Printf.printf
    "[%s] %s/%s\n%!"
    (primitive_label (to_manifest_primitive spec.Sol_cli_deployment_plan.primitive))
    spec.domain
    spec.source_name
;;

let dry_run_service
      ~workspace
      ~sha
      ~release_id
      (spec : Sol_cli_deployment_plan.service_spec)
  =
  print_service_start spec;
  Sol_cli_up_execution.apply_service_manifest
    ~ctx:Sol_cli_kube_destination.local_context
    ~workspace
    ~release_id
    ~dry_run:true
    (Sol_cli_up_execution.dry_run_spec ~workspace ~sha spec)
  |> Result.map ignore
;;

let deploy_service
      ~workspace
      ~ctx_dir
      ~sha
      ~release_id
      ~restart_secret
      (spec : Sol_cli_deployment_plan.service_spec)
  =
  let exec = Sol_cli_up_execution.service_execution ~workspace ~ctx_dir ~sha spec in
  print_service_start spec;
  Printf.printf "  packaging %s...\n%!" exec.push_image;
  let* () = Sol_cli_up_execution.build_image exec in
  Printf.printf "  pushing...\n%!";
  let* () = Sol_cli_up_execution.push_image exec in
  let* _ =
    Sol_cli_up_execution.apply_service_manifest
      ~ctx:Sol_cli_kube_destination.local_context
      ~workspace
      ~release_id
      ~dry_run:false
      spec
  in
  let* () =
    match restart_secret, spec.primitive with
    | true, (Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker) ->
      let namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace in
      let name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
      Sol_cli_kubectl.rollout_restart
        ~ctx:Sol_cli_kube_destination.local_context
        ~kind:("deployment/" ^ name)
        ~namespace
      |> Result.map ignore
      |> Result.map_error (fun error ->
        Printf.sprintf
          "local secret values were applied for %s/%s, but the workload restart failed: \
           %s"
          namespace
          name
          (Sol_cli_process.error_to_string error))
    | _ -> Ok ()
  in
  let* () =
    match spec.primitive with
    | Sol_cli_deployment_plan.Fn -> Ok ()
    | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
      Printf.printf "  waiting for rollout...\n%!";
      Sol_cli_up_execution.wait_for_service_rollout
        ~ctx:Sol_cli_kube_destination.local_context
        spec
        exec
  in
  Ok exec
;;

let expose_service
      ~pf_failed
      (spec : Sol_cli_deployment_plan.service_spec)
      (exec : Sol_cli_up_execution.service_execution)
  =
  let k8s_name = Sol_cli_deployment_plan.k8s_name_to_string exec.k8s_name in
  let namespace = Sol_cli_deployment_plan.namespace_to_string exec.namespace in
  match spec.primitive with
  | Sol_cli_deployment_plan.Svc ->
    let local_port = 8080 in
    let pf_name = Printf.sprintf "%s-%s" namespace k8s_name in
    let target = "svc/" ^ k8s_name in
    if not (Sol_cli_port_forward.is_running pf_name)
    then (
      let replaced =
        Sol_cli_port_forward.replace_conflicting ~local_port ~namespace ~target
      in
      replaced
      |> List.iter (fun (old : Sol_cli_port_forward.spec) ->
        Printf.printf
          "  [sol local deploy] replacing stale port-forward for %s/%s on port %d\n%!"
          old.namespace
          old.target
          local_port);
      if replaced <> [] then Unix.sleepf 0.4;
      Sol_cli_port_forward.start
        ~ctx:Sol_cli_kube_destination.local_context
        { name = pf_name; namespace; target; local_port; remote_port = 80 }
      |> Result.iter_error (Printf.eprintf "  warning: port-forward not started: %s\n%!"));
    let pf_alive =
      match Sol_cli_port_forward.check_alive ~name:pf_name with
      | Alive -> true
      | Dead { log; log_tail } ->
        Printf.printf
          "  warning: port-forward for %s failed (port %d may be in use by another \
           workspace).\n"
          pf_name
          local_port;
        Printf.printf "           See %s for details.\n" log;
        if log_tail <> []
        then
          Printf.printf
            "           Last log lines:\n             %s\n"
            (String.concat "\n             " log_tail);
        Printf.printf
          "           Run: kill $(lsof -ti:%d) && sol local deploy\n%!"
          local_port;
        false
    in
    Printf.printf "  ✓  namespace %s  image %s\n%!" namespace spec.image;
    if pf_alive
    then
      Printf.printf
        "  →  http://localhost:%d  (port-forward running in background)\n\n%!"
        local_port
    else (
      pf_failed := true;
      Printf.printf "\n%!")
  | _ ->
    Printf.printf "  ✓  namespace %s  image %s\n%!" namespace spec.image;
    Printf.printf "\n%!"
;;

let apply_service ~workspace ~ctx_dir ~sha ~pf_failed ~release_id ~restart_secret spec =
  let* exec = deploy_service ~workspace ~ctx_dir ~sha ~release_id ~restart_secret spec in
  expose_service ~pf_failed spec exec;
  Ok ()
;;

let record_plan run_log plan =
  Sol_cli_run_log.append_phase_log
    run_log
    ~phase:"plan"
    (Format.asprintf "%a" Sol_cli_deployment_plan.pp_summary plan)
;;

let cluster = Sol_cli_kube_destination.local_context

let observed_contract ~workspace =
  Sol_cli_release_store.deployed_contract ~ctx:cluster ~workspace
;;

let load_local_secret_values ~root ~facts services =
  services
  |> Sol_cli_result.map_list (fun (service : Sol_cli_manifest.service) ->
    let unit_address = service.domain ^ "/" ^ service.name in
    let* workload =
      match
        List.find_opt
          (fun (workload : Sol_cli_workspace_model.workload) ->
             String.equal workload.service.domain service.domain
             && String.equal workload.service.name service.name)
          facts.Sol_cli_workspace_model.workloads
      with
      | None -> Error (service.name ^ " is not part of the loaded workspace")
      | Some workload -> Ok workload
    in
    let* secret_keys =
      match workload.config with
      | Ok config -> Ok config.Sol_cli_toml.secret_keys
      | Error error -> Error (Sol_cli_toml.parse_error_to_string error)
    in
    let required = Sol_cli_manifest.required_secret_keys secret_keys in
    let* values =
      Sol_cli_local_secret_input.load ~root ~unit_address
      |> Result.map_error (fun error -> service.name ^ ": " ^ error)
    in
    let missing =
      required
      |> List.filter (fun key ->
        match List.assoc_opt key values with
        | Some value when String.trim value <> "" -> false
        | _ -> true)
      |> List.sort_uniq String.compare
    in
    match missing with
    | [] -> Ok (unit_address, List.filter (fun (key, _) -> List.mem key required) values)
    | _ ->
      Error
        (Printf.sprintf
           "%s is missing local secret value(s): %s. Add them to \
            sol/secrets.local/%s.env."
           unit_address
           (String.concat ", " missing)
           unit_address))
  |> Sol_cli_exit.of_msg
;;

let apply_local_secret_values ~secret_values (plan : Sol_cli_deployment_plan.t) =
  plan.services
  |> List.fold_left
       (fun acc (spec : Sol_cli_deployment_plan.service_spec) ->
          let* changed_units = acc in
          let unit_address = spec.domain ^ "/" ^ spec.source_name in
          let required =
            Sol_cli_manifest.required_secret_keys
              ~transport:(Sol_cli_manifest.kafka_transport_of_config spec.config)
              (List.map fst spec.secrets)
          in
          let values =
            Option.value ~default:[] (List.assoc_opt unit_address secret_values)
            |> List.filter (fun (key, _) -> List.mem key required)
          in
          let secret_name =
            Sol_cli_manifest.workload_secret_name
              (Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name)
          in
          let* changed =
            Sol_cli_secret.apply_unit_values
              ~ctx:cluster
              ~namespace:(Sol_cli_deployment_plan.namespace_to_string spec.namespace)
              ~secret_name
              values
            |> Result.map_error (fun error ->
              Printf.sprintf "could not write local values for %s: %s" unit_address error)
          in
          Ok (if changed then unit_address :: changed_units else changed_units))
       (Ok [])
;;

let prepare_plan
      ~run_log
      ~dry_run
      ~requested_scope
      ~workspace
      ~sha
      ~facts
      ~declared
      ~services
  =
  print_header ~workspace ~sha ~dry_run;
  let* plan = build_plan ~requested_scope ~workspace ~sha ~facts ~declared ~services in
  let* observed =
    observed_contract ~workspace |> Sol_cli_exit.of_error (fun msg -> msg)
  in
  let* plan =
    Sol_cli_deployment_plan.with_observed_contract ~observed plan
    |> Sol_cli_exit.of_error Sol_cli_deployment_plan.plan_error_to_string
  in
  (match plan.Sol_cli_deployment_plan.contract_changes with
   | [] -> ()
   | changes ->
     Printf.printf "\nContract changes:\n%!";
     changes
     |> List.iter (fun change ->
       Printf.printf "  %s\n%!" (Sol_cli_deployment_plan.contract_change_to_string change)));
  record_plan run_log plan;
  Ok plan
;;

let run_failed msg = Sol_cli_exit.failure ("\nerror: " ^ msg)

let run_dry_run ~run_log ~requested_scope ~workspace ~sha ~facts ~declared ~services =
  let* plan =
    prepare_plan
      ~run_log
      ~dry_run:true
      ~requested_scope
      ~workspace
      ~sha
      ~facts
      ~declared
      ~services
  in
  Result.map_error run_failed
  @@ Sol_cli_run_log.run_task run_log ~name:"dry-run" (fun () ->
    plan.services
    |> List.fold_left
         (fun acc spec ->
            let* () = acc in
            dry_run_service
              ~workspace
              ~sha
              ~release_id:
                (Sol_cli_deployment_plan.workload_release_id
                   ~workspace:plan.Sol_cli_deployment_plan.workspace
                   ~environment:plan.Sol_cli_deployment_plan.environment.env
                   spec)
              spec)
         (Ok ()))
;;

let apply_plan ~secret_values ~run_log ~workspace ~sha ~repo_root ~pf_failed ~lease plan =
  Sol_cli_run_log.run_task run_log ~name:"apply" (fun () ->
    let* () = Sol_cli_boundary_lease.ensure_held lease in
    let* changed_units = apply_local_secret_values ~secret_values plan in
    let* () =
      Sol_cli_local_platform.with_schema_registry_endpoint (fun ~url ->
        Sol_cli_contract.report
          ~workspace:repo_root
          ~registry_url:url
          ~scope:plan.Sol_cli_deployment_plan.requested_scope
          ~mode:Sol_cli_contract.Apply)
    in
    plan.services
    |> List.fold_left
         (fun acc spec ->
            let* () = acc in
            let* () = Sol_cli_boundary_lease.ensure_held lease in
            apply_service
              ~workspace
              ~ctx_dir:repo_root
              ~sha
              ~pf_failed
              ~restart_secret:
                (List.mem (spec.domain ^ "/" ^ spec.source_name) changed_units)
              ~release_id:
                (Sol_cli_deployment_plan.workload_release_id
                   ~workspace:plan.Sol_cli_deployment_plan.workspace
                   ~environment:plan.Sol_cli_deployment_plan.environment.env
                   spec)
              spec)
         (Ok ()))
;;

let report_surplus_workloads ~workspace (plan : Sol_cli_deployment_plan.t) =
  if String.equal plan.requested_scope "workspace"
  then (
    match Sol_cli_rollback.live_workloads ~ctx:cluster ~workspace with
    | Error _ -> ()
    | Ok live ->
      let surplus = Sol_cli_rollback.unexpected_workloads ~expected:plan.services ~live in
      if surplus <> []
      then (
        Printf.printf
          "\nNote: %d live workload(s) in this workspace are not part of this deploy:\n"
          (List.length surplus);
        surplus
        |> List.iter (fun ((id : Sol_cli_rollback.workload_identity), _) ->
          Printf.printf
            "  %s %s/%s\n"
            (Sol_cli_rollback.kind_resource id.kind)
            id.namespace
            id.name);
        Printf.printf
          "These may be stale from a removed/renamed service. 'sol rollback' prunes them \
           automatically when restoring a recorded release; delete them by hand if you \
           want them gone now.\n\
           %!"))
;;

let report_apply_success ~workspace ~facts plan =
  let summary = Sol_cli_up_execution.post_deploy_summary ~facts plan in
  Printf.printf "Done. %d service(s) deployed.\n" summary.deployed_count;
  Printf.printf "Use kubectl to inspect the local workloads.\n";
  if summary.pending_migrations > 0
  then
    Printf.printf
      "\n\
       Note: %d migration file(s) found in db/migrations/ — run 'sol migrate' to apply.\n"
      summary.pending_migrations;
  report_surplus_workloads ~workspace plan
;;

let run_apply
      ~run_log
      ~requested_scope
      ~workspace
      ~sha
      ~facts
      ~declared
      ~services
      ~repo_root
      ~confirm_group_change
      ~keep_releases
      ~secret_values
  =
  let* () = check_contract ~facts ~services in
  ensure_postgres_url ();
  print_header ~workspace ~sha ~dry_run:false;
  let* plan = build_plan ~requested_scope ~workspace ~sha ~facts ~declared ~services in
  let pf_failed = ref false in
  let result =
    Sol_cli_deploy_run.run_lifecycle
      ~cluster
      ~workspace
      ~sha
      ~run_log
      ~keep_releases
      ~confirm_group_change
      ~present_plan:(fun plan ->
        (match plan.Sol_cli_deployment_plan.contract_changes with
         | [] -> ()
         | changes ->
           Printf.printf "\nContract changes:\n%!";
           changes
           |> List.iter (fun change ->
             Printf.printf
               "  %s\n%!"
               (Sol_cli_deployment_plan.contract_change_to_string change)));
        Ok ())
      ~gates:(fun _ -> Ok ())
      ~database_setup:(fun () -> Ok ())
      ~post_setup_gates:(fun _ -> Ok ())
      ~before_apply:(fun _ -> Ok ())
      ~apply:(fun ~lease ~release_id:_ plan ->
        apply_plan
          ~secret_values
          ~run_log
          ~workspace
          ~sha
          ~repo_root
          ~pf_failed
          ~lease
          plan
        |> Result.map (fun () -> []))
      ~report_success:(fun plan _ -> report_apply_success ~workspace ~facts plan)
      ~push_events:(fun ~release_id:_ _ -> ())
      plan
  in
  Result.map_error run_failed
  @@ let* () = result in
     if !pf_failed then Error "one or more port-forwards failed" else Ok ()
;;

let run (req : Sol_cli_command_request.local_deploy_request) =
  let* { root = repo_root; name = workspace } = Sol_cli_workspace.enter_cwd () in
  let sha = req.image_tag in
  let* facts = Sol_cli_workspace_model.load ~root:repo_root |> Sol_cli_exit.of_msg in
  let* declared =
    Sol_cli_config.load_declared ~root:repo_root
    |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
  in
  let inventory = Sol_cli_workspace_model.services facts in
  let* { requested_scope; services; _ } =
    Sol_cli_workload_selection.resolve_nonempty
      ~none:"no services found in app/ with a Dockerfile"
      req.scope
      inventory
    |> Sol_cli_exit.of_msg
  in
  let* secret_values =
    match req.mode with
    | Sol_cli_command_request.Dry_run -> Ok []
    | Apply -> load_local_secret_values ~root:repo_root ~facts services
  in
  let* () =
    match req.mode with
    | Sol_cli_command_request.Dry_run -> Ok ()
    | Apply -> establish_prerequisites ~root:repo_root
  in
  let run_log = Sol_cli_run_log.create ~prefix:"local-deploy" () in
  Printf.printf
    "\nRun: %s\n  log: %s/\n"
    (Sol_cli_run_log.run_id run_log)
    (Sol_cli_run_log.dir run_log);
  match req.mode with
  | Sol_cli_command_request.Dry_run ->
    run_dry_run ~run_log ~requested_scope ~workspace ~sha ~facts ~declared ~services
  | Apply ->
    run_apply
      ~run_log
      ~requested_scope
      ~workspace
      ~sha
      ~facts
      ~declared
      ~services
      ~repo_root
      ~confirm_group_change:req.confirm_group_change
      ~keep_releases:req.keep_releases
      ~secret_values
;;

let scope_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info
        [ "scope" ]
        ~docv:"DOMAIN[/UNIT]"
        ~doc:
          "Build and deploy one domain (`payments`) or one unit (`payments/charge_svc`). \
           Omit to deploy the whole workspace. A name that matches nothing fails closed \
           and says what does, before any image is built.")
;;

let dry_run_flag =
  Arg.(
    value
    & flag
    & info
        [ "dry-run" ]
        ~doc:
          "Print synthesized YAML to stdout without establishing local prerequisites or \
           applying to the cluster")
;;

let tag_arg =
  Arg.(
    value
    & opt (some Sol_cli_args.text) None
    & info [ "tag" ] ~docv:"TAG" ~doc:"Docker image tag (default: short git SHA)")
;;

let confirm_group_change_flag =
  Arg.(
    value
    & flag
    & info
        [ "confirm-group-change" ]
        ~doc:"Acknowledge that consumer group IDs have changed and proceed with deploy")
;;

let keep_releases_arg =
  Arg.(
    value
    & opt int Sol_cli_release_retention.default_keep
    & info
        [ "keep-releases" ]
        ~docv:"N"
        ~doc:
          (Printf.sprintf
             "Keep the last N release records after a successful deploy (default %d). \
              The current and previous release are never pruned. Deployment-event \
              history is not affected."
             Sol_cli_release_retention.default_keep))
;;

let cmd =
  Cmd.v
    (Cmd.info
       "deploy"
       ~doc:
         "Build images, synthesize k8s manifests, and deploy to the local cluster, \
          establishing its prerequisites (k3d cluster, infrastructure, port-forwards) \
          first. Local-only — no target concept, unlike 'sol deploy'.")
    Term.(
      const (fun scope dry_run tag confirm_group_change keep_releases ->
        let result =
          let* req =
            Sol_cli_command_request.make_local_deploy_request
              ~scope
              ~dry_run
              ~tag
              ~confirm_group_change
              ~keep_releases
              ~git_sha:Sol_cli_command_request.git_sha
            |> Sol_cli_exit.of_msg
          in
          Option.iter (Printf.eprintf "warning: %s\n") req.image_tag_warning;
          run req
        in
        Sol_cli_exit.exit_on result)
      $ scope_arg
      $ dry_run_flag
      $ tag_arg
      $ confirm_group_change_flag
      $ keep_releases_arg)
;;
